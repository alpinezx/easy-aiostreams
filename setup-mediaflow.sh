#!/usr/bin/env bash

set -euo pipefail

# Resolved to an absolute path HERE, at the very top, before anything below
# can cd elsewhere. Same reasoning as the equivalent line in
# setup-aiostreams.sh, setup-vpn-gluetun.sh, setup-watchdog.sh, and
# setup-webhook.sh.
SELF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;33m!! %s !!\033[0m\n' "$1"; }
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

INSTALL_DIR="$HOME/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"
SHARED_NET="aios_shared"

STATE_DIR="$INSTALL_DIR/mediaflow-state"
CONFIG_FILE="$STATE_DIR/config"
MEDIAFLOW_COMPOSE="$STATE_DIR/docker-compose.yml"
MEDIAFLOW_ENV_FILE="$STATE_DIR/mediaflow.env"
# Written by Stop, cleared by Start. Tells setup-watchdog.sh a stopped
# proxy is deliberate, so it doesn't page you.
STOPPED_MARKER="$STATE_DIR/stopped-on-purpose"
CADDY_SNIPPET="$CADDY_DROPIN_DIR/50-mediaflow.caddy"

CONTAINER_NAME="mediaflow-proxy-light"
INTERNAL_PORT="8888"

# Host-side directory that gets bind-mounted into the caddy container so
# fail2ban (which runs on the HOST, not in any container) can read Caddy's
# access log for this one subdomain directly off disk.
CADDY_LOG_HOST_DIR="$INSTALL_DIR/caddy-logs"
CADDY_LOG_HOST_DIR_CONTAINER_PATH="/var/log/caddy-logs"
CADDY_LOG_MOUNT_MARKER="caddy-logs"
FAIL2BAN_FILTER_FILE="/etc/fail2ban/filter.d/aios-mediaflow.conf"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/aios-mediaflow.conf"

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || \
        docker network create "$SHARED_NET" >/dev/null
}

# The main install's aiostreams service isn't on aios_shared by default
# (only caddy is). MediaFlow is the first bolt-on where aiostreams itself
# has to reach something on aios_shared, so the main compose file needs a
# small patch. And if the fail2ban jail is installed, caddy also needs a
# host log directory mounted.
#
# Mode-aware: in VPN mode aiostreams runs with network_mode:
# "service:gluetun" and can't have its own networks: list, so gluetun is
# the one that gets aios_shared (aiostreams inherits it).
#
# Split in two on purpose:
#   patch_main_compose    edits the file only, never touches containers.
#                         setup-vpn-gluetun.sh and setup-aiostreams.sh's
#                         Reconfigure call this (via 'patch-compose') right
#                         after they rewrite docker-compose.yml and BEFORE
#                         they start the stack, so the stack comes up
#                         already wired, through their own tunnel gate.
#   apply_main_compose_patches
#                         patches, then recreates only what changed, and
#                         in VPN mode only starts aiostreams again after
#                         the tunnel is confirmed. Used by Start/Reconfigure
#                         here, when the stack is already running.
#
# Both idempotent. Set PATCHED_NETWORK / PATCHED_LOG_MOUNT for the caller.
patch_main_compose() {
    PATCHED_NETWORK=false
    PATCHED_LOG_MOUNT=false
    [[ -f "$COMPOSE_FILE" ]] || return 0

    if grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null; then
        local gluetun_block
        gluetun_block=$(sed -n '/^  gluetun:/,/^  aiostreams:/p' "$COMPOSE_FILE")
        if ! grep -q 'aios_shared' <<< "$gluetun_block"; then
            awk '
                /- FIREWALL_INPUT_PORTS=3000/ && !done {
                    print
                    print "    networks:"
                    print "      - default"
                    print "      - aios_shared"
                    done = 1
                    next
                }
                { print }
            ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
            PATCHED_NETWORK=true
        fi
    else
        local block
        block=$(sed -n '/^  aiostreams:/,/^  caddy:/p' "$COMPOSE_FILE")
        if ! grep -q 'aios_shared' <<< "$block"; then
            awk '
                /^  caddy:/ && !done {
                    print "    networks:"
                    print "      - default"
                    print "      - aios_shared"
                    done = 1
                }
                { print }
            ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
            PATCHED_NETWORK=true
        fi
    fi

    # Only when the jail exists. Every compose rewrite (VPN toggle,
    # Reconfigure) drops this mount, and without it fail2ban silently
    # watches a log file nothing writes to anymore.
    if [[ -f "$FAIL2BAN_JAIL_FILE" ]] && ! grep -q "$CADDY_LOG_MOUNT_MARKER" "$COMPOSE_FILE"; then
        mkdir -p "$CADDY_LOG_HOST_DIR"
        awk -v marker="$CADDY_LOG_MOUNT_MARKER" -v containerpath="$CADDY_LOG_HOST_DIR_CONTAINER_PATH" '
            /- \.\/caddy\.d:\/etc\/caddy\/caddy\.d/ && !done {
                print
                print "      - ./" marker ":" containerpath
                done = 1
                next
            }
            { print }
        ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
        PATCHED_LOG_MOUNT=true
    fi
    chmod 600 "$COMPOSE_FILE"
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

tunnel_confirmed() {
    local attempt svc
    for attempt in 1 2 3 4 5 6 7 8; do
        for svc in ifconfig.me/ip icanhazip.com ipinfo.io/ip; do
            docker exec gluetun wget -qO- --timeout=5 "$svc" 2>/dev/null | grep -qE '^[0-9]' && return 0
        done
        echo "  Tunnel not confirmed yet (attempt ${attempt}/8)..."
        sleep 2
    done
    return 1
}

apply_main_compose_patches() {
    patch_main_compose

    if $PATCHED_NETWORK; then
        if grep -q 'container_name: gluetun' "$COMPOSE_FILE" 2>/dev/null; then
            info "Wiring gluetun onto aios_shared (VPN mode; aiostreams inherits gluetun's network)"
            # Same order as setup-aiostreams.sh's tunnel gate: gluetun first,
            # confirm the tunnel, only then aiostreams, and only if it was
            # running beforehand (a deliberate stop stays stopped).
            local aio_was_running=false
            container_running aiostreams && aio_was_running=true
            (cd "$INSTALL_DIR" && docker compose up -d --force-recreate --no-deps gluetun) || \
                warn "Couldn't recreate gluetun. Run setup-aiostreams.sh, option 4 (Restart the stack)."
            if $aio_was_running; then
                if tunnel_confirmed; then
                    (cd "$INSTALL_DIR" && docker compose up -d --force-recreate --no-deps aiostreams) || \
                        warn "Couldn't recreate aiostreams. Run setup-aiostreams.sh, option 4 (Restart the stack)."
                else
                    alert "Tunnel not confirmed after recreating gluetun, so aiostreams was NOT restarted"
                    warn "Fix the tunnel, then run setup-aiostreams.sh, option 4 (Restart the stack)."
                fi
            fi
        else
            info "Wiring aiostreams onto aios_shared (needed so it can reach MediaFlow Proxy Light)"
            if container_running aiostreams; then
                (cd "$INSTALL_DIR" && docker compose up -d --force-recreate --no-deps aiostreams) || \
                    warn "Couldn't recreate aiostreams. Run 'docker compose up -d --force-recreate aiostreams' in $INSTALL_DIR."
            fi
        fi
    fi

    if $PATCHED_LOG_MOUNT; then
        info "Re-mounting caddy's log directory for the fail2ban jail"
        recreate_caddy_to_pick_up_mount
    fi
    return 0
}

# Kept under its old name so anything still calling it keeps working.
ensure_aiostreams_shared_network() {
    apply_main_compose_patches
}

ensure_caddy_dropin_dir() {
    mkdir -p "$CADDY_DROPIN_DIR"
}

# Secrets go in their own env file (single-quoted, read literally by
# Compose), not through shell-exported variables. A manual 'docker compose
# up -d' in this folder then can't recreate the proxy with an empty
# password, and characters like $ & ; in a proxy password can't break
# anything.
write_env_file() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    (
        umask 077
        {
            printf "APP__AUTH__API_PASSWORD='%s'\n" "${MEDIAFLOW_API_PASSWORD:-}"
            if [[ -n "${MEDIAFLOW_PROXY_URL:-}" ]]; then
                printf "APP__PROXY__PROXY_URL='%s'\n" "$MEDIAFLOW_PROXY_URL"
                printf "APP__PROXY__ALL_PROXY='true'\n"
            fi
        } > "$MEDIAFLOW_ENV_FILE"
    )
    chmod 600 "$MEDIAFLOW_ENV_FILE"
}

write_compose() {
    write_env_file

    cat > "$MEDIAFLOW_COMPOSE" << EOF
services:
  mediaflow-proxy-light:
    image: ghcr.io/mhdzumair/mediaflow-proxy-light:latest
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      - APP__SERVER__HOST=0.0.0.0
      - APP__SERVER__PORT=${INTERNAL_PORT}
    env_file:
      - ${MEDIAFLOW_ENV_FILE}
    networks:
      - ${SHARED_NET}
networks:
  ${SHARED_NET}:
    external: true
EOF
}

write_caddy_snippet() {
    local domain="$1" with_log="${2:-auto}"
    rm -f "${CADDY_SNIPPET}.rejected"
    # The access log only exists for fail2ban. Without the jail there's
    # no host mount behind that path, so Caddy would just fill up its own
    # container filesystem with a log nobody reads.
    if [[ "$with_log" == "auto" ]]; then
        with_log=false
        [[ -f "$FAIL2BAN_JAIL_FILE" ]] && with_log=true
    fi
    local log_block=""
    if [[ "$with_log" == "true" ]]; then
        log_block="    log {
        output file ${CADDY_LOG_HOST_DIR_CONTAINER_PATH}/mediaflow-access.log
        format json
    }
"
    fi
    cat > "$CADDY_SNIPPET" << EOF
${domain} {
${log_block}
    # Blocks MediaFlow's own browsable UI (home page, docs, speedtest,
    # playlist/URL builder tools). Done here at Caddy rather than via a
    # MediaFlow env var, since Light's own config reference (unlike the
    # original Python MediaFlow Proxy) has no confirmed page-disable
    # setting, this works regardless either way. Real proxy endpoints
    # (/proxy/*, /metrics, /health, /generate_url(s), /extractor/*, etc)
    # are untouched, only this exact narrow set of browsable pages 404s.
    @blocked path / /docs /docs/* /speedtest /speedtest.html /playlist_builder.html /playlist/builder /url_generator.html /logo.png
    respond @blocked 404

    reverse_proxy ${CONTAINER_NAME}:${INTERNAL_PORT}
}
EOF
}

# Restarts just the main install's caddy container so it picks up the new
# file under caddy.d/ and gets a cert for the new subdomain. Caddy doesn't
# watch that directory on its own. Same idea as setup-webhook.sh's version.
get_domain() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    echo "$DOMAIN"
}

restart_caddy_to_pick_up_dropin() {
    # A reload, not a restart: Caddy validates the new config first and, if
    # it's bad, refuses it and keeps serving the old one. A restart with a
    # bad snippet would take the main AIOStreams site down with it.
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy; then
        warn "caddy container isn't running, so the new subdomain won't be live until it is. Run setup-aiostreams.sh's Start/Restart option first."
        return 0
    fi
    local out
    if out=$(docker exec -w /etc/caddy caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
        return 0
    fi
    warn "Caddy rejected the new config and is still running the old one (main site unaffected)."
    echo "$out" | tail -n 5
    if [[ -f "$CADDY_SNIPPET" ]]; then
        # Out of the *.caddy glob, so the next Caddy restart or server
        # reboot doesn't trip over it and take the main site down.
        mv -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
        warn "Moved MediaFlow's Caddy snippet aside to ${CADDY_SNIPPET}.rejected so it can't break Caddy on the next restart."
        warn "Run Reconfigure (option 4) to fix the subdomain."
    fi
}

# Mounting a new volume (unlike restarting) needs the container recreated,
# not just restarted, for the new mount to actually take effect.
recreate_caddy_to_pick_up_mount() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy; then
        (cd "$INSTALL_DIR" && docker compose up -d --force-recreate --no-deps caddy) || \
            warn "Couldn't recreate the caddy container automatically. Run 'docker compose up -d --force-recreate caddy' in $INSTALL_DIR yourself."
    else
        warn "caddy container isn't running. Run setup-aiostreams.sh's Start/Restart option first, then retry."
    fi
}

# Installs a fail2ban jail that watches ONLY this one subdomain's access
# log for any 404. That's a safe, aggressive rule specifically here (unlike
# the main AIOStreams domain) because legitimate traffic only ever hits a
# small set of known, documented paths (/proxy/*, /metrics, /health,
# /generate_url(s), /extractor/*). A 404 on this subdomain is essentially
# never a real client, almost always a bot probing for WordPress/PHP/etc,
# exactly the traffic seen scanning it within hours of going live.
do_install_fail2ban() {
    command -v fail2ban-client >/dev/null 2>&1 || \
        error "fail2ban isn't installed on this server. Install it first (e.g. 'apt-get install -y fail2ban'), then re-run this option."

    local domain
    domain=$(get_domain)
    [[ -n "$domain" ]] || error "No MediaFlow config found. Run Start/Reconfigure first."

    # Log mount + log{} block. patch_main_compose only adds the mount once
    # the jail file exists, so force it here, where the jail is about to be
    # written a few lines down.
    mkdir -p "$CADDY_LOG_HOST_DIR"
    if ! grep -q "$CADDY_LOG_MOUNT_MARKER" "$COMPOSE_FILE"; then
        touch "$FAIL2BAN_JAIL_FILE"   # placeholder so the patcher adds the mount
        patch_main_compose
        recreate_caddy_to_pick_up_mount
    fi
    write_caddy_snippet "$domain" "true"
    restart_caddy_to_pick_up_dropin
    touch "$CADDY_LOG_HOST_DIR/mediaflow-access.log"

    # This server's own public IP MUST be exempt. Any request that resolves
    # the public domain and hairpins back in (a curl test run from this box
    # itself, or any container calling out to the public URL rather than
    # the internal docker network) arrives at Caddy looking exactly like an
    # external visitor from this IP. Without this exemption, a single local
    # test can ban the server's own IP firewall-wide on ports 80/443,
    # taking down the MAIN AIOStreams domain too, not just this subdomain,
    # since both share the same server and the same public IP.
    info "Detecting this server's own public IP (to exempt it from ever being banned)"
    local own_ip=""
    local svc
    for svc in "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        own_ip=$(curl -fs4 --max-time 4 "$svc" 2>/dev/null | tr -d ' \n') && [[ -n "$own_ip" ]] && break
    done
    if [[ -n "$own_ip" ]]; then
        echo "  Detected: $own_ip (will be exempted)"
    else
        warn "  Couldn't detect it automatically. If you ever test from this server itself and get banned, unban with:"
        warn "  sudo fail2ban-client set aios-mediaflow unbanip <the-ip-that-got-banned>"
    fi

    info "Writing fail2ban filter and jail"
    # Counts 401/404 only on paths OUTSIDE the real API. Real clients
    # can legitimately get those on /proxy/* etc: a 401 from a stream URL
    # cached before a password change, or a 404 passed through from a dead
    # upstream link. Counting those would ban the owner's own IP from
    # ports 80/443 for 24h, main AIOStreams site included. That includes
    # MediaFlow's encrypted links (/_token_<encrypted>/proxy/...), which is
    # what AIOStreams actually sends; only a token followed by a real API
    # path is exempt, so bots can't dodge the jail by putting /_token_ in
    # front of a probe. Scanners probe
    # things like /wp-login.php and /.env, which this still catches. The
    # bare "/" is also excluded so opening the URL in a browser to check
    # it can't get you banned.
    cat > "$FAIL2BAN_FILTER_FILE" << 'EOF'
# Matches a 401 or 404 in Caddy's JSON access log for the MediaFlow
# subdomain, only on paths that aren't part of MediaFlow's real API.
# Installed/managed by setup-mediaflow.sh (easy-aiostreams).
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"uri":"/(?!proxy/|extractor/|generate_url|health|metrics|_token_[^/"]*/(?:proxy/|extractor/|generate_url)|")[^"]*".*"status":\s*(401|404)\b
ignoreregex =
# Caddy writes the time as a bare Unix number mid-line ("ts":1727183424.52),
# which fail2ban doesn't recognise on its own. Without this it drops some
# matches as "no valid date/time found", so a bot that stops at exactly 3
# hits never gets banned.
datepattern = "ts":{EPOCH}
EOF

    cat > "$FAIL2BAN_JAIL_FILE" << EOF
[aios-mediaflow]
enabled  = true
port     = http,https
filter   = aios-mediaflow
# Explicit, because Ubuntu 24.04's fail2ban package (1.0.2-3) sets
# 'backend = systemd' for every jail in jail.d/defaults-debian.conf. That
# makes fail2ban read the system journal and ignore logpath entirely, so
# without this the jail never sees Caddy's log and never bans anything.
# Newer packages (Debian 13, Ubuntu 26.04) limit that to sshd, so this is
# just the same 'auto' they'd use anyway, and guards against anyone who
# has set a global journal default themselves.
backend  = auto
logpath  = ${CADDY_LOG_HOST_DIR}/mediaflow-access.log
maxretry = 3
findtime = 600
bantime  = 86400
ignoreip = 127.0.0.1/8 ::1${own_ip:+ $own_ip}
EOF

    info "Reloading fail2ban"
    systemctl restart fail2ban || fail2ban-client reload

    # Defensive: if an earlier run of this jail (e.g. before this exemption
    # existed) already banned this server's own IP, undo that now rather
    # than leaving it self-banned until someone notices.
    if [[ -n "$own_ip" ]]; then
        fail2ban-client set aios-mediaflow unbanip "$own_ip" >/dev/null 2>&1 || true
    fi

    echo ""
    echo "Done. Check it's active with: sudo fail2ban-client status aios-mediaflow"
    echo "Any 3 x (401 or 404) on non-API paths from the same IP within 10 minutes on ${domain} gets a 24h ban."
    echo "Real proxy traffic (/proxy/*, /extractor/*, etc.) never counts, even if it errors."
    echo "This server's own IP (${own_ip:-undetected}) is permanently exempt."
    alert "If you or your Stremio-based client routes through a commercial VPN, that exit IP is likely shared with other customers. Someone else on the same IP tripping this jail bans you too, for something you didn't do. If streams through this proxy fail unexpectedly, check: sudo fail2ban-client status aios-mediaflow"
}

do_uninstall_fail2ban() {
    rm -f "$FAIL2BAN_JAIL_FILE" "$FAIL2BAN_FILTER_FILE"
    if command -v fail2ban-client >/dev/null 2>&1; then
        systemctl restart fail2ban 2>/dev/null || fail2ban-client reload 2>/dev/null || true
    fi
    local domain
    domain=$(get_domain)
    if [[ -n "$domain" && -f "$CADDY_SNIPPET" ]]; then
        write_caddy_snippet "$domain" "false"
        restart_caddy_to_pick_up_dropin
    fi
    echo "Removed the aios-mediaflow jail. fail2ban itself and any other jails (e.g. SSH) are untouched."
}

print_aiostreams_settings() {
    local domain password
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    domain="$DOMAIN"
    password="$MEDIAFLOW_API_PASSWORD"
    echo ""
    echo "Paste these into AIOStreams' dashboard, Proxy settings, Proxy Service = MediaFlow Proxy:"
    echo -e "  URL:        \033[1;36mhttp://${CONTAINER_NAME}:${INTERNAL_PORT}\033[0m  (internal, container-to-container)"
    echo -e "  Public URL: \033[1;36mhttps://${domain}\033[0m  (what streams actually resolve to for clients)"
    echo -e "  Password:   \033[1;36m${password}\033[0m"
    echo ""
    echo "Save in the dashboard, then:"
    alert "If a stream you already had open doesn't start, just refresh the stream list in your Stremio-based client, no need to reinstall the manifest, that's usually all it takes."
}

# Single-quoted so both 'source' and anything else reading this treat the
# values as plain text. Validators below guarantee no single quotes or
# whitespace get this far.
write_config() {
    (
        umask 077
        printf "DOMAIN='%s'\nMEDIAFLOW_API_PASSWORD='%s'\nMEDIAFLOW_PROXY_URL='%s'\n" \
            "$1" "$2" "$3" > "$CONFIG_FILE"
    )
    chmod 600 "$CONFIG_FILE"
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# Other domains this server's Caddy already serves. Reusing one would make
# Caddy reject the whole config.
other_domains() {
    [[ -f "$INSTALL_DIR/Caddyfile" ]] && head -n1 "$INSTALL_DIR/Caddyfile" | awk '{print $1}'
    grep -hoP "^DOMAIN='?\K[^'\s]+" "$INSTALL_DIR/webhook-relay-state/config" 2>/dev/null || true
}

do_configure() {
    local from_start="${1:-false}"

    [[ -f "$COMPOSE_FILE" ]] || \
        error "Couldn't find $COMPOSE_FILE. Run setup-aiostreams.sh first, this bolts on to that install."

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    ensure_caddy_dropin_dir
    ensure_shared_network
    apply_main_compose_patches

    info "Subdomain for MediaFlow Proxy Light"
    echo "Needs to be its OWN subdomain, different from your main AIOStreams"
    echo "domain, with its own A record already pointed at this server's IP"
    echo "(same as the main installer required). e.g. mediaflow.yourdomain.com"
    echo ""
    echo "This has to be publicly reachable: AIOStreams hands stream URLs"
    echo "built from this address straight to your Stremio-based client,"
    echo "which is out on the internet, not on this server's Docker network."
    local domain taken clash
    while true; do
        read -rp "Subdomain: " domain
        domain=$(echo "$domain" | xargs)
        if ! valid_domain "$domain"; then
            warn "That doesn't look like a domain. Letters, numbers, dots and hyphens only (e.g. mediaflow.example.com)."
            continue
        fi
        clash=false
        while IFS= read -r taken; do
            [[ -n "$taken" && "${domain,,}" == "${taken,,}" ]] && clash=true
        done < <(other_domains)
        if $clash; then
            warn "$domain is already used by your main install or the webhook relay. MediaFlow needs its own subdomain."
            continue
        fi
        break
    done

    local existing_password=""
    local existing_proxy_url=""
    [[ -f "$CONFIG_FILE" ]] && { source "$CONFIG_FILE"; existing_password="${MEDIAFLOW_API_PASSWORD:-}"; existing_proxy_url="${MEDIAFLOW_PROXY_URL:-}"; }

    info "API password"
    echo "Protects this proxy from being used by anyone who isn't AIOStreams."
    local suggestion password
    suggestion=$(openssl rand -hex 24 2>/dev/null || true)
    [[ -z "$suggestion" ]] && suggestion="mf-${RANDOM}${RANDOM}${RANDOM}"
    # URL-safe only: the password ends up in stream URLs as a query value.
    while true; do
        if [[ -n "$existing_password" ]]; then
            read -rp "Password [Enter to keep existing]: " password
            password="${password:-$existing_password}"
        else
            read -rp "Password [Enter to use a generated one]: " password
            password="${password:-$suggestion}"
        fi
        [[ "$password" =~ ^[A-Za-z0-9._~-]{12,}$ ]] && break
        warn "At least 12 characters: letters, numbers, and . _ ~ - only (it goes into stream URLs)."
    done
    if [[ -n "$existing_password" && "$password" != "$existing_password" ]]; then
        warn "Changing the password breaks stream links your clients already have cached."
        warn "Refresh the stream list in your client after saving the new password in AIOStreams."
    fi

    info "Outbound proxy for MediaFlow's own video traffic (optional)"
    echo "Separate from anything in AIOStreams' Addon proxy config, that"
    echo "setting never reaches MediaFlow's traffic. Leave blank to have"
    echo "video go out on this VPS's own IP, as before."
    echo "Format: http://user:pass@host:port or socks5://user:pass@host:port"
    local proxy_url
    while true; do
        if [[ -n "$existing_proxy_url" ]]; then
            read -rp "Proxy URL [Enter to keep existing, type 'none' to remove]: " proxy_url
            if [[ "$proxy_url" == "none" ]]; then
                proxy_url=""
            else
                proxy_url="${proxy_url:-$existing_proxy_url}"
            fi
        else
            read -rp "Proxy URL [Enter for none]: " proxy_url
        fi
        [[ -z "$proxy_url" ]] && break
        [[ "$proxy_url" =~ ^(https?|socks5h?)://[^\'[:space:]]+$ ]] && break
        warn "Needs to start with http://, https://, socks5:// or socks5h://, with no spaces or single quotes."
    done

    write_config "$domain" "$password" "$proxy_url"

    write_compose
    write_caddy_snippet "$domain"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        info "Applying the new settings to the running container"
        (cd "$STATE_DIR" && docker compose -f "$MEDIAFLOW_COMPOSE" up -d --force-recreate)
        restart_caddy_to_pick_up_dropin
    elif [[ "$from_start" != "true" ]]; then
        # If do_start called us (first-ever Start, no config yet), it's
        # about to bring the container up and print settings itself right
        # after, so saying "run option 2 next" here would be telling the
        # person to do the thing they're already in the middle of doing.
        echo ""
        echo "Not running yet, run option 2 (Start) next to bring it up with these settings."
    fi

    # Same reasoning: skip our own print when do_start will print its own
    # copy in a few seconds anyway, once the container's actually running.
    [[ "$from_start" == "true" ]] || print_aiostreams_settings
}

do_start() {
    local quiet="${1:-false}"
    [[ -f "$CONFIG_FILE" ]] || do_configure "true"
    ensure_caddy_dropin_dir
    ensure_shared_network
    apply_main_compose_patches
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    # Rewrites older unquoted configs into the quoted format.
    write_config "$DOMAIN" "$MEDIAFLOW_API_PASSWORD" "${MEDIAFLOW_PROXY_URL:-}"
    write_compose
    # Refreshes the site file too, so it matches whether the jail is on.
    write_caddy_snippet "$DOMAIN"
    # Pull first, so Start doubles as Update: this stack isn't covered by
    # setup-aiostreams.sh's Update option, and without a pull the container
    # would be recreated from the same cached image forever. A failed pull
    # (offline, registry hiccup) just falls back to the cached image.
    info "Checking for a newer MediaFlow Proxy Light image"
    local image_snapshot
    # shellcheck disable=SC2046  # image refs never contain spaces
    image_snapshot=$(snapshot_image_ids $(compose_image_refs "$MEDIAFLOW_COMPOSE"))
    (cd "$STATE_DIR" && docker compose -f "$MEDIAFLOW_COMPOSE" pull) || \
        warn "Couldn't pull a newer image, starting with the one already on this server."
    (cd "$STATE_DIR" && docker compose -f "$MEDIAFLOW_COMPOSE" up -d --force-recreate)
    cleanup_replaced_images "$image_snapshot"
    rm -f "$STOPPED_MARKER"
    restart_caddy_to_pick_up_dropin
    info "MediaFlow Proxy Light running. It can take a minute for the HTTPS cert on the new subdomain to issue."
    if [[ "$quiet" == "true" ]]; then
        echo "Run 'sudo bash setup-mediaflow.sh' → option 6 if you need the URL/password again."
    else
        print_aiostreams_settings
    fi
}

do_stop() {
    [[ -f "$MEDIAFLOW_COMPOSE" ]] || error "Not set up yet."
    (cd "$STATE_DIR" && docker compose -f "$MEDIAFLOW_COMPOSE" down)
    touch "$STOPPED_MARKER"
    echo "Stopped. Config and password are kept. Start picks up where it left off."
    alert "If a Stremio-based client already has this title's stream list open, it may still show the proxied version. If playback just hangs, refresh the stream list in that client, no need to reinstall anything, since AIOStreams picks up the change immediately once you ask it again."
}

do_status() {
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        echo "Domain:      ${DOMAIN:-unset}"
        echo "Public URL:  https://${DOMAIN:-<domain>}"
        if [[ -n "${MEDIAFLOW_PROXY_URL:-}" ]]; then
            # Strip credentials before printing, only show scheme+host+port.
            echo "Outbound proxy: $(sed -E 's#^([a-z0-9]+://)[^@]+@#\1<credentials hidden>@#' <<< "$MEDIAFLOW_PROXY_URL")"
        else
            echo "Outbound proxy: none (video goes out on this VPS's own IP)"
        fi
    else
        echo "Not configured yet."
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        echo "Proxy:       RUNNING"
    else
        echo "Proxy:       STOPPED"
    fi
}

do_test() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" || \
        error "Not running. Start it first (option 2)."

    local domain
    domain=$(get_domain)

    info "1/2: Checking the container responds internally"
    local internal_status
    internal_status=$(docker run --rm --network "$SHARED_NET" curlimages/curl \
        -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${CONTAINER_NAME}:${INTERNAL_PORT}/health" 2>/dev/null || echo "000")
    if [[ "$internal_status" == "200" ]]; then
        echo "  OK, the process itself is alive."
    else
        warn "  No response over the internal network (got '${internal_status}'). Check: docker compose -f $MEDIAFLOW_COMPOSE logs"
        return
    fi

    info "2/2: Checking the REAL path (https://${domain}), same route your streaming client actually uses"
    echo "This proves DNS, TLS, and Caddy are all correctly wired, not just that the container is alive."
    local http_status
    http_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${domain}/health" 2>/dev/null || echo "000")
    if [[ "$http_status" == "200" ]]; then
        echo "  OK (HTTP 200). MediaFlow is genuinely reachable the same way your client reaches it."
        echo ""
        echo "For absolute certainty on a SPECIFIC stream: open DevTools' Network tab on your"
        echo "client while something plays, and confirm the actual video request goes to"
        echo "https://${domain}/... — that's the one thing that can never be faked or ambiguous."
    elif [[ "$http_status" == "000" ]]; then
        warn "  Could not reach https://${domain} at all (timeout or DNS/TLS failure)."
        warn "  The container is alive internally, but nothing outside this server can reach it right now."
        warn "  Check: DNS A record for ${domain}, and 'docker compose logs caddy' in $INSTALL_DIR."
    else
        warn "  Got HTTP ${http_status} from https://${domain}/health, expected 200."
        warn "  Check: 'docker compose logs caddy' in $INSTALL_DIR."
    fi
}

do_uninstall() {
    warn "This stops and removes the MediaFlow Proxy Light container, its Caddy site, saved config (including the API password), and the fail2ban jail if one was added."
    read -rp "Continue? [y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|Yes) ;;
        *) echo "Cancelled."; return ;;
    esac
    [[ -f "$MEDIAFLOW_COMPOSE" ]] && (cd "$STATE_DIR" && docker compose -f "$MEDIAFLOW_COMPOSE" down 2>/dev/null || true)
    [[ -f "$FAIL2BAN_JAIL_FILE" ]] && do_uninstall_fail2ban
    # Full uninstall also purges the access log that jail was reading, plus
    # its host directory. do_uninstall_fail2ban (option 8, remove protection
    # only) leaves these alone on purpose, since removing just the jail
    # while keeping mediaflow installed shouldn't delete logs someone might
    # still want to look at.
    if [[ -d "$CADDY_LOG_HOST_DIR" ]]; then
        info "Cleaning up fail2ban's log directory"
        rm -rf "$CADDY_LOG_HOST_DIR"
    fi
    rm -f "$CADDY_SNIPPET" "${CADDY_SNIPPET}.rejected"
    restart_caddy_to_pick_up_dropin
    rm -rf "$STATE_DIR"
    echo "Done. Running this script again starts fresh from first-time setup."
    echo "Remember to switch AIOStreams' Proxy settings back off MediaFlow if you don't have another instance to point at."
    alert "If a Stremio-based client still shows a hanging stream from this proxy afterward, refresh the stream list in that client, that's usually enough, no manifest reinstall needed."
}

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash setup-mediaflow.sh"
command -v docker >/dev/null || error "Docker not found. Run this on the same server as setup-aiostreams.sh."

# Bug fix: same reasoning as the equivalent block in setup-webhook.sh, under
# sudo $INSTALL_DIR is root's home, so this keeps future runs finding the
# right copy regardless of where the script was downloaded to.
sync_self_into_install_dir() {
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
    local dest="$INSTALL_DIR/setup-mediaflow.sh"
    [[ -f "$SELF_SCRIPT_PATH" ]] || return 0
    [[ "$SELF_SCRIPT_PATH" == "$dest" ]] && return 0
    if [[ ! -f "$dest" ]] || ! cmp -s "$SELF_SCRIPT_PATH" "$dest"; then
        if cp -- "$SELF_SCRIPT_PATH" "$dest" 2>/dev/null; then
            chmod +x "$dest" 2>/dev/null || true
            echo "(Synced this script into $INSTALL_DIR/setup-mediaflow.sh.)"
        fi
    fi
    return 0
}
sync_self_into_install_dir

# Non-interactive entrypoint for setup-aiostreams.sh's restore flow to call,
# same pattern as setup-webhook.sh's 'start-relay'. Requires an existing
# config (restore only calls this after the config file has already landed
# via the extracted tarball), so this never prompts.
# Called by setup-vpn-gluetun.sh and setup-aiostreams.sh (Reconfigure)
# right after they rewrite docker-compose.yml, before they start anything.
# Edits the file only. They bring the stack up themselves, through their
# own tunnel gate, already wired.
if [[ "${1:-}" == "patch-compose" ]]; then
    [[ -f "$CONFIG_FILE" ]] || exit 0
    patch_main_compose
    exit 0
fi

if [[ "${1:-}" == "start-mediaflow" ]]; then
    [[ -f "$CONFIG_FILE" ]] || error "No MediaFlow config found at $CONFIG_FILE, nothing to start."
    do_start "true"
    exit 0
fi

while true; do
    echo ""
    echo "=== MediaFlow Proxy Light control ==="
    echo "1) Status"
    echo "2) Start (also pulls the latest image)"
    echo "3) Stop"
    echo "4) Reconfigure (change subdomain/password)"
    echo "5) Test (checks the proxy itself is alive)"
    echo "6) Show AIOStreams dashboard settings to paste in"
    echo "7) Add fail2ban protection (blocks bots probing this subdomain)"
    echo "8) Remove fail2ban protection"
    echo "9) Uninstall"
    echo "10) Exit"
    read -rp "Choose an option [1-10]: " CHOICE
    case "$CHOICE" in
        1) do_status ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_configure ;;
        5) do_test ;;
        6)
            [[ -f "$CONFIG_FILE" ]] && print_aiostreams_settings || echo "Not configured yet."
            ;;
        7) do_install_fail2ban ;;
        8) do_uninstall_fail2ban ;;
        9) do_uninstall ;;
        10) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
