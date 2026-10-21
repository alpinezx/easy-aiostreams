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

STATE_DIR="$INSTALL_DIR/aiometadata-state"
CONFIG_FILE="$STATE_DIR/config"
AIOM_COMPOSE="$STATE_DIR/docker-compose.yml"
AIOM_ENV_FILE="$STATE_DIR/aiometadata.env"
# Its SQLite database: every configuration, account and the Dashboard's
# settings (including any Built-in API keys). The part worth backing up.
DATA_DIR="$STATE_DIR/data"
# Written by Stop, cleared by Start, so a stopped add-on is known to be
# deliberate.
STOPPED_MARKER="$STATE_DIR/stopped-on-purpose"
CADDY_SNIPPET="$CADDY_DROPIN_DIR/55-aiometadata.caddy"

CONTAINER_NAME="aiometadata"
REDIS_CONTAINER="aiometadata_redis"
INTERNAL_PORT="3232"
IMAGE_REPO="ghcr.io/cedya77/aiometadata"
# AIOMetadata needs Redis 8 or newer (it refuses to start otherwise).
REDIS_IMAGE="redis:8"
# Redis is only a cache. Without a limit it never evicts anything and grows
# for ever; with one, AIOMetadata's own eviction policy drops old entries.
REDIS_MAXMEMORY="256mb"
RELEASES_API="https://api.github.com/repos/cedya77/aiometadata/releases/latest"

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || \
        docker network create "$SHARED_NET" >/dev/null
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# Single-quoted so 'source' reads the values as plain text. The validators
# below make sure no single quotes or spaces get this far.
write_config() {
    (
        umask 077
        printf "DOMAIN='%s'\nADDON_PASSWORD='%s'\nADMIN_KEY='%s'\nAIOM_VERSION='%s'\n" \
            "$1" "$2" "$3" "$4" > "$CONFIG_FILE"
    )
    chmod 600 "$CONFIG_FILE"
}

# Secrets go in their own env file, read literally by Compose, so a manual
# 'docker compose up -d' in this folder can't start it without them.
write_env_file() {
    (
        umask 077
        {
            printf "PORT='%s'\n" "$INTERNAL_PORT"
            printf "HOST_NAME='https://%s'\n" "$DOMAIN"
            printf "NODE_ENV='production'\n"
            printf "LOG_LEVEL='info'\n"
            printf "DATABASE_URI='sqlite://addon/data/db.sqlite'\n"
            printf "REDIS_URL='redis://%s:6379'\n" "$REDIS_CONTAINER"
            # Unlocks the Dashboard, and signs its artwork links so nobody
            # else can use this server to fetch images.
            printf "ADMIN_KEY='%s'\n" "$ADMIN_KEY"
            # Needed to create a configuration, so nobody else can use this
            # server. Existing configurations keep working without it.
            printf "ADDON_PASSWORD='%s'\n" "$ADDON_PASSWORD"
            # Otherwise anyone can open the Dashboard as a guest and see its
            # stats, including which titles are being looked up.
            printf "DISABLE_GUEST_MODE='true'\n"
        } > "$AIOM_ENV_FILE"
    )
    chmod 600 "$AIOM_ENV_FILE"
}

# AIOMetadata joins aios_shared so Caddy can reach it. Redis stays on this
# stack's own network, with no ports, so only AIOMetadata can talk to it.
# Its cache lives in a Docker volume, outside $INSTALL_DIR, so backups
# leave it out (it rebuilds itself).
write_compose() {
    write_env_file
    mkdir -p "$DATA_DIR"
    cat > "$AIOM_COMPOSE" << EOF
name: aiometadata
services:
  aiometadata:
    image: ${IMAGE_REPO}:${AIOM_VERSION}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    init: true
    env_file:
      - ${AIOM_ENV_FILE}
    volumes:
      - ${DATA_DIR}:/app/addon/data
    depends_on:
      aiometadata_redis:
        condition: service_healthy
    networks:
      - default
      - ${SHARED_NET}

  aiometadata_redis:
    image: ${REDIS_IMAGE}
    container_name: ${REDIS_CONTAINER}
    restart: unless-stopped
    command: redis-server --appendonly yes --save 3600 1 --maxmemory ${REDIS_MAXMEMORY}
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  redis-data:

networks:
  ${SHARED_NET}:
    external: true
EOF
    chmod 600 "$AIOM_COMPOSE"
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
        warn "Moved AIOMetadata's Caddy site aside to ${CADDY_SNIPPET}.rejected. Run Reconfigure (option 4) to fix the subdomain."
    fi
}

compose() {
    (cd "$STATE_DIR" && docker compose -f "$AIOM_COMPOSE" "$@")
}

# The newest release's version, without the leading v (e.g. 3.6.1).
latest_version() {
    curl -fsSL --max-time 10 "$RELEASES_API" 2>/dev/null \
        | grep -oP '"tag_name":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+(?=")' | head -n1 || true
}

# The version the running container reports.
running_version() {
    docker exec "$CONTAINER_NAME" wget -qO- --timeout=5 "http://localhost:${INTERNAL_PORT}/api/config/addon-info" 2>/dev/null \
        | grep -oP '"addonVersion":\s*"v?\K[^"]+' || true
}

# Waits for the image's own health check (it allows 40s to start).
wait_healthy() {
    local i state
    for i in $(seq 1 45); do
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

print_details() {
    load_config || { echo "Not set up yet."; return 0; }
    echo ""
    echo -e "  Configure page:  \033[1;36mhttps://${DOMAIN}/configure\033[0m"
    echo -e "  Addon password:  \033[1;36m${ADDON_PASSWORD}\033[0m  (asked for when you save a new configuration)"
    echo -e "  Dashboard:       \033[1;36mhttps://${DOMAIN}/dashboard\033[0m"
    echo -e "  Admin key:       \033[1;36m${ADMIN_KEY}\033[0m  (opens the Dashboard)"
    echo ""
    echo "Set your API keys once in the Dashboard: Settings, API Keys, the rows named"
    echo "\"Built-in ...\" (e.g. Built-in TMDB Key). Every configuration then uses them."
    echo "A TMDB key is the only one needed: get one free at"
    echo "https://www.themoviedb.org/settings/api"
    warn "Use the Built-in rows only. The plain ones (e.g. \"TMDB API Key\") are shown to"
    warn "anyone who opens the configure page."
    echo ""
    echo "Then create a configuration on the configure page and install it in your"
    echo "Stremio-based client, or add its manifest URL to AIOStreams."
}

do_configure() {
    local from_start="${1:-false}"

    [[ -f "$COMPOSE_FILE" ]] || \
        error "Couldn't find $COMPOSE_FILE. Run setup-aiostreams.sh first, this bolts on to that install."

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    mkdir -p "$CADDY_DROPIN_DIR"
    ensure_shared_network

    local old_domain="" old_password="" old_key="" old_version=""
    if load_config; then
        old_domain="$DOMAIN"; old_password="$ADDON_PASSWORD"; old_key="$ADMIN_KEY"; old_version="${AIOM_VERSION:-}"
    fi

    info "Subdomain for AIOMetadata"
    echo "Needs its OWN subdomain, different from your main AIOStreams domain,"
    echo "with an A record already pointed at this server's IP."
    echo "e.g. meta.yourdomain.com"
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
            warn "That doesn't look like a domain. Letters, numbers, dots and hyphens only (e.g. meta.example.com)."
            continue
        fi
        clash=false
        while IFS= read -r taken; do
            [[ -n "$taken" && "${domain,,}" == "${taken,,}" ]] && clash=true
        done < <(other_domains)
        if $clash; then
            warn "$domain is already used on this server (main site, control panel or another add-on). AIOMetadata needs its own."
            continue
        fi
        check_subdomain_dns "$domain" || continue
        break
    done

    info "Addon password"
    echo "Keeps your instance private: creating a configuration needs this password,"
    echo "so nobody else can use your server. Your own configurations keep working"
    echo "in your apps without it."
    local suggestion password
    suggestion=$(openssl rand -hex 10 2>/dev/null || true)
    [[ -z "$suggestion" ]] && suggestion="aiom-${RANDOM}${RANDOM}${RANDOM}"
    while true; do
        if [[ -n "$old_password" ]]; then
            read -rp "Password [Enter to keep the current one]: " password
            password="${password:-$old_password}"
        else
            read -rp "Password [Enter to use a generated one]: " password
            password="${password:-$suggestion}"
        fi
        if [[ ${#password} -lt 8 ]]; then
            warn "Please use at least 8 characters."
            continue
        fi
        if [[ ! "$password" =~ ^[A-Za-z0-9@%^*_+=.!?-]+$ ]]; then
            warn "Password can only contain letters, numbers, and these symbols: @ % ^ * _ + = . ! ? -"
            continue
        fi
        break
    done

    # The admin key is generated once and kept: changing it would break
    # the artwork links AIOMetadata has already handed out.
    local key="$old_key"
    if [[ -z "$key" ]]; then
        key=$(openssl rand -hex 32 2>/dev/null || true)
        [[ -n "$key" ]] || error "Couldn't generate an admin key (openssl missing?)."
    fi

    local version="$old_version"
    if [[ -z "$version" ]]; then
        info "Looking up AIOMetadata's newest release"
        version=$(latest_version)
        valid_version "$version" || error "Couldn't look up the newest release on GitHub. Check this server can reach api.github.com, then try again."
        echo "Version $version."
    fi

    write_config "$domain" "$password" "$key" "$version"
    load_config
    write_compose
    write_caddy_snippet

    if container_running "$CONTAINER_NAME"; then
        info "Applying the new settings"
        compose up -d --force-recreate aiometadata
        reload_caddy
        print_details
    elif [[ "$from_start" != "true" ]]; then
        echo ""
        echo "Saved. Run option 2 (Start) next to bring it up with these settings."
    fi
}

do_start() {
    local quiet="${1:-false}"
    load_config || do_configure "true"
    load_config
    mkdir -p "$CADDY_DROPIN_DIR"
    ensure_shared_network
    write_compose
    write_caddy_snippet
    info "Starting AIOMetadata ${AIOM_VERSION}"
    # Quiet: a missing image (after an uninstall, or on a new server) would
    # otherwise print a line per layer, filling a restore's output.
    compose up -d --quiet-pull
    rm -f "$STOPPED_MARKER"
    reload_caddy
    echo "Waiting for it to report healthy (up to 90 seconds)..."
    if wait_healthy; then
        echo "AIOMetadata is running. The HTTPS certificate for a new subdomain can take a minute."
    else
        warn "AIOMetadata didn't report healthy in time. Check its logs (option 9)."
    fi
    if [[ "$quiet" == "true" ]]; then
        echo "Run 'sudo bash setup-aiometadata.sh' and choose option 6 for its address, password and admin key."
    else
        print_details
    fi
}

do_stop() {
    [[ -f "$AIOM_COMPOSE" ]] || error "Not set up yet."
    compose down
    touch "$STOPPED_MARKER"
    echo "Stopped. Settings, configurations and the cache are kept. Start picks up where it left off."
}

do_status() {
    echo ""
    if load_config; then
        echo "Address:     https://${DOMAIN}"
        echo "Version:     ${AIOM_VERSION} (installed)"
    else
        echo "Not set up yet."
        return 0
    fi
    if container_running "$CONTAINER_NAME"; then
        local health running
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
        echo "AIOMetadata: RUNNING${health:+ ($health)}"
        running=$(running_version)
        [[ -n "$running" && "$running" != "$AIOM_VERSION" ]] && echo "             reports version $running"
    elif [[ -f "$STOPPED_MARKER" ]]; then
        echo "AIOMetadata: STOPPED (on purpose)"
    else
        echo "AIOMetadata: STOPPED"
    fi
    if container_running "$REDIS_CONTAINER"; then
        echo "Cache:       RUNNING (Redis, limited to ${REDIS_MAXMEMORY})"
    else
        echo "Cache:       STOPPED"
    fi
    if container_running "$CONTAINER_NAME"; then
        echo ""
        docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}}, CPU {{.CPUPerc}}' "$CONTAINER_NAME" "$REDIS_CONTAINER" 2>/dev/null || true
    fi
    local latest
    latest=$(latest_version)
    if valid_version "$latest" && [[ "$latest" != "$AIOM_VERSION" ]]; then
        echo ""
        echo "Newest release: $latest (Update is option 7)"
    fi
}

do_test() {
    container_running "$CONTAINER_NAME" || error "Not running. Start it first (option 2)."
    load_config

    info "1/2: Checking AIOMetadata answers inside its container"
    if docker exec "$CONTAINER_NAME" wget -q --spider --timeout=5 "http://localhost:${INTERNAL_PORT}/health/live" 2>/dev/null; then
        echo "  OK, it's alive."
    else
        warn "  No answer. Check its logs (option 9)."
        return 0
    fi

    info "2/2: Checking https://${DOMAIN}, the way your apps reach it"
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}/health/live" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        echo "  OK (HTTP 200). DNS, HTTPS and Caddy are all working."
    elif [[ "$status" == "000" ]]; then
        warn "  Couldn't reach https://${DOMAIN} at all (DNS, certificate or network)."
        warn "  Check its A record, and 'docker compose logs caddy' in $INSTALL_DIR."
    else
        warn "  Got HTTP ${status}, expected 200. Check 'docker compose logs caddy' in $INSTALL_DIR."
    fi
}

# Moves to the newest release, or to a version typed in (which also goes
# back to an older one). Releases are pinned, so nothing changes until this
# is run.
# Runs AIOMetadata on the version in its config and waits for it to be
# healthy.
run_version() {
    load_config
    write_compose
    compose up -d --quiet-pull aiometadata
    rm -f "$STOPPED_MARKER"
    echo "Waiting for it to report healthy (up to 90 seconds)..."
    wait_healthy
}

# apply_update <version> <backup: yes|no>. Asks nothing, so the menu and
# the update-aiometadata command share it. Returns 1 when nothing changed
# or the update failed (and the previous version was put back).
apply_update() {
    local target="$1" backup="$2" previous="$AIOM_VERSION"
    if [[ "$target" == "$previous" ]] && container_running "$CONTAINER_NAME"; then
        echo "Already on ${target}. Nothing to do."
        return 0
    fi
    # Download first: a version that doesn't exist changes nothing.
    info "Downloading AIOMetadata ${target}"
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
    info "Switching AIOMetadata from ${previous} to ${target}"
    write_config "$DOMAIN" "$ADDON_PASSWORD" "$ADMIN_KEY" "$target"
    if run_version; then
        echo "AIOMetadata is on ${target} and healthy."
        # The old version's image is no longer needed
        docker image rm "${IMAGE_REPO}:${previous}" >/dev/null 2>&1 || true
        return 0
    fi
    warn "AIOMetadata ${target} didn't report healthy in time. Putting ${previous} back."
    docker logs --tail 15 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /' || true
    write_config "$DOMAIN" "$ADDON_PASSWORD" "$ADMIN_KEY" "$previous"
    if run_version; then
        warn "Back on ${previous}, healthy. Nothing else changed."
    else
        warn "${previous} didn't come back healthy either. Check its logs (option 9), or restore the backup made before this update."
    fi
    docker image rm "${IMAGE_REPO}:${target}" >/dev/null 2>&1 || true
    return 1
}

# Menu option 7: the same as update-aiometadata, with questions.
do_update() {
    load_config || error "Not set up yet. Run option 2 (Start) first."
    local latest choice backup
    latest=$(latest_version)
    echo ""
    echo "Installed: ${AIOM_VERSION}"
    if valid_version "$latest"; then
        echo "Newest:    ${latest}"
    else
        warn "Couldn't look up the newest release on GitHub."
    fi
    echo "Releases: https://github.com/cedya77/aiometadata/releases"
    while true; do
        if valid_version "$latest"; then
            read -rp "Version to install [Enter for ${latest}, or e.g. 3.6.0, or q to cancel]: " choice
            choice="${choice:-$latest}"
        else
            read -rp "Version to install (e.g. 3.6.0, or q to cancel): " choice
        fi
        choice="${choice#v}"
        [[ "$choice" == "q" ]] && { echo "Cancelled."; return 0; }
        valid_version "$choice" && break
        warn "Type a version like 3.6.0."
    done
    if [[ "$choice" == "$AIOM_VERSION" ]] && container_running "$CONTAINER_NAME"; then
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
    [[ -f "$AIOM_COMPOSE" ]] || error "Not set up yet."
    docker logs --tail 60 "$CONTAINER_NAME" 2>&1 || warn "No logs: the container doesn't exist (not started?)."
}

do_uninstall() {
    warn "This removes AIOMetadata: its containers, its cache, its Caddy site, and its saved settings,"
    warn "including every configuration and account in its database. Take a backup first if you might want them back."
    read -rp "Type 'uninstall' to continue: " confirm
    [[ "$confirm" == "uninstall" ]] || { echo "Cancelled."; return 0; }
    local version=""
    load_config && version="${AIOM_VERSION:-}"
    [[ -f "$AIOM_COMPOSE" ]] && { compose down -v 2>/dev/null || true; }
    # In case the compose file was already gone
    docker rm -f "$CONTAINER_NAME" "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    rm -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
    reload_caddy
    rm -rf "$STATE_DIR"
    read -rp "Also remove the downloaded AIOMetadata and Redis images? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy] ]]; then
        [[ -n "$version" ]] && docker image rm "${IMAGE_REPO}:${version}" >/dev/null 2>&1 || true
        docker image rm "$REDIS_IMAGE" >/dev/null 2>&1 || true
        echo "Images removed (any still in use elsewhere were kept)."
    fi
    echo "Done. Running this script again starts fresh from first-time setup."
    echo "Remember to remove AIOMetadata from your Stremio-based apps and AIOStreams."
}

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash setup-aiometadata.sh"
command -v docker >/dev/null || error "Docker not found. Run this on the same server as setup-aiostreams.sh."

# Question-free commands, for restores and the control panel. The menu's
# numbers below must never change once released, since older panels may
# type them.
case "${1:-}" in
    start-aiometadata)
        [[ -f "$CONFIG_FILE" ]] || error "AIOMetadata isn't set up, nothing to start."
        do_start "true" < /dev/null
        exit 0 ;;
    stop-aiometadata)
        [[ -f "$CONFIG_FILE" ]] || error "AIOMetadata isn't set up, nothing to stop."
        do_stop
        exit 0 ;;
    status)
        do_status
        exit 0 ;;
    # update-aiometadata [--backup] [--version X.Y.Z]: the newest release
    # unless a version is given (an older one goes back to it).
    update-aiometadata)
        load_config || error "AIOMetadata isn't set up, nothing to update."
        shift
        u_backup=no u_version=""
        while (( $# )); do
            case "$1" in
                --backup) u_backup=yes ;;
                --version) shift; u_version="${1:-}"; u_version="${u_version#v}"
                    valid_version "$u_version" || error "--version needs a version like 3.6.0." ;;
                *) error "Unknown option '$1'. Use: update-aiometadata [--backup] [--version X.Y.Z]" ;;
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
    echo "=== AIOMetadata control ==="
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Reconfigure (change subdomain or password)"
    echo "5) Test (checks it's reachable)"
    echo "6) Show address, password and admin key"
    echo "7) Update (or go back to an older version)"
    echo "8) Uninstall"
    echo "9) Show recent logs"
    echo "10) Exit"
    read -rp "Choose an option [1-10]: " CHOICE
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
        10) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
