#!/usr/bin/env bash

set -euo pipefail

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;33m!! %s !!\033[0m\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

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
CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"
SHARED_NET="aios_shared"

STATE_DIR="$INSTALL_DIR/aiomanager-state"
CONFIG_FILE="$STATE_DIR/config"
AIOMAN_COMPOSE="$STATE_DIR/docker-compose.yml"
AIOMAN_ENV_FILE="$STATE_DIR/aiomanager.env"
# Its SQLite database (aio.db, with -wal and -shm beside it) and
# server_secret.key, which decrypts the Stremio logins stored in it. The
# part worth backing up. The key is never printed, logged or shown.
DATA_DIR="$STATE_DIR/data"
# Written by Stop, cleared by Start, so a stopped add-on is known to be
# deliberate.
STOPPED_MARKER="$STATE_DIR/stopped-on-purpose"
CADDY_SNIPPET="$CADDY_DROPIN_DIR/56-aiomanager.caddy"

CONTAINER_NAME="aiomanager"
INTERNAL_PORT="1610"
IMAGE_REPO="ghcr.io/sonicx161/aiomanager"
RELEASES_API="https://api.github.com/repos/sonicx161/aiomanager/releases/latest"
# The image has no shell or wget, only Node.
NODE="/nodejs/bin/node"
# How long sign-ups stay open when reopened, before closing by themselves.
SIGNUPS_MINUTES_DEFAULT=30
SIGNUPS_CLOSE_UNIT="aiomanager-signups-close"
SCRIPT_PATH="$INSTALL_DIR/setup-aiomanager.sh"

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || \
        docker network create "$SHARED_NET" >/dev/null
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    SIGNUPS="closed"; SIGNUPS_UNTIL=""
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# write_config <domain> <version> <signups: open|closed> [<until, epoch>].
# Single-quoted so 'source' reads the values as plain text. The validators
# below make sure no single quotes or spaces get this far.
write_config() {
    (
        umask 077
        printf "DOMAIN='%s'\nAIOMAN_VERSION='%s'\nSIGNUPS='%s'\nSIGNUPS_UNTIL='%s'\n" \
            "$1" "$2" "$3" "${4:-}" > "$CONFIG_FILE"
    )
    chmod 600 "$CONFIG_FILE"
}

# Settings go in their own env file, read literally by Compose.
write_env_file() {
    local closed=true
    [[ "$SIGNUPS" == open ]] && closed=false
    (
        umask 077
        {
            printf "PORT='%s'\n" "$INTERNAL_PORT"
            printf "NODE_ENV='production'\n"
            printf "DATA_DIR='/app/data'\n"
            printf "LOG_LEVEL='info'\n"
            # Caddy replaces any X-Forwarded-For a visitor sends, so the
            # address it passes on is the real one. Without this every
            # visitor shares one rate limit.
            printf "TRUST_PROXY='true'\n"
            # shellcheck disable=SC2153  # DOMAIN comes from load_config
            printf "CORS_ORIGINS='https://%s'\n" "$DOMAIN"
            # Logins already made keep working; new ones are refused.
            printf "REGISTRATIONS_CLOSED='%s'\n" "$closed"
        } > "$AIOMAN_ENV_FILE"
    )
    chmod 600 "$AIOMAN_ENV_FILE"
}

# AIOManager joins aios_shared so Caddy can reach it, with no ports of its
# own. Its data is a folder inside $INSTALL_DIR, so backups carry it.
write_compose() {
    write_env_file
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    cat > "$AIOMAN_COMPOSE" << EOF
name: aiomanager
services:
  aiomanager:
    image: ${IMAGE_REPO}:${AIOMAN_VERSION}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    init: true
    env_file:
      - ${AIOMAN_ENV_FILE}
    volumes:
      - ${DATA_DIR}:/app/data
    healthcheck:
      test: ["CMD", "${NODE}", "server/healthcheck.js"]
      # Short, so a check missed while a backup has it paused clears soon.
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
      start_interval: 2s
    networks:
      - ${SHARED_NET}

networks:
  ${SHARED_NET}:
    external: true
EOF
    chmod 600 "$AIOMAN_COMPOSE"
}

write_caddy_snippet() {
    rm -f "${CADDY_SNIPPET}.rejected"
    cat > "$CADDY_SNIPPET" << EOF
${DOMAIN} {
    reverse_proxy ${CONTAINER_NAME}:${INTERNAL_PORT}
}
EOF
}

# A reload, not a restart: Caddy checks the new config first and, if it's
# bad, keeps serving the old one, so the main site never goes down with it.
reload_caddy() {
    if ! container_running caddy; then
        warn "Caddy isn't running, so the subdomain won't be live until it is. Start AIOStreams first (setup-aiostreams.sh)."
        return 0
    fi
    local out
    if out=$(docker exec -w /etc/caddy caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
        return 0
    fi
    warn "Caddy rejected the new config and is still running the old one (main site unaffected)."
    echo "$out" | tail -n 5
    if [[ -f "$CADDY_SNIPPET" ]]; then
        # Out of the *.caddy glob, so the next Caddy restart or reboot
        # doesn't trip over it and take the main site down.
        mv -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
        warn "Moved AIOManager's Caddy site aside to ${CADDY_SNIPPET}.rejected. Run Reconfigure (option 4) to fix the subdomain."
    fi
}

compose() {
    (cd "$STATE_DIR" && docker compose -f "$AIOMAN_COMPOSE" "$@")
}

# The newest release's version, without the leading v (e.g. 2.0.0). Build
# releases (1.8.5+build.2) are left out: their images have no plain tag.
latest_version() {
    curl -fsSL --max-time 10 "$RELEASES_API" 2>/dev/null \
        | grep -oP '"tag_name":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+(?=")' | head -n1 || true
}

# Prints one field of /api/health or /api/config, asked from inside the
# container (it has Node but no wget). Empty when it doesn't answer.
api_field() {
    local path="$1" field="$2"
    docker exec "$CONTAINER_NAME" "$NODE" -e "
fetch('http://localhost:${INTERNAL_PORT}${path}', { signal: AbortSignal.timeout(5000) })
  .then(r => r.json()).then(j => { const v = j['${field}']; if (v !== undefined) console.log(String(v)) })
  .catch(() => {})" 2>/dev/null || true
}

running_version() {
    api_field /api/health version
}

# How many logins (UUID and password) the database holds. Rows without a
# password are AIOManager's own bookkeeping. Read-only; empty if it can't
# be read.
login_count() {
    docker exec -w /app/server "$CONTAINER_NAME" "$NODE" -e "
const D = require('better-sqlite3');
const db = new D('/app/data/aio.db', { readonly: true, fileMustExist: true });
console.log(db.prepare(\"SELECT COUNT(*) AS n FROM kv_store WHERE password IS NOT NULL AND password <> ''\").get().n);
db.close()" 2>/dev/null || true
}

# Waits for the health check in its compose file.
wait_healthy() {
    local state
    for _ in $(seq 1 45); do
        state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
        case "$state" in
            healthy) return 0 ;;
            unhealthy|missing) return 1 ;;
        esac
        sleep 2
    done
    return 1
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

valid_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Every site this server's Caddy already serves (main domain, panel,
# other add-ons). Reusing one would make Caddy reject the whole config.
other_domains() {
    local f
    for f in "$INSTALL_DIR/Caddyfile" "$CADDY_DROPIN_DIR"/*.caddy; do
        [[ -f "$f" && "$f" != "$CADDY_SNIPPET" ]] || continue
        grep -hoP '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(?=\s*\{)' "$f" 2>/dev/null || true
    done
}

# Checks the subdomain points at this server, like the other add-ons do.
# Returns 0 to go ahead, 1 to ask for another one. Never blocks: no
# keyboard, or no way to learn this server's IP, means go ahead.
check_subdomain_dns() {
    local domain="$1" ip="" dns svc choice
    for svc in https://ifconfig.me https://icanhazip.com https://ipinfo.io/ip; do
        ip=$(curl -fs4 --max-time 4 "$svc" 2>/dev/null | tr -d ' \n') && [[ -n "$ip" ]] && break
    done
    [[ -n "$ip" ]] || return 0
    while true; do
        dns=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1; exit }' || true)
        if [[ "$dns" == "$ip" ]]; then
            echo "$domain -> $ip, matches this server."
            return 0
        fi
        warn "$domain resolves to ${dns:-nothing}, but this server is $ip."
        warn "HTTPS won't work for it until its A record points here."
        [[ -t 0 ]] || return 0
        echo "  1) Re-check (after fixing the A record)"
        echo "  2) Enter a different subdomain"
        echo "  3) Use it anyway (the certificate follows once DNS points here)"
        read -rp "Choice [1-3]: " choice || return 0
        case "$choice" in
            1) continue ;;
            2) return 1 ;;
            3) return 0 ;;
            *) warn "Not a valid choice." ;;
        esac
    done
}

# ---- Sign-ups -----------------------------------------------------------
# Open only while someone makes a login: the first one at setup, more
# later from Sign-ups (option 10) or the control panel. Each opening closes
# by itself after a while, through a systemd timer that survives a reboot.

SIGNUPS_UNIT_DIR="/etc/systemd/system"

cancel_signups_timer() {
    systemctl disable --now "${SIGNUPS_CLOSE_UNIT}.timer" >/dev/null 2>&1 || true
    if [[ -f "$SIGNUPS_UNIT_DIR/${SIGNUPS_CLOSE_UNIT}.timer" || -f "$SIGNUPS_UNIT_DIR/${SIGNUPS_CLOSE_UNIT}.service" ]]; then
        rm -f "$SIGNUPS_UNIT_DIR/${SIGNUPS_CLOSE_UNIT}.timer" "$SIGNUPS_UNIT_DIR/${SIGNUPS_CLOSE_UNIT}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    systemctl reset-failed "${SIGNUPS_CLOSE_UNIT}.service" "${SIGNUPS_CLOSE_UNIT}.timer" >/dev/null 2>&1 || true
}

# A timer for the closing time itself, kept on disk so a reboot doesn't lose
# it: Persistent=true runs it soon after the server is back if the time
# passed while it was off. Closing removes it again.
schedule_signups_close() {
    local until="$1"
    [[ -f "$SCRIPT_PATH" ]] && command -v systemctl >/dev/null 2>&1 || return 1
    cat > "$SIGNUPS_UNIT_DIR/${SIGNUPS_CLOSE_UNIT}.service" << EOF
[Unit]
Description=Close AIOManager's sign-ups (opened for a while by setup-aiomanager.sh)

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_PATH} signups close
EOF
    cat > "$SIGNUPS_UNIT_DIR/${SIGNUPS_CLOSE_UNIT}.timer" << EOF
[Unit]
Description=Close AIOManager's sign-ups at the time they were opened until

[Timer]
OnCalendar=$(date -u -d "@$until" '+%Y-%m-%d %H:%M:%S') UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 && systemctl enable --now "${SIGNUPS_CLOSE_UNIT}.timer" >/dev/null 2>&1
}

# Puts the sign-ups setting into the running container. Changing its env
# file makes Compose recreate it, about 5 seconds.
apply_signups() {
    write_env_file
    if container_running "$CONTAINER_NAME"; then
        compose up -d --quiet-pull aiomanager >/dev/null 2>&1 || compose up -d aiomanager
        wait_healthy || warn "AIOManager didn't report healthy in time. Check its logs (option 9)."
    fi
}

# signups_open <minutes>
signups_open() {
    local minutes="$1" until
    until=$(( $(date +%s) + minutes * 60 ))
    write_config "$DOMAIN" "$AIOMAN_VERSION" open "$until"
    load_config
    apply_signups
    cancel_signups_timer
    if schedule_signups_close "$until"; then
        echo "Sign-ups are open until $(date -d "@$until" '+%H:%M') (server time), then close by themselves."
    else
        warn "Sign-ups are open, but couldn't set them to close by themselves. Close them with option 10 when you're done."
    fi
}

signups_close() {
    cancel_signups_timer
    write_config "$DOMAIN" "$AIOMAN_VERSION" closed ""
    load_config
    apply_signups
    echo "Sign-ups are closed. Existing logins keep working."
}

# One line on whether sign-ups are open, for status and the menu.
signups_line() {
    if [[ "$SIGNUPS" != open ]]; then
        echo "closed"
    elif [[ -n "$SIGNUPS_UNTIL" ]] && (( SIGNUPS_UNTIL > $(date +%s) )); then
        echo "OPEN until $(date -d "@$SIGNUPS_UNTIL" '+%H:%M') (server time)"
    else
        echo "OPEN (meant to have closed by now: close them with option 10)"
    fi
}

# A safety net for a reopening whose timer went missing (deleted by hand, or
# systemd off): it closes the next time AIOManager is started.
close_overdue_signups() {
    if [[ "$SIGNUPS" == open && -n "$SIGNUPS_UNTIL" ]] && (( SIGNUPS_UNTIL <= $(date +%s) )); then
        write_config "$DOMAIN" "$AIOMAN_VERSION" closed ""
        load_config
        echo "Sign-ups were left open past their time, so they're closed now."
    fi
}

do_signups() {
    load_config || error "Not set up yet. Run option 2 (Start) first."
    echo ""
    echo "Sign-ups: $(signups_line)"
    local n
    container_running "$CONTAINER_NAME" && n=$(login_count) && [[ -n "$n" ]] && echo "Logins:   $n"
    echo ""
    echo "  1) Open for ${SIGNUPS_MINUTES_DEFAULT} minutes (to make another login)"
    echo "  2) Close now"
    echo "  3) Back"
    local choice
    read -rp "Select an option [1-3]: " choice
    case "$choice" in
        1) signups_open "$SIGNUPS_MINUTES_DEFAULT" ;;
        2) signups_close ;;
        *) return 0 ;;
    esac
}

# The first login, at setup: sign-ups open, wait while it's made, close.
first_login() {
    signups_open 60
    echo ""
    echo -e "Open \033[1;36mhttps://${DOMAIN}\033[0m and create your login. Then copy your UUID"
    echo "from Settings, General, Sync Identity, and save it with your password"
    echo "somewhere safe. There's no password reset."
    echo ""
    if [[ ! -t 0 ]]; then
        echo "Sign-ups close by themselves in an hour, or with option 10."
        return 0
    fi
    local answer n
    while true; do
        read -rp "Press Enter once you're signed in, to close sign-ups (or type 'later' to leave them open for now): " answer || return 0
        [[ "$answer" == later ]] && { echo "Left open. They close by themselves in an hour, or with option 10."; return 0; }
        n=$(login_count)
        if [[ "$n" == 0 ]]; then
            warn "No login has been made yet. Finish creating it first, or type 'later'."
            continue
        fi
        signups_close
        return 0
    done
}

print_details() {
    load_config || { echo "Not set up yet."; return 0; }
    echo ""
    echo -e "  Address:   \033[1;36mhttps://${DOMAIN}\033[0m"
    echo "  Sign-ups:  $(signups_line)"
    echo ""
    echo "Sign in with the UUID and password you made there. To make another login"
    echo "(for a family member, say), open sign-ups with option 10 first."
}

do_configure() {
    local from_start="${1:-false}"

    [[ -f "$COMPOSE_FILE" ]] || \
        error "Couldn't find $COMPOSE_FILE. Run setup-aiostreams.sh first, this bolts on to that install."

    # Made before the first question, so a cancelled setup leaves an empty
    # folder, which counts as not set up.
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    mkdir -p "$CADDY_DROPIN_DIR"
    ensure_shared_network

    local old_domain="" old_version="" old_signups="" old_until=""
    if load_config; then
        old_domain="$DOMAIN"; old_version="${AIOMAN_VERSION:-}"; old_signups="$SIGNUPS"; old_until="$SIGNUPS_UNTIL"
    fi

    info "Subdomain for AIOManager"
    echo "Needs its OWN subdomain, different from your main AIOStreams domain,"
    echo "with an A record already pointed at this server's IP."
    echo "e.g. manager.yourdomain.com"
    local domain taken clash
    while true; do
        if [[ -n "$old_domain" ]]; then
            read -rp "Subdomain [Enter to keep $old_domain]: " domain
            domain="${domain:-$old_domain}"
        else
            read -rp "Subdomain: " domain
        fi
        domain=$(echo "$domain" | xargs)
        if ! valid_domain "$domain"; then
            warn "That doesn't look like a domain. Letters, numbers, dots and hyphens only (e.g. manager.example.com)."
            continue
        fi
        clash=false
        while IFS= read -r taken; do
            [[ -n "$taken" && "${domain,,}" == "${taken,,}" ]] && clash=true
        done < <(other_domains)
        if $clash; then
            warn "$domain is already used on this server (main site, control panel or another add-on). AIOManager needs its own."
            continue
        fi
        check_subdomain_dns "$domain" || continue
        break
    done

    local version="$old_version"
    if [[ -z "$version" ]]; then
        info "Looking up AIOManager's newest release"
        version=$(latest_version)
        valid_version "$version" || error "Couldn't look up the newest release on GitHub. Check this server can reach api.github.com, then try again."
        echo "Version $version."
    fi

    # Closed until Start opens them for the first login.
    write_config "$domain" "$version" "${old_signups:-closed}" "$old_until"
    load_config
    write_compose
    write_caddy_snippet

    if container_running "$CONTAINER_NAME"; then
        info "Applying the new settings"
        compose up -d --force-recreate aiomanager
        reload_caddy
        wait_healthy || warn "AIOManager didn't report healthy in time. Check its logs (option 9)."
        print_details
    elif [[ "$from_start" != "true" ]]; then
        echo ""
        echo "Saved. Run option 2 (Start) next to bring it up with these settings."
    fi
}

do_start() {
    local quiet="${1:-false}" first=false
    if ! load_config; then
        do_configure "true"
        first=true
    fi
    load_config
    close_overdue_signups
    # A restore or the panel's Start: sign-ups open in a backup would have
    # no timer here to close them, so they start closed.
    if [[ "$quiet" == "true" && "$SIGNUPS" == open ]]; then
        cancel_signups_timer
        write_config "$DOMAIN" "$AIOMAN_VERSION" closed ""
        load_config
        echo "Sign-ups were open, so they're closed now. Option 10 opens them again."
    fi
    mkdir -p "$CADDY_DROPIN_DIR"
    ensure_shared_network
    write_compose
    write_caddy_snippet
    info "Starting AIOManager ${AIOMAN_VERSION}"
    # Quiet: a missing image (after an uninstall, or on a new server) would
    # otherwise print a line per layer, filling a restore's output.
    compose up -d --quiet-pull
    rm -f "$STOPPED_MARKER"
    reload_caddy
    echo "Waiting for it to report healthy (up to 90 seconds)..."
    if wait_healthy; then
        echo "AIOManager is running. The HTTPS certificate for a new subdomain can take a minute."
    else
        warn "AIOManager didn't report healthy in time. Check its logs (option 9)."
    fi
    if $first; then
        first_login
    elif [[ "$quiet" == "true" ]]; then
        echo "Run 'sudo bash setup-aiomanager.sh' and choose option 6 for its address."
    else
        print_details
    fi
}

do_stop() {
    [[ -f "$AIOMAN_COMPOSE" ]] || error "Not set up yet."
    compose down
    touch "$STOPPED_MARKER"
    echo "Stopped. Settings, logins and data are kept. Start picks up where it left off."
}

do_status() {
    echo ""
    if load_config; then
        echo "Address:     https://${DOMAIN}"
        echo "Version:     ${AIOMAN_VERSION} (installed)"
        echo "Sign-ups:    $(signups_line)"
    else
        echo "Not set up yet."
        return 0
    fi
    if container_running "$CONTAINER_NAME"; then
        local health running n
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
        echo "AIOManager:  RUNNING${health:+ ($health)}"
        running=$(running_version)
        # Build releases report themselves as "1.8.5 (Build 2)"; only the version counts here
        [[ -n "$running" && "${running%% (*}" != "$AIOMAN_VERSION" ]] && echo "             reports version $running"
        n=$(login_count)
        [[ -n "$n" ]] && echo "Logins:      $n"
        echo ""
        docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}}, CPU {{.CPUPerc}}' "$CONTAINER_NAME" 2>/dev/null || true
    elif [[ -f "$STOPPED_MARKER" ]]; then
        echo "AIOManager:  STOPPED (on purpose)"
    else
        echo "AIOManager:  STOPPED"
    fi
    local latest
    latest=$(latest_version)
    if valid_version "$latest" && [[ "$latest" != "$AIOMAN_VERSION" ]]; then
        echo ""
        echo "Newest release: $latest (Update is option 7)"
    fi
}

do_test() {
    container_running "$CONTAINER_NAME" || error "Not running. Start it first (option 2)."
    load_config

    info "1/3: Checking AIOManager answers inside its container"
    if [[ "$(api_field /api/health status)" == ok ]]; then
        echo "  OK, it's up and its database is healthy."
    else
        warn "  No healthy answer. Check its logs (option 9)."
        return 0
    fi

    info "2/3: Checking https://${DOMAIN}, the way your browser reaches it"
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}/api/health" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        echo "  OK (HTTP 200). DNS, HTTPS and Caddy are all working."
    elif [[ "$status" == "000" ]]; then
        warn "  Couldn't reach https://${DOMAIN} at all (DNS, certificate or network)."
        warn "  Check its A record, and 'docker compose logs caddy' in $INSTALL_DIR."
    else
        warn "  Got HTTP ${status}, expected 200. Check 'docker compose logs caddy' in $INSTALL_DIR."
    fi

    info "3/3: Checking sign-ups are as set"
    local closed
    closed=$(api_field /api/config registrationsClosed)
    if [[ -z "$closed" ]]; then
        warn "  Couldn't ask it (its /api/config didn't answer)."
    elif [[ "$closed" == true && "$SIGNUPS" != open ]]; then
        echo "  OK, closed. Nobody else can make a login."
    elif [[ "$closed" == false && "$SIGNUPS" == open ]]; then
        echo "  Open, as set: $(signups_line)."
    else
        alert "Sign-ups don't match this script's setting"
        warn "  Start AIOManager again (option 2) to put them right."
    fi
}

# Runs AIOManager on the version in its config and waits for it to be
# healthy.
run_version() {
    load_config
    write_compose
    compose up -d --quiet-pull aiomanager
    rm -f "$STOPPED_MARKER"
    echo "Waiting for it to report healthy (up to 90 seconds)..."
    wait_healthy
}

# apply_update <version> <backup: yes|no>. Asks nothing, so the menu and
# the update-aiomanager command share it. Returns 1 when nothing changed
# or the update failed (and the previous version was put back).
apply_update() {
    local target="$1" backup="$2" previous="$AIOMAN_VERSION"
    if [[ "$target" == "$previous" ]] && container_running "$CONTAINER_NAME"; then
        echo "Already on ${target}. Nothing to do."
        return 0
    fi
    # Download first: a version that doesn't exist changes nothing.
    info "Downloading AIOManager ${target}"
    docker pull -q "${IMAGE_REPO}:${target}" >/dev/null || {
        warn "Couldn't download ${IMAGE_REPO}:${target}. Check the version exists. Nothing was changed."
        return 1
    }
    if [[ "$backup" == yes ]]; then
        local backup_script="$INSTALL_DIR/setup-backup.sh"
        [[ -f "$backup_script" ]] || { warn "setup-backup.sh isn't in $INSTALL_DIR, so no backup was made and nothing was changed."; return 1; }
        info "Backing up first"
        bash "$backup_script" backup < /dev/null || { warn "The backup didn't finish, so nothing else was changed."; return 1; }
    fi
    # An older version may not read a database a newer one has changed.
    if [[ "$(printf '%s\n%s\n' "$target" "$previous" | sort -V | head -n1)" == "$target" ]]; then
        warn "Going back from ${previous} to ${target}. If ${previous} changed its database, ${target} may not start;"
        warn "the backup made before updating to ${previous} is then the way back."
    fi
    info "Switching AIOManager from ${previous} to ${target}"
    write_config "$DOMAIN" "$target" "$SIGNUPS" "$SIGNUPS_UNTIL"
    if run_version; then
        echo "AIOManager is on ${target} and healthy."
        # The old version's image is no longer needed
        docker image rm "${IMAGE_REPO}:${previous}" >/dev/null 2>&1 || true
        return 0
    fi
    warn "AIOManager ${target} didn't report healthy in time. Putting ${previous} back."
    docker logs --tail 15 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /' || true
    write_config "$DOMAIN" "$previous" "$SIGNUPS" "$SIGNUPS_UNTIL"
    if run_version; then
        warn "Back on ${previous}, healthy. Nothing else changed."
    else
        warn "${previous} didn't come back healthy either. Check its logs (option 9), or restore the backup made before this update."
    fi
    docker image rm "${IMAGE_REPO}:${target}" >/dev/null 2>&1 || true
    return 1
}

# Menu option 7: the same as update-aiomanager, with questions.
do_update() {
    load_config || error "Not set up yet. Run option 2 (Start) first."
    local latest choice backup
    latest=$(latest_version)
    echo ""
    echo "Installed: ${AIOMAN_VERSION}"
    if valid_version "$latest"; then
        echo "Newest:    ${latest}"
    else
        warn "Couldn't look up the newest release on GitHub."
    fi
    echo "Releases: https://github.com/sonicx161/aiomanager/releases"
    while true; do
        if valid_version "$latest"; then
            read -rp "Version to install [Enter for ${latest}, or e.g. 1.8.5, or q to cancel]: " choice
            choice="${choice:-$latest}"
        else
            read -rp "Version to install (e.g. 2.0.0, or q to cancel): " choice
        fi
        choice="${choice#v}"
        [[ "$choice" == "q" ]] && { echo "Cancelled."; return 0; }
        valid_version "$choice" && break
        warn "Type a version like 2.0.0."
    done
    if [[ "$choice" == "$AIOMAN_VERSION" ]] && container_running "$CONTAINER_NAME"; then
        echo "Already on ${choice}. Nothing to do."
        return 0
    fi
    echo "  1) Back up first, then update"
    echo "  2) Update without backing up"
    echo "  3) Cancel"
    read -rp "Select an option [1-3]: " backup
    case "$backup" in
        1) backup=yes ;;
        2) backup=no ;;
        *) echo "Cancelled."; return 0 ;;
    esac
    apply_update "$choice" "$backup" || true
}

do_logs() {
    [[ -f "$AIOMAN_COMPOSE" ]] || error "Not set up yet."
    docker logs --tail 60 "$CONTAINER_NAME" 2>&1 || warn "No logs: the container doesn't exist (not started?)."
}

# The uninstall itself, asking nothing: the menu's Uninstall and the
# "uninstall" command (the control panel's) share it. $1 = yes also removes
# the image.
remove_aiomanager() {
    local images="${1:-no}" version=""
    load_config && version="${AIOMAN_VERSION:-}"
    cancel_signups_timer
    [[ -f "$AIOMAN_COMPOSE" ]] && { compose down 2>/dev/null || true; }
    # In case the compose file was already gone
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
    reload_caddy
    rm -rf "$STATE_DIR"
    if [[ "$images" == yes ]]; then
        [[ -n "$version" ]] && docker image rm "${IMAGE_REPO}:${version}" >/dev/null 2>&1 || true
        echo "Image removed (unless still in use elsewhere)."
    fi
    echo "Done. Running this script again starts fresh from first-time setup."
}

do_uninstall() {
    warn "This removes AIOManager: its container, its Caddy site, and its saved settings,"
    warn "including every login and everything synced to it. Take a backup first if you might want them back."
    local confirm images=no
    read -rp "Type 'uninstall' to continue: " confirm
    [[ "$confirm" == "uninstall" ]] || { echo "Cancelled."; return 0; }
    read -rp "Also remove the downloaded AIOManager image? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy] ]] && images=yes
    remove_aiomanager "$images"
}

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash setup-aiomanager.sh"
command -v docker >/dev/null || error "Docker not found. Run this on the same server as setup-aiostreams.sh."

# Question-free commands, for restores and the control panel. The menu's
# numbers below must never change once released, since older panels may
# type them.
case "${1:-}" in
    start-aiomanager)
        [[ -f "$CONFIG_FILE" ]] || error "AIOManager isn't set up, nothing to start."
        do_start "true" < /dev/null
        exit 0 ;;
    stop-aiomanager)
        [[ -f "$CONFIG_FILE" ]] || error "AIOManager isn't set up, nothing to stop."
        do_stop
        exit 0 ;;
    status)
        do_status
        exit 0 ;;
    # signups open [minutes] | close | status: the control panel's switch,
    # and the timer that closes them again.
    signups)
        load_config || error "AIOManager isn't set up."
        case "${2:-status}" in
            open)
                s_min="${3:-$SIGNUPS_MINUTES_DEFAULT}"
                { [[ "$s_min" =~ ^[0-9]+$ ]] && (( s_min >= 1 && s_min <= 1440 )); } || error "Minutes must be a number from 1 to 1440."
                signups_open "$s_min" < /dev/null ;;
            close) signups_close < /dev/null ;;
            status) echo "Sign-ups: $(signups_line)" ;;
            *) error "Use: signups open [minutes] | close | status" ;;
        esac
        exit 0 ;;
    # uninstall [remove-image]: the control panel's Uninstall, which asked first
    uninstall)
        [[ -f "$CONFIG_FILE" ]] || error "AIOManager isn't set up, nothing to uninstall."
        [[ -z "${2:-}" || "${2:-}" == remove-image ]] || error "Unknown option '$2'. Use: uninstall [remove-image]"
        remove_aiomanager "$( [[ "${2:-}" == remove-image ]] && echo yes || echo no)" < /dev/null
        exit 0 ;;
    # update-aiomanager [--backup] [--version X.Y.Z]: the newest release
    # unless a version is given (an older one goes back to it).
    update-aiomanager)
        load_config || error "AIOManager isn't set up, nothing to update."
        shift
        u_backup=no u_version=""
        while (( $# )); do
            case "$1" in
                --backup) u_backup=yes ;;
                --version) shift; u_version="${1:-}"; u_version="${u_version#v}"
                    valid_version "$u_version" || error "--version needs a version like 2.0.0." ;;
                *) error "Unknown option '$1'. Use: update-aiomanager [--backup] [--version X.Y.Z]" ;;
            esac
            shift
        done
        if [[ -z "$u_version" ]]; then
            u_version=$(latest_version)
            valid_version "$u_version" || error "Couldn't look up the newest release on GitHub. Nothing was changed."
        fi
        if apply_update "$u_version" "$u_backup" < /dev/null; then exit 0; else exit 1; fi ;;
    "") ;;
    *) error "Unknown command: $1" ;;
esac

while true; do
    echo ""
    echo "=== AIOManager control ==="
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Reconfigure (change subdomain)"
    echo "5) Test (checks it's reachable)"
    echo "6) Show address"
    echo "7) Update (or go back to an older version)"
    echo "8) Uninstall"
    echo "9) Show recent logs"
    echo "10) Sign-ups (open briefly to make another login, or close)"
    echo "11) Exit"
    read -rp "Choose an option [1-11]: " CHOICE
    case "$CHOICE" in
        1) do_status ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_configure ;;
        5) do_test ;;
        6) print_details ;;
        7) do_update ;;
        8) do_uninstall ;;
        9) do_logs ;;
        10) do_signups ;;
        11) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
