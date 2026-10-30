#!/usr/bin/env bash

set -euo pipefail

# Resolved at the very top, before anything can cd elsewhere (same reason as
# the other setup-*.sh scripts).
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;31m!! %s !!\033[0m\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

[[ $EUID -eq 0 ]] || error "Run this as root: sudo bash setup-ui.sh"

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
ROOT_HOME="$(getent passwd root 2>/dev/null | cut -d: -f6)"
ROOT_HOME="${ROOT_HOME:-/root}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"
SHARED_NET="aios_shared"

# The panel's code lives in $INSTALL_DIR/control-panel (where it would land
# if it came from the GitHub repo) and is built straight from there. Its
# settings, login and logs live next to it in ui-state.
PANEL_DIR="$INSTALL_DIR/control-panel"
# Where Update downloads new versions from. AIOS_UI_BRANCH=dev tries the dev
# branch instead of main.
PANEL_BRANCH="${AIOS_UI_BRANCH:-main}"
PANEL_TARBALL="https://github.com/alpinezx/easy-aiostreams/archive/refs/heads/${PANEL_BRANCH}.tar.gz"
STATE_DIR="$INSTALL_DIR/ui-state"
UI_COMPOSE="$STATE_DIR/docker-compose.yml"
CONFIG_FILE="$STATE_DIR/config"
GATE_FILE="$STATE_DIR/gate-token"
AUTH_FILE="$STATE_DIR/auth.json"
CADDY_SNIPPET="$CADDY_DROPIN_DIR/60-ui.caddy"

CONTAINER_NAME="aios-ui"
IMAGE_NAME="aios-ui:local"
INTERNAL_PORT="8080"

require_cmd() { command -v "$1" >/dev/null 2>&1; }

valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

[[ -f "$COMPOSE_FILE" ]] || error "No AIOStreams install found at $INSTALL_DIR. Run setup-aiostreams.sh first."
if ! require_cmd docker || ! docker compose version >/dev/null 2>&1; then
    error "Docker with the compose plugin is required."
fi
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy || \
    error "The 'caddy' container isn't running. Start AIOStreams first (setup-aiostreams.sh, option 3)."

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || docker network create "$SHARED_NET" >/dev/null
}

# Runs from the panel's own folder, the only place it is built from.
require_panel_dir() {
    [[ "$SELF_DIR" -ef "$PANEL_DIR" ]] || \
        error "Run this from $PANEL_DIR (sudo bash $PANEL_DIR/setup-ui.sh). It's running from $SELF_DIR."
    [[ -f "$PANEL_DIR/app/main.py" && -f "$PANEL_DIR/Dockerfile" && -d "$PANEL_DIR/web" ]] || \
        error "$PANEL_DIR is missing some of the panel's files (app/, web/, Dockerfile). Download it again."
}

write_compose() {
    cat > "$UI_COMPOSE" << COMPOSE_EOF
name: aios-ui
services:
  aios-ui:
    build: ${PANEL_DIR}
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    # Root-equivalent on this server, on purpose: it has to run your setup-*.sh
    # scripts on the host itself (through nsenter into PID 1) and read Docker.
    # That is why it sits behind Caddy's secret-cookie gate AND its own login.
    # It publishes no ports. Only Caddy can reach it.
    privileged: true
    pid: host
    environment:
      - UI_INSTALL_DIR=${INSTALL_DIR}
      - UI_ROOT_HOME=${ROOT_HOME}
      - UI_STATE_DIR=/state
      - UI_UPDATE_BRANCH=${PANEL_BRANCH}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${INSTALL_DIR}:${INSTALL_DIR}:ro
      - ${STATE_DIR}:/state
    networks:
      - ${SHARED_NET}
networks:
  ${SHARED_NET}:
    external: true
COMPOSE_EOF
    chmod 600 "$UI_COMPOSE"
}

write_caddy_snippet() {
    local domain="$1" token="$2"
    mkdir -p "$CADDY_DROPIN_DIR"
    rm -f "${CADDY_SNIPPET}.rejected"
    # Visitors without the cookie get a plain 404, so the login page isn't
    # even discoverable. Opening /unlock/<token> once sets the cookie. It's
    # SameSite=Lax, so a link from another app (tapping a phone alert) still
    # gets in; Strict left those on "Not found". Every visit sets it again,
    # which also moves older Strict cookies over.
    cat > "$CADDY_SNIPPET" << CADDY_EOF
${domain} {
    @unlock path /unlock/${token}
    handle @unlock {
        header Set-Cookie "ui_gate=${token}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax"
        redir * / 302
    }

    @gated header Cookie *ui_gate=${token}*
    handle @gated {
        header Set-Cookie "ui_gate=${token}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax"
        reverse_proxy ${CONTAINER_NAME}:${INTERNAL_PORT}
    }

    handle {
        respond "Not found" 404
    }
}
CADDY_EOF
    chmod 600 "$CADDY_SNIPPET"
}

reload_caddy() {
    # A reload, not a restart: Caddy validates first and keeps serving the old
    # config if the new one is bad, so a mistake here can't take AIOStreams down.
    local out
    if out=$(docker exec -w /etc/caddy caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
        return 0
    fi
    warn "Caddy rejected the new config and is still running the old one (AIOStreams unaffected)."
    echo "$out" | tail -n 5
    if [[ -f "$CADDY_SNIPPET" ]]; then
        mv -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
        warn "Moved the UI's Caddy snippet to ${CADDY_SNIPPET}.rejected so it can't break the next Caddy restart."
    fi
    return 1
}

set_credentials() {
    local user pass pass2
    while true; do
        read -rp "Username for the control panel login: " user
        [[ -n "$user" ]] && break
        warn "Username can't be empty."
    done
    while true; do
        read -rsp "Password (at least 10 characters, input hidden): " pass; echo
        if [[ ${#pass} -lt 10 ]]; then warn "That's too short."; continue; fi
        read -rsp "Confirm password: " pass2; echo
        [[ "$pass" == "$pass2" ]] && break
        warn "Those didn't match, try again."
    done
    mkdir -p "$STATE_DIR"
    # Hashed by the app's own code, inside the built image. The password goes
    # in through the environment, never on a command line.
    UI_USER="$user" UI_PW="$pass" docker run --rm -e UI_USER -e UI_PW ${1:+-e UI_ROTATE_SESSIONS=1} \
        -v "$STATE_DIR:/state" "$IMAGE_NAME" python -m app.setup_auth \
        || error "Couldn't save the login."
    chmod 600 "$AUTH_FILE"
}

wait_until_up() {
    for _ in $(seq 1 30); do
        if docker exec "$CONTAINER_NAME" python -c \
            "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${INTERNAL_PORT}/login').status==200 else 1)" \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

print_unlock() {
    local domain token
    domain=$(grep -oP '^DOMAIN=\K.*' "$CONFIG_FILE")
    token=$(cat "$GATE_FILE")
    echo ""
    echo "Open this link ONCE in each browser you want to use (it sets a cookie, then"
    echo "redirects to the login page). Bookmark the plain address afterwards."
    echo ""
    echo -e "  \033[1;36mhttps://${domain}/unlock/${token}\033[0m"
    echo ""
    warn "Anyone with that link can reach the login page, so treat it like a password."
    warn "Option 5 in the menu makes a new one (and signs out every browser)."
}

do_install() {
    info "Easy AIOStreams Control Panel"
    echo "This adds one container and one Caddy site. Your AIOStreams config is not touched."
    read -rp "Domain/subdomain for the control panel (e.g. panel.example.com): " DOMAIN
    valid_domain "$DOMAIN" || error "That doesn't look like a valid domain."
    local main_domain
    main_domain=$(grep -oP 'BASE_URL=https?://\K[^\s"]+' "$COMPOSE_FILE" | head -n1 || true)
    [[ "$DOMAIN" != "$main_domain" ]] || error "That's your AIOStreams domain. The panel needs its own subdomain."

    local ip dns
    ip=$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    dns=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)
    if [[ -n "$ip" && "$dns" != "$ip" ]]; then
        alert "$DOMAIN resolves to '${dns:-nothing}', but this server is $ip."
        echo "HTTPS won't work until an A record points it here."
        read -rp "Continue anyway? (y/N): " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || exit 0
    fi

    ensure_shared_network
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    require_panel_dir
    printf 'DOMAIN=%s\n' "$DOMAIN" > "$CONFIG_FILE"
    write_compose

    info "Building the panel image (a minute or two the first time)"
    build_image || error "Build failed. Scroll up for the reason."

    info "Setting up your login"
    set_credentials

    info "Creating the secret unlock link"
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$GATE_FILE"; chmod 600 "$GATE_FILE"

    info "Starting"
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" up -d)
    wait_until_up || warn "The panel didn't answer within 30s. Check: docker logs $CONTAINER_NAME"

    write_caddy_snippet "$DOMAIN" "$(cat "$GATE_FILE")"
    reload_caddy || error "Caddy wouldn't take the new site. See the message above."

    info "Done"
    print_unlock
}

# True when this script is running inside the panel's own web terminal. Those
# processes live in the panel container, so stopping or rebuilding it from
# there would kill the very command doing it.
in_panel_terminal() {
    [[ "${AIOS_UI_TERMINAL:-}" == "1" ]] && return 0
    local id
    id=$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null) || return 1
    [[ -n "$id" ]] && grep -q "$id" /proc/self/cgroup 2>/dev/null
}

refuse_in_terminal() {
    if in_panel_terminal; then
        warn "You're inside the panel's own web terminal, so this would cut itself off halfway."
        warn "Run it from an SSH session instead (the Restart panel button covers a plain restart)."
        return 0
    fi
    return 1
}

terminal_state() {
    [[ -f "$STATE_DIR/terminal.json" ]] && echo on || echo off
}

# Makes (or replaces) the terminal key. Only a hash is stored; the key is shown once.
make_terminal_key() {
    local key
    key=$(docker run --rm -v "$STATE_DIR:/state" "$IMAGE_NAME" python -m app.setup_terminal on 2>/dev/null) \
        || { warn "The panel image doesn't have the terminal yet. Run option 4 (Update) first, then try again."; return 1; }
    echo ""
    echo "  Terminal key (shown once, store it in a password manager):"
    echo ""
    echo "      $key"
    echo ""
    echo "  Anyone with your login AND this key can get a root shell on the server."
    echo "  Your dashboard login and unlock link alone are not enough."
}

do_terminal() {
    echo ""
    echo "Web terminal is currently: $(terminal_state)"
    echo "  1) Turn on (makes a new key)"
    echo "  2) Make a new key (the old key stops working)"
    echo "  3) Turn off"
    echo "  4) Back"
    read -rp "Choose an option [1-4]: " T
    case "$T" in
        1|2) make_terminal_key ;;
        3) docker run --rm -v "$STATE_DIR:/state" "$IMAGE_NAME" python -m app.setup_terminal off \
               && echo "Terminal is off. The tab is gone and nothing can open a shell." ;;
        *) ;;
    esac
}

do_status() {
    echo ""
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        echo "Panel:   RUNNING"
    else
        echo "Panel:   STOPPED"
    fi
    echo "Address: https://$(grep -oP '^DOMAIN=\K.*' "$CONFIG_FILE")"
    echo "Terminal: $(terminal_state)"
    [[ -f "$CADDY_SNIPPET" ]] && echo "Caddy:   site is enabled" || echo "Caddy:   site is NOT enabled (snippet missing)"
}

do_start() {
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" up -d)
    [[ -f "$CADDY_SNIPPET" ]] || { write_caddy_snippet "$(grep -oP '^DOMAIN=\K.*' "$CONFIG_FILE")" "$(cat "$GATE_FILE")"; reload_caddy || true; }
    echo "Started."
}

do_stop() {
    refuse_in_terminal && return
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" stop)
    echo "Stopped. AIOStreams is not affected."
}

# Menu option 4. Downloads the newest control-panel folder from GitHub into
# $PANEL_DIR (unless told not to), then rebuilds. A download that fails or
# looks wrong changes nothing. "yes" skips the question: the panel's own
# Update button runs it that way, through systemd-run, so it isn't inside the
# panel container it replaces.
do_update() {
    refuse_in_terminal && return
    local C tmp
    if [[ "${1:-}" == yes ]]; then
        C=y
    else
        read -rp "Download the newest version from GitHub first? [Y/n] (n = just rebuild from the files already here): " C
    fi
    if [[ "$C" =~ ^[Nn] ]]; then
        do_rebuild
        return
    fi
    info "Downloading the newest control panel ($PANEL_BRANCH branch)"
    tmp=$(mktemp -d)
    if ! curl -fsSL "$PANEL_TARBALL" | tar xz -C "$tmp" --strip-components=1 "easy-aiostreams-${PANEL_BRANCH}/control-panel" \
        || [[ ! -f "$tmp/control-panel/app/main.py" || ! -f "$tmp/control-panel/setup-ui.sh" ]]; then
        rm -rf "$tmp"
        warn "Couldn't download it. Nothing was changed; the panel keeps running as it is."
        [[ "${1:-}" == yes ]] && return 1
        return 0
    fi
    # Swap the code in. Only code lives here: settings and login are in ui-state.
    rm -rf "${PANEL_DIR:?}/app" "${PANEL_DIR:?}/web" "${PANEL_DIR:?}/tests"
    cp -a "$tmp/control-panel/." "$PANEL_DIR/"
    chmod 700 "$PANEL_DIR/setup-ui.sh"
    rm -rf "$tmp"
    echo "Downloaded."
    # Rebuild with the new copy of this script, in case it changed too.
    exec bash "$PANEL_DIR/setup-ui.sh" rebuild
}

# A newer version of this script may write the Caddy site differently; bring
# it up to date (same domain and unlock link) and reload Caddy only if it changed.
refresh_caddy_snippet() {
    [[ -f "$CADDY_SNIPPET" && -f "$GATE_FILE" && -f "$CONFIG_FILE" ]] || return 0
    local before
    before=$(cat "$CADDY_SNIPPET")
    write_caddy_snippet "$(grep -oP '^DOMAIN=\K.*' "$CONFIG_FILE")" "$(cat "$GATE_FILE")"
    [[ "$(cat "$CADDY_SNIPPET")" == "$before" ]] && return 0
    if ! reload_caddy; then
        # Caddy kept the old site running; put its file back so a restart keeps it too
        printf '%s
' "$before" > "$CADDY_SNIPPET"
        rm -f "${CADDY_SNIPPET}.rejected"
    fi
    return 0
}

# Builds the panel's image with the newest python:3.13-slim, so the Debian and
# Python under it get their security fixes with every update. Without Docker Hub
# it builds on the base image already here rather than failing.
build_image() {
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" build --pull) && return 0
    warn "Couldn't fetch a newer base image, so building with the one already here."
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" build)
}

do_rebuild() {
    refuse_in_terminal && return
    info "Rebuilding from $PANEL_DIR"
    require_panel_dir
    write_compose
    build_image && (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" up -d --force-recreate)
    wait_until_up || warn "The panel didn't answer within 30s. Check: docker logs $CONTAINER_NAME"
    refresh_caddy_snippet
    echo "Rebuilt. Your login and unlock link are unchanged."
}

do_reset_password() {
    refuse_in_terminal && return
    set_credentials rotate
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" restart)
    echo "Password changed. Every browser has been signed out."
}

do_new_link() {
    local domain
    domain=$(grep -oP '^DOMAIN=\K.*' "$CONFIG_FILE")
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$GATE_FILE"; chmod 600 "$GATE_FILE"
    write_caddy_snippet "$domain" "$(cat "$GATE_FILE")"
    reload_caddy || return 0
    print_unlock
    echo "The old link and every browser's cookie stopped working."
}

do_uninstall() {
    refuse_in_terminal && return
    read -rp "Remove the control panel? Your AIOStreams stack isn't touched. [y/N]: " C
    [[ "$C" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }
    (cd "$STATE_DIR" && docker compose -f "$UI_COMPOSE" down) || true
    rm -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
    reload_caddy || true
    docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true
    rm -rf "${STATE_DIR:?}"
    echo "Removed the panel, its settings and its login."
    read -rp "Also delete the panel's own files in $PANEL_DIR? Say n to reinstall from them. [y/N]: " C
    if [[ "$C" =~ ^[Yy]$ ]]; then
        cd / && rm -rf "${PANEL_DIR:?}"
        echo "Deleted $PANEL_DIR. Nothing of the panel is left."
    else
        echo "Kept $PANEL_DIR. Install again with: sudo bash $PANEL_DIR/setup-ui.sh"
    fi
    echo "You can delete the DNS record for the panel's subdomain too, unless you reinstall."
    exit 0
}

if [[ "${1:-}" == "rebuild" && -f "$CONFIG_FILE" ]]; then
    do_rebuild
    exit 0
fi
if [[ "${1:-}" == "update-unattended" && -f "$CONFIG_FILE" ]]; then
    do_update yes
    exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    do_install
    exit 0
fi

while true; do
    echo ""
    echo "=== Easy AIOStreams Control Panel ==="
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Update"
    echo "5) Make a new unlock link"
    echo "6) Change username/password"
    echo "7) Show the unlock link"
    echo "8) Web terminal ($(terminal_state)): turn on/off, new key"
    echo "9) Uninstall"
    echo "10) Exit"
    read -rp "Choose an option [1-10]: " CHOICE
    case "$CHOICE" in
        1) do_status ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_update ;;
        5) do_new_link ;;
        6) do_reset_password ;;
        7) print_unlock ;;
        8) do_terminal ;;
        9) do_uninstall ;;
        10) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
