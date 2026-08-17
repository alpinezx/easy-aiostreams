#!/usr/bin/env bash
#
# Adds an optional gluetun VPN container to an existing AIOStreams Docker
# stack (installed via setup-aiostreams.sh), routing ONLY the aiostreams
# container's network through it — never the host.
#
# Re-run this script any time to get a menu: turn the VPN on/off, check
# status, or reconfigure which WireGuard server it uses. Toggling swaps
# between two saved docker-compose.yml variants ("direct" and "vpn"), both
# kept on disk.
#
# Why gluetun instead of host-level WireGuard (wg-quick): it runs entirely
# inside Docker's network namespace and never touches the host's routing
# table, so it can't cut off an SSH session the way a full-tunnel wg-quick
# config could. Worst case: aiostreams stops responding — switch back to
# "direct" mode from the menu.
#
# Usage:
#   sudo bash setup-vpn-gluetun.sh
#
#   sudo bash setup-vpn-gluetun.sh install-boot-hook
#     Non-interactive: (re)install the systemd boot-safety hook only. Used by
#     setup-aiostreams.sh's restore path; idempotent.

set -euo pipefail

# Resolved to an absolute path HERE, before anything below can cd elsewhere
# (see 'cd "$INSTALL_DIR"' further down) — sync_self_into_install_dir needs
# this to still be accurate later, and re-resolving BASH_SOURCE[0] at that
# point would silently resolve relative to whatever directory the script
# happens to be sitting in BY THEN, not where it was actually invoked from.
SELF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;31m!! %s !!\033[0m\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# Under sudo, $HOME is root's home, not the invoking user's — so a .conf
# file the person SFTP'd into their own home dir wouldn't be found. Resolve
# the real home via SUDO_USER/getent so do_reconfigure_vpn's auto-detect
# checks there too.
REAL_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    [[ -n "$sudo_home" && -d "$sudo_home" ]] && REAL_HOME="$sudo_home"
fi

INSTALL_DIR="$HOME/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"
STATE_DIR="$INSTALL_DIR/vpn-state"
DIRECT_COMPOSE="$STATE_DIR/docker-compose.direct.yml"
VPN_COMPOSE="$STATE_DIR/docker-compose.vpn.yml"
DIRECT_CADDYFILE="$STATE_DIR/Caddyfile.direct"
VPN_CADDYFILE="$STATE_DIR/Caddyfile.vpn"
ACTIVE_MARKER="$STATE_DIR/active"
LAST_CONF_MARKER="$STATE_DIR/last-conf-path"

[[ -f "$COMPOSE_FILE" ]] || error "Couldn't find $COMPOSE_FILE — run setup-aiostreams.sh first."
[[ -f "$CADDYFILE" ]] || error "Couldn't find $CADDYFILE — run setup-aiostreams.sh first."

cd "$INSTALL_DIR"
mkdir -p "$STATE_DIR"
# Holds secrets (WireGuard private key, SECRET_KEY) — owner-only.
chmod 700 "$STATE_DIR"

# Keeps a canonical copy of THIS running script inside $INSTALL_DIR itself,
# on every single invocation. Without this, logging in as a non-root sudo
# user (the DEFAULT on most cloud providers) and following the docs' own
# "cd ~/aiostreams && curl ..." convention downloads this script into THAT
# user's home — but $INSTALL_DIR under sudo is always root's home, a
# completely different directory. do_restore's own script lookup checks
# $INSTALL_DIR first (see setup-aiostreams.sh), so a copy never landing
# there silently breaks the automatic VPN boot-hook reinstall on restore.
# Best-effort; never blocks the actual command being run. No-op once
# already in sync (cmp -s).
sync_self_into_install_dir() {
    local dest="$INSTALL_DIR/setup-vpn-gluetun.sh"
    [[ -f "$SELF_SCRIPT_PATH" ]] || return 0
    [[ "$SELF_SCRIPT_PATH" == "$dest" ]] && return 0
    if [[ ! -f "$dest" ]] || ! cmp -s "$SELF_SCRIPT_PATH" "$dest"; then
        if cp -- "$SELF_SCRIPT_PATH" "$dest" 2>/dev/null; then
            chmod +x "$dest" 2>/dev/null || true
            echo "(Synced this script into $INSTALL_DIR/setup-vpn-gluetun.sh — that's the copy future backups/restores will use.)"
        fi
    fi
    return 0
}
sync_self_into_install_dir

# ---------- helpers used by multiple menu options ----------

# Parses DOMAIN / SECRET_KEY / AUTH_LINE / IMAGE_TAG out of a compose file.
# Returns non-zero instead of exiting, so callers can chain `||` fallbacks.
# IMAGE_TAG isn't part of the success check — defaults to "latest" if absent
# (e.g. a compose file from before build-channel selection existed) so it
# never blocks an otherwise-valid read.
try_read_existing_values() {
    DOMAIN=$(grep -oP 'BASE_URL=https://\K[^"]+' "$1" 2>/dev/null || true)
    SECRET_KEY=$(grep -oP 'SECRET_KEY=\K[^"]+' "$1" 2>/dev/null || true)
    AUTH_LINE=$(grep -oP 'AIOSTREAMS_AUTH=\K[^"]+' "$1" 2>/dev/null | head -1 || true)
    IMAGE_TAG=$(grep -oP 'image: viren070/aiostreams:\K\S+' "$1" 2>/dev/null | head -1 || true)
    [[ -z "$IMAGE_TAG" ]] && IMAGE_TAG="latest"
    [[ -n "$DOMAIN" && -n "$SECRET_KEY" && -n "$AUTH_LINE" ]]
}

read_existing_values() {
    try_read_existing_values "$1" || \
        error "Couldn't parse DOMAIN/SECRET_KEY/AUTH from $1. Check it hasn't been hand-edited into an unexpected format."
}

# chmod 600 wrapper for anything that may contain secrets.
lock_down() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] && chmod 600 "$f"
    done
    # Explicit success: a missing final arg would otherwise make the chain
    # return 1, killing the script under set -e.
    return 0
}

write_direct_files() {
    cat > "$DIRECT_COMPOSE" << EOF
services:
  aiostreams:
    image: viren070/aiostreams:${IMAGE_TAG}
    container_name: aiostreams
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    environment:
      - PORT=3000
      - BASE_URL=https://${DOMAIN}
      - SECRET_KEY=${SECRET_KEY}
      - AIOSTREAMS_AUTH=${AUTH_LINE}
      - AIOSTREAMS_AUTH_REQUIRED=true
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
    cat > "$DIRECT_CADDYFILE" << EOF
${DOMAIN} {
    reverse_proxy aiostreams:3000
}

# Extra sites drop in here as their own files, so rewrites of THIS file
# never lose them. Zero matches is fine.
import caddy.d/*.caddy
EOF
    lock_down "$DIRECT_COMPOSE"
}

write_vpn_files() {
    local dns_line=""
    [[ -n "${WG_DNS:-}" ]] && dns_line=$'\n      - DNS_ADDRESS='"${WG_DNS}"
    cat > "$VPN_COMPOSE" << EOF
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WG_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=${WG_ADDRESS}
      - WIREGUARD_PUBLIC_KEY=${WG_PUBLIC_KEY}
      - WIREGUARD_ENDPOINT_IP=${WG_ENDPOINT_IP}
      - WIREGUARD_ENDPOINT_PORT=${WG_ENDPOINT_PORT}${dns_line}
      # gluetun blocks inbound by default. Caddy proxying to gluetun:3000
      # is inbound traffic into gluetun's namespace, so this port must be
      # opened or the reverse proxy times out even with a healthy tunnel.
      - FIREWALL_INPUT_PORTS=3000
  aiostreams:
    image: viren070/aiostreams:${IMAGE_TAG}
    container_name: aiostreams
    # NOT unless-stopped: on a full reboot Docker restarts unless-stopped
    # containers directly, bypassing 'docker compose up' and this script's
    # tunnel-confirmation logic — aiostreams could attach to gluetun's
    # namespace before the WireGuard handshake completes. Instead it's left
    # stopped on boot, and aiostreams-vpn-boot.service (installed below)
    # starts it explicitly, only after confirming the tunnel. gluetun and
    # caddy keep unless-stopped since neither depends on the tunnel this way.
    restart: "no"
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    volumes:
      - ./data:/app/data
    environment:
      - PORT=3000
      - BASE_URL=https://${DOMAIN}
      - SECRET_KEY=${SECRET_KEY}
      - AIOSTREAMS_AUTH=${AUTH_LINE}
      - AIOSTREAMS_AUTH_REQUIRED=true
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
      - gluetun
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
    cat > "$VPN_CADDYFILE" << EOF
${DOMAIN} {
    reverse_proxy gluetun:3000
}

# Extra sites drop in here as their own files, so rewrites of THIS file
# never lose them. Zero matches is fine.
import caddy.d/*.caddy
EOF
    lock_down "$VPN_COMPOSE"
}

# Regenerates vpn-state/docker-compose.vpn.yml from its own current values,
# re-fed through the current write_vpn_files() template — rather than
# blindly reusing a snapshot that may have been written by an older version
# of this script (so template fixes, e.g. the boot hook, actually reach
# existing installs on the next toggle instead of needing a manual
# Reconfigure). No WireGuard values need re-entering; they're already in
# the snapshot as plain text.
#
# Safe to call on every 'Turn VPN ON': idempotent, no-op if $VPN_COMPOSE
# doesn't exist yet (only true before the very first write_vpn_files call).
refresh_vpn_snapshot() {
    [[ -f "$VPN_COMPOSE" ]] || return 0

    WG_PRIVATE_KEY=$(grep -oP '(?<=WIREGUARD_PRIVATE_KEY=).*' "$VPN_COMPOSE" | head -1 || true)
    WG_ADDRESS=$(grep -oP '(?<=WIREGUARD_ADDRESSES=).*' "$VPN_COMPOSE" | head -1 || true)
    WG_PUBLIC_KEY=$(grep -oP '(?<=WIREGUARD_PUBLIC_KEY=).*' "$VPN_COMPOSE" | head -1 || true)
    WG_ENDPOINT_IP=$(grep -oP '(?<=WIREGUARD_ENDPOINT_IP=).*' "$VPN_COMPOSE" | head -1 || true)
    WG_ENDPOINT_PORT=$(grep -oP '(?<=WIREGUARD_ENDPOINT_PORT=).*' "$VPN_COMPOSE" | head -1 || true)
    WG_DNS=$(grep -oP '(?<=DNS_ADDRESS=).*' "$VPN_COMPOSE" | head -1 || true)
    SECRET_KEY=$(grep -oP '(?<=SECRET_KEY=).*' "$VPN_COMPOSE" | head -1 || true)
    AUTH_LINE=$(grep -oP '(?<=AIOSTREAMS_AUTH=).*' "$VPN_COMPOSE" | head -1 || true)
    DOMAIN=$(head -1 "$VPN_CADDYFILE" 2>/dev/null | awk '{print $1}' || true)
    IMAGE_TAG=$(grep -oP 'image: viren070/aiostreams:\K\S+' "$VPN_COMPOSE" 2>/dev/null | head -1 || true)
    [[ -z "$IMAGE_TAG" ]] && IMAGE_TAG="latest"

    if [[ -z "$WG_PRIVATE_KEY" || -z "$WG_ADDRESS" || -z "$WG_PUBLIC_KEY" || -z "$WG_ENDPOINT_IP" || -z "$WG_ENDPOINT_PORT" || -z "$SECRET_KEY" || -z "$AUTH_LINE" || -z "$DOMAIN" ]]; then
        warn "Couldn't cleanly extract all values from the existing VPN snapshot — leaving it as-is rather than risk writing a broken one. If aiostreams-vpn-boot.service seems missing after this, run 'Reconfigure VPN' (option 4) once to regenerate it from scratch."
        return 0
    fi

    write_vpn_files
}

# ---------- reboot safety: systemd boot hook ----------
#
# aiostreams' VPN-mode restart policy is "no" (see write_vpn_files), so
# Docker won't auto-restart it on reboot the way it does gluetun/caddy.
# This installs a oneshot systemd service that runs after docker.service on
# every boot: wait for gluetun, confirm the tunnel, then start aiostreams —
# the same guarantee apply_mode's VPN branch gives on a live toggle, now
# also enforced across a reboot.
#
# Idempotent — safe on every apply_mode("vpn") call. In direct mode the
# installed hook itself no-ops at boot time rather than needing to be
# installed/removed on every toggle.
BOOT_SCRIPT="/usr/local/bin/aiostreams-vpn-boot.sh"
BOOT_UNIT="/etc/systemd/system/aiostreams-vpn-boot.service"

install_vpn_boot_hook() {
    command -v systemctl >/dev/null 2>&1 || { warn "systemctl not found — skipping boot-safety hook (Docker will fall back to its own unless-stopped restart on reboot, which is not tunnel-gated)."; return 0; }

    cat > "$BOOT_SCRIPT" << EOF
#!/usr/bin/env bash
# Auto-generated by setup-vpn-gluetun.sh — do not edit by hand, it will be
# overwritten. Runs on every boot via aiostreams-vpn-boot.service.
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR}"
COMPOSE_FILE="\$INSTALL_DIR/docker-compose.yml"
TAG="aiostreams-vpn-boot"

log() { logger -t "\$TAG" -- "\$1" 2>/dev/null; echo "\$1"; }

[[ -f "\$COMPOSE_FILE" ]] || { log "No install found at \$INSTALL_DIR — nothing to do."; exit 0; }

# Direct mode: aiostreams has no tunnel dependency, and its restart policy
# there is unless-stopped — Docker already handles it, nothing to do here.
grep -q 'container_name: gluetun' "\$COMPOSE_FILE" 2>/dev/null || { log "Direct mode — nothing for this boot hook to do."; exit 0; }

cd "\$INSTALL_DIR" || exit 1
log "VPN mode detected at boot — waiting for gluetun before starting aiostreams"

# Safety net in case gluetun/caddy (restart: unless-stopped) aren't already
# coming back up on their own by the time this runs.
docker compose up -d --no-deps gluetun caddy >/dev/null 2>&1

waited=0
gluetun_up=false
while (( waited < 60 )); do
    if [[ "\$(docker inspect -f '{{.State.Running}}' gluetun 2>/dev/null)" == "true" ]]; then
        gluetun_up=true
        break
    fi
    sleep 2
    waited=\$((waited + 2))
done

if ! \$gluetun_up; then
    log "gluetun did not come up within 60s of boot — aiostreams NOT started. Check: docker compose -f \$COMPOSE_FILE logs gluetun"
    exit 1
fi

# Longer window than a live toggle's ~16s ceiling since DNS/networking can
# take longer to settle right after boot. Tries several IP-lookup services
# since this runs unattended — one service being down shouldn't read as
# "tunnel not connected".
tunnel_confirmed=false
attempt=1
while (( attempt <= 15 )); do
    for svc in ifconfig.me/ip icanhazip.com ipinfo.io/ip; do
        if docker exec gluetun wget -qO- --timeout=5 "\$svc" 2>/dev/null | grep -qE '^[0-9]'; then
            tunnel_confirmed=true
            break
        fi
    done
    \$tunnel_confirmed && break
    sleep 2
    attempt=\$((attempt + 1))
done

if \$tunnel_confirmed; then
    log "Tunnel confirmed at boot — starting aiostreams"
    docker compose up -d --no-deps aiostreams >/dev/null 2>&1
    log "aiostreams started."
else
    log "Tunnel could not be confirmed after boot — aiostreams NOT started (left stopped, not attached to an unconfirmed tunnel). Check: docker compose -f \$COMPOSE_FILE logs gluetun — then once resolved: cd \$INSTALL_DIR && sudo bash setup-aiostreams.sh (option 3, Start AIOStreams)."
fi
EOF
    chmod 700 "$BOOT_SCRIPT"

    cat > "$BOOT_UNIT" << 'EOF'
[Unit]
Description=AIOStreams VPN-gated startup (starts aiostreams only after the WireGuard tunnel is confirmed connected, when VPN mode is active)
After=docker.service network-online.target
Wants=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/aiostreams-vpn-boot.sh
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable aiostreams-vpn-boot.service >/dev/null 2>&1
    info "Boot-safety hook installed: aiostreams will wait for a confirmed tunnel on every reboot, instead of Docker restarting it blindly."
}

# Called when leaving VPN mode for good (Turn VPN OFF or full VPN
# uninstall). Harmless to leave in place, but removing it keeps the host
# clean once fully back to direct mode.
remove_vpn_boot_hook() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable aiostreams-vpn-boot.service >/dev/null 2>&1 || true
    rm -f "$BOOT_UNIT" "$BOOT_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1
}

# Warns before turning the VPN off while AIOStreams is live and currently
# VPN-protected — switches outbound traffic to the VPS's real IP, with a
# brief window mid-switch where an in-flight request could go out
# unprotected. Silent if VPN is already off or AIOStreams isn't running.
#
# Returns 0 to proceed, 1 if the user cancelled.
confirm_vpn_disruption() {
    local current
    current=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
    [[ "$current" == "vpn" ]] || return 0   # not currently VPN-protected, nothing to warn about

    local aio_running
    aio_running=$(docker inspect -f '{{.State.Running}}' aiostreams 2>/dev/null || echo "false")
    [[ "$aio_running" == "true" ]] || return 0   # not live right now, nothing to expose

    echo ""
    echo -e "\033[1;31m!! WARNING: AIOStreams is LIVE and currently VPN-protected !!\033[0m"
    echo -e "\033[1;31mTurning the VPN off switches its outbound traffic to your VPS's real\033[0m"
    echo -e "\033[1;31mIP from here on, and there's a brief window during the switch itself\033[0m"
    echo -e "\033[1;31mwhere an in-flight request could go out unprotected.\033[0m"
    echo ""
    echo "  1) Continue anyway (stack stays live throughout the switch)"
    echo "  2) Stop AIOStreams first, then continue (nothing served during the switch — safest)"
    echo "  3) Cancel"
    read -rp "Choose an option [1-3]: " RISK_CHOICE
    case "$RISK_CHOICE" in
        1)
            return 0
            ;;
        2)
            info "Stopping AIOStreams so nothing is served during the switch"
            docker compose stop aiostreams || warn "Stop had issues — continuing anyway."
            return 0
            ;;
        *)
            echo "Cancelled — nothing changed."
            return 1
            ;;
    esac
}

apply_mode() {
    local mode="$1"  # "direct" or "vpn"
    # Optional. When "true", AIOStreams is never started as part of this
    # toggle — not started-then-stopped, never created at all. Used only by
    # the menu's Turn VPN ON/OFF options, based on AIOStreams' state right
    # before each toggle. Every other caller (first_time_setup,
    # do_update_gluetun, do_uninstall_vpn) omits this and always brings
    # everything up. do_uninstall_vpn relies on aiostreams being confirmed
    # running after its own apply_mode "direct" call before deleting
    # vpn-state, so this must stay opt-in, not the default.
    local skip_aiostreams="${2:-false}"

    # Re-derive the domain from the live Caddyfile into both saved
    # snapshots before doing anything else, so a toggle can only ever carry
    # the CURRENT domain forward — not silently overwrite a domain fix made
    # some other way (e.g. restore's DNS-mismatch flow) with a stale one
    # frozen in the snapshot. Only the domain line changes; the
    # reverse_proxy target that's supposed to differ between variants is
    # left alone.
    if [[ -f "$CADDYFILE" ]]; then
        local live_domain
        live_domain=$(head -1 "$CADDYFILE" | awk '{print $1}') || true
        if [[ -n "$live_domain" ]]; then
            [[ -f "$DIRECT_CADDYFILE" ]] && sed -i "1s/.*/${live_domain} {/" "$DIRECT_CADDYFILE"
            [[ -f "$VPN_CADDYFILE" ]] && sed -i "1s/.*/${live_domain} {/" "$VPN_CADDYFILE"
            [[ -f "$DIRECT_COMPOSE" ]] && sed -i "s|BASE_URL=https://[^\"[:space:]]*|BASE_URL=https://${live_domain}|" "$DIRECT_COMPOSE"
            [[ -f "$VPN_COMPOSE" ]] && sed -i "s|BASE_URL=https://[^\"[:space:]]*|BASE_URL=https://${live_domain}|" "$VPN_COMPOSE"
        fi
    fi

    # Same idea, for the aiostreams build channel: re-derive it from the LIVE
    # compose file (the one actually running right now) into both snapshots
    # before switching, so a stable/nightly choice made via setup-aiostreams.sh
    # since the last toggle carries forward instead of getting silently
    # reverted to whatever tag was frozen in the snapshot.
    if [[ -f "$COMPOSE_FILE" ]]; then
        local live_tag
        live_tag=$(grep -oP 'image: viren070/aiostreams:\K\S+' "$COMPOSE_FILE" 2>/dev/null | head -1 || true)
        if [[ -n "$live_tag" ]]; then
            [[ -f "$DIRECT_COMPOSE" ]] && sed -i "s|image: viren070/aiostreams:.*|image: viren070/aiostreams:${live_tag}|" "$DIRECT_COMPOSE"
            [[ -f "$VPN_COMPOSE" ]] && sed -i "s|image: viren070/aiostreams:.*|image: viren070/aiostreams:${live_tag}|" "$VPN_COMPOSE"
        fi
    fi

    # Teardown happens FIRST, against the currently active compose file,
    # before the new one is swapped in — otherwise switching vpn -> direct
    # tears down using a file with no gluetun service and no knowledge that
    # aiostreams shares its namespace, and gluetun can be left as an orphan.
    info "Stopping the current stack"
    docker compose down --remove-orphans || {
        warn "Normal teardown failed — force-removing containers by name."
        docker rm -f aiostreams caddy gluetun 2>/dev/null || true
    }

    if [[ "$mode" == "direct" ]]; then
        cp "$DIRECT_COMPOSE" "$COMPOSE_FILE"
        cp "$DIRECT_CADDYFILE" "$CADDYFILE"
        remove_vpn_boot_hook
    else
        refresh_vpn_snapshot
        cp "$VPN_COMPOSE" "$COMPOSE_FILE"
        cp "$VPN_CADDYFILE" "$CADDYFILE"
        install_vpn_boot_hook
    fi
    chmod 600 "$COMPOSE_FILE"
    echo "$mode" > "$ACTIVE_MARKER"

    # Read fresh from whichever Caddyfile was just activated — toggling
    # from the menu doesn't go through read_existing_values.
    local domain
    domain=$(head -1 "$CADDYFILE" | awk '{print $1}')

    info "Starting the stack in '$mode' mode"

    if [[ "$mode" == "vpn" ]]; then
        # aiostreams shares gluetun's namespace. gluetun (+ caddy) come up
        # first, the tunnel is confirmed connected, and only then is
        # aiostreams started — rather than bringing all three up together
        # and relying solely on gluetun's own kill switch during the gap
        # before the handshake finishes.
        if [[ "$skip_aiostreams" == "true" ]]; then
            info "AIOStreams was already stopped — leaving it stopped (not starting it as part of this toggle)"
        fi
        docker compose up -d --no-deps --remove-orphans gluetun caddy

        info "Verifying gluetun and caddy are actually running"
        local core_expected=(caddy gluetun)
        local attempt not_running svc state
        for attempt in 1 2 3 4 5; do
            not_running=()
            for svc in "${core_expected[@]}"; do
                state=$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
                [[ "$state" == "true" ]] || not_running+=("$svc")
            done
            [[ ${#not_running[@]} -eq 0 ]] && break
            sleep 2
        done
        if [[ ${#not_running[@]} -gt 0 ]]; then
            error "Stack did NOT come back up cleanly after switching to '$mode' mode — not running: ${not_running[*]}. Nothing further was deleted or removed. Check 'docker compose logs' and 'docker ps -a', then re-run this script once it's resolved (try 'docker compose up -d' manually from $INSTALL_DIR first — it's often enough on its own)."
        fi

        info "Confirming the WireGuard tunnel is actually connected..."
        # Several IP-lookup services — one being down/rate-limited
        # shouldn't read as "tunnel not connected".
        local tunnel_confirmed=false tunnel_attempt ip_svc
        local ip_svcs=("ifconfig.me/ip" "icanhazip.com" "ipinfo.io/ip")
        for (( tunnel_attempt=1; tunnel_attempt<=8; tunnel_attempt++ )); do
            for ip_svc in "${ip_svcs[@]}"; do
                if docker exec gluetun wget -qO- --timeout=5 "$ip_svc" 2>/dev/null | grep -qE '^[0-9]'; then
                    tunnel_confirmed=true
                    break
                fi
            done
            [[ "$tunnel_confirmed" == "true" ]] && break
            echo "  Tunnel not confirmed yet (attempt ${tunnel_attempt}/8)..."
            sleep 2
        done
        echo ""
        docker compose logs gluetun --tail=15
        echo ""
        if [[ "$tunnel_confirmed" == "true" ]]; then
            EXIT_IP=""
            for ip_svc in "${ip_svcs[@]}"; do
                EXIT_IP=$(docker exec gluetun wget -qO- "$ip_svc" 2>/dev/null) && [[ -n "$EXIT_IP" ]] && break
            done
            echo -e "\033[1;32mVPN is up.\033[0m gluetun's exit IP: $EXIT_IP"
        else
            warn "Couldn't confirm the exit IP automatically. Check manually with:"
            echo "  docker exec gluetun wget -qO- ifconfig.me/ip"
        fi

        if [[ "$skip_aiostreams" != "true" ]]; then
            if [[ "$tunnel_confirmed" == "true" ]]; then
                info "Tunnel confirmed — starting AIOStreams"
                docker compose up -d aiostreams
                for attempt in 1 2 3 4 5; do
                    state=$(docker inspect -f '{{.State.Running}}' aiostreams 2>/dev/null || echo "false")
                    [[ "$state" == "true" ]] && break
                    sleep 2
                done
                [[ "$state" == "true" ]] || \
                    error "AIOStreams did not come up even after the tunnel was confirmed. Check 'docker compose logs aiostreams' and 'docker ps -a'."
            else
                echo ""
                echo -e "\033[1;31m!! NOT starting AIOStreams — the tunnel could not be confirmed connected !!\033[0m"
                echo -e "\033[1;31mStarting it now could mean its traffic goes out unprotected. Check the\033[0m"
                echo -e "\033[1;31mgluetun logs above, fix the tunnel, then run this script again and\033[0m"
                echo -e "\033[1;31mchoose 'Turn VPN ON' to retry — AIOStreams stays stopped until then.\033[0m"
            fi
        fi
    else
        if [[ "$skip_aiostreams" == "true" ]]; then
            # --no-deps so compose doesn't pull aiostreams in as caddy's
            # dependency — caddy alone means the domain still responds
            # (502), and aiostreams is never created.
            info "AIOStreams was already stopped — leaving it stopped (not starting it as part of this toggle)"
            docker compose up -d --no-deps --remove-orphans caddy
        else
            docker compose up -d --remove-orphans
        fi

        # Verify the containers this mode needs are really running before
        # a caller like do_uninstall_vpn is allowed to treat this as done
        # and move on to destructive cleanup steps.
        local expected=(caddy)
        [[ "$skip_aiostreams" == "true" ]] || expected+=(aiostreams)

        info "Verifying containers are actually running"
        local attempt not_running svc state
        for attempt in 1 2 3 4 5; do
            not_running=()
            for svc in "${expected[@]}"; do
                state=$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
                [[ "$state" == "true" ]] || not_running+=("$svc")
            done
            [[ ${#not_running[@]} -eq 0 ]] && break
            sleep 2
        done

        if [[ ${#not_running[@]} -gt 0 ]]; then
            error "Stack did NOT come back up cleanly after switching to '$mode' mode — not running: ${not_running[*]}. Nothing further was deleted or removed. Check 'docker compose logs' and 'docker ps -a', then re-run this script once it's resolved (try 'docker compose up -d' manually from $INSTALL_DIR first — it's often enough on its own)."
        fi
    fi

    echo ""
    echo -e "Confirm at \033[1;36mhttps://${domain}\033[0m"
}

do_status() {
    local active live_mode saved
    active=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")

    # LIVE compose file, independent of the marker: gluetun service
    # present = vpn layout, absent = direct layout.
    if grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null; then
        live_mode="vpn"
    else
        live_mode="direct"
    fi

    echo ""
    echo "Current mode (marker): $active"
    echo "Live compose layout:   $live_mode"

    # Mismatch: another tool (e.g. setup-aiostreams.sh 'Reconfigure') has
    # replaced the live file since this script last set the mode.
    if [[ "$active" != "unknown" && "$active" != "$live_mode" ]]; then
        echo ""
        warn "MISMATCH: the marker says '$active' but the live docker-compose.yml is the '$live_mode' layout."
        warn "Most likely cause: setup-aiostreams.sh's 'Reconfigure' option rewrote the compose file."
        warn "Fix: run option 4 (Reconfigure VPN) so this script re-reads your current domain/login,"
        warn "then toggle to the mode you actually want (option 2 or 3)."
    else
        # Layouts match — but has the CONTENT drifted from the saved
        # variant? Domain and image tag are re-derived from the live file
        # automatically at the top of every apply_mode() call (see there),
        # so drift in ONLY those is harmless and self-corrects on the next
        # toggle — not worth alarming anyone over. SECRET_KEY and the
        # login (AUTH_LINE) are NOT re-derived that way, so drift in
        # EITHER of those really would get silently overwritten by a
        # stale saved value on the next toggle — that's the case actually
        # worth a warning.
        saved="$DIRECT_COMPOSE"
        [[ "$live_mode" == "vpn" ]] && saved="$VPN_COMPOSE"
        if [[ -f "$saved" ]] && ! cmp -s "$COMPOSE_FILE" "$saved"; then
            local live_secret saved_secret live_auth saved_auth
            live_secret=$(grep -oP 'SECRET_KEY=\K[^"]+' "$COMPOSE_FILE" 2>/dev/null || true)
            saved_secret=$(grep -oP 'SECRET_KEY=\K[^"]+' "$saved" 2>/dev/null || true)
            live_auth=$(grep -oP 'AIOSTREAMS_AUTH=\K[^"]+' "$COMPOSE_FILE" 2>/dev/null | head -1 || true)
            saved_auth=$(grep -oP 'AIOSTREAMS_AUTH=\K[^"]+' "$saved" 2>/dev/null | head -1 || true)
            if [[ "$live_secret" != "$saved_secret" || "$live_auth" != "$saved_auth" ]]; then
                echo ""
                warn "The live compose file's SECRET_KEY or login differs from this script's saved"
                warn "'$live_mode' variant — unlike domain/image-tag drift, this does NOT self-correct."
                warn "Run option 4 (Reconfigure VPN) to refresh the saved configs, otherwise the next"
                warn "toggle would overwrite the live file with a stale SECRET_KEY/login."
            fi
            # else: only domain and/or image tag differ — apply_mode()
            # re-derives both from the live file before every toggle, so
            # this is already going to correct itself. No warning needed.
        fi
    fi

    echo ""
    docker compose ps
    if [[ "$active" == "vpn" && "$live_mode" == "vpn" ]]; then
        echo ""
        echo "gluetun exit IP:"
        local status_ip="" status_svc
        for status_svc in "ifconfig.me/ip" "icanhazip.com" "ipinfo.io/ip"; do
            status_ip=$(docker exec gluetun wget -qO- "$status_svc" 2>/dev/null) && [[ -n "$status_ip" ]] && break
        done
        if [[ -n "$status_ip" ]]; then
            echo "$status_ip"
        else
            warn "Couldn't reach any IP-lookup service from inside gluetun — tunnel may be down."
        fi
    fi
}

do_uninstall_vpn() {
    warn "This removes the VPN layer entirely — back to a plain AIOStreams + Caddy stack, as if this script never ran."
    echo ""
    echo "This will:"
    echo "  - Switch back to direct mode if VPN is currently on (a few seconds of downtime)"
    echo "  - Remove the gluetun container and its saved state (including your WireGuard private key)"
    echo "  - Optionally remove the gluetun Docker image"
    echo "  - Optionally delete the original .conf file you uploaded (it also contains your private key)"
    echo ""
    read -rp "Continue? [y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|Yes) ;;
        *) echo "Cancelled."; return ;;
    esac

    local active
    active=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
    if [[ "$active" == "vpn" ]]; then
        info "Switching back to direct mode first"
        apply_mode "direct"
    fi

    info "Removing gluetun container, if it still exists"
    docker rm -f gluetun 2>/dev/null || true

    read -rp "Also remove the gluetun Docker image (qmcgaw/gluetun)? [y/N]: " RM_IMAGE
    case "$RM_IMAGE" in
        y|Y|yes|Yes) docker rmi qmcgaw/gluetun:latest 2>/dev/null || warn "Couldn't remove the image — it may be in use or already gone." ;;
    esac

    local orig_conf=""
    [[ -f "$LAST_CONF_MARKER" ]] && orig_conf=$(cat "$LAST_CONF_MARKER" 2>/dev/null || true)
    if [[ -n "$orig_conf" && -f "$orig_conf" ]]; then
        echo ""
        echo "Your original WireGuard config is still at: $orig_conf"
        echo "It contains your private key in plain text."
        read -rp "Delete it too? [y/N]: " RM_CONF
        case "$RM_CONF" in
            y|Y|yes|Yes) rm -f "$orig_conf" && echo "Deleted $orig_conf." ;;
        esac
    fi

    info "Removing saved VPN state (vpn-state/) — this is where the private key was stored for toggling"

    # Double check aiostreams/caddy are confirmed running before deleting
    # anything irreversible — apply_mode above already hard-stops on
    # failure, but this is defense-in-depth in case that guarantee is ever
    # weakened upstream.
    local svc state
    for svc in aiostreams caddy; do
        state=$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
        [[ "$state" == "true" ]] || error "Refusing to delete VPN state — '$svc' isn't confirmed running. Nothing was deleted. Check 'docker ps -a' and 'docker compose logs', get the stack healthy, then re-run Uninstall VPN layer."
    done

    rm -rf "$STATE_DIR"

    echo ""
    echo "Done. You're back on a plain AIOStreams + Caddy stack with no VPN layer."
    echo "Running this script again will start first-time VPN setup from scratch."
}

do_force_cleanup() {
    warn "Force-removing any aiostreams/caddy/gluetun containers by name."
    docker rm -f aiostreams caddy gluetun 2>/dev/null || true
    docker compose down --remove-orphans 2>/dev/null || true
    echo ""
    echo "Done. Anything left running:"
    docker ps --filter "name=aiostreams" --filter "name=caddy" --filter "name=gluetun"
    echo ""
    echo "Use 'Turn VPN ON' or 'Turn VPN OFF' from the menu to bring the stack back up."
}

do_update_gluetun() {
    # Updates ONLY the gluetun image. setup-aiostreams.sh (menu option 3)
    # also updates gluetun whenever VPN mode is active, since it pulls +
    # force-recreates everything live. This option is for updating gluetun
    # on its own, or keeping the image fresh while in direct mode (where
    # gluetun isn't in the live file and would never get pulled otherwise).
    local active
    active=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")

    info "Pulling latest gluetun image"
    docker pull qmcgaw/gluetun:latest

    if [[ "$active" == "vpn" ]]; then
        echo ""
        echo "VPN mode is active — restarting the stack so the new image takes effect."
        echo "(Full toggle rather than a lone container restart: aiostreams shares"
        echo "gluetun's network namespace, so both must be recreated together.)"
        apply_mode "vpn"
    else
        echo ""
        echo "Done. You're in direct mode, so nothing needs restarting —"
        echo "the updated image will be used next time you turn the VPN on."
    fi
}

do_reconfigure_vpn() {
    # Prefer the live compose file; fall back to the saved direct variant.
    try_read_existing_values "$COMPOSE_FILE" || read_existing_values "$DIRECT_COMPOSE"

    info "WireGuard config"
    echo "Point this at a WireGuard .conf file already on this server."

    # Auto-detect .conf files in /root and the invoking sudo user's home,
    # filtered by content (needs [Interface]/[Peer]/PrivateKey/Endpoint) so
    # an unrelated .conf like nginx.conf isn't offered as a choice.
    local scan_dirs=("/root")
    [[ "$REAL_HOME" != "/root" ]] && scan_dirs+=("$REAL_HOME")
    local candidates=() detected=()
    while IFS= read -r -d '' f; do
        candidates+=("$f")
    done < <(find "${scan_dirs[@]}" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)

    for f in "${candidates[@]}"; do
        if grep -qi '^\[Interface\]' "$f" 2>/dev/null && \
           grep -qi '^\[Peer\]' "$f" 2>/dev/null && \
           grep -qi '^PrivateKey' "$f" 2>/dev/null && \
           grep -qi '^Endpoint' "$f" 2>/dev/null; then
            detected+=("$f")
        fi
    done

    local scan_dirs_str
    scan_dirs_str=$(IFS=', '; echo "${scan_dirs[*]}")

    if [[ ${#detected[@]} -eq 0 && ${#candidates[@]} -gt 0 ]]; then
        echo "Found .conf file(s) in $scan_dirs_str, but none look like valid WireGuard configs (missing [Interface]/[Peer]/PrivateKey/Endpoint) — skipping auto-detect."
    fi

    local last_used=""
    [[ -f "$LAST_CONF_MARKER" ]] && last_used=$(cat "$LAST_CONF_MARKER" 2>/dev/null || true)

    if [[ ${#detected[@]} -eq 1 ]]; then
        local tag=""
        [[ "${detected[0]}" == "$last_used" ]] && tag=" (currently in use)"
        echo "Found ${detected[0]}${tag}."
        read -rp "Use this file? [Y/n] (or enter a different path): " WG_CHOICE
        case "$WG_CHOICE" in
            ""|y|Y|yes|Yes) WG_PATH="${detected[0]}" ;;
            n|N|no|No) read -rp "Path to .conf file: " WG_PATH ;;
            *) WG_PATH="$WG_CHOICE" ;;
        esac
    elif [[ ${#detected[@]} -gt 1 ]]; then
        echo "Found multiple .conf files:"
        local i=1
        for f in "${detected[@]}"; do
            local tag=""
            [[ "$f" == "$last_used" ]] && tag=" (currently in use)"
            echo "  $i) $f$tag"
            ((i++))
        done
        echo "  0) Enter a different path"
        read -rp "Choose a number [0-${#detected[@]}]: " WG_NUM
        if [[ "$WG_NUM" =~ ^[0-9]+$ ]] && (( WG_NUM >= 1 && WG_NUM <= ${#detected[@]} )); then
            WG_PATH="${detected[$((WG_NUM-1))]}"
        else
            read -rp "Path to .conf file: " WG_PATH
        fi
    else
        read -rp "Path to .conf file: " WG_PATH
    fi

    [[ -f "$WG_PATH" ]] || error "File not found: $WG_PATH"

    WG_PRIVATE_KEY=$(grep -i '^PrivateKey' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' \r' || true)
    WG_ADDRESS=$(grep -i '^Address' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' \r' || true)
    WG_PUBLIC_KEY=$(grep -i '^PublicKey' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' \r' || true)
    WG_ENDPOINT=$(grep -i '^Endpoint' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' \r' || true)

    [[ -n "$WG_PRIVATE_KEY" && -n "$WG_ADDRESS" && -n "$WG_PUBLIC_KEY" && -n "$WG_ENDPOINT" ]] || \
        error "Couldn't parse PrivateKey/Address/PublicKey/Endpoint from $WG_PATH."

    WG_ENDPOINT_IP="${WG_ENDPOINT%%:*}"
    WG_ENDPOINT_PORT="${WG_ENDPOINT##*:}"

    if ! [[ "$WG_ENDPOINT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Endpoint '$WG_ENDPOINT_IP' isn't a literal IPv4 address. gluetun requires an IP, not a hostname — resolve it first (e.g. 'dig +short $WG_ENDPOINT_IP') and edit the .conf file's Endpoint line before retrying."
    fi

    echo "  Parsed endpoint: $WG_ENDPOINT_IP:$WG_ENDPOINT_PORT"

    info "DNS (optional)"
    echo "By default gluetun uses its own encrypted DNS (Cloudflare) rather than"
    echo "your VPN provider's DNS server. This is intentional privacy design —"
    echo "queries still go through the tunnel either way — but some DNS-leak-test"
    echo "sites flag it as a mismatch since the resolver isn't your VPN provider's."

    # Most WireGuard configs include their own DNS = line, so check there
    # first rather than making the person look it up.
    local dns_from_conf=""
    dns_from_conf=$(grep -i '^DNS' "$WG_PATH" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r' | cut -d, -f1 || true)

    local dns_default=""
    [[ -f "$VPN_COMPOSE" ]] && dns_default=$(grep -i '^\s*- DNS_ADDRESS=' "$VPN_COMPOSE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r' || true)

    if [[ -n "$dns_from_conf" ]]; then
        echo ""
        echo "Found DNS = $dns_from_conf in $WG_PATH — this is what the provider's own app would use."
        read -rp "Use this DNS server? [Y/n] (or type a different IP, or 'clear' to skip DNS entirely): " WG_DNS_INPUT
        case "$WG_DNS_INPUT" in
            ""|y|Y|yes|Yes) WG_DNS="$dns_from_conf" ;;
            clear|Clear|CLEAR) WG_DNS="" ;;
            n|N|no|No) read -rp "DNS server IP (blank to skip): " WG_DNS ;;
            *) WG_DNS="$WG_DNS_INPUT" ;;
        esac
    elif [[ -n "$dns_default" ]]; then
        echo ""
        echo "No DNS line found in $WG_PATH. Leave blank to keep gluetun's default,"
        echo "or enter a DNS server IP to use instead."
        read -rp "DNS server IP [$dns_default, Enter to keep, or type 'clear' to unset]: " WG_DNS_INPUT
        case "$WG_DNS_INPUT" in
            "") WG_DNS="$dns_default" ;;
            clear|Clear|CLEAR) WG_DNS="" ;;
            *) WG_DNS="$WG_DNS_INPUT" ;;
        esac
    else
        echo ""
        echo "No DNS line found in $WG_PATH. Leave blank to keep gluetun's default,"
        echo "or enter a DNS server IP to use instead (e.g. NordVPN: 103.86.96.100)."
        read -rp "DNS server IP (blank to skip): " WG_DNS
    fi

    echo "$WG_PATH" > "$LAST_CONF_MARKER"
    write_vpn_files
    echo "VPN config saved. Choose 'Turn VPN ON' from the menu to apply it."
}

# ---------- first-time setup ----------

first_time_setup() {
    info "First-time VPN setup"
    read_existing_values "$COMPOSE_FILE"
    echo "  Domain: $DOMAIN"
    echo "  Auth user: ${AUTH_LINE%%:*}"

    write_direct_files   # capture current (pre-VPN) state as the "direct" variant

    do_reconfigure_vpn

    BACKUP_DIR="$INSTALL_DIR/backup-pre-vpn-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    cp "$COMPOSE_FILE" "$BACKUP_DIR/"
    cp "$CADDYFILE" "$BACKUP_DIR/"
    lock_down "$BACKUP_DIR"/*
    echo "(Original config also backed up to $BACKUP_DIR, just in case.)"

    apply_mode "vpn"
}

# ---------- menu ----------

# Non-interactive entry point so do_restore (setup-aiostreams.sh) can
# install the boot-safety hook on a freshly-restored server without going
# through the interactive menu. Idempotent — safe even if already installed.
if [[ "${1:-}" == "install-boot-hook" ]]; then
    install_vpn_boot_hook
    exit 0
fi

if [[ ! -f "$ACTIVE_MARKER" ]]; then
    first_time_setup
    exit 0
fi

while true; do
    echo ""
    echo "=== AIOStreams VPN control ==="
    CURRENT=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
    echo "Current mode: $CURRENT"

    # Self-healing reminder — see the matching check in setup-aiostreams.sh
    # for why this derives from the unit's existence rather than a marker.
    if [[ "$CURRENT" == "vpn" && ! -f "$BOOT_UNIT" ]]; then
        alert "VPN mode is on but the boot-safety hook is not installed. AIOStreams"
        alert "will not restart after a reboot. Fix: choose \"Turn VPN ON\" (option 2)."
    fi
    echo ""
    echo "1) Status"
    echo "2) Turn VPN ON"
    echo "3) Turn VPN OFF (direct connection)"
    echo "4) Reconfigure VPN (change WireGuard server/config)"
    echo "5) Update gluetun (pull latest image; safe restart if VPN is on)"
    echo "6) Force cleanup (remove stray containers if a toggle got wedged)"
    echo "7) Uninstall VPN layer (clean removal, back to plain AIOStreams + Caddy)"
    echo "8) Exit"
    read -rp "Choose an option [1-8]: " CHOICE

    case "$CHOICE" in
        1) do_status ;;
        2)
            # No confirm_vpn_disruption gate — unlike OFF, this direction
            # never exposes anything. skip_aio purely avoids resurrecting
            # AIOStreams if it was deliberately left stopped beforehand.
            aio_running_now=$(docker inspect -f '{{.State.Running}}' aiostreams 2>/dev/null || echo "false")
            skip_aio="false"
            [[ "$aio_running_now" == "true" ]] || skip_aio="true"
            apply_mode "vpn" "$skip_aio"
            ;;
        3)
            if confirm_vpn_disruption; then
                # Check AFTER confirm_vpn_disruption — if the user picked
                # "Stop AIOStreams first" inside that prompt, it's only
                # actually stopped by the time we get here.
                aio_running_now=$(docker inspect -f '{{.State.Running}}' aiostreams 2>/dev/null || echo "false")
                skip_aio="false"
                [[ "$aio_running_now" == "true" ]] || skip_aio="true"
                apply_mode "direct" "$skip_aio"
            fi
            ;;
        4) do_reconfigure_vpn ;;
        5) do_update_gluetun ;;
        6) do_force_cleanup ;;
        7) do_uninstall_vpn ;;
        8) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
