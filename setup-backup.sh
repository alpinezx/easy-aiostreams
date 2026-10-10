#!/usr/bin/env bash
#
# Backup and restore for Easy AIOStreams.
#
#   sudo bash /opt/aiostreams/setup-backup.sh                  menu
#   sudo bash /opt/aiostreams/setup-backup.sh backup           make a backup
#   sudo bash /opt/aiostreams/setup-backup.sh restore [file]   restore one
#
# setup-aiostreams.sh's own "backup" and "restore" commands and menu
# options hand over to this script, so either way works.

set -euo pipefail

# Resolved here, before anything can cd elsewhere.
SELF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF_SCRIPT_PATH")"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;31m!! %s !!\033[0m\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Everything lives in /opt/aiostreams: one folder for root and every user.
OPT_INSTALL_DIR="/opt/aiostreams"
INSTALL_DIR="$OPT_INSTALL_DIR"

# Installs made before October 2026 live in root's home instead. These
# scripts don't work with that layout: stop rather than mistake the server
# for one without an install. setup-aiostreams.sh offers the move.
for _old in "$(getent passwd root 2>/dev/null | cut -d: -f6)/aiostreams" "${HOME:-/root}/aiostreams"; do
    if [[ "$_old" == /*/aiostreams && "$_old" != "$INSTALL_DIR" && ! -L "$_old" \
        && -f "$_old/docker-compose.yml" && ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        echo "This server's AIOStreams install is still in $_old, where installs made"
        echo "before October 2026 live. It now belongs in $INSTALL_DIR. To move it, run:"
        echo "  sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiostreams.sh -o $_old/setup-aiostreams.sh"
        echo "  sudo bash $_old/setup-aiostreams.sh"
        echo "or follow https://github.com/alpinezx/easy-aiostreams/tree/migrate-to-opt"
        exit 1
    fi
done
unset _old
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"

# Where a missing setup-aiostreams.sh is fetched from. AIOS_BRANCH=dev to test.
RAW_BASE="https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/${AIOS_BRANCH:-main}"

# Root's home: where backup tarballs are written. Looked up rather than
# taken from $HOME, so a caller with HOME set elsewhere can't scatter
# tarballs into odd places.
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"
ROOT_HOME="${ROOT_HOME:-/root}"
BACKUP_HOME="$ROOT_HOME"

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# Under sudo, $HOME is root's home, not the invoking user's, so a backup
# tarball scp'd into the user's own home wouldn't be found. Defaults to
# root's home, not $HOME, so a caller with HOME set elsewhere doesn't get a
# stray "user copy" of each backup there.
REAL_HOME="$ROOT_HOME"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    [[ -n "$sudo_home" && -d "$sudo_home" ]] && REAL_HOME="$sudo_home"
fi

for REQUIRED_CMD in curl tar; do
    require_cmd "$REQUIRED_CMD" || error "Required command '$REQUIRED_CMD' not found. Install it first (e.g. 'apt-get install -y $REQUIRED_CMD') and re-run this script."
done

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

do_backup() {
    [[ -f "$COMPOSE_FILE" ]] || error "No installation found at $INSTALL_DIR, nothing to back up."

    info "Backing up $INSTALL_DIR"
    echo "Included: compose files (SECRET_KEY + logins), Caddyfile + drop-ins,"
    echo "AIOStreams user configs (./data), vpn-state (WireGuard private key,"
    echo "if the VPN layer was ever set up), webhook-relay-state (if that bolt-on"
    echo "was ever set up), and any original WireGuard .conf"
    echo "file(s) found in /root or your home directory (staged as a convenience"
    echo "copy, not required for the VPN layer itself to keep working)."
    echo "NOT included: Caddy's HTTPS certificates (they live in named Docker volumes"
    echo "and are re-issued automatically on any new server, dead weight in a backup)."
    echo ""

    if [[ -d "$INSTALL_DIR/watchdog-state" ]]; then
        if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
            touch "$INSTALL_DIR/watchdog-state/was-active-at-backup"
        else
            rm -f "$INSTALL_DIR/watchdog-state/was-active-at-backup"
        fi
    fi

    # Same idea as the watchdog marker above, but keyed on the container
    # actually running rather than a systemd timer, since the webhook relay
    # is a separate docker compose stack, not a systemd unit.
    if [[ -d "$INSTALL_DIR/webhook-relay-state" ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aios-webhook-relay; then
            touch "$INSTALL_DIR/webhook-relay-state/was-active-at-backup"
        else
            rm -f "$INSTALL_DIR/webhook-relay-state/was-active-at-backup"
        fi
    fi

    # Same idea again for MediaFlow Proxy Light: a separate compose stack on
    # aios_shared, not part of the main docker-compose.yml, so it needs its
    # own was-active marker to know whether to bring it back on restore.
    if [[ -d "$INSTALL_DIR/mediaflow-state" ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mediaflow-proxy-light; then
            touch "$INSTALL_DIR/mediaflow-state/was-active-at-backup"
        else
            rm -f "$INSTALL_DIR/mediaflow-state/was-active-at-backup"
        fi
    fi

    if [[ -d "$INSTALL_DIR/vpn-state" ]]; then
        local conf_stage_dir="$INSTALL_DIR/vpn-state/original-confs"
        rm -rf "$conf_stage_dir"
        local conf_scan_dirs=("/root")
        [[ "$REAL_HOME" != "/root" ]] && conf_scan_dirs+=("$REAL_HOME")
        local conf_candidates=() conf_staged_count=0 conf_staged_names=() f
        while IFS= read -r -d '' f; do
            conf_candidates+=("$f")
        done < <(find "${conf_scan_dirs[@]}" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)
        for f in "${conf_candidates[@]}"; do
            if grep -qi '^\[Interface\]' "$f" 2>/dev/null && \
               grep -qi '^\[Peer\]' "$f" 2>/dev/null && \
               grep -qi '^PrivateKey' "$f" 2>/dev/null && \
               grep -qi '^Endpoint' "$f" 2>/dev/null; then
                local dest_subdir="user"
                [[ "$(dirname "$f")" == "/root" ]] && dest_subdir="root"
                mkdir -p "$conf_stage_dir/$dest_subdir"
                if cp -- "$f" "$conf_stage_dir/$dest_subdir/$(basename "$f")" 2>/dev/null; then
                    chmod 600 "$conf_stage_dir/$dest_subdir/$(basename "$f")"
                    conf_staged_count=$((conf_staged_count + 1))
                    conf_staged_names+=("$f")
                fi
            fi
        done
        if (( conf_staged_count > 0 )); then
            echo "Also staging $conf_staged_count original WireGuard .conf file(s) for restore convenience:"
            for f in "${conf_staged_names[@]}"; do
                echo "  - $f"
            done
            echo ""
        fi
    fi

    local ts out size ip tar_status user_copy=""
    ts=$(date +%Y%m%d-%H%M%S)
    out="$BACKUP_HOME/aiostreams-backup-${ts}.tar.gz"
    # umask is process-wide, so scope it to a subshell so it doesn't leak
    # into files written later this session.
    # caddy-logs is MediaFlow's access log for fail2ban: regenerated on its
    # own, can grow to around 1GB, and holds full stream URLs (which can
    # include the MediaFlow API password). Nothing a restore needs.
    if ( umask 077; tar --warning=no-file-changed --exclude="$(basename "$INSTALL_DIR")/caddy-logs" \
            -czf "$out" -C "$(dirname "$INSTALL_DIR")" "$(basename "$INSTALL_DIR")" ); then
        tar_status=0
    else
        tar_status=$?
    fi
    # GNU tar: 0 = clean, 1 = file changed while being read (archive still
    # usable), 2+ = genuinely failed.
    if (( tar_status > 1 )); then
        rm -f "$out"
        error "Backup failed. The archive was removed and no backup was written."
    fi
    if (( tar_status == 1 )); then
        warn "Some files changed while the archive was being read. The backup is complete and"
        warn "restorable, but data written during the sweep may not be captured consistently."
    fi
    chmod 600 "$out"
    size=$(du -h "$out" | cut -f1)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    echo -e "Backup written: \033[1;36m$out\033[0m (${size})"

    # Under sudo, $REAL_HOME differs from root's home, also drop a copy
    # there so the invoking user can access it directly.
    if [[ "$REAL_HOME" != "$BACKUP_HOME" ]]; then
        user_copy="$REAL_HOME/aiostreams-backup-${ts}.tar.gz"
        if cp -- "$out" "$user_copy" 2>/dev/null; then
            chmod 600 "$user_copy"
            if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
                chown "$SUDO_UID:$SUDO_GID" "$user_copy" 2>/dev/null || true
            fi
            echo -e "Also copied to: \033[1;36m$user_copy\033[0m (owned by $SUDO_USER, so you can scp it directly)"
        else
            warn "Could not also copy the backup to $REAL_HOME. The copy in $BACKUP_HOME above is still good."
            user_copy=""
        fi
    fi
    echo ""
    echo "Copy it OFF this server now, from your local machine:"
    if [[ -n "$user_copy" ]]; then
        echo -e "  \033[1;36mscp ${SUDO_USER}@${ip:-<server-ip>}:${user_copy} .\033[0m"
    else
        echo -e "  \033[1;36mscp root@${ip:-<server-ip>}:${out} .\033[0m"
    fi
    echo ""
    echo "To move to a new server: copy the tarball over, download setup-aiostreams.sh"
    echo "there as in the Quick start, then run:"
    echo -e "  \033[1;36msudo bash setup-aiostreams.sh restore aiostreams-backup-${ts}.tar.gz\033[0m"
    echo ""
    warn "This file contains your SECRET_KEY, all logins, and (if present) your"
    warn "WireGuard PRIVATE KEY. Treat it like a password: store it somewhere"
    warn "encrypted, never share it, and delete old copies you no longer need."
    if [[ -n "$user_copy" ]]; then
        warn "That applies to BOTH copies above, delete the one in $BACKUP_HOME too once you're done."
    fi
    if [[ -t 0 ]]; then
        read -rp "Continue now that you've read this... " _
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Restore helpers
# ---------------------------------------------------------------------------

# Files outside the install folder that can have its absolute path written
# into them by the add-on scripts.
INSTALL_PATH_EXTERNAL_FILES=(
    /etc/systemd/system/aiostreams-watchdog.service
    /etc/systemd/system/aios-webhook-boot-notify.service
    /etc/systemd/system/aiostreams-vpn-boot.service
    /usr/local/bin/aiostreams-vpn-boot.sh
    /etc/fail2ban/jail.d/aios-mediaflow.conf
)

# NUL-separated list of every small config file that can name the install
# folder: the external files above, plus compose files, configs, env files
# and Caddy files inside it. Never ./data, logs, or the panel's source copy.
install_path_files() {
    local dir="$1" f
    for f in "${INSTALL_PATH_EXTERNAL_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            printf '%s\0' "$f"
        fi
    done
    find "$dir" -maxdepth 3 \
        \( -path "$dir/data" -o -path "$dir/caddy-logs" -o -path "$dir/ui-state/src" \) -prune -o \
        -type f -size -1024k \
        \( -name '*.yml' -o -name '*.yaml' -o -name '*.env' -o -name 'config' -o -name '*.caddy' -o -name 'Caddyfile*' \) \
        -print0 2>/dev/null
}

# Replaces the folder path FROM with TO wherever FROM appears as a whole path
# (followed by /, :, a quote, a space or the end of the line), so a name like
# /root/aiostreams-backup-... is never touched. Sets REWRITTEN_FILES.
rewrite_install_paths() {
    local from="$1" to="$2" dir="$3" f re
    REWRITTEN_FILES=()
    re=$(printf '%s' "$from" | sed 's/[][\.*^$+?(){}|#]/\\&/g')
    while IFS= read -r -d '' f; do
        grep -qF -- "$from" "$f" 2>/dev/null || continue
        sed -i -E "s#${re}([/:\"'[:space:]]|\$)#${to}\\1#g" "$f"
        REWRITTEN_FILES+=("$f")
    done < <(install_path_files "$dir")
    return 0
}

check_restored_domain_dns() {
    [[ -f "$CADDYFILE" ]] || return 0   # nothing to check against
    local domain
    domain=$(head -n1 "$CADDYFILE" | awk '{print $1}')
    [[ -n "$domain" ]] || return 0

    local retry_interval="${DNS_RETRY_INTERVAL:-15}"
    local retry_max="${DNS_RETRY_MAX:-600}"

    while true; do
        echo ""
        echo "Checking DNS for the restored domain ($domain)..."

        local resolved_ip
        if require_cmd getent; then
            resolved_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1 }' | head -n1 || true)
        else
            resolved_ip=$(ping -c1 "$domain" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' || true)
        fi

        local public_ip svc
        public_ip=""
        for svc in "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
            public_ip=$(curl -fs4 --max-time 4 "$svc" 2>/dev/null | tr -d ' \n') && [[ -n "$public_ip" ]] && break
        done

        if [[ -n "$resolved_ip" && -n "$public_ip" && "$resolved_ip" == "$public_ip" ]]; then
            echo "Resolved $domain -> $resolved_ip, matches this server. Good to go."
            return 0
        fi

        if [[ -z "$resolved_ip" ]]; then
            warn "$domain does not resolve yet."
        elif [[ -z "$public_ip" ]]; then
            warn "Resolved $domain -> $resolved_ip, but couldn't determine this server's own public IP to compare it against."
        else
            echo ""
            alert "DOMAIN / SERVER MISMATCH"
            alert "$domain currently resolves to $resolved_ip, but THIS server's public IP is $public_ip."
            alert "That usually means DNS is still pointing at the OLD server (or hasn't propagated yet)."
        fi
        warn "Starting the stack now will likely fail to get an HTTPS certificate."

        echo ""
        echo "What would you like to do?"
        echo "  1) Re-check DNS now (do this after updating your A record)"
        echo "  2) Wait and auto-retry every ${retry_interval}s (up to $((retry_max/60)) min) while DNS propagates"
        echo "  3) Enter a different domain (fixes a typo, or use a new domain for this restore)"
        echo "  4) Continue anyway (not recommended, cert will likely fail)"
        echo "  5) Abort restore"
        read -rp "Choice [1-5]: " CHOICE

        case "$CHOICE" in
            1)
                continue
                ;;
            2)
                echo "Waiting for DNS to propagate (checking every ${retry_interval}s)... Ctrl+C to stop waiting."
                local waited=0 recheck
                while (( waited < retry_max )); do
                    sleep "$retry_interval"
                    waited=$((waited + retry_interval))
                    if require_cmd getent; then
                        recheck=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1 }' | head -n1 || true)
                    else
                        recheck=$(ping -c1 "$domain" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' || true)
                    fi
                    echo "  [${waited}s] $domain -> ${recheck:-<not resolving>}"
                    if [[ -n "$recheck" && -n "$public_ip" && "$recheck" == "$public_ip" ]]; then
                        echo "DNS now matches this server."
                        return 0
                    fi
                done
                warn "Still not matching after $((retry_max/60)) minutes. Back to the menu."
                continue
                ;;
            3)
                local new_domain
                read -rp "Enter the correct domain for this instance: " new_domain
                new_domain=$(echo "$new_domain" | xargs)
                if [[ -z "$new_domain" ]]; then
                    warn "Domain cannot be empty."
                    continue
                fi
                if [[ "$new_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    warn "Please enter a domain name, not an IP address. Caddy needs a domain to issue an HTTPS certificate."
                    continue
                fi
                # Hostname-safe chars only. This gets spliced into sed
                # expressions below, so '/', '|', '{', '}', '#' would break
                # the sed call or inject a stray Caddyfile directive.
                if [[ ! "$new_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                    warn "Domain can only contain letters, numbers, dots, and hyphens (e.g. streams.example.com)."
                    continue
                fi
                sed -i "1s/.*/${new_domain} {/" "$CADDYFILE"
                # Compose file's BASE_URL must match too, or the VPN toggle
                # script would regenerate the Caddyfile from the old domain.
                if [[ -f "${COMPOSE_FILE:-}" ]]; then
                    sed -i "s|BASE_URL=https://[^\"[:space:]]*|BASE_URL=https://${new_domain}|" "$COMPOSE_FILE"
                fi
                domain="$new_domain"
                echo "Caddyfile and compose file's BASE_URL updated to use $domain. Re-checking..."
                continue
                ;;
            4)
                warn "Continuing anyway, Caddy will likely fail to get a cert until this is fixed."
                return 0
                ;;
            5)
                error "Restore aborted. Fix DNS (or the domain) and re-run restore when ready."
                ;;
            *)
                warn "Not a valid choice."
                continue
                ;;
        esac
    done
}

# Puts a saved copy of a script into the install folder when it's missing
# there or different. The copy being run wins over the backup's, so a
# restore always finishes with the newest scripts you have.
install_script_copy() {
    local src="$1" name="$2" dest="$INSTALL_DIR/$2"
    [[ -n "$src" && -f "$src" ]] || return 0
    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        cp -- "$src" "$dest" && chmod 755 "$dest"
    fi
    return 0
}

# Finds the setup-script for an add-on: the install folder first, then next
# to this script.
find_script() {
    local name="$1" candidate
    for candidate in "$INSTALL_DIR/$name" "$SELF_DIR/$name"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

do_restore() {
    local tarball="${1:-}"

    info "Restore from backup"
    if [[ -z "$tarball" ]]; then
        local candidates=() f sel
        shopt -s nullglob
        for f in "$BACKUP_HOME"/*aiostreams*.tar.gz "$REAL_HOME"/*aiostreams*.tar.gz "$PWD"/*aiostreams*.tar.gz; do
            [[ -f "$f" ]] && candidates+=("$f")
        done
        shopt -u nullglob
        if [[ ${#candidates[@]} -gt 0 ]]; then
            # newest first; awk de-dupes since these dirs often overlap
            mapfile -t candidates < <(ls -1t -- "${candidates[@]}" 2>/dev/null | awk '!seen[$0]++')
        fi

        if [[ ${#candidates[@]} -gt 0 ]]; then
            echo "Found ${#candidates[@]} backup(s) (newest first):"
            local i=1
            for f in "${candidates[@]}"; do
                printf '  %d) %s  —  %s, %s\n' "$i" "$f" \
                    "$(du -h -- "$f" | cut -f1)" \
                    "$(date -r "$f" '+%Y-%m-%d %H:%M')"
                i=$((i+1))
            done
            echo "  m) Enter a path manually"
            if [[ ${#candidates[@]} -eq 1 ]]; then
                read -rp "Select a backup [1, m] (Enter = 1): " sel
                [[ -z "$sel" ]] && sel=1
            else
                read -rp "Select a backup [1-${#candidates[@]}, m]: " sel
            fi
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#candidates[@]} )); then
                tarball="${candidates[$((sel-1))]}"
            else
                read -rp "Path to backup tarball: " tarball
            fi
        else
            if [[ "$REAL_HOME" != "$BACKUP_HOME" ]]; then
                echo "No aiostreams backup tarballs found in $BACKUP_HOME, $REAL_HOME, or the current directory."
            else
                echo "No aiostreams backup tarballs found in $BACKUP_HOME or the current directory."
            fi
            read -rp "Path to backup tarball (aiostreams-backup-*.tar.gz): " tarball
        fi
    fi
    [[ -f "$tarball" ]] || error "File not found: $tarball"
    # Absolute now, before anything below can move directories around: the
    # INSTALL_DIR-move check just below compares path prefixes. -P resolves
    # links too, so a tarball reached through ~/aiostreams still counts as
    # inside the install folder.
    tarball="$(cd "$(dirname "$tarball")" && pwd -P)/$(basename "$tarball")"
    # Captured to a variable instead of piped into grep -q: with pipefail,
    # grep exiting early on match can SIGPIPE tar and clobber tar's exit
    # status. This also distinguishes "corrupted archive" from "not ours".
    local tar_listing
    tar_listing=$(tar -tzf "$tarball" 2>&1) || \
        error "Couldn't read $tarball as a .tar.gz archive. It may be corrupted or incomplete. Try re-copying it and retry."
    grep -q 'aiostreams/docker-compose.yml' <<< "$tar_listing" || \
        error "That archive doesn't look like a backup made by this script (no aiostreams/docker-compose.yml inside)."

    # Keep the scripts being run before the install folder moves: they may
    # live in it, and they're put back into the restored one further down.
    local keep
    keep=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: $keep is local
    trap "rm -rf '$keep'" EXIT
    cp -- "$SELF_SCRIPT_PATH" "$keep/setup-backup.sh"
    local main_src="${AIOS_MAIN_SCRIPT:-}"
    [[ -n "$main_src" && -f "$main_src" ]] || main_src=$(find_script setup-aiostreams.sh)
    if [[ -n "$main_src" ]]; then
        cp -- "$main_src" "$keep/setup-aiostreams.sh"
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        warn "An installation already exists at $INSTALL_DIR."
        warn "Restoring will REPLACE it, including its SECRET_KEY. If the existing"
        warn "install has user configs the backup doesn't, those would be orphaned."
        read -rp "Move the current install aside and continue? [y/N]: " C
        if [[ ! "$C" =~ ^[Yy]$ ]]; then
            echo "Restore cancelled."
            return 0
        fi
        local aside
        aside="$(dirname "$INSTALL_DIR")/aiostreams.pre-restore-$(date +%Y%m%d-%H%M%S)"
        mv "$INSTALL_DIR" "$aside"
        echo "Current install moved aside to $aside (delete it once you're happy with the restore)."
        # A tarball sitting inside $INSTALL_DIR moved along with it.
        if [[ "$tarball" == "$INSTALL_DIR"/* ]]; then
            tarball="$aside/${tarball#"$INSTALL_DIR"/}"
            echo "(The backup tarball was inside $INSTALL_DIR, so it moved to $aside too,"
            echo " using it from its new location: $tarball)"
        fi
    fi

    if require_cmd docker; then
        info "Docker is already installed, skipping install."
    else
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
    fi
    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose plugin not found even after install. Check 'docker compose version' manually."
    fi

    info "Extracting backup"
    # Only the aiostreams/ folder: a tarball with anything else in it can't
    # drop files elsewhere (e.g. ~/.ssh). Every backup, including ones made
    # before the move to /opt, stores the folder as aiostreams/.
    mkdir -p "$(dirname "$INSTALL_DIR")"
    tar xzf "$tarball" -C "$(dirname "$INSTALL_DIR")" aiostreams
    chmod 700 "$INSTALL_DIR"   # setup-aiostreams.sh sets the final access below
    # A backup made before the move to /opt has /root/aiostreams written
    # into the add-on compose files (and the panel's). Point them here.
    local old_root
    for old_root in "$ROOT_HOME/aiostreams" "/root/aiostreams"; do
        rewrite_install_paths "$old_root" "$INSTALL_DIR" "$INSTALL_DIR"
        if (( ${#REWRITTEN_FILES[@]} > 0 )); then
            echo "Pointed ${#REWRITTEN_FILES[@]} file(s) from the backup's old folder ($old_root) at $INSTALL_DIR."
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    done
    chmod 600 "$COMPOSE_FILE" 2>/dev/null || true
    grep -q 'SECRET_KEY=' "$COMPOSE_FILE" || \
        error "Restored compose file has no SECRET_KEY. The archive may be damaged. Nothing has been started."

    local conf_stage_dir="$INSTALL_DIR/vpn-state/original-confs"
    local conf_restored_count=0 f
    if [[ -d "$conf_stage_dir" ]]; then
        if [[ -d "$conf_stage_dir/root" ]]; then
            for f in "$conf_stage_dir/root"/*.conf; do
                [[ -f "$f" ]] || continue
                if cp -- "$f" "/root/$(basename "$f")" 2>/dev/null; then
                    chmod 600 "/root/$(basename "$f")"
                    conf_restored_count=$((conf_restored_count + 1))
                fi
            done
        fi
        if [[ -d "$conf_stage_dir/user" ]]; then
            for f in "$conf_stage_dir/user"/*.conf; do
                [[ -f "$f" ]] || continue
                local dest
                dest="$REAL_HOME/$(basename "$f")"
                if cp -- "$f" "$dest" 2>/dev/null; then
                    chmod 600 "$dest"
                    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
                        chown "$SUDO_UID:$SUDO_GID" "$dest" 2>/dev/null || true
                    fi
                    conf_restored_count=$((conf_restored_count + 1))
                fi
            done
        fi
        if (( conf_restored_count > 0 )); then
            echo "Restored $conf_restored_count original WireGuard .conf file(s) to /root and/or $REAL_HOME."
        fi
    fi

    # The scripts being run win over the backup's copies.
    install_script_copy "$keep/setup-backup.sh" setup-backup.sh
    install_script_copy "$keep/setup-aiostreams.sh" setup-aiostreams.sh
    # A backup from before this script existed carries a setup-aiostreams.sh
    # that can't start a restored stack for it. Fetch the current one.
    if ! grep -q '_restore-start)' "$INSTALL_DIR/setup-aiostreams.sh" 2>/dev/null; then
        info "Downloading the current setup-aiostreams.sh"
        curl -fsSL "$RAW_BASE/setup-aiostreams.sh" -o "$keep/main-dl.sh" \
            && grep -q '_restore-start)' "$keep/main-dl.sh" \
            || error "Couldn't download setup-aiostreams.sh. The backup is extracted to $INSTALL_DIR; put the current setup-aiostreams.sh there and run: sudo bash $INSTALL_DIR/setup-backup.sh restore $tarball"
        install_script_copy "$keep/main-dl.sh" setup-aiostreams.sh
    fi

    check_restored_domain_dns

    # Folder access, ~/aiostreams shortcuts, VPN boot hook, image pull, the
    # start itself (through the tunnel with the VPN) and the HTTPS check all
    # live in setup-aiostreams.sh, so they work the same as everywhere else.
    local start_status=0
    bash "$INSTALL_DIR/setup-aiostreams.sh" _restore-start || start_status=$?
    if (( start_status == 2 )); then
        echo "Restore cancelled, nothing started. The backup is in place in $INSTALL_DIR."
        return 0
    fi

    # Add-ons come back only if they were running when the backup was made.
    local watchdog_was_active=false watchdog_back=false
    if [[ -f "$INSTALL_DIR/watchdog-state/was-active-at-backup" ]]; then
        watchdog_was_active=true
        local watchdog_script
        watchdog_script=$(find_script setup-watchdog.sh)
        if [[ -n "$watchdog_script" ]]; then
            bash "$watchdog_script" install-timer < /dev/null || true
            if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
                watchdog_back=true
            else
                warn "Couldn't reinstall the watchdog's timer automatically. See the reminder below."
            fi
        fi
        rm -f "$INSTALL_DIR/watchdog-state/was-active-at-backup"
    fi

    local webhook_was_active=false webhook_back=false
    if [[ -f "$INSTALL_DIR/webhook-relay-state/was-active-at-backup" ]]; then
        webhook_was_active=true
        local webhook_script
        webhook_script=$(find_script setup-webhook.sh)
        if [[ -n "$webhook_script" ]]; then
            bash "$webhook_script" start-relay < /dev/null || true
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aios-webhook-relay; then
                webhook_back=true
            else
                warn "Couldn't restart the webhook relay automatically. See the reminder below."
            fi
        fi
        rm -f "$INSTALL_DIR/webhook-relay-state/was-active-at-backup"
    fi

    local mediaflow_was_active=false mediaflow_back=false
    if [[ -f "$INSTALL_DIR/mediaflow-state/was-active-at-backup" ]]; then
        mediaflow_was_active=true
        local mediaflow_script
        mediaflow_script=$(find_script setup-mediaflow.sh)
        if [[ -n "$mediaflow_script" ]]; then
            bash "$mediaflow_script" start-mediaflow < /dev/null || true
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mediaflow-proxy-light; then
                mediaflow_back=true
            else
                warn "Couldn't restart MediaFlow Proxy Light automatically. See the reminder below."
            fi
        fi
        rm -f "$INSTALL_DIR/mediaflow-state/was-active-at-backup"
    fi

    info "Restore complete!"
    echo ""
    echo "Because the SECRET_KEY and data came over intact, every existing user config"
    echo "and installed Stremio manifest URL keeps working, nothing to recreate."
    echo ""
    echo "If this is a NEW server (new IP), remember:"
    echo "  - Update the DNS A record for the domain to point at THIS server's IP."
    echo "  - Caddy re-issues HTTPS certificates automatically once DNS resolves here"
    echo "    (its cert volumes start fresh; that's expected and fine)."
    if grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null; then
        if [[ -f /etc/systemd/system/aiostreams-vpn-boot.service ]]; then
            echo "  - VPN mode: the boot-safety hook (aiostreams-vpn-boot.service) has been"
            echo "    reinstalled on this server, so AIOStreams will come back correctly after"
            echo "    a reboot, gated on the tunnel, same as it did on the original server."
        else
            echo "  - VPN mode: the boot-safety hook (aiostreams-vpn-boot.service) lives outside"
            echo "    the backup and could NOT be installed automatically (setup-vpn-gluetun.sh"
            echo "    wasn't found in $INSTALL_DIR), AIOStreams will not survive this server's"
            echo "    next reboot until you run 'sudo bash $INSTALL_DIR/setup-vpn-gluetun.sh'"
            echo "    and choose 'Turn VPN ON' once to install it."
        fi
    fi
    if $watchdog_was_active; then
        if $watchdog_back; then
            echo "  - Watchdog: it was running before the backup, so its timer"
            echo "    (aiostreams-watchdog.timer) has been reinstalled on this server,"
            echo "    alerts will resume with no action needed."
        else
            echo "  - Watchdog: it was running before the backup, but its timer could NOT be"
            echo "    reinstalled automatically. You won't get alerts until you run"
            echo "    'sudo bash $INSTALL_DIR/setup-watchdog.sh' and choose 'Start' once."
        fi
    fi
    if $webhook_was_active; then
        if $webhook_back; then
            echo "  - Webhook relay: it was running before the backup, so the container is back"
            echo "    up with the same subdomain/token/ntfy topic, nothing else needed. If this"
            echo "    is a NEW server, remember its subdomain also needs its own DNS A record"
            echo "    pointed here, same as the main domain above."
        else
            echo "  - Webhook relay: it was running before the backup, but could NOT be"
            echo "    restarted automatically. It won't receive events until you run"
            echo "    'sudo bash $INSTALL_DIR/setup-webhook.sh' and choose 'Start' once."
        fi
    fi
    if $mediaflow_was_active; then
        if $mediaflow_back; then
            echo "  - MediaFlow Proxy Light: it was running before the backup, so it's back up"
            echo "    with the same subdomain/password, nothing else needed. If this is a NEW"
            echo "    server, remember its subdomain also needs its own DNS A record pointed"
            echo "    here, same as the main domain above."
        else
            echo "  - MediaFlow Proxy Light: it was running before the backup, but could NOT be"
            echo "    restarted automatically. It won't be reachable until you run"
            echo "    'sudo bash $INSTALL_DIR/setup-mediaflow.sh' and choose Start."
        fi
    fi
    if (( conf_restored_count > 0 )); then
        echo "  - WireGuard .conf: $conf_restored_count original file(s) restored to /root"
        echo "    and/or $REAL_HOME, same as they were on the old server (convenience"
        echo "    copies for quick reconfigures, not required for the VPN layer itself)."
    fi
    echo "  - Verify by logging into the AIOStreams page and playing one stream from a"
    echo "    device that already had the addon installed. Keep the old server running"
    echo "    until that works. It's your rollback."
    return 0
}

case "${1:-}" in
    backup)
        do_backup
        exit 0
        ;;
    restore)
        do_restore "${2:-}"
        exit 0
        ;;
    "")
        ;;
    *)
        error "Unknown command '$1'. Use: backup, or restore [file]."
        ;;
esac

info "Backup & restore"
echo "  1) Back up now"
echo "  2) Restore from a backup (replaces the current install)"
echo "  3) Exit"
read -rp "Select an option [1-3]: " MENU_CHOICE
case "$MENU_CHOICE" in
    1) do_backup ;;
    2) do_restore "" ;;
    *) echo "Exiting." ;;
esac
