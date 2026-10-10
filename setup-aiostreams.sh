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

# Image cleanup after updates. Remembers each image's ID before a pull,
# then removes just the old copies that pull replaced. Only ever touches
# this stack's own images, and Docker refuses to delete one a container
# still uses, so anything not recreated keeps its old image (no harm).
snapshot_image_ids() {
    local ref
    for ref in "$@"; do
        printf '%s %s\n' "$ref" "$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || echo none)"
    done
}

cleanup_replaced_images() {
    local ref old new freed=0
    while read -r ref old; do
        [[ -z "$ref" || -z "$old" || "$old" == "none" ]] && continue
        new=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || echo none)
        if [[ "$new" != "$old" ]] && docker image rm "$old" >/dev/null 2>&1; then
            freed=$((freed + 1))
        fi
    done <<< "$1"
    if (( freed > 0 )); then
        echo "Removed $freed old image(s) replaced by this update, to free disk space."
    fi
    return 0
}

compose_image_refs() {
    grep -oP '^\s*image:\s*\K\S+' "$1" 2>/dev/null || true
}

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

    # Only warn if the VPN was actually set up and then switched off. The
    # 'active' marker is written only once setup completes; the vpn-state
    # folder itself is created as soon as setup-vpn-gluetun.sh is opened,
    # so checking for the folder warned people who never set a VPN up.
    [[ -f "$INSTALL_DIR/vpn-state/active" ]] || return 0
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
        rm -f "$STOPPED_MARKER"
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

# Install folder. New installs, and servers moved with
# 'sudo bash setup-aiostreams.sh migrate', use /opt/aiostreams: one path for
# root and every sudo user. A server set up before that keeps its old
# ~/aiostreams under root's home until it is migrated. The same rule is in
# every setup-*.sh and in setup-ui.sh, so keep them identical.
OPT_INSTALL_DIR="/opt/aiostreams"
LEGACY_INSTALL_DIR=""
for _legacy in "${HOME:-/root}/aiostreams" "$(getent passwd root 2>/dev/null | cut -d: -f6)/aiostreams"; do
    if [[ "$_legacy" == /*/aiostreams && "$_legacy" != "$OPT_INSTALL_DIR" && ! -L "$_legacy" \
        && -f "$_legacy/docker-compose.yml" ]]; then
        LEGACY_INSTALL_DIR="$_legacy"
        break
    fi
done
unset _legacy
if [[ -n "$LEGACY_INSTALL_DIR" && ! -f "$OPT_INSTALL_DIR/docker-compose.yml" ]]; then
    INSTALL_DIR="$LEGACY_INSTALL_DIR"
else
    INSTALL_DIR="$OPT_INSTALL_DIR"
fi

# Root's home: where backup tarballs are written, same as always. Looked up
# rather than taken from $HOME, so a caller that sets HOME to something else
# (an older control panel passes the install folder's parent, which is /opt
# after a migrate) can't scatter tarballs into /opt.
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"
ROOT_HOME="${ROOT_HOME:-/root}"

# Everything derived from INSTALL_DIR, in one place so 'migrate' can switch
# to the new folder halfway through a run.
set_install_paths() {
    INSTALL_DIR="$1"
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
    CADDYFILE="$INSTALL_DIR/Caddyfile"
    CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"
    # Written by "Stop AIOStreams" so the watchdog knows a stopped aiostreams is
    # deliberate and doesn't page you. Cleared on any start; the watchdog also
    # clears it itself whenever it sees aiostreams running again.
    STOPPED_MARKER="$INSTALL_DIR/aiostreams-stopped-on-purpose"
    # Legacy installs keep writing backups next to themselves, exactly as
    # before. /opt installs write them to root's home.
    if [[ "$INSTALL_DIR" == "$OPT_INSTALL_DIR" ]]; then
        BACKUP_HOME="$ROOT_HOME"
    else
        BACKUP_HOME="$(dirname "$INSTALL_DIR")"
    fi
}
set_install_paths "$INSTALL_DIR"

SHARED_NET="aios_shared"

# Canonical list of scripts that belong in $INSTALL_DIR (and, for
# convenience, in the invoking user's own ~/aiostreams too). Used both by
# do_backup's mismatch check and by do_restore's copy-back-to-user step, so
# the two stay in sync and neither one silently drops a script again.
AIOSTREAMS_SCRIPTS=(setup-aiostreams.sh setup-vpn-gluetun.sh setup-watchdog.sh setup-webhook.sh setup-mediaflow.sh)

# Set by the Reconfigure menu option only, when it needs the final restart
# (further down) to know whether to bring the stack back up through the
# tunnel-confirmed VPN gate instead of a plain restart. Defaults to false so
# a fresh install (which never touches this flag) doesn't trip `set -u`.
RECONFIGURE_WAS_VPN_ACTIVE=false

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

# Set by do_backup to the tarball it wrote, empty when it was cancelled.
LAST_BACKUP_FILE=""

do_backup() {
    LAST_BACKUP_FILE=""
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
    # A ~/aiostreams that is just a link to the install folder (the /opt
    # layout) has nothing to compare.
    if [[ "$REAL_HOME" != "$BACKUP_HOME" && -d "$REAL_HOME/aiostreams" ]] \
        && ! [[ "$REAL_HOME/aiostreams" -ef "$INSTALL_DIR" ]]; then
        local script_mismatch=() sname
        for sname in "${AIOSTREAMS_SCRIPTS[@]}"; do
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
    LAST_BACKUP_FILE="$out"
    size=$(du -h "$out" | cut -f1)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    echo -e "Backup written: \033[1;36m$out\033[0m (${size})"

    # Under sudo, $REAL_HOME differs from root's home, also drop a copy
    # there so the invoking user can access it directly.
    if [[ "$REAL_HOME" != "$BACKUP_HOME" ]]; then
        local user_copy="$REAL_HOME/aiostreams-backup-${ts}.tar.gz"
        if cp -- "$out" "$user_copy" 2>/dev/null; then
            chmod 600 "$user_copy"
            if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
                chown "$SUDO_UID:$SUDO_GID" "$user_copy" 2>/dev/null || true
            fi
            echo -e "Also copied to: \033[1;36m$user_copy\033[0m (owned by $SUDO_USER, so you can scp it directly)"
        else
            warn "Could not also copy the backup to $REAL_HOME. The copy in $BACKUP_HOME above is still good."
        fi
    fi
    echo ""
    echo "Copy it OFF this server now, from your local machine:"
    if [[ "$REAL_HOME" != "$BACKUP_HOME" ]]; then
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
    if [[ "$REAL_HOME" != "$BACKUP_HOME" ]]; then
        warn "That applies to BOTH copies above, delete the one in $BACKUP_HOME too once you're done."
    fi
    [[ -t 0 ]] && read -rp "Continue now that you've read this... " _
}

remove_addons_on_uninstall() {
    local removed=()
    if [[ -f /etc/systemd/system/aiostreams-watchdog.timer ]]; then
        systemctl disable --now aiostreams-watchdog.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aiostreams-watchdog.timer /etc/systemd/system/aiostreams-watchdog.service
        removed+=("watchdog timer")
    fi
    if [[ -f /etc/systemd/system/aiostreams-vpn-boot.service ]]; then
        systemctl disable aiostreams-vpn-boot.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aiostreams-vpn-boot.service /usr/local/bin/aiostreams-vpn-boot.sh
        removed+=("VPN boot hook")
    fi
    if [[ -f "$INSTALL_DIR/webhook-relay-state/docker-compose.yml" ]]; then
        (cd "$INSTALL_DIR/webhook-relay-state" && docker compose -f docker-compose.yml down >/dev/null 2>&1) || \
            docker rm -f aios-webhook-relay >/dev/null 2>&1 || true
        removed+=("webhook relay container")
    fi
    if [[ -f "$INSTALL_DIR/mediaflow-state/docker-compose.yml" ]]; then
        (cd "$INSTALL_DIR/mediaflow-state" && docker compose -f docker-compose.yml down >/dev/null 2>&1) || \
            docker rm -f mediaflow-proxy-light >/dev/null 2>&1 || true
        removed+=("MediaFlow Proxy Light container")
    fi
    # fail2ban can refuse to start at all if a jail's log file is missing, so
    # leaving this behind after ~/aiostreams is deleted would also take
    # down any other jails on the server (SSH included).
    if [[ -f /etc/fail2ban/jail.d/aios-mediaflow.conf ]]; then
        rm -f /etc/fail2ban/jail.d/aios-mediaflow.conf /etc/fail2ban/filter.d/aios-mediaflow.conf
        systemctl restart fail2ban >/dev/null 2>&1 || true
        removed+=("MediaFlow fail2ban jail")
    fi
    if [[ -f /etc/systemd/system/aios-webhook-boot-notify.service ]]; then
        systemctl disable aios-webhook-boot-notify.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aios-webhook-boot-notify.service
        removed+=("webhook reboot notification")
    fi
    if (( ${#removed[@]} > 0 )); then
        systemctl daemon-reload >/dev/null 2>&1 || true
        local joined
        joined=$(printf '%s, ' "${removed[@]}")
        echo "Also removed add-ons: ${joined%, }."
        echo "(Their saved settings stay in $INSTALL_DIR unless you delete that below.)"
    fi
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
        for f in "$BACKUP_HOME"/*aiostreams*.tar.gz "$HOME"/*aiostreams*.tar.gz "$REAL_HOME"/*aiostreams*.tar.gz "$PWD"/*aiostreams*.tar.gz; do
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
    # Resolve to an absolute path now, before anything below can move
    # directories around, a relative path (e.g. typed by hand, or passed
    # as the CLI arg) would otherwise silently break the INSTALL_DIR-move
    # check just below, since string-prefix matching needs both sides in
    # the same (absolute) form. -P resolves links too, so a tarball reached
    # through a ~/aiostreams link still counts as inside the install folder.
    tarball="$(cd "$(dirname "$tarball")" && pwd -P)/$(basename "$tarball")"
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
        aside="$(dirname "$INSTALL_DIR")/aiostreams.pre-restore-$(date +%Y%m%d-%H%M%S)"
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
    # Only the aiostreams/ folder: a tarball with anything else in it can't
    # drop files elsewhere in root's home (e.g. ~/.ssh). Every backup, old or
    # new, stores the folder as aiostreams/, so this lands it in
    # $INSTALL_DIR whichever layout this server uses.
    mkdir -p "$(dirname "$INSTALL_DIR")"
    tar xzf "$tarball" -C "$(dirname "$INSTALL_DIR")" aiostreams
    if [[ "$INSTALL_DIR" == "$OPT_INSTALL_DIR" ]]; then
        secure_install_dir
    fi
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

    # Scripts travel inside $INSTALL_DIR in the tarball, so the tar xzf
    # above already put them back at $INSTALL_DIR (root's copy). But under
    # sudo as a non-root user, people also keep a convenience copy in their
    # own ~/aiostreams (that's where they scp the tarball to and run this
    # script from). Nothing restores that copy unless we do it here too,
    # same idea as the WireGuard .conf restore just above.
    # In the /opt layout there is no separate copy: ~/aiostreams becomes a
    # link to the install folder instead (link_install_shortcuts).
    local script_restored_count=0
    if [[ "$INSTALL_DIR" == "$OPT_INSTALL_DIR" ]]; then
        # The copy of this script being run wins over the one in the
        # tarball, the same as the next run's sync would do.
        sync_self_into_install_dir
        link_install_shortcuts
    elif [[ "$REAL_HOME" != "$BACKUP_HOME" ]] && ! [[ "$REAL_HOME/aiostreams" -ef "$INSTALL_DIR" ]]; then
        mkdir -p "$REAL_HOME/aiostreams"
        for sname in "${AIOSTREAMS_SCRIPTS[@]}"; do
            local src="$INSTALL_DIR/$sname"
            [[ -f "$src" ]] || continue
            local dest="$REAL_HOME/aiostreams/$sname"
            if cp -- "$src" "$dest" 2>/dev/null; then
                chmod 664 "$dest"
                if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
                    chown "$SUDO_UID:$SUDO_GID" "$dest" 2>/dev/null || true
                    chown "$SUDO_UID:$SUDO_GID" "$REAL_HOME/aiostreams" 2>/dev/null || true
                fi
                script_restored_count=$((script_restored_count + 1))
            fi
        done
        if (( script_restored_count > 0 )); then
            echo "Restored $script_restored_count script(s) to $REAL_HOME/aiostreams (your convenience copy)."
        fi
    fi

    check_restored_domain_dns

    ensure_shared_network
    ensure_caddy_dropin_dir   # no-op on current backups; creates it for pre-drop-in ones

    warn_if_vpn_layer_off "Restoring" || { echo "Restore cancelled, nothing started."; return 0; }

    info "Starting the restored stack"

    # Restoring a backup brings back a database that may be from a newer app
    # version than whatever image happens to be cached locally on this box
    # (e.g. left over from before an uninstall, or just never pulled since).
    # Starting on a stale image against a newer database fails with a
    # migration-mismatch error, so always pull fresh before bringing it up.
    info "Pulling current images before starting"
    local image_snapshot
    # shellcheck disable=SC2046  # image refs never contain spaces
    image_snapshot=$(snapshot_image_ids $(compose_image_refs "$COMPOSE_FILE"))
    if ! (cd "$INSTALL_DIR" && docker compose pull); then
        # Read the actual tag this restore uses (could be nightly, not latest)
        # so the fallback command tells you to pull the right one.
        RESTORED_TAG=$(sed -n 's/.*image: viren070\/aiostreams:\([^[:space:]]*\).*/\1/p' "$COMPOSE_FILE" 2>/dev/null | head -n1)
        RESTORED_TAG=${RESTORED_TAG:-latest}
        warn "Pull failed or partially failed - continuing with whatever's cached. If the stack fails to start with a database-migration error, run 'sudo docker pull viren070/aiostreams:${RESTORED_TAG}' manually and retry (this restore uses the '${RESTORED_TAG}' tag)."
    fi

    hook_installed_during_restore=false
    watchdog_reinstalled_during_restore=false
    webhook_relay_reinstalled_during_restore=false
    mediaflow_reinstalled_during_restore=false
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
    cleanup_replaced_images "$image_snapshot"

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

    # Same pattern again for the webhook relay: independent of the VPN
    # branch above, decided purely by whether it was running at backup time.
    webhook_relay_was_active_at_backup=false
    if [[ -f "$INSTALL_DIR/webhook-relay-state/was-active-at-backup" ]]; then
        webhook_relay_was_active_at_backup=true
        local webhook_script=""
        for candidate in "$INSTALL_DIR/setup-webhook.sh" "$script_dir/setup-webhook.sh"; do
            if [[ -f "$candidate" ]]; then
                webhook_script="$candidate"
                break
            fi
        done
        if [[ -n "$webhook_script" ]]; then
            ensure_shared_network
            bash "$webhook_script" start-relay < /dev/null || true
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aios-webhook-relay; then
                webhook_relay_reinstalled_during_restore=true
            else
                warn "Couldn't restart the webhook relay automatically. See the reminder below."
            fi
        fi
        rm -f "$INSTALL_DIR/webhook-relay-state/was-active-at-backup"
    fi

    # Same pattern again for MediaFlow Proxy Light: independent of the VPN
    # branch above, decided purely by whether it was running at backup time.
    mediaflow_was_active_at_backup=false
    if [[ -f "$INSTALL_DIR/mediaflow-state/was-active-at-backup" ]]; then
        mediaflow_was_active_at_backup=true
        local mediaflow_script=""
        for candidate in "$INSTALL_DIR/setup-mediaflow.sh" "$script_dir/setup-mediaflow.sh"; do
            if [[ -f "$candidate" ]]; then
                mediaflow_script="$candidate"
                break
            fi
        done
        if [[ -n "$mediaflow_script" ]]; then
            ensure_shared_network
            bash "$mediaflow_script" start-mediaflow < /dev/null || true
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mediaflow-proxy-light; then
                mediaflow_reinstalled_during_restore=true
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
    if $webhook_relay_was_active_at_backup; then
        if $webhook_relay_reinstalled_during_restore; then
            echo "  - Webhook relay: it was running before the backup, so the container is back"
            echo "    up with the same subdomain/token/ntfy topic — nothing else needed. If this"
            echo "    is a NEW server, remember its subdomain also needs its own DNS A record"
            echo "    pointed here, same as the main domain above."
        else
            echo "  - Webhook relay: it was running before the backup, but could NOT be"
            echo "    restarted automatically (setup-webhook.sh wasn't found in $INSTALL_DIR"
            echo "    or next to this script), it won't receive events until you run 'sudo bash"
            echo "    setup-webhook.sh' and choose 'Start' once to bring it back up."
        fi
    fi
    if $mediaflow_was_active_at_backup; then
        if $mediaflow_reinstalled_during_restore; then
            echo "  - MediaFlow Proxy Light: it was running before the backup, so it's back up"
            echo "    with the same subdomain/password — nothing else needed. If this is a NEW"
            echo "    server, remember its subdomain also needs its own DNS A record pointed"
            echo "    here, same as the main domain above."
        else
            echo "  - MediaFlow Proxy Light: it was running before the backup, but could NOT be"
            echo "    restarted automatically (setup-mediaflow.sh wasn't found in $INSTALL_DIR"
            echo "    or next to this script), it won't be reachable until you run 'sudo bash"
            echo "    setup-mediaflow.sh' and choose Start to bring it back up."
        fi
    fi
    if (( conf_restored_count > 0 )); then
        echo "  - WireGuard .conf: $conf_restored_count original file(s) restored to /root"
        echo "    and/or $REAL_HOME, same as they were on the old server (convenience"
        echo "    copies for quick reconfigures, not required for the VPN layer itself)."
    fi
    if (( script_restored_count > 0 )); then
        echo "  - Scripts: $script_restored_count file(s) restored to $REAL_HOME/aiostreams,"
        echo "    same convenience copy you had on the old server (the real copy that"
        echo "    actually runs the install lives in $INSTALL_DIR)."
    fi
    echo "  - Verify by logging into the AIOStreams page and playing one stream from a"
    echo "    device that already had the addon installed. Keep the old server running"
    echo "    until that works. It's your rollback."
}

# ---------------------------------------------------------------------------
# The /opt layout: shortcut links, and 'migrate' for servers set up before it.
# ---------------------------------------------------------------------------

# /opt/aiostreams holds the SECRET_KEY, logins and (with the VPN) a WireGuard
# private key, which root's home used to keep private. Root-only, except
# that the sudo user running this gets read access through their group, so
# 'cd ~/aiostreams' and SFTP browsing still work for them (they can already
# read all of it through sudo). Writing still needs sudo or root.
secure_install_dir() {
    local dir="${1:-$INSTALL_DIR}"
    chown root:root "$dir" 2>/dev/null || true
    if [[ -n "${SUDO_GID:-}" && "${SUDO_GID}" != 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        chgrp "$SUDO_GID" "$dir" 2>/dev/null && chmod 750 "$dir" && return 0
    fi
    chmod 700 "$dir"
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

# True when this runs inside the control panel's web terminal (root or user
# shell). Those processes share the panel container's cgroup namespace, so
# compare against it rather than trusting an environment variable alone,
# which sudo clears for the user shell.
in_panel_terminal() {
    [[ "${AIOS_UI_TERMINAL:-}" == "1" ]] && return 0
    local pid mine
    pid=$(docker inspect -f '{{.State.Pid}}' aios-ui 2>/dev/null) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    mine=$(readlink /proc/self/ns/cgroup 2>/dev/null) || return 1
    [[ -n "$mine" && "$mine" == "$(readlink "/proc/$pid/ns/cgroup" 2>/dev/null)" \
        && "$mine" != "$(readlink /proc/1/ns/cgroup 2>/dev/null)" ]]
}

# /opt layout only. Gives root, and the sudo user running this, a
# ~/aiostreams that is just a link to the install folder, so 'cd ~/aiostreams'
# and every older doc keep working. A real ~/aiostreams folder from before is
# removed when all it holds is identical copies of these scripts; anything
# else in it means it is renamed to ~/aiostreams.old-<time> instead, so
# nothing is ever deleted that isn't already in the install folder.
link_install_shortcuts() {
    [[ "$INSTALL_DIR" == "$OPT_INSTALL_DIR" && -d "$INSTALL_DIR" ]] || return 0
    local homes=("$ROOT_HOME") h link aside name owner moved_into=false
    if [[ -n "${REAL_HOME:-}" && "$REAL_HOME" != "$ROOT_HOME" ]]; then
        homes+=("$REAL_HOME")
    fi
    for h in "${homes[@]}"; do
        [[ -d "$h" ]] || continue
        link="$h/aiostreams"
        if [[ -L "$link" ]]; then
            if [[ "$link" -ef "$INSTALL_DIR" ]]; then
                continue
            fi
            warn "$link is a link to $(readlink "$link"), not to $INSTALL_DIR. Left it alone."
            continue
        elif [[ -d "$link" ]]; then
            if [[ -f "$link/docker-compose.yml" ]]; then
                warn "$link has a docker-compose.yml of its own, so it was left alone."
                warn "Only one of $link and $INSTALL_DIR should hold the install. Check which is in use."
                continue
            fi
            for name in "${AIOSTREAMS_SCRIPTS[@]}"; do
                [[ -f "$link/$name" && ! -L "$link/$name" ]] || continue
                # One the install folder doesn't have yet (say an add-on
                # downloaded but never run) moves in, the way running it would.
                if [[ ! -e "$INSTALL_DIR/$name" ]]; then
                    cp -- "$link/$name" "$INSTALL_DIR/$name" && chmod 755 "$INSTALL_DIR/$name"
                fi
                if cmp -s "$link/$name" "$INSTALL_DIR/$name"; then
                    rm -f -- "$link/$name"
                fi
            done
            if ! rmdir -- "$link" 2>/dev/null; then
                aside="$h/aiostreams.old-$(date +%Y%m%d-%H%M%S)"
                mv -- "$link" "$aside"
                echo "Your old $link had other files in it too, so it was renamed to"
                echo "$aside. Nothing in it was deleted. Remove it once you've checked it."
            fi
            moved_into=true
        elif [[ -e "$link" ]]; then
            warn "$link exists and isn't a folder. Left it alone."
            continue
        fi
        ln -s -- "$INSTALL_DIR" "$link"
        owner=$(stat -c '%u:%g' "$h" 2>/dev/null) || owner=""
        if [[ -n "$owner" ]]; then
            chown -h "$owner" "$link" 2>/dev/null || true
        fi
        echo "$link is now a shortcut to $INSTALL_DIR."
    done
    if $moved_into; then
        echo "(If your terminal was sitting in the old folder, run 'cd ~/aiostreams' to land in the new one.)"
    fi
    return 0
}

# Undoes link_install_shortcuts, for uninstall and 'migrate undo'.
remove_install_shortcuts() {
    local target="$1" h
    for h in "$ROOT_HOME" "${REAL_HOME:-}"; do
        [[ -n "$h" ]] || continue
        if [[ -L "$h/aiostreams" && "$(readlink "$h/aiostreams")" == "$target" ]]; then
            rm -f -- "$h/aiostreams"
        fi
    done
    return 0
}

# Files outside the install folder that can have its absolute path written
# into them. Each is generated by one of the scripts, but regenerating them
# through those scripts would also enable, start or test things, so migrate
# rewrites the path in place instead (and 'migrate undo' rewrites it back).
MIGRATE_EXTERNAL_FILES=(
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
    for f in "${MIGRATE_EXTERNAL_FILES[@]}"; do
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

# Stops everything that has files open in the install folder, remembering
# what was running so migrate_start_all brings back the same set. The panel
# only mounts the folder read-only, so it is only stopped when the move has
# to copy across disks.
migrate_stop_all() {
    local dir="$1" stop_panel="$2"
    M_WATCHDOG=false; M_STACK=false; M_AIO=false; M_MEDIAFLOW=false; M_RELAY=false; M_PANEL=false
    if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
        M_WATCHDOG=true
        systemctl stop aiostreams-watchdog.timer 2>/dev/null || true
        echo "Paused the watchdog, so it doesn't alert while things are stopped."
    fi
    if container_running aiostreams; then M_AIO=true; M_STACK=true; fi
    if container_running caddy || container_running gluetun; then M_STACK=true; fi
    if container_running mediaflow-proxy-light; then M_MEDIAFLOW=true; fi
    if container_running aios-webhook-relay; then M_RELAY=true; fi
    if container_running aios-ui; then M_PANEL=true; fi

    info "Stopping the stack"
    if [[ -f "$dir/mediaflow-state/docker-compose.yml" ]]; then
        (cd "$dir/mediaflow-state" && docker compose -f docker-compose.yml stop) || true
    fi
    if [[ -f "$dir/webhook-relay-state/docker-compose.yml" ]]; then
        (cd "$dir/webhook-relay-state" && docker compose -f docker-compose.yml stop) || true
    fi
    (cd "$dir" && docker compose stop) || warn "docker compose stop reported a problem. Carrying on, the move itself doesn't need Docker."
    if $stop_panel && [[ -f "$dir/ui-state/docker-compose.yml" ]]; then
        (cd "$dir/ui-state" && docker compose -f docker-compose.yml stop) || true
    fi
    return 0
}

migrate_start_all() {
    local dir="$1"
    cd "$dir" || { warn "Could not cd to $dir, nothing was started."; return 1; }
    if $M_STACK; then
        info "Starting the stack from $dir"
        if vpn_mode_active; then
            if $M_AIO; then
                vpn_gated_start_aiostreams || warn "AIOStreams didn't come back up. See the message above, then use Start (option 3)."
            else
                docker compose up -d --no-deps gluetun caddy || warn "gluetun/caddy didn't start. Check 'docker compose logs' in $dir."
            fi
        else
            if $M_AIO; then
                docker compose up -d || warn "The stack didn't start cleanly. Check 'docker compose logs' in $dir."
            else
                docker compose up -d --no-deps caddy || warn "caddy didn't start. Check 'docker compose logs caddy' in $dir."
            fi
        fi
    else
        echo "The stack wasn't running before, so it was left stopped."
    fi
    if $M_MEDIAFLOW; then
        (cd "$dir/mediaflow-state" && docker compose -f docker-compose.yml up -d) || \
            warn "MediaFlow Proxy Light didn't start. Run 'sudo bash setup-mediaflow.sh' and choose Start."
    fi
    if $M_RELAY; then
        (cd "$dir/webhook-relay-state" && docker compose -f docker-compose.yml up -d) || \
            warn "The webhook relay didn't start. Run 'sudo bash setup-webhook.sh' and choose Start."
    fi
    if $M_WATCHDOG; then
        systemctl start aiostreams-watchdog.timer 2>/dev/null || \
            warn "Couldn't resume the watchdog. Run 'sudo bash setup-watchdog.sh' and choose Start."
    fi
    return 0
}

# Recreates the control panel so its mounts point at the new folder. Runs a
# few seconds later as its own systemd unit: from the panel's web terminal,
# recreating the panel directly would kill this very shell halfway.
recreate_panel() {
    local dir="$1/ui-state"
    [[ -f "$dir/docker-compose.yml" ]] || return 0
    if require_cmd systemd-run && systemd-run --quiet --collect --unit="aios-ui-recreate-$(date +%s)" \
            /bin/bash -c "sleep 4; cd $(printf '%q' "$dir") && docker compose -f docker-compose.yml up -d --force-recreate --no-build" \
            >/dev/null 2>&1; then
        echo "The control panel restarts on the new folder in a few seconds. If you're"
        echo "using it right now, its terminal disconnects; reload the page after that."
    else
        (cd "$dir" && docker compose -f docker-compose.yml up -d --force-recreate --no-build) || \
            warn "Couldn't restart the control panel. Run 'sudo bash setup-ui.sh' and choose Start."
    fi
}

# Shared by migrate and 'migrate undo': summary of what was rewritten and
# what still mentions the old path (it keeps working through the link).
report_path_rewrite() {
    local from="$1" dir="$2" f left=()
    if (( ${#REWRITTEN_FILES[@]} > 0 )); then
        echo "Updated the folder path in:"
        for f in "${REWRITTEN_FILES[@]}"; do echo "  - $f"; done
    fi
    while IFS= read -r -d '' f; do
        if grep -qE -- "$(printf '%s' "$from" | sed 's/[][\.*^$+?(){}|]/\\&/g')([/:\"'[:space:]]|\$)" "$f" 2>/dev/null; then
            left+=("$f")
        fi
    done < <(install_path_files "$dir")
    if (( ${#left[@]} > 0 )); then
        warn "These still mention $from:"
        for f in "${left[@]}"; do warn "  - $f"; done
    fi
    return 0
}

# Shared checks before moving the folder either way. Sets M_SAME_FS.
migrate_preflight() {
    local from="$1" to_parent="$2"
    require_cmd docker && docker compose version >/dev/null 2>&1 || \
        error "Docker with the compose plugin is needed to stop and start the stack."
    mkdir -p "$to_parent"
    M_SAME_FS=true
    if [[ "$(stat -c %d "$from")" != "$(stat -c %d "$to_parent")" ]]; then
        M_SAME_FS=false
        if in_panel_terminal; then
            error "$from and $to_parent are on different disks here, so the move has to copy files and the control panel has to stop for it, which would cut off this terminal. Run it over SSH instead."
        fi
    fi
}

do_migrate() {
    local old="$INSTALL_DIR" new="$OPT_INSTALL_DIR" stray="" C

    info "Move the install to $new"
    if [[ "$old" == "$new" ]]; then
        if [[ -f "$new/docker-compose.yml" ]]; then
            echo "This server already uses $new. Nothing to move."
            link_install_shortcuts
            return 0
        fi
        error "No AIOStreams install found to move (looked in $ROOT_HOME/aiostreams and $new)."
    fi
    if [[ -L "$new" ]] || { [[ -e "$new" ]] && [[ ! -d "$new" ]]; }; then
        error "$new exists but isn't a plain folder. Not touching anything."
    fi
    if [[ -d "$new" ]]; then
        # Checked by the path rule already, but say so plainly here.
        [[ -f "$new/docker-compose.yml" ]] && error "$new already holds an install. Not touching anything."
        stray="$new.pre-migrate-$(date +%Y%m%d-%H%M%S)"
    fi
    migrate_preflight "$old" "$(dirname "$new")"

    echo "This moves everything in $old to $new, one folder for root and"
    echo "every user, and leaves a link at $old so old commands and docs keep working."
    echo ""
    echo "  1. Takes a backup first (same as menu option 7)"
    echo "  2. Stops AIOStreams and its add-ons (about a minute of downtime)"
    echo "  3. Moves the folder and updates the files that name it (add-on compose"
    echo "     files, systemd units, the VPN boot hook, the fail2ban jail)"
    echo "  4. Starts back up whatever was running before"
    if [[ -n "$stray" ]]; then
        echo ""
        echo "$new already exists with no install in it (probably scripts downloaded"
        echo "there). It gets renamed to $stray first, nothing in it is deleted."
    fi
    if [[ -n "${REAL_HOME:-}" && "$REAL_HOME" != "$ROOT_HOME" && -d "$REAL_HOME/aiostreams" && ! -L "$REAL_HOME/aiostreams" ]]; then
        echo ""
        echo "Your own $REAL_HOME/aiostreams becomes a shortcut to $new too. Scripts in"
        echo "it that match the install are dropped; anything else keeps the folder,"
        echo "renamed to $REAL_HOME/aiostreams.old-<time>."
    fi
    echo ""
    echo "Undo any time with: sudo bash $new/setup-aiostreams.sh migrate undo"
    if ! ${MIGRATE_ASSUME_YES:-false}; then
        read -rp "Go ahead? [y/N]: " C
        [[ "$C" =~ ^[Yy]$ ]] || { echo "Cancelled, nothing changed."; return 0; }
    fi

    # '|| true': do_backup's last line is a tty-only pause, which returns
    # non-zero without a terminal. LAST_BACKUP_FILE says whether it worked.
    do_backup || true
    [[ -n "$LAST_BACKUP_FILE" ]] || { echo "No backup was made, so nothing was moved."; return 0; }

    if [[ -n "$stray" ]]; then
        mv -- "$new" "$stray"
        echo "Renamed the empty $new to $stray."
    fi
    if $M_SAME_FS; then
        migrate_stop_all "$old" false
    else
        migrate_stop_all "$old" true
    fi

    info "Moving $old to $new"
    cd / || true
    if ! mv -- "$old" "$new"; then
        error "The move failed. If $old is still complete, start it again with: cd $old && sudo docker compose up -d"
    fi
    secure_install_dir "$new"
    ln -s -- "$new" "$old"
    echo "Moved. $old is now a link to $new."

    rewrite_install_paths "$old" "$new" "$new"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ " ${REWRITTEN_FILES[*]} " == *" /etc/fail2ban/jail.d/aios-mediaflow.conf "* ]]; then
        systemctl restart fail2ban >/dev/null 2>&1 || warn "fail2ban didn't restart. Check: systemctl status fail2ban"
    fi
    report_path_rewrite "$old" "$new"

    set_install_paths "$new"
    link_install_shortcuts
    migrate_start_all "$new"

    if $M_STACK; then
        local proj wd
        proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' caddy 2>/dev/null || true)
        wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' caddy 2>/dev/null || true)
        if [[ "$proj" == "aiostreams" && "$wd" == "$new" ]]; then
            echo "Docker still calls the stack 'aiostreams', so it kept the same containers"
            echo "and the same HTTPS certificate volumes."
        else
            warn "Docker reports project '${proj:-?}' in '${wd:-?}' for caddy, expected 'aiostreams' in $new."
            warn "Check 'sudo docker compose ls' before going further."
        fi
    fi

    info "Done"
    echo "Install folder: $new"
    echo "Menu from now on: sudo bash $new/setup-aiostreams.sh"
    echo "(cd ~/aiostreams still works, it's a shortcut now)"
    echo "Backup taken before the move: $LAST_BACKUP_FILE"
    echo "To put it back: sudo bash $new/setup-aiostreams.sh migrate undo"
    if $M_PANEL || ! $M_SAME_FS; then
        echo ""
        recreate_panel "$new"
    fi
}

do_migrate_undo() {
    local new="$OPT_INSTALL_DIR" old="$ROOT_HOME/aiostreams" C prev name f
    info "Move the install back to $old"
    [[ "$INSTALL_DIR" == "$new" && -f "$new/docker-compose.yml" ]] || \
        error "This server doesn't use $new, so there's nothing to undo."
    if [[ -L "$old" ]]; then
        [[ "$old" -ef "$new" ]] || error "$old is a link to somewhere else. Not touching anything."
    elif [[ -e "$old" ]]; then
        error "$old exists and isn't the link migrate leaves. Not touching anything."
    fi
    migrate_preflight "$new" "$ROOT_HOME"

    echo "This moves everything in $new back to $old (the old layout) and"
    echo "puts back the paths migrate changed. It takes a backup first and stops the"
    echo "stack for about a minute, same as the move did."
    read -rp "Go ahead? [y/N]: " C
    [[ "$C" =~ ^[Yy]$ ]] || { echo "Cancelled, nothing changed."; return 0; }

    # '|| true': do_backup's last line is a tty-only pause, which returns
    # non-zero without a terminal. LAST_BACKUP_FILE says whether it worked.
    do_backup || true
    [[ -n "$LAST_BACKUP_FILE" ]] || { echo "No backup was made, so nothing was moved."; return 0; }

    if $M_SAME_FS; then
        migrate_stop_all "$new" false
    else
        migrate_stop_all "$new" true
    fi
    info "Moving $new to $old"
    cd / || true
    rm -f -- "$old"
    if ! mv -- "$new" "$old"; then
        error "The move failed. If $new is still complete, start it again with: cd $new && sudo docker compose up -d"
    fi
    rewrite_install_paths "$new" "$old" "$old"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ " ${REWRITTEN_FILES[*]} " == *" /etc/fail2ban/jail.d/aios-mediaflow.conf "* ]]; then
        systemctl restart fail2ban >/dev/null 2>&1 || warn "fail2ban didn't restart. Check: systemctl status fail2ban"
    fi
    report_path_rewrite "$new" "$old"

    # The sudo user's convenience copy, the way the old layout expects it.
    remove_install_shortcuts "$new"
    if [[ -n "${REAL_HOME:-}" && "$REAL_HOME" != "$ROOT_HOME" && ! -e "$REAL_HOME/aiostreams" ]]; then
        prev=$(find "$REAL_HOME" -maxdepth 1 -type d -name 'aiostreams.old-*' 2>/dev/null | sort | tail -n1)
        if [[ -n "$prev" ]]; then
            mv -- "$prev" "$REAL_HOME/aiostreams"
            echo "Put your old folder back: $prev is $REAL_HOME/aiostreams again."
        else
            mkdir -p "$REAL_HOME/aiostreams"
        fi
        for name in "${AIOSTREAMS_SCRIPTS[@]}"; do
            f="$REAL_HOME/aiostreams/$name"
            if [[ -f "$old/$name" && ! -e "$f" ]]; then
                cp -- "$old/$name" "$f" && chmod 664 "$f"
            fi
        done
        if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
            chown -R "$SUDO_UID:$SUDO_GID" "$REAL_HOME/aiostreams" 2>/dev/null || true
        fi
        echo "$REAL_HOME/aiostreams holds your copy of the scripts again."
    fi

    set_install_paths "$old"
    migrate_start_all "$old"

    info "Done"
    echo "Install folder: $old (the old layout)"
    echo "Backup taken before the move: $LAST_BACKUP_FILE"
    if $M_PANEL || ! $M_SAME_FS; then
        echo ""
        recreate_panel "$old"
    fi
}

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# Under sudo, $HOME is root's home, not the invoking user's, so a backup
# tarball scp'd into the user's own home wouldn't be found. Resolve the real
# home via SUDO_USER/getent so restore's scan checks there too.
# Defaults to where backups go (root's home), not $HOME, so a caller with
# HOME set elsewhere doesn't get a stray "user copy" of each backup there.
REAL_HOME="$BACKUP_HOME"
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
    migrate)
        if [[ "${2:-}" == "undo" ]]; then
            do_migrate_undo
        else
            # --yes: the person already said yes (the offer below, or the
            # same offer in one of the add-on scripts).
            [[ "${2:-}" == "--yes" ]] && MIGRATE_ASSUME_YES=true
            do_migrate
        fi
        exit 0
        ;;
esac

# A server still on the old layout is offered the move to /opt, only when a
# person is at the keyboard for the plain menu: never for subcommands, and
# never from the control panel's buttons (stdout is a pipe there). Saying no
# changes nothing; it asks again next time.
if [[ "$INSTALL_DIR" != "$OPT_INSTALL_DIR" && $# -eq 0 && -t 0 && -t 1 ]]; then
    echo ""
    echo "Easy AIOStreams now keeps everything in $OPT_INSTALL_DIR, one folder for"
    echo "root and every user. This server still uses $INSTALL_DIR."
    read -rp "Move it now? It takes a backup first, about a minute of downtime. [Y/n]: " MOVE_NOW
    if [[ ! "$MOVE_NOW" =~ ^[Nn] ]]; then
        MIGRATE_ASSUME_YES=true
        do_migrate
        echo ""
        read -rp "Press Enter to go on to the menu... " _
    fi
fi

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
            touch "$STOPPED_MARKER"
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
                rm -f "$STOPPED_MARKER"
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
            # shellcheck disable=SC2046  # image refs never contain spaces
            IMAGE_SNAPSHOT=$(snapshot_image_ids $(compose_image_refs "$COMPOSE_FILE"))
            docker compose pull
            if vpn_mode_active; then
                echo "VPN mode detected, recreating gluetun+caddy first, then gating aiostreams"
                echo "behind a confirmed tunnel before it comes up on the new images..."
                vpn_gated_start_aiostreams --force-recreate --remove-orphans || true
            else
                docker compose up -d --force-recreate --remove-orphans
            fi
            cleanup_replaced_images "$IMAGE_SNAPSHOT"
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

            echo ""
            echo "This stack's images (aiostreams, caddy, and gluetun if VPN mode is on) are"
            echo "pulled from a registry, not built locally. If you leave them cached and"
            echo "later restore a backup from a server running a newer version, the restore"
            echo "will silently reuse this old cached image instead of a current one, which"
            echo "can fail with a database-migration mismatch (the restored database expects"
            echo "a newer app than what's actually running)."
            read -rp "Also remove the cached images, so the next install/restore pulls fresh? [Y/n]: " REMOVE_IMAGES
            REMOVE_IMAGES=${REMOVE_IMAGES:-Y}
            if [[ "$REMOVE_IMAGES" =~ ^[Yy]$ ]]; then
                RMI_MODE="all"
            else
                RMI_MODE="local"
                warn "Keeping cached images. If you restore a newer backup onto this box later,"
                warn "check which tag that backup actually uses first ('grep image: docker-compose.yml'"
                warn "inside the extracted backup, it'll say :latest or :nightly), then run"
                warn "'sudo docker pull viren070/aiostreams:<that tag>' before restoring, to avoid"
                warn "reusing this stale cached image against a newer database."
            fi

            if [[ "$REMOVE_VOLUMES" =~ ^[Yy]$ ]]; then
                docker compose down -v --rmi "$RMI_MODE"
                echo "Containers, volumes, and $([[ "$RMI_MODE" == "all" ]] && echo "images (including pulled ones)" || echo "locally-built images only, pulled images kept") removed."
            else
                docker compose down --rmi "$RMI_MODE"
                echo "Containers and $([[ "$RMI_MODE" == "all" ]] && echo "images (including pulled ones)" || echo "locally-built images only, pulled images kept") removed (volumes preserved)."
            fi
            # Add-ons live outside this compose stack (systemd units, and the
            # webhook relay's own compose stack), so 'down' above never
            # touches them. Left behind, the watchdog timer keeps firing every
            # 2 min against a script that may be deleted next, and the relay
            # keeps running with nothing in front of it.
            remove_addons_on_uninstall
            docker network rm "$SHARED_NET" >/dev/null 2>&1 || true

            read -rp "Delete the config directory ($INSTALL_DIR), including your SECRET_KEY backup? [y/N]: " REMOVE_CONFIG
            if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
                cd "$HOME"
                rm -rf "$INSTALL_DIR"
                remove_install_shortcuts "$INSTALL_DIR"
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
# root of a real gap. setup-vpn-gluetun.sh reads these two lines from the
# live compose file and carries them into both its direct and VPN variants
# on every toggle, so the setting survives VPN mode either way.
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
if [[ "$INSTALL_DIR" == "$OPT_INSTALL_DIR" && ! -f "$COMPOSE_FILE" ]]; then
    # A fresh install (the README has people make this folder with
    # 'sudo mkdir' first): see secure_install_dir for who gets access.
    mkdir -p "$INSTALL_DIR"
    secure_install_dir
fi
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
    image: caddy:2
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

# The template above doesn't know about MediaFlow Proxy Light's patches
# (aios_shared wiring for aiostreams, caddy log mount for its fail2ban
# jail). Re-apply them to the file now, before anything starts, so the
# stack comes up already wired instead of silently losing them.
if [[ -f "$INSTALL_DIR/mediaflow-state/config" ]]; then
    if [[ -f "$INSTALL_DIR/setup-mediaflow.sh" ]]; then
        bash "$INSTALL_DIR/setup-mediaflow.sh" patch-compose < /dev/null || \
            warn "Couldn't re-apply MediaFlow's compose changes. Run 'sudo bash setup-mediaflow.sh' and choose Start afterward."
    else
        warn "MediaFlow is configured but setup-mediaflow.sh isn't in $INSTALL_DIR. Run it and choose Start afterward."
    fi
fi

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

Note: the username & password also live in ${INSTALL_DIR}/docker-compose.yml
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

# The first sync of this run happened before the folder existed.
sync_self_into_install_dir
link_install_shortcuts

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
echo "  - If you already had a config from before this change: open the configure page,"
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
