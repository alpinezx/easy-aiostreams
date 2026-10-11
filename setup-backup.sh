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

# Installs made before October 2026 live in /root/aiostreams instead, and
# these scripts don't work with that layout. Stop rather than mistake the
# server for one without an install.
_old="$(getent passwd root 2>/dev/null | cut -d: -f6)/aiostreams"
if [[ -f "$_old/docker-compose.yml" && ! -L "$_old" && ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    echo "This server's AIOStreams install is in $_old, from before October 2026."
    echo "These scripts only work with $INSTALL_DIR. Move it first:"
    echo "  https://github.com/alpinezx/easy-aiostreams/tree/migrate-to-opt"
    exit 1
fi
unset _old
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"

# Where a missing setup-aiostreams.sh is fetched from. AIOS_BRANCH=dev to test.
RAW_BASE="https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/${AIOS_BRANCH:-main}"
MIGRATE_SCRIPT_URL="https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/migrate-to-opt/setup-aiostreams.sh"

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

    # And for the control panel, so a restore brings it back only if it was
    # running.
    if [[ -f "$INSTALL_DIR/ui-state/config" ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aios-ui; then
            touch "$INSTALL_DIR/ui-state/was-active-at-backup"
        else
            rm -f "$INSTALL_DIR/ui-state/was-active-at-backup"
        fi
    fi
    # Tells a restore which of the markers above this backup can have.
    # Format 2 added the panel's.
    printf '# Written by setup-backup.sh with each backup.\nformat=2\n' > "$INSTALL_DIR/backup-info"

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
    # AIOStreams writes to its database every few seconds. Freeze it while
    # the archive is written so the database is copied in one piece, not
    # caught mid-write. A pause keeps it running (no restart, no VPN
    # re-check), and the trap unfreezes it however this script ends.
    local paused=false started
    if [[ "$(docker inspect -f '{{.State.Status}}' aiostreams 2>/dev/null)" == "running" ]] \
        && docker pause aiostreams >/dev/null 2>&1; then
        paused=true
        trap 'docker unpause aiostreams >/dev/null 2>&1 || true' EXIT
        echo "Pausing AIOStreams while the backup is written, so its database is copied cleanly..."
    fi
    started=$SECONDS
    if ( umask 077; tar --warning=no-file-changed --exclude="$(basename "$INSTALL_DIR")/caddy-logs" \
            -czf "$out" -C "$(dirname "$INSTALL_DIR")" "$(basename "$INSTALL_DIR")" ); then
        tar_status=0
    else
        tar_status=$?
    fi
    if $paused; then
        docker unpause aiostreams >/dev/null 2>&1 || warn "Couldn't unpause AIOStreams. Run: docker unpause aiostreams"
        trap - EXIT
        echo "AIOStreams resumed (paused for $((SECONDS - started))s)."
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

# Set when the person moves the main domain during a restore, so the
# summary doesn't promise that installed addons keep working.
RESTORE_OLD_DOMAIN=""

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
                [[ -n "$RESTORE_OLD_DOMAIN" ]] || RESTORE_OLD_DOMAIN="$domain"
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
# Add-ons, as far as a restore is concerned
# ---------------------------------------------------------------------------

# The add-ons with a subdomain of their own:
# id|name|state folder|Caddy site file|container
ADDONS=(
    "mediaflow|MediaFlow Proxy|mediaflow-state|50-mediaflow.caddy|mediaflow-proxy-light"
    "webhook|Webhook relay|webhook-relay-state|50-webhook-relay.caddy|aios-webhook-relay"
    "panel|Control panel|ui-state|60-ui.caddy|aios-ui"
)
# Filled in by check_addon_domains for each installed add-on, by id.
declare -A ADDON_NAME=() ADDON_DOMAIN=() ADDON_START=() ADDON_DNS=() ADDON_NEW=() ADDON_OFF_BY_CHOICE=()
PUBLIC_IP=""

addon_domain() {
    grep -m1 -oP "^DOMAIN='?\K[^'\s]+" "$INSTALL_DIR/$1/config" 2>/dev/null || true
}

resolve_ip() {
    getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1; exit }' || true
}

# Sets PUBLIC_IP to this server's own public IPv4 address, once.
find_public_ip() {
    [[ -n "$PUBLIC_IP" ]] && return 0
    local svc
    for svc in "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        PUBLIC_IP=$(curl -fs4 --max-time 4 "$svc" 2>/dev/null | tr -d ' \n') && [[ -n "$PUBLIC_IP" ]] && break
    done
    return 0
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# True when this runs inside the control panel's own web terminal. Stopping
# the panel from there would kill the shell running this restore.
in_panel_terminal() {
    [[ "${AIOS_UI_TERMINAL:-}" == "1" ]] && return 0
    local id
    id=$(docker inspect -f '{{.Id}}' aios-ui 2>/dev/null) || return 1
    [[ -n "$id" ]] && grep -q "$id" /proc/self/cgroup 2>/dev/null
}

# Whether an add-on was running when the backup was made. Backups before
# format 2 didn't record the panel's state, and the panel is normally
# running, so it counts as running when it's installed.
addon_was_running() {
    local id="$1" dir="$2" format
    [[ -f "$INSTALL_DIR/$dir/was-active-at-backup" ]] && return 0
    if [[ "$id" == panel ]]; then
        format=$(grep -m1 -oP '^format=\K[0-9]+' "$INSTALL_DIR/backup-info" 2>/dev/null || echo 1)
        (( format < 2 )) && return 0
    fi
    return 1
}

# The add-ons of the install about to be set aside, for the warning.
current_addons() {
    local found=()
    [[ -f "$INSTALL_DIR/mediaflow-state/docker-compose.yml" ]] && found+=("MediaFlow Proxy")
    [[ -f "$INSTALL_DIR/webhook-relay-state/docker-compose.yml" ]] && found+=("webhook relay")
    [[ -f /etc/systemd/system/aiostreams-watchdog.timer ]] && found+=("watchdog")
    [[ -f /etc/systemd/system/aiostreams-vpn-boot.service ]] && found+=("VPN boot hook")
    [[ -f /etc/fail2ban/jail.d/aios-mediaflow.conf ]] && found+=("MediaFlow fail2ban jail")
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx aios-ui && found+=("control panel")
    (( ${#found[@]} )) && printf '%s, ' "${found[@]}" | sed 's/, $//'
    return 0
}

# Stops and removes the add-ons of the install about to be set aside, so
# nothing keeps running against a folder that has moved. The backup's own
# add-ons come back further down. The panel is left running when this runs
# inside its own terminal.
retire_current_addons() {
    local main="$1"
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx aios-ui; then
        if in_panel_terminal; then
            echo "Leaving the control panel running, since this restore runs inside it."
        else
            docker rm -f aios-ui >/dev/null 2>&1 && echo "Stopped the current control panel."
        fi
    fi
    bash "$main" _remove-addons < /dev/null || \
        warn "Couldn't remove all of the current install's add-ons. Check 'docker ps' afterwards."
}

# Points an add-on at a new subdomain: its saved settings and its Caddy site.
set_addon_domain() {
    local dir="$1" site="$2" old="$3" new="$4" q="" old_re
    grep -q "^DOMAIN='" "$INSTALL_DIR/$dir/config" && q="'"
    sed -i "s/^DOMAIN=.*/DOMAIN=${q}${new}${q}/" "$INSTALL_DIR/$dir/config"
    old_re=$(printf '%s' "$old" | sed 's/[.]/\\./g')
    [[ -f "$INSTALL_DIR/caddy.d/$site" ]] && sed -i "0,/^${old_re} {/s//${new} {/" "$INSTALL_DIR/caddy.d/$site"
    return 0
}

# Asks for a new subdomain for an add-on until it gets a usable one, or an
# empty answer (keep the old one). Prints the chosen domain.
ask_new_domain() {
    local name="$1" here="$2" taken="$3" current="$4" new ip yn
    while true; do
        read -rp "New subdomain for $name (Enter to keep the current one): " new >&2 || return 0
        new=$(echo "$new" | xargs)
        [[ -z "$new" || "${new,,}" == "${current,,}" ]] && return 0
        if ! valid_domain "$new"; then
            warn "That doesn't look like a domain. Letters, numbers, dots and hyphens only (e.g. proxy.example.com)." >&2
            continue
        fi
        if [[ " $taken " == *" ${new,,} "* ]]; then
            warn "$new is already used by AIOStreams or another add-on. Each needs its own subdomain." >&2
            continue
        fi
        ip=$(resolve_ip "$new")
        if [[ -n "$here" && "$ip" != "$here" ]]; then
            if [[ -n "$ip" ]]; then
                warn "$new points at $ip, not this server ($here)." >&2
            else
                warn "$new doesn't resolve to anything yet." >&2
            fi
            read -rp "Use it anyway (its certificate follows once DNS points here)? [y/N]: " yn >&2 || yn=""
            [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        printf '%s\n' "$new"
        return 0
    done
}

# Every add-on installed in the backup, running or not, gets its subdomain
# checked: one switched off for now still needs DNS pointing here the day
# it's switched back on. For each one that doesn't point here, you can move
# it to another subdomain, keep it and fix DNS yourself, or (if it was
# running) leave it switched off for now. Nothing here blocks the restore.
check_addon_domains() {
    local a id name dir site ctr domain ip here choice new taken main_domain
    find_public_ip
    here="$PUBLIC_IP"
    main_domain=$(head -n1 "$CADDYFILE" 2>/dev/null | awk '{print $1}')
    taken="${main_domain,,}"
    for a in "${ADDONS[@]}"; do
        IFS='|' read -r id name dir site ctr <<< "$a"
        [[ -f "$INSTALL_DIR/$dir/config" ]] || continue
        domain=$(addon_domain "$dir")
        ADDON_NAME[$id]="$name"
        ADDON_DOMAIN[$id]="$domain"
        ADDON_START[$id]=false
        addon_was_running "$id" "$dir" && ADDON_START[$id]=true
        [[ -n "$domain" ]] && taken+=" ${domain,,}"
    done
    (( ${#ADDON_NAME[@]} )) || return 0

    echo ""
    echo "Checking the add-ons' subdomains..."
    for a in "${ADDONS[@]}"; do
        IFS='|' read -r id name dir site ctr <<< "$a"
        [[ -n "${ADDON_NAME[$id]:-}" ]] || continue
        domain="${ADDON_DOMAIN[$id]}"
        if [[ -z "$domain" ]]; then
            ADDON_DNS[$id]=unknown
            continue
        fi
        ip=$(resolve_ip "$domain")
        if [[ -z "$here" ]]; then
            ADDON_DNS[$id]=unknown
            echo "  $name: $domain (couldn't find this server's own IP to compare)"
            continue
        fi
        if [[ "$ip" == "$here" ]]; then
            ADDON_DNS[$id]=ok
            echo "  $name: $domain points here. Good."
            continue
        fi
        ADDON_DNS[$id]=waiting
        echo ""
        if [[ -n "$ip" ]]; then
            warn "$name: $domain points at $ip, but this server is $here."
        else
            warn "$name: $domain doesn't resolve to anything yet."
        fi
        if ${ADDON_START[$id]}; then
            echo "  1) Move it to a different subdomain (one whose A record points here)"
            echo "  2) Keep $domain and point its DNS here yourself (it starts now)"
            echo "  3) Keep $domain but leave it switched off for now"
        else
            echo "  It was switched off when the backup was made, so it stays off either way."
            echo "  1) Move it to a different subdomain (one whose A record points here)"
            echo "  2) Keep $domain and point its DNS here before you switch it on"
        fi
        while true; do
            read -rp "Choice (Enter = 2): " choice || choice=2
            case "${choice:-2}" in
                1)
                    new=$(ask_new_domain "$name" "$here" "$taken" "$domain")
                    if [[ -n "$new" && "${new,,}" != "${domain,,}" ]]; then
                        set_addon_domain "$dir" "$site" "$domain" "$new"
                        taken+=" ${new,,}"
                        ADDON_NEW[$id]="$new"
                        ADDON_DOMAIN[$id]="$new"
                        [[ "$(resolve_ip "$new")" == "$here" ]] && ADDON_DNS[$id]=ok
                        echo "  $name now uses $new."
                    fi
                    break ;;
                2) break ;;
                3)
                    if ${ADDON_START[$id]}; then
                        ADDON_START[$id]=false
                        ADDON_OFF_BY_CHOICE[$id]=true
                        break
                    fi
                    warn "Not a valid choice." ;;
                *) warn "Not a valid choice." ;;
            esac
        done
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

    # A backup from before October 2026 names /root/aiostreams inside its
    # add-on and panel settings, which only work there. The migrate-to-opt
    # version restores those into /opt; send it there before changing anything.
    local old_ref
    old_ref=$(tar -xzOf "$tarball" --exclude='aiostreams/data' --wildcards --no-anchored \
            '*.yml' '*.yaml' '*.caddy' '*.env' 'config' 2>/dev/null \
        | grep -m1 -oE '/(root|home/[^/[:space:]"]+)/aiostreams([/:"[:space:]]|$)' || true)
    if [[ -n "$old_ref" ]]; then
        echo ""
        warn "This backup is from before October 2026, when installs lived in /root/aiostreams."
        echo "Restore it once with the migrate-to-opt version, which brings it into"
        echo "$INSTALL_DIR, then put the current script back:"
        echo ""
        echo "  curl -fsSL $MIGRATE_SCRIPT_URL -o ~/setup-aiostreams-migrate.sh"
        echo "  sudo bash ~/setup-aiostreams-migrate.sh restore $tarball"
        echo "  rm ~/setup-aiostreams-migrate.sh"
        echo "  sudo curl -fsSL https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/setup-aiostreams.sh -o $INSTALL_DIR/setup-aiostreams.sh"
        echo ""
        echo "Nothing was changed on this server."
        return 1
    fi

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
    else
        # None around: the backup carries one, which does if it's current.
        tar -xzOf "$tarball" aiostreams/setup-aiostreams.sh > "$keep/setup-aiostreams.sh" 2>/dev/null || true
    fi
    # This restore needs a setup-aiostreams.sh that can retire the current
    # add-ons and start the restored stack. One from before this script
    # existed can't, so fetch the current one, before anything changes.
    if ! grep -q '_remove-addons)' "$keep/setup-aiostreams.sh" 2>/dev/null; then
        info "Downloading the current setup-aiostreams.sh"
        if curl -fsSL "$RAW_BASE/setup-aiostreams.sh" -o "$keep/main-dl.sh" \
            && grep -q '_remove-addons)' "$keep/main-dl.sh"; then
            mv -f -- "$keep/main-dl.sh" "$keep/setup-aiostreams.sh"
        else
            error "Couldn't download setup-aiostreams.sh. Put the current one next to this script and run the restore again. Nothing was changed."
        fi
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        local addons_now
        addons_now=$(current_addons)
        warn "An installation already exists at $INSTALL_DIR."
        warn "Restoring will REPLACE it, including its SECRET_KEY. If the existing"
        warn "install has user configs the backup doesn't, those would be orphaned."
        if [[ -n "$addons_now" ]]; then
            warn "Its add-ons are stopped and removed first ($addons_now)."
            warn "The backup's own add-ons are brought back afterwards."
        fi
        read -rp "Move the current install aside and continue? [y/N]: " C
        if [[ ! "$C" =~ ^[Yy]$ ]]; then
            echo "Restore cancelled."
            return 0
        fi
        [[ -n "$addons_now" ]] && retire_current_addons "$keep/setup-aiostreams.sh"
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
    # drop files elsewhere (e.g. ~/.ssh). Every backup stores the folder as
    # aiostreams/.
    mkdir -p "$(dirname "$INSTALL_DIR")"
    tar xzf "$tarball" -C "$(dirname "$INSTALL_DIR")" aiostreams
    chmod 700 "$INSTALL_DIR"   # setup-aiostreams.sh sets the final access below
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

    check_restored_domain_dns
    check_addon_domains

    # MediaFlow's fail2ban jail lives outside the backup. Whether it was on
    # shows in its Caddy site (the access log is only there for the jail);
    # look before Start rewrites that file.
    local mediaflow_jail_lost=false
    if grep -q 'mediaflow-access.log' "$INSTALL_DIR/caddy.d/50-mediaflow.caddy" 2>/dev/null \
        && [[ ! -f /etc/fail2ban/jail.d/aios-mediaflow.conf ]]; then
        mediaflow_jail_lost=true
    fi

    # Folder access, ~/aiostreams shortcuts, VPN boot hook, image pull, the
    # start itself (through the tunnel with the VPN) and the HTTPS check all
    # live in setup-aiostreams.sh, so they work the same as everywhere else.
    local start_status=0
    bash "$INSTALL_DIR/setup-aiostreams.sh" _restore-start || start_status=$?
    if (( start_status == 2 )); then
        echo "Restore cancelled, nothing started. The backup is in place in $INSTALL_DIR."
        return 0
    fi

    # Add-ons come back only if they were running when the backup was made
    # (and you didn't choose to leave them off above). Each line of the
    # summary is collected as it goes.
    local summary=() script
    if [[ -f "$INSTALL_DIR/watchdog-state/was-active-at-backup" ]]; then
        script=$(find_script setup-watchdog.sh)
        [[ -n "$script" ]] && { bash "$script" install-timer < /dev/null || true; }
        if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
            summary+=("Watchdog: running again, alerts resume by themselves.")
        else
            summary+=("Watchdog: was running, but couldn't be started. Run 'sudo bash $INSTALL_DIR/setup-watchdog.sh' and choose Start.")
        fi
    elif [[ -f "$INSTALL_DIR/watchdog-state/config" ]]; then
        summary+=("Watchdog: switched off when the backup was made, left off.")
    fi

    local id dir site ctr name a ok
    for a in "${ADDONS[@]}"; do
        IFS='|' read -r id name dir site ctr <<< "$a"
        [[ -n "${ADDON_NAME[$id]:-}" ]] || continue
        local domain="${ADDON_DOMAIN[$id]}" where="" line own
        [[ -n "$domain" ]] && where=" ($domain)"
        case "$id" in
            mediaflow) own="$INSTALL_DIR/setup-mediaflow.sh" ;;
            webhook) own="$INSTALL_DIR/setup-webhook.sh" ;;
            panel) own="$INSTALL_DIR/control-panel/setup-ui.sh" ;;
        esac
        if ! ${ADDON_START[$id]}; then
            if [[ -n "${ADDON_OFF_BY_CHOICE[$id]:-}" ]]; then
                line="$name$where: left off, as you chose. Point its DNS here, then run 'sudo bash $own' and choose Start."
            else
                line="$name$where: switched off when the backup was made, left off."
            fi
            [[ "${ADDON_DNS[$id]:-}" == waiting ]] && [[ -z "${ADDON_OFF_BY_CHOICE[$id]:-}" ]] && \
                line+=" Its DNS doesn't point here yet: fix that before switching it on."
            summary+=("$line")
            continue
        fi
        ok=false
        case "$id" in
            mediaflow)
                script=$(find_script setup-mediaflow.sh)
                [[ -n "$script" ]] && { bash "$script" start-mediaflow < /dev/null || true; } ;;
            webhook)
                script=$(find_script setup-webhook.sh)
                [[ -n "$script" ]] && { bash "$script" start-relay < /dev/null || true; } ;;
            panel)
                if in_panel_terminal; then
                    summary+=("$name$where: press Restart panel (Terminal tab) so it picks up the restored install.")
                    continue
                fi
                script="$INSTALL_DIR/control-panel/setup-ui.sh"
                if [[ -f "$script" ]]; then
                    info "Building and starting the control panel"
                    bash "$script" rebuild < /dev/null || true
                else
                    summary+=("$name$where: its files aren't in the backup. Download it again (see docs/basic/control-panel.md); your login and unlock link are kept.")
                    continue
                fi ;;
        esac
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$ctr" && ok=true
        if $ok && [[ "${ADDON_DNS[$id]:-}" == waiting ]]; then
            line="$name$where: running, waiting for DNS. Point $domain at ${PUBLIC_IP:-this server} and its certificate follows by itself."
        elif $ok; then
            line="$name$where: running again."
        else
            line="$name$where: was running, but couldn't be started. Run 'sudo bash $own' and choose Start."
        fi
        summary+=("$line")
    done

    # What changed with a new subdomain needs updating elsewhere too.
    local token
    if [[ -n "${ADDON_NEW[mediaflow]:-}" ]]; then
        summary+=("MediaFlow moved to ${ADDON_NEW[mediaflow]}: in the AIOStreams dashboard, set its Public URL to https://${ADDON_NEW[mediaflow]}")
    fi
    if [[ -n "${ADDON_NEW[webhook]:-}" ]]; then
        token=$(grep -m1 -oP "^WEBHOOK_TOKEN='?\K[^'\s]+" "$INSTALL_DIR/webhook-relay-state/config" 2>/dev/null || true)
        summary+=("Webhook relay moved: paste the new URL into the sites that send to it: https://${ADDON_NEW[webhook]}/hook/${token:-<token>}")
    fi
    if [[ -n "${ADDON_NAME[panel]:-}" && -f "$INSTALL_DIR/ui-state/gate-token" ]]; then
        summary+=("Control panel unlock link (open it once in each browser): https://${ADDON_DOMAIN[panel]}/unlock/$(cat "$INSTALL_DIR/ui-state/gate-token")")
    fi
    $mediaflow_jail_lost && \
        summary+=("MediaFlow's fail2ban protection was on, but lives outside the backup: add it again with setup-mediaflow.sh option 7.")
    if (( conf_restored_count > 0 )); then
        summary+=("WireGuard .conf: $conf_restored_count original file(s) restored to /root and/or $REAL_HOME (convenience copies).")
    fi

    rm -f "$INSTALL_DIR"/{watchdog-state,webhook-relay-state,mediaflow-state,ui-state}/was-active-at-backup

    info "Restore complete!"
    echo ""
    local main_now
    main_now=$(head -n1 "$CADDYFILE" 2>/dev/null | awk '{print $1}')
    if [[ -n "$RESTORE_OLD_DOMAIN" && "$RESTORE_OLD_DOMAIN" != "$main_now" ]]; then
        echo "The SECRET_KEY and data came over intact, so every user config is here."
        echo "But the domain changed from $RESTORE_OLD_DOMAIN to $main_now, and addons"
        echo "installed from the old address won't follow it. Log in at"
        echo "https://$main_now, open each config and install it in your Stremio"
        echo "client again from there, then remove the old one."
    else
        echo "The SECRET_KEY and data came over intact, so every existing user config"
        echo "and installed Stremio manifest URL keeps working."
    fi
    if grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null; then
        if [[ -f /etc/systemd/system/aiostreams-vpn-boot.service ]]; then
            summary=("VPN: on, and its boot-safety hook is installed, so AIOStreams comes back after a reboot." "${summary[@]}")
        else
            summary=("VPN: on, but its boot-safety hook couldn't be installed. Run 'sudo bash $INSTALL_DIR/setup-vpn-gluetun.sh' and choose 'Turn VPN ON' once, or AIOStreams won't come back after a reboot." "${summary[@]}")
        fi
    fi
    if (( ${#summary[@]} )); then
        echo ""
        for line in "${summary[@]}"; do
            echo "  - $line"
        done
    fi
    echo ""
    if [[ -n "$RESTORE_OLD_DOMAIN" && "$RESTORE_OLD_DOMAIN" != "$main_now" ]]; then
        echo "If this is a new server, keep the old one running until you've logged in at"
        echo "https://$main_now, installed the addon from there on one device and played a"
        echo "stream. It's your rollback."
    else
        echo "If this is a new server, keep the old one running until you've logged into"
        echo "AIOStreams here and played one stream from a device that already had the"
        echo "addon installed. It's your rollback."
    fi
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
