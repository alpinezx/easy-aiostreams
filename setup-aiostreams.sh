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
    if [[ "${UNATTENDED:-false}" == true ]]; then
        echo "Not done: the VPN is set up but switched off. Turn it on first (sudo bash setup-vpn-gluetun.sh),"
        echo "or do this from the menu over SSH, which asks whether to go on in direct mode."
        return 1
    fi
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
# Where setup-backup.sh is fetched from when it's missing. AIOS_BRANCH=dev to test.
RAW_BASE="https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/${AIOS_BRANCH:-main}"
CADDYFILE="$INSTALL_DIR/Caddyfile"
CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"
# Written by "Stop AIOStreams" so the watchdog knows a stopped aiostreams is
# deliberate and doesn't page you. Cleared on any start; the watchdog also
# clears it itself whenever it sees aiostreams running again.
STOPPED_MARKER="$INSTALL_DIR/aiostreams-stopped-on-purpose"

# Root's home, for its ~/aiostreams shortcut. Looked up rather than taken
# from $HOME, which a caller can set elsewhere.
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"
ROOT_HOME="${ROOT_HOME:-/root}"

SHARED_NET="aios_shared"

# Every script that belongs in $INSTALL_DIR. Used when a leftover
# ~/aiostreams folder is turned into a shortcut (link_install_shortcuts).
AIOSTREAMS_SCRIPTS=(setup-aiostreams.sh setup-backup.sh setup-vpn-gluetun.sh setup-watchdog.sh setup-webhook.sh setup-mediaflow.sh setup-aiometadata.sh setup-aiomanager.sh)

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

# Removes the add-ons that live outside the main compose stack. "restore"
# is setup-backup.sh retiring the install it's about to set aside.
remove_addons_on_uninstall() {
    local mode="${1:-uninstall}" removed=()
    if [[ -f /etc/systemd/system/aiostreams-watchdog.timer ]]; then
        systemctl disable --now aiostreams-watchdog.timer >/dev/null 2>&1 || true
        systemctl disable --now aiostreams-watchdog-boot.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aiostreams-watchdog.timer /etc/systemd/system/aiostreams-watchdog.service \
              /etc/systemd/system/aiostreams-watchdog-boot.service
        removed+=("watchdog timer")
    fi
    # Scheduled backups: a restore only pauses the timer (it follows the
    # restored backup's schedule afterwards); an uninstall removes it.
    if [[ -f /etc/systemd/system/aiostreams-backup.timer ]]; then
        if [[ "$mode" == restore ]]; then
            systemctl stop aiostreams-backup.timer >/dev/null 2>&1 || true
        else
            systemctl disable --now aiostreams-backup.timer >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/aiostreams-backup.timer /etc/systemd/system/aiostreams-backup.service
            removed+=("scheduled backups timer")
        fi
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
    # Its Redis cache is a Docker volume: kept for a restore (the restored
    # AIOMetadata reuses it), removed with an uninstall.
    if [[ -f "$INSTALL_DIR/aiometadata-state/docker-compose.yml" ]]; then
        local down_args=(down)
        [[ "$mode" == restore ]] || down_args+=(-v)
        (cd "$INSTALL_DIR/aiometadata-state" && docker compose -f docker-compose.yml "${down_args[@]}" >/dev/null 2>&1) || \
            docker rm -f aiometadata aiometadata_redis >/dev/null 2>&1 || true
        removed+=("AIOMetadata containers")
    fi
    # Its data is a folder, not a volume, so nothing else to keep. The timer
    # that closes reopened sign-ups would run against a folder that's gone.
    if [[ -f "$INSTALL_DIR/aiomanager-state/docker-compose.yml" ]]; then
        systemctl disable --now aiomanager-signups-close.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aiomanager-signups-close.timer /etc/systemd/system/aiomanager-signups-close.service
        (cd "$INSTALL_DIR/aiomanager-state" && docker compose -f docker-compose.yml down >/dev/null 2>&1) || \
            docker rm -f aiomanager >/dev/null 2>&1 || true
        removed+=("AIOManager container")
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
        if [[ "$mode" == restore ]]; then
            echo "Stopped and removed the current install's add-ons: ${joined%, }."
        else
            echo "Also removed add-ons: ${joined%, }."
            echo "(Their saved settings stay in $INSTALL_DIR unless you delete that below.)"
        fi
    fi
}

# The webhook relay was retired in October 2026 and setup-webhook.sh is no
# longer on GitHub. This removes one that's still installed, asking nothing
# (the control panel's Uninstall runs it too): container, reboot
# notification, Caddy site, settings and the script. Its python image is a
# common one, so it's left for Free up space.
remove_webhook_relay() {
    local state="$INSTALL_DIR/webhook-relay-state" site="$CADDY_DROPIN_DIR/50-webhook-relay.caddy"
    if [[ ! -e "$state" && ! -e "$site" && ! -f /etc/systemd/system/aios-webhook-boot-notify.service ]] \
        && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx aios-webhook-relay; then
        echo "No webhook relay found on this server, nothing to remove."
        rm -f "$INSTALL_DIR/setup-webhook.sh"
        return 0
    fi
    if [[ -f "$state/docker-compose.yml" ]]; then
        (cd "$state" && docker compose -f docker-compose.yml down >/dev/null 2>&1) || true
    fi
    docker rm -f aios-webhook-relay >/dev/null 2>&1 || true
    if [[ -f /etc/systemd/system/aios-webhook-boot-notify.service ]]; then
        systemctl disable aios-webhook-boot-notify.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/aios-webhook-boot-notify.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$site" "$site.rejected"
    # A reload, not a restart: a bad config elsewhere can't take the main site down
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy; then
        docker exec -w /etc/caddy caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
            || warn "Caddy didn't reload; it drops the relay's site at its next restart."
    fi
    rm -rf "$state"
    rm -f "$INSTALL_DIR/setup-webhook.sh"
    echo "Webhook relay removed. Point your uptime tracker straight at ntfy if it can send there."
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
# flow and restore, so it's parameterized on domain rather than reading
# the global $DOMAIN, which restore never sets.
wait_for_cert_and_diagnose() {
    local domain="$1"
    echo "Waiting for Caddy to obtain its HTTPS certificate,"
    echo "(this can take longer on a genuinely fresh cert request)..."
    local MAX_WAIT=90 INTERVAL=5 elapsed=0 cert_ok=false
    while [[ $elapsed -lt $MAX_WAIT ]]; do
        # Checks the TLS layer directly rather than parsing Caddy's log wording,
        # since current Caddy versions don't log a fixed "certificate obtained"
        # phrase. Also naturally covers reusing an existing valid cert.
        # timeout: a connection that opens but never answers would otherwise
        # hang here for good instead of failing after MAX_WAIT.
        if echo | timeout 10 openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null \
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

# ---------------------------------------------------------------------------
# The install folder: permissions and ~/aiostreams shortcuts.
# ---------------------------------------------------------------------------

# /opt/aiostreams holds the SECRET_KEY, logins and (with the VPN) a WireGuard
# private key. Root-only, except
# that the sudo user running this gets read access through their group, so
# 'cd ~/aiostreams' and SFTP browsing still work for them (they can already
# read all of it through sudo). Writing still needs sudo or root.
# Run as plain root (no sudo user, e.g. a root shell), a user who already has
# that access keeps it: the folder's group is theirs and their ~/aiostreams
# already points here. A restore extracts with the backup's group, so this
# covers it too. Anyone else, or no such shortcut (a new server), gets none.
secure_install_dir() {
    local dir="${1:-$INSTALL_DIR}" gid user ugid home
    gid=$(stat -c %g "$dir" 2>/dev/null || echo 0)
    chown root:root "$dir" 2>/dev/null || true
    if [[ -n "${SUDO_GID:-}" && "${SUDO_GID}" != 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        chgrp "$SUDO_GID" "$dir" 2>/dev/null && chmod 750 "$dir" && return 0
    fi
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]] && [[ "$gid" != 0 ]]; then
        while IFS=: read -r user _ _ ugid _ home _; do
            [[ "$ugid" == "$gid" && "$user" != root && -L "$home/aiostreams" && "$home/aiostreams" -ef "$dir" ]] || continue
            chgrp "$gid" "$dir" 2>/dev/null && chmod 750 "$dir" && return 0
        done < <(getent passwd)
    fi
    chmod 700 "$dir"
}

# Gives root, and the sudo user running this, a
# ~/aiostreams that is just a link to the install folder, a handy shortcut.
# A real ~/aiostreams folder (an old habit: downloading scripts there) is
# removed when all it holds is identical copies of these scripts; anything
# else in it means it is renamed to ~/aiostreams.old-<time> instead, so
# nothing is ever deleted that isn't already in the install folder.
link_install_shortcuts() {
    [[ -d "$INSTALL_DIR" ]] || return 0
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
            local differ=()
            for name in "${AIOSTREAMS_SCRIPTS[@]}"; do
                [[ -f "$link/$name" && ! -L "$link/$name" ]] || continue
                # One the install folder doesn't have yet (say an add-on
                # downloaded but never run) moves in, the way running it would.
                if [[ ! -e "$INSTALL_DIR/$name" ]]; then
                    cp -- "$link/$name" "$INSTALL_DIR/$name" && chmod 755 "$INSTALL_DIR/$name"
                fi
                if cmp -s "$link/$name" "$INSTALL_DIR/$name"; then
                    rm -f -- "$link/$name"
                else
                    differ+=("$name")
                fi
            done
            if ! rmdir -- "$link" 2>/dev/null; then
                aside="$h/aiostreams.old-$(date +%Y%m%d-%H%M%S)"
                mv -- "$link" "$aside"
                echo "Your old $link had other files in it too, so it was renamed to"
                echo "$aside. Nothing in it was deleted. Remove it once you've checked it."
                if (( ${#differ[@]} > 0 )); then
                    echo "These scripts in it were different from the install folder's copies,"
                    echo "which are the ones in use from now on: ${differ[*]}"
                    echo "If yours were the newer ones, copy them over:"
                    echo "  sudo cp $aside/<script> $INSTALL_DIR/"
                fi
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

# Undoes link_install_shortcuts, for uninstall.
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

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# Under sudo, $HOME is root's home, not the invoking user's. Resolve the
# real one via SUDO_USER/getent, for the ~/aiostreams shortcut. Defaults to
# root's home, not $HOME.
REAL_HOME="$ROOT_HOME"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    [[ -n "$sudo_home" && -d "$sudo_home" ]] && REAL_HOME="$sudo_home"
fi

for REQUIRED_CMD in curl openssl tar; do
    require_cmd "$REQUIRED_CMD" || error "Required command '$REQUIRED_CMD' not found. Install it first (e.g. 'apt-get install -y $REQUIRED_CMD') and re-run this script."
done

# Puts the copy of this script being run into the install folder, so
# backups carry it. Used on a fresh install, where the script may have been
# run from somewhere else (a home folder).
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

# Backup and restore live in setup-backup.sh. Finds it in the install
# folder or next to this script, and downloads it when it's in neither.
backup_script() {
    local candidate dest
    for candidate in "$INSTALL_DIR/setup-backup.sh" "$(dirname "$SELF_SCRIPT_PATH")/setup-backup.sh"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if [[ -d "$INSTALL_DIR" ]]; then
        dest="$INSTALL_DIR/setup-backup.sh"
    else
        dest="$(mktemp -d)/setup-backup.sh"
    fi
    echo "Downloading setup-backup.sh (backup and restore)..." >&2
    if curl -fsSL "$RAW_BASE/setup-backup.sh" -o "$dest.part" && grep -q 'do_restore()' "$dest.part"; then
        mv -f -- "$dest.part" "$dest"
        chmod 755 "$dest"
        printf '%s\n' "$dest"
        return 0
    fi
    rm -f -- "$dest.part"
    warn "Couldn't download setup-backup.sh. Get it with:"
    warn "  sudo curl -fsSL $RAW_BASE/setup-backup.sh -o $INSTALL_DIR/setup-backup.sh"
    return 1
}

# Runs setup-backup.sh with the given command. AIOS_MAIN_SCRIPT tells a
# restore which copy of this script to put back into the install folder.
run_backup_script() {
    local script
    script=$(backup_script) || return 1
    AIOS_MAIN_SCRIPT="$SELF_SCRIPT_PATH" bash "$script" "$@"
}

# The part of a restore that starts things, called by setup-backup.sh once
# the backup is extracted and its domain checked. Exits 2 when you choose
# not to start in direct mode with the VPN switched off.
restore_start_stack() {
    secure_install_dir
    link_install_shortcuts
    ensure_shared_network
    ensure_caddy_dropin_dir   # no-op on current backups; creates it for pre-drop-in ones

    warn_if_vpn_layer_off "Restoring" || return 2

    info "Starting the restored stack"
    # The restored database may be from a newer app version than whatever
    # image is cached here, and starting on a stale image fails with a
    # migration error, so always pull fresh first.
    info "Pulling current images before starting"
    local image_snapshot
    # shellcheck disable=SC2046  # image refs never contain spaces
    image_snapshot=$(snapshot_image_ids $(compose_image_refs "$COMPOSE_FILE"))
    if ! (cd "$INSTALL_DIR" && docker compose pull); then
        local tag
        tag=$(sed -n 's/.*image: viren070\/aiostreams:\([^[:space:]]*\).*/\1/p' "$COMPOSE_FILE" 2>/dev/null | head -n1)
        tag=${tag:-latest}
        warn "Pull failed or partially failed - continuing with whatever's cached. If the stack fails to start with a database-migration error, run 'sudo docker pull viren070/aiostreams:${tag}' manually and retry (this restore uses the '${tag}' tag)."
    fi

    if vpn_mode_active; then
        # < /dev/null: an older setup-vpn-gluetun.sh without this command
        # falls into its menu instead; closed stdin makes it exit at once.
        if [[ -f "$INSTALL_DIR/setup-vpn-gluetun.sh" ]]; then
            bash "$INSTALL_DIR/setup-vpn-gluetun.sh" install-boot-hook < /dev/null || true
            if [[ ! -f /etc/systemd/system/aiostreams-vpn-boot.service ]]; then
                warn "Couldn't install the boot-safety hook automatically. See the reminder below."
            fi
        fi
        info "VPN layer detected in this backup, bringing the tunnel up before starting AIOStreams"
        vpn_gated_start_aiostreams --remove-orphans || true
    else
        (cd "$INSTALL_DIR" && docker compose up -d --force-recreate --remove-orphans)
    fi
    cleanup_replaced_images "$image_snapshot"

    # DNS matching doesn't rule out a blocked port on a new server, so
    # confirm the certificate itself.
    if [[ -f "$CADDYFILE" ]]; then
        local restored_domain
        restored_domain=$(head -n1 "$CADDYFILE" | awk '{print $1}')
        [[ -n "$restored_domain" ]] && wait_for_cert_and_diagnose "$restored_domain"
    fi
    return 0
}

# ---- Maintenance: the control panel's Maintenance page runs these, and they
# ask nothing, so they work the same over SSH:
#   sudo bash setup-aiostreams.sh free-space | system-updates | log-limits

# After Docker itself restarts (a system update upgraded it, or the log limits
# were set), bring back what should be running. In VPN mode AIOStreams has
# restart: "no", so nothing else would. Stopped on purpose stays stopped.
ensure_stack_running() {
    cd "$INSTALL_DIR" || return 1
    if [[ -f "$STOPPED_MARKER" ]]; then
        docker compose up -d --no-deps caddy $(vpn_mode_active && echo gluetun) || true
        return 0
    fi
    if vpn_mode_active; then
        vpn_gated_start_aiostreams --remove-orphans
    else
        docker compose up -d --remove-orphans
    fi
}

# Old images nothing uses (each AIOStreams update leaves the previous one
# behind, untagged, and switching channel leaves the other channel's), build
# leftovers (every panel rebuild adds some) and system logs beyond the newest
# 100 MB. Other tagged images, like gluetun's while the VPN is off, are kept
# for when they're wanted again.
do_free_space() {
    local before after img
    before=$(df -B1 --output=avail "$INSTALL_DIR" | tail -n 1)
    # One summary line per step: Docker's own output lists every layer and build record
    info "Removing old images nothing uses"
    docker image prune -f | tail -n 1
    for img in $(docker images viren070/aiostreams --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>'); do
        if [[ -z "$(docker ps -aq --filter "ancestor=$img")" ]] && docker rmi "$img" >/dev/null; then echo "Removed $img"; fi
    done
    info "Removing build leftovers"
    docker builder prune -f | tail -n 1
    if command -v journalctl >/dev/null 2>&1; then
        info "Trimming the system logs to the newest 100 MB"
        journalctl --vacuum-size=100M 2>&1 | tail -n 1
    fi
    after=$(df -B1 --output=avail "$INSTALL_DIR" | tail -n 1)
    echo ""
    if (( after > before )); then
        echo "Done. Freed about $(( (after - before) / 1048576 )) MB."
    else
        echo "Done. There was nothing worth freeing."
    fi
}

# Ubuntu's waiting updates that Install updates would install now, one
# "package/source version arch [upgradable ...]" line each. Ubuntu phases some
# updates in (a growing share of servers over a few days) and apt holds those
# back until this server's turn, so they're left out: installing wouldn't
# touch them. upgradable_count counts every waiting one, phased included.
# Read-only.
upgradable_now() {
    command -v apt >/dev/null 2>&1 || return 1
    local sim list p line
    local -A ready=()
    list=$(apt list --upgradable 2>/dev/null | grep -F '[upgradable' || true)
    [[ -n "$list" ]] || return 0
    sim=$(apt-get -s -o Debug::NoLocking=1 upgrade --with-new-pkgs 2>/dev/null || true)
    # If the simulation can't run, show them all rather than none
    [[ -n "$sim" ]] || { echo "$list"; return 0; }
    while read -r p; do [[ -n "$p" ]] && ready[$p]=1; done < <(awk '/^Inst /{print $2}' <<< "$sim")
    while IFS= read -r line; do
        [[ -n "${ready[${line%%/*}]:-}" ]] && echo "$line"
    done <<< "$list"
    return 0
}

upgradable_count() {
    apt list --upgradable 2>/dev/null | grep -cF '[upgradable' || true
}

# Ubuntu's package updates, as "apt upgrade" over SSH would, keeping any config
# file you've changed. If Docker itself was upgraded it restarts every
# container, so the stack is brought back afterwards (the control panel runs
# this outside its own container for the same reason).
do_system_updates() {
    command -v apt-get >/dev/null 2>&1 || error "This server doesn't use apt, so this can't update it."
    export DEBIAN_FRONTEND=noninteractive
    info "Refreshing Ubuntu's package lists"
    apt-get -q -o DPkg::Lock::Timeout=300 update || error "Couldn't refresh the package lists. Nothing was installed."
    info "Installing updates"
    apt-get -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        upgrade --with-new-pkgs || error "The update stopped partway. Run 'sudo apt upgrade' over SSH to see why."
    info "Making sure everything is running"
    ensure_stack_running || warn "AIOStreams didn't come back by itself. Use Start on the Overview, or option 3 here."
    echo ""
    if [[ -f /var/run/reboot-required ]]; then
        warn "Done. A restart is needed to finish (a new kernel or system library): use Reboot server when it suits."
    else
        echo "Done. No restart needed."
    fi
}

# Caps each container's log at 10 MB (3 files) through Docker's own settings
# (/etc/docker/daemon.json), so every container gets it, add-ons and the
# panel included. Docker has to restart to read it, and containers only take
# it when they're recreated, so everything is recreated once. A daemon.json
# Docker rejects is put back as it was.
LOG_MAX_SIZE="10m"
LOG_MAX_FILE="3"
do_log_limits() {
    local f=/etc/docker/daemon.json
    if [[ -s "$f" ]] && grep -q '"max-size"' "$f"; then
        echo "Docker already limits container logs here. Nothing to do."
        return 0
    fi
    if [[ -s "$f" ]] && ! grep -qx '[[:space:]]*{[[:space:]]*}[[:space:]]*' "$f"; then
        # Some other settings are already there: add to them rather than replace them
        command -v python3 >/dev/null 2>&1 || error "$f already has settings, and python3 isn't here to add to them safely. Add \"log-opts\": {\"max-size\": \"$LOG_MAX_SIZE\", \"max-file\": \"$LOG_MAX_FILE\"} by hand."
        cp -p "$f" "$f.before-log-limits"
        python3 - "$f" "$LOG_MAX_SIZE" "$LOG_MAX_FILE" <<'PY' || { mv -f "$f.before-log-limits" "$f"; error "Couldn't read $f as JSON. Nothing was changed."; }
import json, sys
path, size, files = sys.argv[1:4]
with open(path) as fh:
    conf = json.load(fh)
if conf.get("log-driver", "json-file") not in ("json-file", "local"):
    sys.exit("log driver " + conf["log-driver"])
conf.setdefault("log-opts", {}).update({"max-size": size, "max-file": files})
with open(path, "w") as fh:
    json.dump(conf, fh, indent=2)
    fh.write("\n")
PY
    else
        [[ -e "$f" ]] && cp -p "$f" "$f.before-log-limits"
        mkdir -p /etc/docker
        printf '{\n  "log-opts": { "max-size": "%s", "max-file": "%s" }\n}\n' "$LOG_MAX_SIZE" "$LOG_MAX_FILE" > "$f"
    fi
    if dockerd --help 2>/dev/null | grep -q -- '--validate' && ! dockerd --validate --config-file "$f" >/dev/null 2>&1; then
        if [[ -e "$f.before-log-limits" ]]; then mv -f "$f.before-log-limits" "$f"; else rm -f "$f"; fi
        error "Docker didn't accept the new settings, so they were taken back out. Nothing else changed."
    fi
    info "Restarting Docker to read the new limit (every container restarts)"
    if ! systemctl restart docker; then
        warn "Docker didn't restart with the new settings. Putting the old ones back."
        if [[ -e "$f.before-log-limits" ]]; then mv -f "$f.before-log-limits" "$f"; else rm -f "$f"; fi
        systemctl restart docker || true
        ensure_stack_running || true
        error "The log limits weren't set. Docker is back on its old settings."
    fi
    rm -f "$f.before-log-limits"
    info "Recreating the containers so they take the limit"
    cd "$INSTALL_DIR" || return 1
    local on_purpose=0
    [[ -f "$STOPPED_MARKER" ]] && on_purpose=1
    if vpn_mode_active; then
        vpn_gated_start_aiostreams --force-recreate --remove-orphans || true
    else
        docker compose up -d --force-recreate --remove-orphans || true
    fi
    if (( on_purpose )); then docker compose stop aiostreams >/dev/null 2>&1 || true; touch "$STOPPED_MARKER"; fi
    local d running
    for d in mediaflow-state webhook-relay-state aiometadata-state aiomanager-state; do
        [[ -f "$INSTALL_DIR/$d/docker-compose.yml" ]] || continue
        running=$(cd "$INSTALL_DIR/$d" && docker compose ps -q 2>/dev/null)
        [[ -n "$running" ]] && (cd "$INSTALL_DIR/$d" && docker compose up -d --force-recreate) || true
    done
    # The panel last: recreating it ends its own view of this (it runs outside it)
    if [[ -f "$INSTALL_DIR/ui-state/docker-compose.yml" ]]; then
        (cd "$INSTALL_DIR/ui-state" && docker compose -f docker-compose.yml up -d --force-recreate) || true
    fi
    echo ""
    echo "Done. Each container's log is now capped at $LOG_MAX_SIZE ($LOG_MAX_FILE files)."
}

# ---- Status and Maintenance for SSH: what the control panel's Overview and
# Maintenance page show, as text. Menu options 1 and 11, and "status".

# "5h 18m", "3d 4h", from seconds
human_age() {
    local s=$1
    if (( s < 3600 )); then echo "$(( s / 60 ))m"
    elif (( s < 86400 )); then echo "$(( s / 3600 ))h $(( s % 3600 / 60 ))m"
    else echo "$(( s / 86400 ))d $(( s % 86400 / 3600 ))h"
    fi
}

bytes() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# The running build and whether a newer one is out on its channel. GitHub is
# asked once, with a short timeout; without an answer only the build shows.
status_version() {
    local tag node build ver btag latest channel
    tag=$(sed -n 's/.*image: viren070\/aiostreams:\([^[:space:]]*\).*/\1/p' "$COMPOSE_FILE" 2>/dev/null | head -n1)
    case "$tag" in latest) channel=stable ;; nightly) channel=nightly ;; *) channel="pinned to $tag" ;; esac
    for node in /nodejs/bin/node node; do
        build=$(docker exec aiostreams "$node" -p "const m=require('/app/resources/metadata.json');m.version+' '+m.tag" 2>/dev/null) && break
        build=""
    done
    read -r ver btag <<< "$build"
    if [[ -z "$ver" ]]; then
        echo "  Version:   unknown, AIOStreams isn't running ($channel)"
        return 0
    fi
    if [[ "$channel" == stable ]]; then
        latest=$(curl -fsS -m 8 https://api.github.com/repos/viren070/aiostreams/releases/latest 2>/dev/null \
            | grep -oP '"tag_name":\s*"\Kv[0-9]+\.[0-9]+\.[0-9]+(?=")' | head -n 1) || true
        if [[ -z "$latest" ]]; then echo "  Version:   v$ver (stable)"
        elif [[ "$latest" == "v$ver" ]]; then echo "  Version:   v$ver (stable), up to date"
        elif [[ "$(printf '%s\n%s\n' "v$ver" "$latest" | sort -V | tail -n 1)" == "$latest" ]]; then
            echo -e "  Version:   v$ver (stable), \033[1;33m$latest is out\033[0m: option 5 updates"
        else echo "  Version:   v$ver (stable)"
        fi
    elif [[ "$channel" == nightly ]]; then
        latest=$(curl -fsS -m 8 "https://api.github.com/repos/viren070/aiostreams/releases?per_page=30" 2>/dev/null \
            | grep -oP '"tag_name":\s*"\K[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}-nightly(?=")' | sort | tail -n 1) || true
        if [[ -n "$latest" && "$btag" =~ -nightly$ && "$latest" > "$btag" ]]; then
            echo -e "  Version:   v$ver (nightly $btag), \033[1;33ma newer nightly is out\033[0m: option 5 updates"
        else echo "  Version:   v$ver (nightly $btag)"
        fi
    else
        echo "  Version:   v$ver ($channel)"
    fi
}

show_status() {
    local domain end days c label st up load cpus mem total used pct sched every time day line list n s ph age newest
    cd "$INSTALL_DIR"
    domain=$(head -n1 "$CADDYFILE" 2>/dev/null | awk '{print $1}')
    echo "=== AIOStreams ==="
    status_version
    if [[ -n "$domain" ]]; then
        end=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$domain" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || true
        if [[ -n "$end" ]]; then
            days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
            if (( days < 10 )); then
                echo -e "  Site:      https://$domain, \033[1;33mHTTPS certificate $days days left, not renewing\033[0m (check: docker logs caddy)"
            else
                echo "  Site:      https://$domain, HTTPS certificate $days days left (renews by itself)"
            fi
        else
            echo "  Site:      https://$domain, HTTPS certificate couldn't be checked"
        fi
    fi
    echo ""
    echo "=== Services ==="
    for c in "caddy|Caddy" "gluetun|VPN tunnel" "aiostreams|AIOStreams" "mediaflow-proxy-light|MediaFlow Proxy" \
             "aios-webhook-relay|Webhook relay" "aiometadata|AIOMetadata" "aiomanager|AIOManager" "aios-ui|Control panel"; do
        label=${c#*|}; c=${c%%|*}
        st=$(docker ps -a --filter "name=^${c}\$" --format '{{.Status}}' 2>/dev/null | head -n 1)
        [[ -n "$st" ]] || continue
        if [[ "$c" == aiostreams && -f "$STOPPED_MARKER" && "$st" != Up* ]]; then st+=", stopped on purpose"; fi
        printf '  %-16s %s\n' "$label" "$st"
    done
    if [[ -f "$INSTALL_DIR/vpn-state/active" ]]; then
        if vpn_mode_active; then line="on, traffic goes through it"; else line="off, a direct connection"; fi
        printf '  %-16s %s\n' "VPN" "$line"
    fi
    if [[ -f "$INSTALL_DIR/watchdog-state/config" ]]; then
        if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
            line="running, last check: $(cat "$INSTALL_DIR/watchdog-state/last-check" 2>/dev/null || echo none yet)"
        else
            line="stopped"
        fi
        printf '  %-16s %s\n' "Phone alerts" "$line"
    fi
    echo ""
    echo "=== This server ==="
    up=$(cut -d. -f1 /proc/uptime)
    echo "  Up for:    $(human_age "$up")"
    read -r load _ < /proc/loadavg
    cpus=$(nproc 2>/dev/null || echo 1)
    echo "  Load:      $load on $cpus CPU$( (( cpus == 1 )) || echo s)"
    read -r total used < <(free -b | awk '/^Mem:/ {print $2, $3}')
    echo "  Memory:    $(bytes "$used") of $(bytes "$total") ($(( used * 100 / total ))% used)"
    read -r total used pct < <(df -P -B1 "$INSTALL_DIR" | awk 'NR == 2 {print $2, $3, $5}')
    echo "  Disk:      $(bytes "$used") of $(bytes "$total") ($pct used)"
    # The newest backup of any kind, and the schedule
    newest=$( { find /root -maxdepth 1 -type f -name 'aiostreams-backup-*.tar.gz' -printf '%T@\n'
                find /home -mindepth 2 -maxdepth 2 -type f -name 'aiostreams-backup-*.tar.gz' -printf '%T@\n'; } 2>/dev/null \
              | sort -rn | head -n 1 | cut -d. -f1)
    sched=$(grep -m1 -oP '^every=\K\S+' "$INSTALL_DIR/backup-schedule" 2>/dev/null || true)
    time=$(grep -m1 -oP '^time=\K\S+' "$INSTALL_DIR/backup-schedule" 2>/dev/null || true)
    day=$(grep -m1 -oP '^day=\K[1-7]' "$INSTALL_DIR/backup-schedule" 2>/dev/null || echo 7)
    case "$sched" in
        daily) every="scheduled daily at $time" ;;
        weekly) every="scheduled $(cut -d' ' -f"$day" <<< "Mondays Tuesdays Wednesdays Thursdays Fridays Saturdays Sundays") at $time" ;;
        *) every="none scheduled" ;;
    esac
    if [[ "$newest" =~ ^[0-9]+$ ]]; then
        age=$(( $(date +%s) - newest ))
        echo "  Backups:   newest $(human_age "$age") old, $every"
    else
        echo "  Backups:   none yet, $every"
    fi
    if list=$(upgradable_now); then
        n=$(grep -c . <<< "$list" || true)
        s=$(grep -c -- '-security' <<< "$list" || true)
        ph=$(( $(upgradable_count) - n ))
        if (( n )); then
            echo "  Updates:   $n waiting$( (( s )) && echo " ($s for security)"), option 11 installs them$( (( ph > 0 )) && echo "; $ph more rolling out gradually (phased)")"
        else
            echo "  Updates:   none waiting$( (( ph > 0 )) && echo " ($ph rolling out gradually, phased: Ubuntu offers them to this server in a few days)")"
        fi
    fi
    if [[ -f /var/run/reboot-required ]]; then echo -e "  \033[1;33mA restart is needed to finish installing updates.\033[0m"; fi
    return 0
}

# What Maintenance would do, before doing it
maint_summary() {
    local ids=() img size=0 b build journal list n s ph
    while IFS= read -r img; do [[ -n "$img" ]] && ids+=("$img"); done < <(docker images -f dangling=true -q 2>/dev/null)
    for img in $(docker images viren070/aiostreams --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>'); do
        if [[ -z "$(docker ps -aq --filter "ancestor=$img")" ]]; then ids+=("$(docker images -q "$img")"); fi
    done
    for img in "${ids[@]}"; do
        b=$(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null || echo 0)
        size=$(( size + ${b:-0} ))
    done
    build=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1 == "Build Cache" {print $2}')
    journal=$(journalctl --disk-usage 2>/dev/null | grep -oP 'take up \K\S+' || true)
    echo "  Old images nothing uses: ${#ids[@]}$( (( ${#ids[@]} )) && echo " (up to $(bytes "$size"))")"
    echo "  Build leftovers:         ${build:-0B}"
    [[ -n "$journal" ]] && echo "  System logs:             $journal (free up space trims them to the newest 100 MB)"
    if list=$(upgradable_now); then
        n=$(grep -c . <<< "$list" || true)
        s=$(grep -c -- '-security' <<< "$list" || true)
        ph=$(( $(upgradable_count) - n ))
        if (( n )); then
            echo "  Updates waiting:         $n$( (( s )) && echo " ($s for security)")$( (( ph > 0 )) && echo ", and $ph rolling out gradually (phased)")"
        else
            echo "  Updates waiting:         none$( (( ph > 0 )) && echo " ($ph rolling out gradually, phased)")"
        fi
    fi
    [[ -f /var/run/reboot-required ]] && echo "  A restart is needed to finish installing updates (sudo reboot, when it suits)."
    if [[ -s /etc/docker/daemon.json ]] && grep -q '"max-size"' /etc/docker/daemon.json; then
        echo "  Container log limits:    set"
    else
        echo "  Container log limits:    not set (logs can grow until the disk fills)"
    fi
    return 0
}

maintenance_menu() {
    local c yn
    while true; do
        echo ""
        echo "=== Maintenance ==="
        maint_summary
        echo ""
        echo "  1) Free up space (old images, build leftovers, system logs beyond 100 MB)"
        echo "  2) Install updates (Ubuntu's, as apt upgrade would)"
        echo "  3) Set container log limits (10 MB each; every container restarts once)"
        echo "  0) Back"
        read -rp "Choose [0-3]: " c || return 0
        case "$c" in
            1) do_free_space ;;
            2)
                read -rp "Install them now? If Docker itself is updated, every container restarts for a few seconds. [y/N]: " yn || return 0
                if [[ "$yn" =~ ^[Yy]$ ]]; then do_system_updates; fi
                ;;
            3)
                read -rp "Every container restarts once, a few seconds of downtime. Go ahead? [y/N]: " yn || return 0
                if [[ "$yn" =~ ^[Yy]$ ]]; then do_log_limits; fi
                ;;
            0|"") return 0 ;;
            *) warn "Not a valid option." ;;
        esac
    done
}

# ---- Stop, Start, Restart and Update: menu options 2 to 5, and the commands
# the control panel runs, "stop", "start", "restart" and
# "update [--backup] [--channel latest|nightly]". The panel used to type the
# menu numbers, and older panels still do, so those numbers must never
# change. The commands ask nothing: where the menu asks whether to go on with
# the VPN set up but switched off, they stop instead.
UNATTENDED=false

do_stop_aio() {
    echo ""
    cd "$INSTALL_DIR"
    echo "Stopping AIOStreams..."
    # Targets aiostreams only, caddy (and gluetun in VPN mode) stay
    # up, so the domain still responds (502) instead of going dark.
    docker compose stop aiostreams
    touch "$STOPPED_MARKER"
    echo "Stopped. Caddy is still up (visitors get a 502) and, if VPN mode is"
    echo "on, the tunnel is untouched. Start (option 3) to bring it back."
}

do_start_aio() {
    echo ""
    cd "$INSTALL_DIR"
    warn_if_vpn_layer_off "Starting AIOStreams" || return 1
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
}

do_restart_stack() {
    echo ""
    cd "$INSTALL_DIR"
    if vpn_mode_active; then
        echo "VPN mode detected (gluetun present), recreating gluetun+caddy first, then"
        echo "gating aiostreams behind a confirmed tunnel, so it never re-attaches to a"
        echo "stale or not-yet-connected namespace..."
        vpn_gated_start_aiostreams --force-recreate --remove-orphans || true
    else
        warn_if_vpn_layer_off "Restarting the stack" || return 1
        echo "Restarting the stack..."
        docker compose restart
    fi
    echo "Restarted. Check status with: docker compose ps"
}

# do_update_aio <backup: ask|yes|no> <channel: ask|keep|latest|nightly>
do_update_aio() {
    local backup="$1" channel="$2" UPDATE_CHOICE SWITCH_CHANNEL NEW_CHANNEL_CHOICE CONFIRM_CHANNEL_SWITCH
    echo ""
    cd "$INSTALL_DIR"
    if [[ "$backup" == ask ]]; then
        echo "Update AIOStreams:"
        echo "  1) Backup first, then update"
        echo "  2) Update without backing up"
        echo "  3) Cancel"
        read -rp "Select an option [1-3]: " UPDATE_CHOICE
        case "$UPDATE_CHOICE" in
            1) backup=yes ;;
            2) backup=no ;;
            *) echo "Update cancelled."; return 0 ;;
        esac
    fi

    CURRENT_TAG=$(grep "image: viren070/aiostreams:" "$COMPOSE_FILE" | head -n1 | sed 's/.*aiostreams://')
    [[ -z "$CURRENT_TAG" ]] && CURRENT_TAG="latest"
    NEW_TAG="$CURRENT_TAG"
    # Nightly can move the database past what stable reads; that backup is the way back
    if [[ "$channel" == nightly && "$CURRENT_TAG" != nightly && "$backup" != yes ]]; then
        echo "Switching to nightly needs a backup first (--backup): it's the way back to stable."
        return 1
    fi

    if [[ "$backup" == yes ]]; then
        if [[ "$UNATTENDED" == true ]]; then
            run_backup_script backup < /dev/null || { warn "The backup didn't finish, so nothing else was changed."; return 1; }
        else
            run_backup_script backup || { warn "The backup didn't finish, so nothing else was changed."; return 1; }
        fi
        echo ""
    fi

    echo ""
    echo "Current build channel: ${CURRENT_TAG}"
    if [[ "$channel" == latest || "$channel" == nightly ]]; then
        NEW_TAG="$channel"
    elif [[ "$channel" == ask ]]; then
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
        fi
    fi
    if [[ "$NEW_TAG" != "$CURRENT_TAG" ]]; then
        sed -i "s|image: viren070/aiostreams:.*|image: viren070/aiostreams:${NEW_TAG}|" "$COMPOSE_FILE"
        info "Switched to ${NEW_TAG}, will pull and recreate below."
    fi

    warn_if_vpn_layer_off "Updating AIOStreams" || return 1
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
}

case "${1:-}" in
    backup|restore)
        script=$(backup_script) || exit 1
        AIOS_MAIN_SCRIPT="$SELF_SCRIPT_PATH" exec bash "$script" "$@"
        ;;
    _remove-addons)
        remove_addons_on_uninstall restore
        exit 0
        ;;
    _restore-start)
        status=0
        restore_start_stack || status=$?
        exit "$status"
        ;;
    stop|start|restart|update)
        [[ -f "$COMPOSE_FILE" ]] || error "No AIOStreams install found at $INSTALL_DIR."
        require_cmd docker && docker compose version >/dev/null 2>&1 || error "Docker/Compose isn't available."
        UNATTENDED=true
        case "$1" in
            stop) do_stop_aio ;;
            start) do_start_aio || exit 1 ;;
            restart) do_restart_stack || exit 1 ;;
            update)
                cmd_backup=no cmd_channel=keep
                shift
                while (( $# )); do
                    case "$1" in
                        --backup) cmd_backup=yes ;;
                        --channel)
                            [[ "${2:-}" =~ ^(latest|nightly)$ ]] || error "--channel takes latest or nightly."
                            cmd_channel=$2
                            shift
                            ;;
                        *) error "Unknown option '$1'. Use: update [--backup] [--channel latest|nightly]" ;;
                    esac
                    shift
                done
                do_update_aio "$cmd_backup" "$cmd_channel" || exit 1
                ;;
        esac
        exit 0
        ;;
    status)
        [[ -f "$COMPOSE_FILE" ]] || error "No AIOStreams install found at $INSTALL_DIR."
        show_status
        exit 0
        ;;
    free-space) do_free_space; exit 0 ;;
    system-updates) do_system_updates; exit 0 ;;
    log-limits) do_log_limits; exit 0 ;;
    remove-webhook-relay) remove_webhook_relay; exit 0 ;;
esac


while true; do

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
    echo " 11) Maintenance (free up space, system updates, container log limits)"
    echo ""
    # Exit stays 10 and Maintenance is 11: the control panel types 10 to leave the menu
    read -rp "Select an option [1-11]: " MENU_CHOICE

    case "$MENU_CHOICE" in
        1)
            echo ""
            show_status
            continue
            ;;
        11)
            maintenance_menu
            continue
            ;;
        2) do_stop_aio; continue ;;
        3) do_start_aio || true; continue ;;
        4) do_restart_stack || true; continue ;;
        5) do_update_aio ask ask || true; continue ;;
        6)
            echo ""

            echo "Reconfigure AIOStreams:"
            echo "  1) Backup first, then reconfigure"
            echo "  2) Reconfigure without backing up"
            echo "  3) Cancel"
            read -rp "Select an option [1-3]: " RECONFIGURE_CHOICE
            case "$RECONFIGURE_CHOICE" in
                1)
                    run_backup_script backup || { warn "The backup didn't finish, so nothing else was changed."; continue; }
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
            run_backup_script backup || true
            continue
            ;;
        8)
            echo ""
            run_backup_script restore || true
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
            run_backup_script restore || true
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
if [[ ! -f "$COMPOSE_FILE" ]]; then
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
# below, since heredocs can't branch: empty string when the user opted out,
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
