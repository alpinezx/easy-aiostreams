#!/usr/bin/env bash
#
# Cloudflare Tunnel for Easy AIOStreams: host from home, behind any router,
# with no ports forwarded and no public IP needed.
#
#   sudo bash /opt/aiostreams/setup-tunnel.sh            menu
#   sudo bash /opt/aiostreams/setup-tunnel.sh on         turn it on (asks for the tunnel's token)
#   sudo bash /opt/aiostreams/setup-tunnel.sh off        back to a normal server (asks first; --yes skips)
#   sudo bash /opt/aiostreams/setup-tunnel.sh status     on or off, connected or not, the routes needed
#   sudo bash /opt/aiostreams/setup-tunnel.sh check      exit 0 connected, 1 not connected, 2 off
#   sudo bash /opt/aiostreams/setup-tunnel.sh routes     the hostnames that need a route in Cloudflare
#   sudo bash /opt/aiostreams/setup-tunnel.sh token      replace the token
#   sudo bash /opt/aiostreams/setup-tunnel.sh update     pull the newest cloudflared
#
# cloudflared runs in tunnel-state/ with its own compose file, on the same
# Docker network as the add-ons, and connects out to Cloudflare. Cloudflare
# holds the HTTPS certificates and passes visitors down the tunnel to Caddy.
# Caddy then serves every site as plain HTTP on port 80, from one block at
# the top of the Caddyfile; the sites themselves are written as on any server,
# and nothing is published on the server's ports 80 and 443.
#
# setup-aiostreams.sh's option 11 and its "tunnel" command hand over to this
# script. Anything that rewrites the Caddyfile or the compose file (install,
# Reconfigure, the VPN) runs "_apply" afterwards, which puts tunnel mode back.

set -euo pipefail

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

# Everything lives in /opt/aiostreams: one folder for root and every user.
INSTALL_DIR="/opt/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"
STATE_DIR="$INSTALL_DIR/tunnel-state"
TOKEN_FILE="$STATE_DIR/token.env"
TUNNEL_COMPOSE="$STATE_DIR/docker-compose.yml"
SHARED_NET="aios_shared"
IMAGE="cloudflare/cloudflared:latest"
# cloudflared's own status page, on Docker's network only (the panel reads /ready)
METRICS_PORT=20241

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

tunnel_on() { [[ -s "$TOKEN_FILE" ]]; }

# ---- Caddy and the compose file ---------------------------------------------

BLOCK_START="# >>> Cloudflare Tunnel (setup-tunnel.sh adds and removes this block)"
BLOCK_END="# <<< Cloudflare Tunnel"

caddy_block() {
    cat << EOF
$BLOCK_START
{
	# Cloudflare holds the HTTPS certificates, so every site below is served as plain HTTP on port 80
	auto_https off
	https_port 80
	# The visitor's real address, from Cloudflare's header, trusted only from Docker's own networks
	servers {
		trusted_proxies static private_ranges
		client_ip_headers CF-Connecting-IP
	}
}
$BLOCK_END

EOF
}

# The Caddyfile with the block taken out, and one blank line after it gone too
caddy_without_block() {
    awk -v s="$BLOCK_START" -v e="$BLOCK_END" '
        $0 == s { skip = 1; next }
        skip && $0 == e { skip = 0; drop_blank = 1; next }
        skip { next }
        drop_blank && $0 == "" { drop_blank = 0; next }
        { drop_blank = 0; print }
    ' "$CADDYFILE"
}

# Caddy reads the Caddyfile through a single-file mount, so it's rewritten in
# place: replacing it would leave Caddy reading the old one until recreated.
# Prints "changed" when it did.
apply_caddy() {
    [[ -f "$CADDYFILE" ]] || return 0
    local now want
    now=$(cat "$CADDYFILE")
    want=$(caddy_without_block)
    if tunnel_on; then want="$(caddy_block)"$'\n\n'"$want"; fi
    if [[ "$now" != "$want" ]]; then
        printf '%s\n' "$want" > "$CADDYFILE"
        echo changed
    fi
}

# Takes ports 80 and 443 out of Caddy's service with the tunnel on, and puts
# them back with it off. Both of the main compose files (direct and VPN) list
# them the same way. Prints "changed" when it did.
apply_compose() {
    [[ -f "$COMPOSE_FILE" ]] || return 0
    local now want
    now=$(cat "$COMPOSE_FILE")
    if tunnel_on; then
        want=$(awk '
            $0 == "    ports:" { held = $0; n = 0; next }
            held != "" && n < 2 && ($0 == "      - \"80:80\"" || $0 == "      - \"443:443\"") { n++; if (n == 2) held = ""; next }
            held != "" { print held; held = "" }
            { print }
        ' "$COMPOSE_FILE")
    elif grep -qF '"443:443"' "$COMPOSE_FILE"; then
        return 0
    else
        # Back after "restart: unless-stopped" in Caddy's service
        want=$(awk '
            /^  [a-z]/ { in_caddy = ($0 == "  caddy:") }
            { print }
            in_caddy && !done && $0 == "    restart: unless-stopped" {
                print "    ports:"; print "      - \"80:80\""; print "      - \"443:443\""; done = 1
            }
        ' "$COMPOSE_FILE")
    fi
    if [[ "$now" != "$want" ]]; then
        printf '%s\n' "$want" > "$COMPOSE_FILE"
        echo changed
    fi
}

# Puts Caddy and the compose file in the right mode for the tunnel being on or
# off, and makes a running Caddy pick the change up. Safe to run any time.
do_apply() {
    local c p
    c=$(apply_caddy)
    p=$(apply_compose)
    [[ -n "$(docker ps -q --filter name='^caddy$' 2>/dev/null)" ]] || return 0
    if [[ -n "$p" ]]; then
        # Its ports changed: only recreating it does that (--no-deps leaves AIOStreams and the VPN alone)
        (cd "$INSTALL_DIR" && docker compose up -d --no-deps caddy >/dev/null 2>&1) \
            || warn "Couldn't recreate Caddy. Run: cd $INSTALL_DIR && sudo docker compose up -d caddy"
    elif [[ -n "$c" ]]; then
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || docker restart caddy >/dev/null
    fi
    return 0
}

# ---- cloudflared --------------------------------------------------------------

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || docker network create "$SHARED_NET" >/dev/null
}

write_tunnel_compose() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$TUNNEL_COMPOSE" << EOF
# Written by setup-tunnel.sh. The token is in token.env, readable by root only.
services:
  cloudflared:
    image: ${IMAGE}
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate --metrics 0.0.0.0:${METRICS_PORT} run
    env_file: token.env
    # Healthy while it has a connection to Cloudflare
    healthcheck:
      test: ["CMD", "cloudflared", "tunnel", "--metrics", "localhost:${METRICS_PORT}", "ready"]
      interval: 30s
      timeout: 5s
      start_period: 20s
      retries: 2
    networks:
      - ${SHARED_NET}
networks:
  ${SHARED_NET}:
    external: true
EOF
}

tunnel_compose() { (cd "$STATE_DIR" && docker compose -f "$TUNNEL_COMPOSE" "$@"); }

# cloudflared connects over QUIC (UDP) and asks for 7 MB socket buffers, more
# than Linux allows by default, which it logs as "failed to sufficiently
# increase receive buffer size" and runs a little slower. These limits are the
# whole server's, kept in a file of their own; never lowered if already higher.
# Prints "changed" when it raised them.
SYSCTL_FILE="/etc/sysctl.d/60-aiostreams-tunnel.conf"
BUFFER_BYTES=7500000

raise_buffers() {
    local key now changed=""
    for key in net.core.rmem_max net.core.wmem_max; do
        now=$(sysctl -n "$key" 2>/dev/null || echo 0)
        (( now < BUFFER_BYTES )) && changed=1
    done
    [[ -n "$changed" ]] || return 0
    printf '# Written by setup-tunnel.sh: room for cloudflared'"'"'s QUIC connection (removed with the tunnel)\nnet.core.rmem_max = %s\nnet.core.wmem_max = %s\n' \
        "$BUFFER_BYTES" "$BUFFER_BYTES" > "$SYSCTL_FILE"
    if sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        echo changed
    else
        warn "Couldn't raise the network buffer limits. The tunnel works anyway, a little slower."
    fi
}

# Taken out with the tunnel; the limits go back to the defaults at the next restart
drop_buffers() { rm -f "$SYSCTL_FILE"; }

# 0 connected, 1 not
connected() {
    docker exec cloudflared cloudflared tunnel --metrics "localhost:$METRICS_PORT" ready >/dev/null 2>&1
}

wait_connected() {
    local tries=15
    while (( tries-- > 0 )); do
        connected && return 0
        sleep 2
    done
    return 1
}

# A tunnel token is base64 of {"a":account,"t":tunnel ID,"s":secret}. Prints the tunnel's ID.
token_tunnel_id() {
    local json
    json=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
    grep -oP '"t"\s*:\s*"\K[0-9a-f-]{36}' <<< "$json"
}

# Asks for the token without showing it, checks it, saves it. Never printed or logged.
ask_token() {
    local t id
    echo ""
    echo "Paste the tunnel's token: in Cloudflare, Networking > Tunnels > your tunnel, the"
    echo "long text after --token in its Docker command (it starts with eyJ). It won't show."
    while true; do
        read -rsp "Tunnel token: " t; echo
        t=$(printf '%s' "$t" | tr -d '[:space:]')
        t=${t#--token}
        if id=$(token_tunnel_id "$t") && [[ -n "$id" ]]; then break; fi
        warn "That isn't a tunnel token. Copy only the part that starts with eyJ."
    done
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$t" > "$TOKEN_FILE" )
    echo "Saved, for tunnel $id."
}

# Every site Caddy serves: the first site of the Caddyfile and of each caddy.d file
hostnames() {
    local f
    for f in "$CADDYFILE" "$INSTALL_DIR"/caddy.d/*.caddy; do
        [[ -f "$f" ]] || continue
        grep -oP '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(?=\s*\{)' "$f" || true
    done | awk '!seen[$0]++'
}

print_routes() {
    local h
    echo "Each of these needs a route on the tunnel in Cloudflare:"
    echo "  Networking > Tunnels > your tunnel > Routes > Add route > Published application,"
    echo "  with Service URL http://caddy:80"
    echo ""
    while read -r h; do [[ -n "$h" ]] && echo "    $h"; done < <(hostnames)
    echo ""
    echo "Routes already there are fine. (Not the Routes page in the sidebar: that one is"
    echo "for private networks.)"
}

# ---- commands -----------------------------------------------------------------

do_on() {
    [[ -f "$COMPOSE_FILE" ]] || error "No AIOStreams install found at $INSTALL_DIR. Run setup-aiostreams.sh first."
    if tunnel_on; then
        echo "The tunnel is already on. Use 'token' to change its token."
    else
        info "Cloudflare Tunnel"
        echo "Visitors reach this server through Cloudflare, so it works behind any router"
        echo "with nothing forwarded. Cloudflare holds the HTTPS certificates."
        ask_token
    fi
    ensure_shared_network
    write_tunnel_compose
    local raised was_running=""
    raised=$(raise_buffers)
    [[ -n "$(docker ps -q --filter name='^cloudflared$' 2>/dev/null)" ]] && was_running=1
    info "Starting cloudflared"
    tunnel_compose pull -q 2>/dev/null || warn "Couldn't pull $IMAGE, using the copy already here."
    tunnel_compose up -d
    # A running one only takes the larger buffers when it reconnects
    if [[ -n "$raised" && -n "$was_running" ]]; then docker restart cloudflared >/dev/null 2>&1 || true; fi
    info "Switching Caddy to the tunnel"
    do_apply
    if wait_connected; then
        echo "Connected to Cloudflare."
    else
        warn "cloudflared hasn't connected yet. Usually the token: run 'token' to paste it again."
        warn "Its log: sudo docker logs cloudflared"
    fi
    echo ""
    print_routes
    echo "Also worth switching on, for each domain: SSL/TLS > Edge Certificates > Always Use HTTPS."
}

do_off() {
    tunnel_on || { echo "The tunnel is already off."; return 0; }
    if [[ "${1:-}" != "--yes" ]]; then
        echo "This stops the tunnel and makes this a normal server again: Caddy listens on"
        echo "ports 80 and 443 and gets its own certificates. Each site then needs an A record"
        echo "pointing at this server's public IP (and those ports forwarded, at home)."
        read -rp "Turn the tunnel off? [y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || { echo "Left on."; return 0; }
    fi
    [[ -f "$TUNNEL_COMPOSE" ]] && tunnel_compose down >/dev/null 2>&1 || true
    rm -f "$TOKEN_FILE"
    drop_buffers
    info "Switching Caddy back"
    do_apply
    echo "The tunnel is off. In Cloudflare, replace each site's Tunnel record with an A record"
    echo "to this server, and you can delete the tunnel itself."
}

do_check() {
    tunnel_on || return 2
    connected
}

status_line() {
    if ! tunnel_on; then
        echo "Cloudflare Tunnel: off"
        return 0
    fi
    local st
    st=$(docker inspect -f '{{.State.Status}}' cloudflared 2>/dev/null || echo "not created")
    if connected; then
        echo "Cloudflare Tunnel: on, connected"
    else
        echo -e "Cloudflare Tunnel: on, \033[1;33mnot connected\033[0m (cloudflared: $st; log: sudo docker logs cloudflared)"
    fi
}

do_status() {
    status_line
    tunnel_on || return 0
    echo ""
    print_routes
}

do_token() {
    tunnel_on || error "The tunnel is off. Turn it on instead."
    ask_token
    tunnel_compose up -d --force-recreate
    if wait_connected; then echo "Connected with the new token."; else warn "Not connected yet: sudo docker logs cloudflared"; fi
}

do_update() {
    tunnel_on || error "The tunnel is off."
    local before after
    before=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)
    tunnel_compose pull -q
    after=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)
    if [[ "$before" == "$after" ]]; then
        echo "cloudflared is already the newest."
        return 0
    fi
    # Visitors wait a few seconds while it reconnects
    tunnel_compose up -d
    docker image prune -f >/dev/null 2>&1 || true
    if wait_connected; then echo "Updated and connected."; else warn "Updated, not connected yet: sudo docker logs cloudflared"; fi
}

tunnel_menu() {
    while true; do
        echo ""
        status_line
        echo ""
        echo "  1) Status and routes"
        if tunnel_on; then
            echo "  2) Change the token"
            echo "  3) Turn the tunnel off"
        else
            echo "  2) Turn the tunnel on"
            echo "  3) (off already)"
        fi
        echo "  4) Update cloudflared"
        echo "  5) Exit"
        read -rp "Choose an option [1-5]: " c || return 0
        case "$c" in
            1) echo ""; do_status ;;
            2) if tunnel_on; then do_token; else do_on; fi ;;
            3) do_off ;;
            4) do_update || true ;;
            5) return 0 ;;
            *) echo "Choose 1 to 5." ;;
        esac
    done
}

case "${1:-}" in
    on) do_on ;;
    off) shift; do_off "${1:-}" ;;
    status) do_status ;;
    check) s=0; do_check || s=$?; exit "$s" ;;
    routes) print_routes ;;
    token) do_token ;;
    update) do_update ;;
    _apply) do_apply ;;
    "") tunnel_menu ;;
    *) error "Unknown command '$1'. Use: on, off, status, check, routes, token or update, or nothing for the menu." ;;
esac
exit 0
