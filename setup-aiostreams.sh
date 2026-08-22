#!/usr/bin/env bash

set -euo pipefail

# Resolved to an absolute path HERE, at the very top, before anything below
# can cd elsewhere. sync_self_into_install_dir (further down) needs this to
# stay accurate regardless of what else runs first, since re-resolving
# BASH_SOURCE[0] later would silently resolve relative to whatever
# directory the script happens to be sitting in by then, not where it was
# actually invoked from.
SELF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;31m!! %s !!\033[0m\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

# Colors just the given fragment red+bold, for embedding inside an otherwise
# plain line, e.g. echo "some text $(hl "the important bit") more text".
hl() { printf '\033[1;31m%s\033[0m' "$1"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1
}

vpn_mode_active() {
    grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null
}

warn_if_vpn_layer_off() {
    local action_desc="$1"   # e.g. "Starting", "Restarting", "Updating"

    [[ -d "$INSTALL_DIR/vpn-state" ]] || return 0
    vpn_mode_active && return 0

    echo ""
    alert "VPN is currently OFF (direct mode) for this install"
    alert "${action_desc} now means AIOStreams' traffic, including debrid API"
    alert "calls, goes out via your VPS's real IP, not through the VPN."
    echo ""
    read -rp "Continue anyway in direct mode? [y/N]: " VPN_OFF_CONTINUE
    if [[ ! "$VPN_OFF_CONTINUE" =~ ^[Yy]$ ]]; then
        echo "Cancelled. Turn the VPN on first with: sudo bash setup-vpn-gluetun.sh"
        return 1
    fi
    return 0
}

# Confirms gluetun's WireGuard tunnel is actually passing traffic, not just
# that the gluetun container is running (depends_on only guarantees start
# order, not that the handshake completed).
confirm_gluetun_tunnel() {
    local max_attempts="${1:-5}" attempt svc
    local svcs=("ifconfig.me/ip" "icanhazip.com" "ipinfo.io/ip")
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        for svc in "${svcs[@]}"; do
            if docker exec gluetun wget -qO- --timeout=5 "$svc" 2>/dev/null | grep -qE '^[0-9]'; then
                return 0
            fi
        done
        echo "  Tunnel not confirmed yet (attempt ${attempt}/${max_attempts})..."
        sleep 2
    done
    return 1
}

# Brings the VPN-mode stack up: gluetun + caddy start first (--no-deps so
# aiostreams isn't dragged along via depends_on), the tunnel is confirmed
# connected, and only then does aiostreams start.
vpn_gated_start_aiostreams() {
    cd "$INSTALL_DIR" || { warn "Could not cd to $INSTALL_DIR"; return 1; }

    docker compose up -d --no-deps "$@" gluetun caddy || \
        warn "Could not start gluetun/caddy. Check 'docker compose logs' in $INSTALL_DIR."

    echo "  Waiting for gluetun to actually be running..."
    local waited=0 gluetun_up=false
    while (( waited < 30 )); do
        if [[ "$(docker inspect -f '{{.State.Running}}' gluetun 2>/dev/null)" == "true" ]]; then
            gluetun_up=true
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if ! $gluetun_up; then
        warn "gluetun did not start. Aiostreams was NOT started. Check 'docker compose logs gluetun' in $INSTALL_DIR, resolve it, then retry."
        return 1
    fi

    echo "  Confirming the WireGuard tunnel is actually connected..."
    if confirm_gluetun_tunnel; then
        echo "  Tunnel confirmed, starting aiostreams"
        docker compose up -d --no-deps "$@" aiostreams || \
            { warn "aiostreams didn't start cleanly. Check 'docker compose logs aiostreams' in $INSTALL_DIR."; return 1; }
        return 0
    else
        echo ""
        alert "NOT starting aiostreams: the tunnel could not be confirmed connected"
        alert "Starting it now could mean its traffic (including debrid API calls) goes"
        alert "out unprotected. Check the gluetun logs, fix the tunnel, then retry this"
        alert "action once it's confirmed. Aiostreams stays stopped until then."
        [[ -t 0 ]] && read -rp "Continue now that you've read this... " _
        return 1
    fi
}

INSTALL_DIR="$HOME/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"

SHARED_NET="aios_shared"

# Set by the Reconfigure menu option only, when it needs the final restart
# (further down) to know whether to bring the stack back up through the
# tunnel-confirmed VPN gate instead of a plain restart. Defaults to false so
# a fresh install (which never touches this flag) doesn't trip `set -u`.
RECONFIGURE_WAS_VPN_ACTIVE=false
CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || \
        docker network create "$SHARED_NET" >/dev/null
}

ensure_caddy_dropin_dir() {
    mkdir -p "$CADDY_DROPIN_DIR"
    if [[ ! -f "$CADDY_DROPIN_DIR/00-placeholder.caddy" ]]; then
        printf '# Drop-in Caddy site configs live here.\n# Managed by setup-aiostreams.sh, safe to leave otherwise empty.\n' \
            > "$CADDY_DROPIN_DIR/00-placeholder.caddy"
    fi
}

do_backup() {
    [[ -f "$COMPOSE_FILE" ]] || error "No installation found at $INSTALL_DIR, nothing to back up."

    # Under sudo (not literal root), $INSTALL_DIR is ALWAYS $HOME/aiostreams
    # where $HOME is root's home, regardless of which directory you're
    # sitting in, or where you dropped updated .sh files. If someone's been
    # editing/updating scripts in their own user's ~/aiostreams (a very
    # natural thing to do. That's often the directory they're actually
    # looking at), those changes silently never reach the backup, because
    # this backs up $INSTALL_DIR specifically. Confirmed happening in
    # practice, not just theoretical: catch it here so it's visible BEFORE
    # a backup goes out missing scripts, not discovered three restores
    # later on a different server. Only relevant when running via sudo as
    # a non-root user in the first place. $REAL_HOME == $HOME otherwise.
    if [[ "$REAL_HOME" != "$HOME" && -d "$REAL_HOME/aiostreams" ]]; then
        local script_mismatch=() sname
        for sname in setup-aiostreams.sh setup-vpn-gluetun.sh setup-watchdog.sh; do
            local user_copy="$REAL_HOME/aiostreams/$sname"
            local root_copy="$INSTALL_DIR/$sname"
            [[ -f "$user_copy" ]] || continue
            if [[ ! -f "$root_copy" ]]; then
                script_mismatch+=("$sname (in $REAL_HOME/aiostreams, not in $INSTALL_DIR)")
            elif ! cmp -s "$user_copy" "$root_copy"; then
                script_mismatch+=("$sname (differs between the two locations)")
            fi
        done
        if (( ${#script_mismatch[@]} > 0 )); then
            warn "This backup will only include scripts from $INSTALL_DIR (that's what"
            warn "\$HOME resolves to under sudo), NOT $REAL_HOME/aiostreams, even though"
            warn "that's likely the directory you're actually looking at day to day."
            warn "Mismatch found:"
            for sname in "${script_mismatch[@]}"; do
                warn "  - $sname"
            done
            warn "If you meant to update the scripts that actually get backed up, copy them"
            warn "into $INSTALL_DIR first: sudo cp $REAL_HOME/aiostreams/*.sh $INSTALL_DIR/"
            read -rp "Continue with the backup as-is anyway? [y/N]: " CONTINUE_MISMATCH
            [[ "$CONTINUE_MISMATCH" =~ ^[Yy]$ ]] || { echo "Backup cancelled."; return 0; }
        fi
    fi

    info "Backing up $INSTALL_DIR"
    echo "Included: compose files (SECRET_KEY + logins), Caddyfile + drop-ins,"
    echo "AIOStreams user configs (./data), vpn-state (WireGuard private key,"
    echo "if the VPN layer was ever set up), and any original WireGuard .conf"
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

    if [[ -d "$INSTALL_DIR/vpn-state" ]]; then
        local conf_stage_dir="$INSTALL_DIR/vpn-state/original-confs"
        rm -rf "$conf_stage_dir"
        local conf_scan_dirs=("/root")
        [[ "$REAL_HOME" != "/root" ]] && conf_scan_dirs+=("$REAL_HOME")
        local conf_candidates=() conf_staged_count=0 conf_staged_names=()
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

    local ts out size ip tar_status
    ts=$(date +%Y%m%d-%H%M%S)
    out="$HOME/aiostreams-backup-${ts}.tar.gz"
    # umask is process-wide, so scope it to a subshell so it doesn't leak
    # into files written later this session.
    if ( umask 077; tar --warning=no-file-changed -czf "$out" -C "$HOME" "$(basename "$INSTALL_DIR")" ); then
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

    # Under sudo, $REAL_HOME differs from root's $HOME, also drop a copy
    # there so the invoking user can access it directly.
    if [[ "$REAL_HOME" != "$HOME" ]]; then
        local user_copy="$REAL_HOME/aiostreams-backup-${ts}.tar.gz"
        if cp -- "$out" "$user_copy" 2>/dev/null; then
            chmod 600 "$user_copy"
            if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
                chown "$SUDO_UID:$SUDO_GID" "$user_copy" 2>/dev/null || true
            fi
            echo -e "Also copied to: \033[1;36m$user_copy\033[0m (owned by $SUDO_USER, so you can scp it directly)"
        else
            warn "Could not also copy the backup to $REAL_HOME. The copy in $HOME above is still good."
        fi
    fi
    echo ""
    echo "Copy it OFF this server now, from your local machine:"
    if [[ "$REAL_HOME" != "$HOME" ]]; then
        echo -e "  \033[1;36mscp ${SUDO_USER}@${ip:-<server-ip>}:${user_copy:-$out} .\033[0m"
    else
        echo -e "  \033[1;36mscp root@${ip:-<server-ip>}:${out} .\033[0m"
    fi
    echo ""
    echo "To migrate to a new server: copy this script + the tarball over, then run:"
    echo -e "  \033[1;36msudo bash setup-aiostreams.sh restore aiostreams-backup-${ts}.tar.gz\033[0m"
    echo ""
    warn "This file contains your SECRET_KEY, all logins, and (if present) your"
    warn "WireGuard PRIVATE KEY. Treat it like a password: store it somewhere"
    warn "encrypted, never share it, and delete old copies you no longer need."
    if [[ "$REAL_HOME" != "$HOME" ]]; then
        warn "That applies to BOTH copies above, delete the one in $HOME too once you're done."
    fi
    [[ -t 0 ]] && read -rp "Continue now that you've read this... " _
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
                return 1
                ;;
            *)
                warn "Not a valid choice."
                continue
                ;;
        esac
    done
}

# Waits up to 90s for Caddy to obtain a valid HTTPS cert for $1, then, if it
# didn't confirm in time, tries to work out why. If Caddy's actually bound
# to 80/443 locally AND DNS matches this server's own public IP, DNS and the
# server itself are both fine, so the only thing left that explains the
# outside world not completing a handshake is a network-level block in
# front of the server, almost always a cloud provider's own firewall/
# security group console (Oracle Cloud's default VCN Security List is the
# one we see block people the most). Otherwise falls back to a generic
# DNS-propagation-delay message. Used by both the fresh-install/Reconfigure
# flow and do_restore, so it's parameterized on domain rather than reading
# the global $DOMAIN, which do_restore never sets.
wait_for_cert_and_diagnose() {
    local domain="$1"
    echo "Waiting for Caddy to obtain its HTTPS certificate,"
    echo "(this can take longer on a genuinely fresh cert request)..."
    local MAX_WAIT=90 INTERVAL=5 elapsed=0 cert_ok=false
    while [[ $elapsed -lt $MAX_WAIT ]]; do
        # Checks the TLS layer directly rather than parsing Caddy's log wording,
        # since current Caddy versions don't log a fixed "certificate obtained"
        # phrase. Also naturally covers reusing an existing valid cert.
        if echo | openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null | grep -q "$domain"; then
            cert_ok=true
            break
        fi
        echo "  Not confirmed yet... (${elapsed}s elapsed)"
        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done
    if $cert_ok; then
        echo "HTTPS certificate confirmed (obtained fresh, or reused an existing valid one)."
        return 0
    fi

    local CADDY_BOUND=false
    if docker port caddy 80/tcp >/dev/null 2>&1 && docker port caddy 443/tcp >/dev/null 2>&1; then
        CADDY_BOUND=true
    fi

    local DIAG_RESOLVED_IP=""
    if require_cmd getent; then
        DIAG_RESOLVED_IP=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1 }' | head -n1 || true)
    fi
    local DIAG_PUBLIC_IP="" SVC
    for SVC in "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        DIAG_PUBLIC_IP=$(curl -fs4 --max-time 4 "$SVC" 2>/dev/null | tr -d ' \n') && [[ -n "$DIAG_PUBLIC_IP" ]] && break
    done

    if $CADDY_BOUND && [[ -n "$DIAG_RESOLVED_IP" && -n "$DIAG_PUBLIC_IP" && "$DIAG_RESOLVED_IP" == "$DIAG_PUBLIC_IP" ]]; then
        echo ""
        echo "!! $(hl "COULDN'T CONFIRM THE HTTPS CERTIFICATE") after ${MAX_WAIT}s !!"
        echo "Caddy is listening, and DNS matches this server's IP."
        echo "That points to $(hl "ports 80/443") being blocked before they"
        echo "even reach the server, almost always a firewall in your cloud"
        echo "provider's own console (security group / security list),"
        echo "not anything wrong with this install."
        echo ""
        echo "See the Firewall & Ports guide, step 2:"
        echo "https://github.com/alpinezx/easy-aiostreams/blob/main/docs/basic/firewall-ports.md"
        echo ""
        echo "Once it's fixed: re-run this script, pick 4) Restart the"
        echo "stack, then 1) View status to confirm. No need to"
        echo "Reconfigure or reinstall."
        echo ""
        [[ -t 0 ]] && read -rp "Continue now that you've read this... " _
    else
        warn "Couldn't confirm certificate issuance after ${MAX_WAIT}s."
        warn "Check 'docker compose logs caddy'."
        warn "This is usually a DNS propagation delay if the domain is brand new."
        warn "Caddy keeps retrying on its own in the background,"
        warn "so this often clears up by itself within a few minutes."
        warn "If you want to force an immediate retry,"
        warn "re-run this script and pick 4) Restart the stack, then 1) View status to confirm."
    fi
}

do_restore() {
    local tarball="${1:-}"

    info "Restore from backup"
    if [[ -z "$tarball" ]]; then
        local candidates=() f sel
        shopt -s nullglob
        for f in "$HOME"/*aiostreams*.tar.gz "$REAL_HOME"/*aiostreams*.tar.gz "$PWD"/*aiostreams*.tar.gz; do
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
            if [[ "$REAL_HOME" != "$HOME" ]]; then
                echo "No aiostreams backup tarballs found in $HOME, $REAL_HOME, or the current directory."
            else
                echo "No aiostreams backup tarballs found in $HOME or the current directory."
            fi
            read -rp "Path to backup tarball (aiostreams-backup-*.tar.gz): " tarball
        fi
    fi
    [[ -f "$tarball" ]] || error "File not found: $tarball"
    # Resolve to an absolute path now, before anything below can move
    # directories around, a relative path (e.g. typed by hand, or passed
    # as the CLI arg) would otherwise silently break the INSTALL_DIR-move
    # check just below, since string-prefix matching needs both sides in
    # the same (absolute) form.
    tarball="$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")"
    # Captured to a variable instead of piped into grep -q: with pipefail,
    # grep exiting early on match can SIGPIPE tar and clobber tar's exit
    # status. This also distinguishes "corrupted archive" from "not ours".
    local tar_listing
    tar_listing=$(tar -tzf "$tarball" 2>&1) || \
        error "Couldn't read $tarball as a .tar.gz archive. It may be corrupted or incomplete. Try re-copying it and retry."
    grep -q 'aiostreams/docker-compose.yml' <<< "$tar_listing" || \
        error "That archive doesn't look like a backup made by this script (no aiostreams/docker-compose.yml inside)."

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
        aside="$HOME/aiostreams.pre-restore-$(date +%Y%m%d-%H%M%S)"
        mv "$INSTALL_DIR" "$aside"
        echo "Current install moved aside to $aside (delete it once you're happy with the restore)."
        # If the tarball was sitting INSIDE $INSTALL_DIR (e.g. scp'd/cd'd
        # into ~/aiostreams before running restore, a completely normal
        # thing to do), the mv above just took it along for the ride —
        # it's not missing, just relocated under $aside now. Update the
        # reference so extraction below finds it at its new location
        # instead of erroring on a path that technically still describes
        # where the file WAS, not where it now is.
        if [[ "$tarball" == "$INSTALL_DIR"/* ]]; then
            tarball="$aside/${tarball#"$INSTALL_DIR"/}"
            echo "(The backup tarball was inside $INSTALL_DIR, so it moved to $aside too —"
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
    tar xzf "$tarball" -C "$HOME"
    chmod 600 "$COMPOSE_FILE" 2>/dev/null || true
    grep -q 'SECRET_KEY=' "$COMPOSE_FILE" || \
        error "Restored compose file has no SECRET_KEY. The archive may be damaged. Nothing has been started."

    local conf_stage_dir="$INSTALL_DIR/vpn-state/original-confs"
    local conf_restored_count=0
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
                local dest="$REAL_HOME/$(basename "$f")"
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

    check_restored_domain_dns

    ensure_shared_network
    ensure_caddy_dropin_dir   # no-op on current backups; creates it for pre-drop-in ones

    warn_if_vpn_layer_off "Restoring" || { echo "Restore cancelled, nothing started."; return 0; }

    info "Starting the restored stack"
    hook_installed_during_restore=false
    watchdog_reinstalled_during_restore=false
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if vpn_mode_active; then
        # Bug fix: checking only script_dir missed it every time a VPN layer
        # was in play, because restore is typically launched from $HOME while
        # setup-vpn-gluetun.sh (traveling inside the backup) lands in
        # $INSTALL_DIR. Check that first, then fall back to script_dir.
        local vpn_script=""
        for candidate in "$INSTALL_DIR/setup-vpn-gluetun.sh" "$script_dir/setup-vpn-gluetun.sh"; do
            if [[ -f "$candidate" ]]; then
                vpn_script="$candidate"
                break
            fi
        done
        if [[ -n "$vpn_script" ]]; then
            # < /dev/null: an older $vpn_script that predates this flag falls
            # through into its interactive menu instead of erroring; closed
            # stdin makes its first `read` hit EOF and exit immediately
            # instead of hijacking this session. Its exit code alone isn't
            # trustworthy either (a clean menu EXIT also returns 0), so check
            # the real thing that matters: does the systemd unit exist now?
            bash "$vpn_script" install-boot-hook < /dev/null || true
            if [[ -f /etc/systemd/system/aiostreams-vpn-boot.service ]]; then
                hook_installed_during_restore=true
            else
                warn "Couldn't install the boot-safety hook automatically. See the reminder below."
            fi
        fi

        info "VPN layer detected in this backup, bringing the tunnel up before starting AIOStreams"
        cd "$INSTALL_DIR" || error "Could not cd to $INSTALL_DIR"
        vpn_gated_start_aiostreams --remove-orphans || true
    else
        (cd "$INSTALL_DIR" && docker compose up -d --force-recreate --remove-orphans)
    fi

    # Same domain check_restored_domain_dns already confirmed against DNS
    # above, re-read here since that was a local var in a different
    # function. DNS matching beforehand doesn't rule out a blocked port on
    # this (possibly new) server, so still worth confirming the cert itself.
    if [[ -f "$CADDYFILE" ]]; then
        local restored_domain
        restored_domain=$(head -n1 "$CADDYFILE" | awk '{print $1}')
        [[ -n "$restored_domain" ]] && wait_for_cert_and_diagnose "$restored_domain"
    fi

    # Deliberately independent of the vpn_mode_active branch above — the
    # was-active-at-backup marker alone decides this, not current VPN state.
    watchdog_was_active_at_backup=false
    if [[ -f "$INSTALL_DIR/watchdog-state/was-active-at-backup" ]]; then
        watchdog_was_active_at_backup=true
        local watchdog_script=""
        for candidate in "$INSTALL_DIR/setup-watchdog.sh" "$script_dir/setup-watchdog.sh"; do
            if [[ -f "$candidate" ]]; then
                watchdog_script="$candidate"
                break
            fi
        done
        if [[ -n "$watchdog_script" ]]; then
            bash "$watchdog_script" install-timer < /dev/null || true
            if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
                watchdog_reinstalled_during_restore=true
            else
                warn "Couldn't reinstall the watchdog's timer automatically. See the reminder below."
            fi
        fi
        # Consumed, removed so it doesn't linger as a stale internal marker.
        rm -f "$INSTALL_DIR/watchdog-state/was-active-at-backup"
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
    if vpn_mode_active; then
        if $hook_installed_during_restore; then
            echo "  - VPN mode: the boot-safety hook (aiostreams-vpn-boot.service) has been"
            echo "    reinstalled on this server, so AIOStreams will come back correctly after"
            echo "    a reboot, gated on the tunnel, same as it did on the original server."
        else
            echo "  - VPN mode: the boot-safety hook (aiostreams-vpn-boot.service) lives outside"
            echo "    the backup and could NOT be installed automatically (setup-vpn-gluetun.sh"
            echo "    wasn't found in $INSTALL_DIR or next to this script), AIOStreams will not"
            echo "    survive this server's next reboot until you run 'sudo bash"
            echo "    setup-vpn-gluetun.sh' and choose 'Turn VPN ON' once to install it."
        fi
    fi
    if $watchdog_was_active_at_backup; then
        if $watchdog_reinstalled_during_restore; then
            echo "  - Watchdog: it was running before the backup, so its timer"
            echo "    (aiostreams-watchdog.timer) has been reinstalled on this server —"
            echo "    alerts will resume with no action needed."
        else
            echo "  - Watchdog: it was running before the backup, but its timer could NOT be"
            echo "    reinstalled automatically (setup-watchdog.sh wasn't found in $INSTALL_DIR"
            echo "    or next to this script), you won't get alerts until you run 'sudo bash"
            echo "    setup-watchdog.sh' and choose 'Start' once to reinstall it."
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
}

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# Under sudo, $HOME is root's home, not the invoking user's, so a backup
# tarball scp'd into the user's own home wouldn't be found. Resolve the real
# home via SUDO_USER/getent so restore's scan checks there too.
REAL_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    [[ -n "$sudo_home" && -d "$sudo_home" ]] && REAL_HOME="$sudo_home"
fi

for REQUIRED_CMD in curl openssl tar; do
    require_cmd "$REQUIRED_CMD" || error "Required command '$REQUIRED_CMD' not found. Install it first (e.g. 'apt-get install -y $REQUIRED_CMD') and re-run this script."
done

# Bug fix (confirmed happening in practice, repeatedly): under sudo, $HOME
# is root's home, not the invoking user's, so a script downloaded into a
# non-root sudo user's home (the common cloud-provider default) never
# actually reaches $INSTALL_DIR, and do_backup only tars $INSTALL_DIR.
# This keeps whatever copy is currently running synced there on every call.
sync_self_into_install_dir() {
    [[ -d "$INSTALL_DIR" ]] || return 0
    local dest="$INSTALL_DIR/setup-aiostreams.sh"
    [[ -f "$SELF_SCRIPT_PATH" ]] || return 0
    [[ "$SELF_SCRIPT_PATH" == "$dest" ]] && return 0
    if [[ ! -f "$dest" ]] || ! cmp -s "$SELF_SCRIPT_PATH" "$dest"; then
        if cp -- "$SELF_SCRIPT_PATH" "$dest" 2>/dev/null; then
            chmod +x "$dest" 2>/dev/null || true
            echo "(Synced this script into $INSTALL_DIR/setup-aiostreams.sh. That's the copy future backups will use.)"
        fi
    fi
    return 0
}
sync_self_into_install_dir

case "${1:-}" in
    backup)
        do_backup
        exit 0
        ;;
    restore)
        do_restore "${2:-}"
        exit 0
        ;;
esac

while true; do

sync_self_into_install_dir

if [[ -f "$COMPOSE_FILE" ]]; then
    if ! require_cmd docker || ! docker compose version >/dev/null 2>&1; then
        error "Existing AIOStreams config found at $INSTALL_DIR, but Docker/Compose isn't available. Reinstall Docker or remove $INSTALL_DIR to start fresh."
    fi

    # Derived from whether the systemd unit exists (not a marker file), so
    # it self-clears once the hook is installed.
    if grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null \
        && [[ ! -f /etc/systemd/system/aiostreams-vpn-boot.service ]]; then
        alert "VPN mode is configured but the boot-safety hook is not installed on this"
        alert "server. AIOStreams will not restart after a reboot. Fix: run"
        alert "'sudo bash setup-vpn-gluetun.sh' and choose \"Turn VPN ON\"."
    fi

    echo ""
    echo "Existing AIOStreams installation detected at $INSTALL_DIR"
    echo ""
    echo "What would you like to do?"
    echo "  1) View status"
    echo "  2) Stop AIOStreams"
    echo "  3) Start AIOStreams"
    echo "  4) Restart the stack (AIOStreams + Caddy, and the VPN if enabled)"
    echo "  5) Update (pull latest images + restart; can also switch stable/nightly)"
    echo "  6) Reconfigure (change domain/login, backs up current config)"
    echo "  7) Backup (one tarball with everything needed for migration or safekeeping)"
    echo "  8) Restore from backup (replaces this install. See docs/basic/backup-restore.md)"
    echo "  9) Uninstall (clean removal)"
    echo " 10) Exit"
    echo ""
    read -rp "Select an option [1-10]: " MENU_CHOICE

    case "$MENU_CHOICE" in
        1)
            echo ""
            echo "=== Container Status ==="
            cd "$INSTALL_DIR"
            docker compose ps
            echo ""
            echo "=== Recent Caddy cert log lines ==="
            docker compose logs caddy 2>/dev/null | grep -i "certificate" | tail -5 || echo "No cert-related log lines found."
            continue
            ;;
        2)
            echo ""
            cd "$INSTALL_DIR"
            echo "Stopping AIOStreams..."
            # Targets aiostreams only, caddy (and gluetun in VPN mode) stay
            # up, so the domain still responds (502) instead of going dark.
            docker compose stop aiostreams
            echo "Stopped. Caddy is still up (visitors get a 502) and, if VPN mode is"
            echo "on, the tunnel is untouched. Start (option 3) to bring it back."
            continue
            ;;
        3)
            echo ""
            cd "$INSTALL_DIR"

            warn_if_vpn_layer_off "Starting AIOStreams" || continue

            if vpn_mode_active; then
                echo "VPN mode detected, bringing the tunnel up before starting AIOStreams..."
                if vpn_gated_start_aiostreams --remove-orphans; then
                    echo "Started, tunnel confirmed."
                fi
            else
                # 'up -d' rather than 'start': also handles the case where
                # the container doesn't exist yet at all.
                docker compose up -d aiostreams
                echo "Started."
            fi
            echo ""
            echo "Check status with: docker compose ps"
            continue
            ;;
        4)
            echo ""
            cd "$INSTALL_DIR"
            if vpn_mode_active; then
                echo "VPN mode detected (gluetun present), recreating gluetun+caddy first, then"
                echo "gating aiostreams behind a confirmed tunnel, so it never re-attaches to a"
                echo "stale or not-yet-connected namespace..."
                vpn_gated_start_aiostreams --force-recreate --remove-orphans || true
            else
                warn_if_vpn_layer_off "Restarting the stack" || continue
                echo "Restarting the stack..."
                docker compose restart
            fi
            echo "Restarted. Check status with: docker compose ps"
            continue
            ;;
        5)
            echo ""
            cd "$INSTALL_DIR"

            echo "Update AIOStreams:"
            echo "  1) Backup first, then update"
            echo "  2) Update without backing up"
            echo "  3) Cancel"
            read -rp "Select an option [1-3]: " UPDATE_CHOICE
            case "$UPDATE_CHOICE" in
                1)
                    do_backup
                    echo ""
                    ;;
                2)
                    ;;
                *)
                    echo "Update cancelled."
                    continue
                    ;;
            esac

            CURRENT_TAG=$(grep "image: viren070/aiostreams:" "$COMPOSE_FILE" | head -n1 | sed 's/.*aiostreams://')
            [[ -z "$CURRENT_TAG" ]] && CURRENT_TAG="latest"
            echo ""
            echo "Current build channel: ${CURRENT_TAG}"
            read -rp "Switch build channel before updating? [y/N]: " SWITCH_CHANNEL
            if [[ "$SWITCH_CHANNEL" =~ ^[Yy]$ ]]; then
                echo "  1) Stable (latest)"
                echo "  2) Nightly"
                read -rp "Choice [1-2]: " NEW_CHANNEL_CHOICE
                case "$NEW_CHANNEL_CHOICE" in
                    1) NEW_TAG="latest" ;;
                    2) NEW_TAG="nightly" ;;
                    *)
                        warn "Not a valid choice, staying on ${CURRENT_TAG}."
                        NEW_TAG="$CURRENT_TAG"
                        ;;
                esac
                if [[ "$NEW_TAG" != "$CURRENT_TAG" ]]; then
                    echo ""
                    if [[ "$NEW_TAG" == "nightly" ]]; then
                        alert "You're switching to NIGHTLY, bleeding-edge builds off every commit."
                        alert "It can change behavior or break without notice."
                    else
                        alert "You're switching from nightly to stable. This is a DOWNGRADE."
                        alert "If nightly has moved ahead with a config/database format change stable"
                        alert "doesn't know about yet, stable may not read that data correctly."
                        warn "Consider backing up first (menu option 7) if you haven't already."
                    fi
                    read -rp "Continue switching to ${NEW_TAG}? [y/N]: " CONFIRM_CHANNEL_SWITCH
                    if [[ ! "$CONFIRM_CHANNEL_SWITCH" =~ ^[Yy]$ ]]; then
                        echo "Staying on ${CURRENT_TAG}."
                        NEW_TAG="$CURRENT_TAG"
                    fi
                fi
                if [[ "$NEW_TAG" != "$CURRENT_TAG" ]]; then
                    sed -i "s|image: viren070/aiostreams:.*|image: viren070/aiostreams:${NEW_TAG}|" "$COMPOSE_FILE"
                    info "Switched to ${NEW_TAG}, will pull and recreate below."
                fi
            fi

            warn_if_vpn_layer_off "Updating AIOStreams" || continue
            echo "Updating AIOStreams (pull + recreate)..."
            docker compose pull
            if vpn_mode_active; then
                echo "VPN mode detected, recreating gluetun+caddy first, then gating aiostreams"
                echo "behind a confirmed tunnel before it comes up on the new images..."
                vpn_gated_start_aiostreams --force-recreate --remove-orphans || true
            else
                docker compose up -d --force-recreate --remove-orphans
            fi
            echo ""
            echo "Update complete. Current images:"
            docker compose images
            continue
            ;;
        6)
            echo ""

            echo "Reconfigure AIOStreams:"
            echo "  1) Backup first, then reconfigure"
            echo "  2) Reconfigure without backing up"
            echo "  3) Cancel"
            read -rp "Select an option [1-3]: " RECONFIGURE_CHOICE
            case "$RECONFIGURE_CHOICE" in
                1)
                    do_backup
                    echo ""
                    ;;
                2)
                    ;;
                *)
                    echo "Reconfigure cancelled."
                    continue
                    ;;
            esac

            # The install flow below writes a fresh docker-compose.yml with
            # no VPN awareness, it would silently drop gluetun. Catch that
            # here before it happens. Captured into a flag (rather than
            # re-checked later) because by the time the restart step runs,
            # the live compose file has already been overwritten with the
            # new template, so vpn_mode_active would no longer say "vpn"
            # even if it was true when Reconfigure started.
            if vpn_mode_active; then
                RECONFIGURE_WAS_VPN_ACTIVE=true
                info "VPN mode is active"
                echo "Reconfigure's compose template doesn't include gluetun, so AIOStreams"
                echo "will come back up in direct mode (no VPN tunnel) once this finishes."
                echo "Run setup-vpn-gluetun.sh afterward whenever you want the VPN layer back."
                read -rp "Continue with reconfigure? [y/N]: " CONFIRM_RECONFIGURE_VPN
                if [[ ! "$CONFIRM_RECONFIGURE_VPN" =~ ^[Yy]$ ]]; then
                    echo "Reconfigure cancelled."
                    continue
                fi
            else
                warn_if_vpn_layer_off "Reconfiguring" || continue
            fi

            echo "Proceeding with reconfiguration. Current config will be backed up first."
            BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"
            cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak_${BACKUP_SUFFIX}"
            [[ -f "$CADDYFILE" ]] && cp "$CADDYFILE" "${CADDYFILE}.bak_${BACKUP_SUFFIX}"
            echo "Backed up to *.bak_${BACKUP_SUFFIX}"
            # falls through to the install flow below
            ;;
        9)
            echo ""
            echo "=== AIOStreams Uninstall ==="
            read -rp "Are you sure you want to completely remove AIOStreams? [y/N]: " CONFIRM_UNINSTALL
            if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
                echo "Uninstall cancelled."
                continue
            fi

            cd "$INSTALL_DIR"
            read -rp "Delete Docker volumes too? This removes your Caddy HTTPS certificates. [y/N]: " REMOVE_VOLUMES
            if [[ "$REMOVE_VOLUMES" =~ ^[Yy]$ ]]; then
                docker compose down -v --rmi local
                echo "Containers, volumes, and images removed."
            else
                docker compose down --rmi local
                echo "Containers and images removed (volumes preserved)."
            fi
            docker network rm "$SHARED_NET" >/dev/null 2>&1 || true

            read -rp "Delete the config directory ($INSTALL_DIR), including your SECRET_KEY backup? [y/N]: " REMOVE_CONFIG
            if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
                cd "$HOME"
                rm -rf "$INSTALL_DIR"
                echo "Configuration removed."
            else
                echo "Configuration preserved in $INSTALL_DIR"
                if [[ -d "$INSTALL_DIR/vpn-state" ]]; then
                    echo ""
                    warn "Note: $INSTALL_DIR/vpn-state contains your WireGuard PRIVATE KEY"
                    warn "(inside the saved VPN compose config)."
                    read -rp "Delete just the vpn-state directory (recommended if you're done with the VPN)? [y/N]: " REMOVE_VPN_STATE
                    if [[ "$REMOVE_VPN_STATE" =~ ^[Yy]$ ]]; then
                        rm -rf "$INSTALL_DIR/vpn-state"
                        echo "vpn-state removed. (Re-run setup-vpn-gluetun.sh any time to set the VPN up again.)"
                    else
                        echo "vpn-state preserved. Remember it holds your WireGuard private key."
                    fi
                fi
            fi

            echo ""
            echo "Uninstall complete."
            continue
            ;;
        7)
            echo ""
            do_backup
            continue
            ;;
        8)
            echo ""
            do_restore ""
            continue
            ;;
        10)
            echo "Exiting."
            exit 0
            ;;
        *)
            warn "Not a valid option."
            continue
            ;;
    esac
else
    info "AIOStreams self-hosted setup"
    echo ""
    echo "  1) Fresh install, sets up:"
    echo "       - Docker (installed automatically if missing)"
    echo "       - AIOStreams (the Stremio meta-addon)"
    echo "       - Caddy (reverse proxy with automatic HTTPS via Let's Encrypt)"
    echo "       - AIOStreams' built-in login, locking config creation/editing to your account only"
    echo ""
    echo "  2) Restore from a backup (migrating from another server), brings back your"
    echo "     whole stack from a tarball made by this script's Backup option, same"
    echo "     SECRET_KEY and all, so every existing user config and installed Stremio"
    echo "     manifest keeps working. Handles everything itself, including Docker."
    echo "     (Also available non-interactively:  sudo bash setup-aiostreams.sh restore <file>)"
    echo ""
    echo "After either path, you'll land back on the management menu, no need to"
    echo "re-run this script."
    echo ""
    read -rp "Select an option [1-2], or Ctrl+C to cancel: " FIRSTRUN_CHOICE
    case "$FIRSTRUN_CHOICE" in
        1)  ;;  # fall through to the fresh-install flow below
        2)
            do_restore ""
            continue
            ;;
        *)
            warn "Not a valid option."
            continue
            ;;
    esac
fi

info "A few questions before we start"

while true; do
    read -rp "Domain/subdomain for this instance (e.g. streams.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | xargs)  # trim whitespace

    if [[ -z "$DOMAIN" ]]; then
        warn "Domain cannot be empty."
        continue
    fi

    # Reject raw IPs, since Let's Encrypt needs a real domain name
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Please enter a domain name, not an IP address. Caddy needs a domain to issue an HTTPS certificate."
        continue
    fi

    # Hostname-safe chars only, also relied on by the sed calls in restore's
    # manual domain re-entry above.
    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        warn "Domain can only contain letters, numbers, dots, and hyphens (e.g. streams.example.com)."
        continue
    fi

    break
done

echo ""
echo "Checking DNS resolution for $DOMAIN..."
if require_cmd getent; then
    RESOLVED_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{ print $1 }' | head -n1 || true)
else
    RESOLVED_IP=$(ping -c1 "$DOMAIN" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' || true)
fi

if [[ -z "$RESOLVED_IP" ]]; then
    warn "Could not resolve $DOMAIN. If you haven't set the DNS A record yet, Caddy will fail to get an HTTPS certificate."
    read -rp "Continue anyway? (y/N): " CONTINUE_ANYWAY
    if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
        error "Aborting. Set up your DNS A record first, then re-run this script."
    fi
else
    PUBLIC_IP=""
    for SVC in "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        PUBLIC_IP=$(curl -fs4 --max-time 4 "$SVC" 2>/dev/null | tr -d ' \n') && [[ -n "$PUBLIC_IP" ]] && break
    done

    if [[ -z "$PUBLIC_IP" ]]; then
        echo "Resolved $DOMAIN -> $RESOLVED_IP (couldn't determine this server's own public IP to double check it matches)."
    elif [[ "$RESOLVED_IP" != "$PUBLIC_IP" ]]; then
        echo ""
        alert "DOMAIN / SERVER MISMATCH"
        alert "$DOMAIN currently resolves to $RESOLVED_IP, but THIS server's public IP is $PUBLIC_IP."
        alert "That usually means DNS is pointing somewhere else, a different server, or a typo."
        read -rp "Continue anyway? (y/N): " CONTINUE_ANYWAY
        if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
            error "Aborting. Point $DOMAIN's A record at $PUBLIC_IP, then re-run this script."
        fi
    else
        echo "Resolved $DOMAIN -> $RESOLVED_IP, matches this server."
    fi
fi

echo ""
while true; do
    read -rp "Username for logging into AIOStreams (configure page + dashboard): " AUTH_USER
    if [[ -z "$AUTH_USER" ]]; then
        warn "Username cannot be empty."
        continue
    fi
    # AIOSTREAMS_AUTH is a comma-separated list of user:pass pairs.
    if [[ ! "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "Username can only contain letters, numbers, dots, underscores, and hyphens."
        continue
    fi
    break
done

while true; do
    read -rsp "Password for that account (input hidden): " AUTH_PASS
    echo ""
    if [[ -z "$AUTH_PASS" ]]; then
        warn "Password cannot be empty. Try again."
        continue
    fi
    if [[ ${#AUTH_PASS} -lt 8 ]]; then
        warn "Please use at least 8 characters."
        continue
    fi
    # Stored in AIOSTREAMS_AUTH (user:pass,user:pass format) in
    # docker-compose.yml, so ':' ',' and shell/YAML-special chars are excluded.
    if [[ ! "$AUTH_PASS" =~ ^[A-Za-z0-9@%^*_+=.!?-]+$ ]]; then
        warn "Password can only contain letters, numbers, and these symbols: @ % ^ * _ + = . ! ? -"
        continue
    fi
    read -rsp "Confirm password: " AUTH_PASS_CONFIRM
    echo ""
    if [[ "$AUTH_PASS" != "$AUTH_PASS_CONFIRM" ]]; then
        warn "Passwords didn't match. Try again."
        continue
    fi
    break
done

DEFAULT_IMAGE_TAG="latest"
if [[ -f "$COMPOSE_FILE" ]] && grep -q "image: viren070/aiostreams:" "$COMPOSE_FILE"; then
    EXISTING_TAG=$(grep "image: viren070/aiostreams:" "$COMPOSE_FILE" | head -n1 | sed 's/.*aiostreams://')
    [[ -n "$EXISTING_TAG" ]] && DEFAULT_IMAGE_TAG="$EXISTING_TAG"
fi

echo ""
echo "Which AIOStreams build would you like to run?"
echo "  1) Stable (the 'latest' tag), recommended for most people"
echo "  2) Nightly (the 'nightly' tag), newest commits, built automatically on every"
echo "     push; can break or change behavior without notice"
read -rp "Choice [1-2] (current: ${DEFAULT_IMAGE_TAG}, Enter to keep): " IMAGE_CHANNEL_CHOICE
case "$IMAGE_CHANNEL_CHOICE" in
    1) IMAGE_TAG="latest" ;;
    2) IMAGE_TAG="nightly" ;;
    "") IMAGE_TAG="$DEFAULT_IMAGE_TAG" ;;
    *)
        warn "Not a valid choice, keeping ${DEFAULT_IMAGE_TAG}."
        IMAGE_TAG="$DEFAULT_IMAGE_TAG"
        ;;
esac

if [[ "$IMAGE_TAG" != "$DEFAULT_IMAGE_TAG" ]]; then
    echo ""
    if [[ "$IMAGE_TAG" == "nightly" ]]; then
        alert "You're switching to NIGHTLY, bleeding-edge builds off every commit."
        alert "It can change behavior or break without notice."
    else
        alert "You're switching from nightly to stable. This is a DOWNGRADE."
        alert "If nightly has moved ahead with a config/database format change stable"
        alert "doesn't know about yet, stable may not read that data correctly."
        [[ -f "$COMPOSE_FILE" ]] && warn "Consider backing up first (menu option 7) if you haven't already."
    fi
    read -rp "Continue switching to ${IMAGE_TAG}? [y/N]: " CONFIRM_CHANNEL_SWITCH
    if [[ ! "$CONFIRM_CHANNEL_SWITCH" =~ ^[Yy]$ ]]; then
        echo "Staying on ${DEFAULT_IMAGE_TAG}."
        IMAGE_TAG="$DEFAULT_IMAGE_TAG"
    fi
fi
info "Using image tag: viren070/aiostreams:${IMAGE_TAG}"

# ---------- optional: regex filters & synced filter templates ----------
#
# AIOStreams gates its regex-based stream filter and synced Stream Expression
# sync behind extra trust (SEL_SYNC_ACCESS / REGEX_FILTER_ACCESS), since
# without a login these could be abused. Once AIOSTREAMS_AUTH_REQUIRED=true
# is set (always true for installs from this script), AIOStreams' own docs
# say setting these to "all" is safe for a single-owner instance. Off by
# default: a fresh install has no configs yet, and most people never need it.
# Community-shared filter templates (e.g. regex-based sort/filter packs) are
# the main reason to turn this on, without it those templates fail silently.
#
# Asked ONLY on a genuinely fresh install (no existing compose file yet).
# On Reconfigure, this is deliberately NOT re-asked, it just carries forward
# whatever was already set, silently. Re-asking on every Reconfigure was the
# root of a real gap: setup-vpn-gluetun.sh's own compose template has no
# awareness of these two vars at all, so toggling VPN mode after answering
# this prompt could silently drop the setting without any clear signal why.
# Leaving it as a one-time fresh-install decision sidesteps that entirely,
# it's just carried along untouched from here on, VPN mode or not.
if [[ -f "$COMPOSE_FILE" ]]; then
    if grep -q "SEL_SYNC_ACCESS=all" "$COMPOSE_FILE" && grep -q "REGEX_FILTER_ACCESS=all" "$COMPOSE_FILE"; then
        ENABLE_ADVANCED_ACCESS=true
    else
        ENABLE_ADVANCED_ACCESS=false
    fi
else
    echo ""
    echo "Enable regex filters & synced filter templates? (recommended)"
    echo "  Turns on SEL_SYNC_ACCESS=all and REGEX_FILTER_ACCESS=all."
    echo "  Most community AIOStreams templates need this to work at all."
    echo "  Low-risk on a single-login instance; if you add more logins"
    echo "  later, every account gets this too, worth remembering."
    echo ""
    echo "    [Y] (recommended) Locks both to 'all', forced + read-only in"
    echo "        the dashboard. Convenient, but changing it back later"
    echo "        needs a docker-compose.yml edit or reinstall."
    echo ""
    echo "    [n] Leaves both toggles alone, fully editable in the"
    echo "        dashboard (Settings) any time. No downside to declining"
    echo "        now if you're not sure yet."
    echo ""
    read -rp "Enable? [Y/n]: " ADVANCED_ACCESS_CHOICE
    if [[ "$ADVANCED_ACCESS_CHOICE" =~ ^[Nn]$ ]]; then
        ENABLE_ADVANCED_ACCESS=false
        warn "If you later import a config and see errors mentioning regex or"
        warn "SEL (Stream Expression Language), log into the dashboard,"
        warn "go to Settings > user limits, and turn Regex Filter Access,"
        warn "and SEL Sync Access to 'all'. No YAML edit or reinstall needed."
        read -rp "Press Enter to continue... " _
    else
        ENABLE_ADVANCED_ACCESS=true
        info "Regex filters & synced templates will be enabled."
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

info "Setting up $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [[ -f "$COMPOSE_FILE" ]] && grep -q "SECRET_KEY=" "$COMPOSE_FILE"; then
    info "Reusing existing SECRET_KEY from current config (changing it would invalidate stored configs)"
    SECRET_KEY=$(grep "SECRET_KEY=" "$COMPOSE_FILE" | head -n1 | sed 's/.*SECRET_KEY=//')
else
    info "Generating SECRET_KEY (used to encrypt stored AIOStreams configs)"
    SECRET_KEY=$(openssl rand -hex 32)
fi

info "Writing docker-compose.yml"
ensure_caddy_dropin_dir

# Built as its own variable rather than an inline conditional in the heredoc
# below, since heredocs can't branch — empty string when the user opted out,
# so nothing extra lands in the file at all.
ADVANCED_ACCESS_ENV_LINES=""
if $ENABLE_ADVANCED_ACCESS; then
    ADVANCED_ACCESS_ENV_LINES="      # Opt-in (see setup prompt): unlocks regex-based stream filters and
      # synced Stream Expression templates. Safe alongside AUTH_REQUIRED=true.
      - SEL_SYNC_ACCESS=all
      - REGEX_FILTER_ACCESS=all"
fi

# umask 077 while writing: file contains SECRET_KEY and the login password.
OLD_UMASK=$(umask)
umask 077
cat > docker-compose.yml << EOF
services:
  aiostreams:
    image: viren070/aiostreams:${IMAGE_TAG}
    container_name: aiostreams
    restart: unless-stopped
    # Reuses the exact healthcheck command baked into the image, just runs
    # it every 5s instead of the image's default 30s, so the "waiting for
    # healthy" step below finishes faster. If a future image build moves
    # /app/scripts/healthcheck.js, this override will fail its checks and
    # the wait loop will time out with its usual warning, same as if this
    # override wasn't here at all.
    healthcheck:
      test: ["CMD", "/nodejs/bin/node", "/app/scripts/healthcheck.js"]
      interval: 5s
      timeout: 5s
      start_period: 5s
      retries: 3
    volumes:
      - ./data:/app/data
    environment:
      - PORT=3000
      - BASE_URL=https://${DOMAIN}
      - SECRET_KEY=${SECRET_KEY}
      # Built-in login: protects the configure page, dashboard, AND the
      # config API itself, nobody can create/edit configs without this login.
      - AIOSTREAMS_AUTH=${AUTH_USER}:${AUTH_PASS}
      - AIOSTREAMS_AUTH_REQUIRED=true
${ADVANCED_ACCESS_ENV_LINES}
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./caddy.d:/etc/caddy/caddy.d
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - aiostreams
    networks:
      - default
      - aios_shared
volumes:
  caddy_data:
  caddy_config:
networks:
  aios_shared:
    external: true
EOF
umask "$OLD_UMASK"

chmod 600 docker-compose.yml

info "Writing Caddyfile (HTTPS reverse proxy; access control is handled by AIOStreams' own login)"
cat > Caddyfile << EOF
${DOMAIN} {
    reverse_proxy aiostreams:3000
}

# Extra sites drop in here as their own files, so rewrites of THIS file
# never lose them. Zero matches is fine.
import caddy.d/*.caddy
EOF

ensure_shared_network

info "Pulling images"
MAX_RETRIES=3
attempt=1
until docker compose pull; do
    if [[ $attempt -ge $MAX_RETRIES ]]; then
        error "Failed to pull images after $MAX_RETRIES attempts. Check your network connection and try again."
    fi
    warn "Pull failed (attempt $attempt/$MAX_RETRIES), retrying in 5s..."
    attempt=$((attempt + 1))
    sleep 5
done

info "Starting containers"
docker compose up -d --force-recreate --remove-orphans

echo "Waiting for aiostreams to become healthy..."
MAX_WAIT=120; INTERVAL=5; elapsed=0; success=false
while [[ $elapsed -lt $MAX_WAIT ]]; do
    status=$(docker inspect -f '{{.State.Health.Status}}' aiostreams 2>/dev/null)
    if [[ "$status" == "healthy" ]]; then
        success=true
        break
    fi
    echo "  [${elapsed}s] status: ${status:-starting}"
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done
if $success; then
    echo "aiostreams is healthy (took ~${elapsed}s)."
else
    warn "aiostreams didn't report healthy after ${MAX_WAIT}s."
    warn "Check 'docker compose logs aiostreams' for details."
fi

if $RECONFIGURE_WAS_VPN_ACTIVE; then
    echo ""
    warn "AIOStreams is now running in DIRECT mode (no VPN tunnel)."
    warn "Reconfigure's compose template has no gluetun service, so VPN mode"
    warn "doesn't carry over automatically. Run 'sudo bash setup-vpn-gluetun.sh'"
    warn "whenever you want it back, no rush if you're just running direct for now."

    # setup-watchdog.sh decides whether to check gluetun's tunnel purely off
    # this marker, it has no other way of knowing VPN mode just ended.
    # Left untouched, it would keep checking a gluetun container that no
    # longer exists and fire a false "tunnel is down" alert after a couple
    # of failed checks, even though this was intentional. Setting it to
    # "direct" here is the same thing apply_mode() in setup-vpn-gluetun.sh
    # does on its own "Turn VPN OFF" path, so this just keeps the marker
    # honest a step earlier, before the watchdog ever gets a chance to
    # notice anything is "wrong".
    VPN_STATE_DIR="$INSTALL_DIR/vpn-state"
    if [[ -f "$VPN_STATE_DIR/active" ]]; then
        echo "direct" > "$VPN_STATE_DIR/active"
        if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
            echo "Watchdog is running, it checks that marker directly, so it'll correctly"
            echo "skip the tunnel check from now on instead of alerting on a false 'down'."
        fi
    fi
fi

wait_for_cert_and_diagnose "$DOMAIN"

CREDS_FILE="$INSTALL_DIR/CREDENTIALS.txt"
OLD_UMASK=$(umask)
umask 077
cat > "$CREDS_FILE" << EOF
AIOStreams self-hosted setup, credentials generated on $(date)

Site URL:         https://${DOMAIN}
Login username:   ${AUTH_USER}
Login password:   (the one you typed in, write it down in your password manager)

Note: the username & password also live in ~/aiostreams/docker-compose.yml
(the AIOSTREAMS_AUTH line) because AIOStreams reads them from there on startup.
That file is readable by root only (chmod 600). If you ever change the
password, edit that line and run: docker compose up -d

SECRET_KEY (do NOT lose this, cannot be changed later without resetting stored configs):
${SECRET_KEY}

Reminder: move this file somewhere safe (password manager, encrypted notes) and then delete it from the server:
  rm ${CREDS_FILE}
EOF
umask "$OLD_UMASK"
chmod 600 "$CREDS_FILE"

info "Done!"
echo ""
if $RECONFIGURE_WAS_VPN_ACTIVE; then
    echo "Note: running in direct mode (VPN not carried over). Run setup-vpn-gluetun.sh"
    echo "whenever you want the VPN layer back."
    echo ""
fi
echo -e "Visit: \033[1;36mhttps://${DOMAIN}\033[0m"
echo "Log in with the username/password you just set (AIOStreams' own login page)."
echo ""
echo "Config creation and editing now require that login, including the API,"
echo "not just the web pages, so nobody else can piggyback on your instance."
echo ""
echo "IMPORTANT:"
echo -e "  - Your SECRET_KEY and login username are saved to: \033[1;36m$CREDS_FILE\033[0m"
echo "  - Move that file somewhere safe (off the server) and then delete it,"
echo "    it currently sits in plaintext on disk."
echo "    log in, and hit Save once so it picks up the new access protection."
if $ENABLE_ADVANCED_ACCESS; then
    echo "  - Regex filters & synced filter templates are ENABLED (SEL_SYNC_ACCESS=all,"
    echo "    REGEX_FILTER_ACCESS=all), locked read-only in the dashboard. Edit"
    echo "    docker-compose.yml directly to turn it off, Reconfigure won't touch it."
else
    echo "  - Regex filters & synced filter templates are OFF for now, but both"
    echo "    toggles are fully editable in the dashboard (Settings) whenever you"
    echo "    need them, no YAML edit or reinstall required."
fi
echo ""
echo "Useful commands:"
echo "  cd $INSTALL_DIR && docker compose ps         # check container status"
echo "  cd $INSTALL_DIR && docker compose logs -f     # tail logs"
echo ""
read -rp "Press Enter to return to the menu... " _

done
