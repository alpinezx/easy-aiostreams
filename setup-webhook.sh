#!/usr/bin/env bash

set -euo pipefail

# Resolved to an absolute path HERE, at the very top, before anything below
# can cd elsewhere. Same reasoning as the equivalent line in
# setup-aiostreams.sh, setup-vpn-gluetun.sh, and setup-watchdog.sh.
SELF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

INSTALL_DIR="$HOME/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDY_DROPIN_DIR="$INSTALL_DIR/caddy.d"
SHARED_NET="aios_shared"

STATE_DIR="$INSTALL_DIR/webhook-relay-state"
CONFIG_FILE="$STATE_DIR/config"
EVENTS_LOG="$STATE_DIR/events.log"
APP_SCRIPT="$STATE_DIR/webhook_relay.py"
RELAY_COMPOSE="$STATE_DIR/docker-compose.yml"
CADDY_SNIPPET="$CADDY_DROPIN_DIR/50-webhook-relay.caddy"
SCRIPT_COPY="$STATE_DIR/setup-webhook.sh"

CONTAINER_NAME="aios-webhook-relay"
INTERNAL_PORT="8787"

# ---------------------------------------------------------------------------
# The receiver itself: stdlib-only Python, no image build, no dependencies.
# Mounted into python:3-alpine and run directly. Always ACKs fast (so the
# calling site's "challenge ping" succeeds even if the ntfy forward fails),
# then best-effort relays the payload to ntfy in the background.
# ---------------------------------------------------------------------------
write_app_script() {
    cat > "$APP_SCRIPT" << 'PYEOF'
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("WEBHOOK_TOKEN", "")
NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "")
EVENTS_LOG = os.environ.get("EVENTS_LOG", "/state/events.log")
MAX_BODY = 20000  # refuse to buffer/log absurdly large payloads

def summarize(raw_body):
    text = raw_body.decode("utf-8", errors="replace").strip()
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            interesting = {k: data[k] for k in list(data)[:8]}
            text = json.dumps(interesting, ensure_ascii=False)
    except (ValueError, TypeError):
        pass
    return text[:800] if text else "(empty body)"

def log_event(line):
    try:
        with open(EVENTS_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass

def forward_to_ntfy(summary):
    if not NTFY_TOPIC:
        return False, "no ntfy topic configured"
    url = f"{NTFY_SERVER}/{NTFY_TOPIC}"
    req = urllib.request.Request(
        url,
        data=summary.encode("utf-8"),
        headers={"Title": "Webhook received"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5).read()
        return True, None
    except Exception as exc:  # best-effort, never blocks the ACK
        return False, str(exc)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # docker logs already capture stdout; skip noisy default access log

    def _reject(self, code):
        self.send_response(code)
        self.end_headers()

    def do_GET(self):
        # Plain health check, no token required.
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_HEAD(self):
        # Same health check as GET, minus the body. `curl -I` and some
        # uptime monitors use HEAD specifically, without this they'd get
        # Python's generic 501 even though the server is perfectly healthy.
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "hook" or not TOKEN or parts[1] != TOKEN:
            self._reject(404)  # 404, not 403: don't confirm the path exists
            return

        length = int(self.headers.get("Content-Length", 0) or 0)
        if length > MAX_BODY:
            self._reject(413)
            return
        raw_body = self.rfile.read(length) if length else b""

        # Some senders (this uptime tracker included) verify the endpoint by
        # POSTing a JSON body with a "challenge" value and expecting that
        # exact value echoed straight back, not just any 200. Check for that
        # before falling back to the plain ack used for real events.
        challenge = None
        try:
            parsed = json.loads(raw_body.decode("utf-8", errors="replace"))
            if isinstance(parsed, dict) and "challenge" in parsed:
                challenge = parsed["challenge"]
        except (ValueError, TypeError):
            pass

        if challenge is not None:
            body = json.dumps({"challenge": challenge}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            stamp = time.strftime("%d %b %Y, %H:%M:%S %Z")
            log_event(f"{stamp}  verification challenge echoed back")
            return

        # ACK immediately. A real event just needs a 200; it doesn't wait
        # on ntfy.
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

        summary = summarize(raw_body)
        ok, err = forward_to_ntfy(summary)
        stamp = time.strftime("%d %b %Y, %H:%M:%S %Z")
        status = "forwarded" if ok else f"NOT forwarded ({err})"
        log_event(f"{stamp}  {status}  {summary}")

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8787"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PYEOF
    chmod 644 "$APP_SCRIPT"
}

ensure_shared_network() {
    docker network inspect "$SHARED_NET" >/dev/null 2>&1 || \
        docker network create "$SHARED_NET" >/dev/null
}

ensure_caddy_dropin_dir() {
    mkdir -p "$CADDY_DROPIN_DIR"
}

write_compose() {
    cat > "$RELAY_COMPOSE" << EOF
services:
  webhook-relay:
    image: python:3-alpine
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    command: ["python3", "/app/webhook_relay.py"]
    volumes:
      - ${APP_SCRIPT}:/app/webhook_relay.py:ro
      - ${STATE_DIR}:/state
    environment:
      - PORT=${INTERNAL_PORT}
      - WEBHOOK_TOKEN=\${WEBHOOK_TOKEN}
      - NTFY_SERVER=\${NTFY_SERVER}
      - NTFY_TOPIC=\${NTFY_TOPIC}
      - EVENTS_LOG=/state/events.log
    networks:
      - ${SHARED_NET}
networks:
  ${SHARED_NET}:
    external: true
EOF
}

write_caddy_snippet() {
    local domain="$1"
    cat > "$CADDY_SNIPPET" << EOF
${domain} {
    reverse_proxy ${CONTAINER_NAME}:${INTERNAL_PORT}
}
EOF
}

restart_caddy_to_pick_up_dropin() {
    # The main install's caddy container needs to see the new file under
    # caddy.d/ and get a fresh cert for the new subdomain. Caddy doesn't
    # watch that directory on its own, so a restart of just that one
    # container (not the whole stack) is what actually applies it.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy; then
        (cd "$INSTALL_DIR" && docker compose restart caddy) || \
            warn "Couldn't restart the caddy container automatically. Run 'docker compose restart caddy' in $INSTALL_DIR yourself."
    else
        warn "No running 'caddy' container found. Is setup-aiostreams.sh installed and running on this server?"
    fi
}

do_configure() {
    [[ -f "$COMPOSE_FILE" ]] || \
        error "Couldn't find $COMPOSE_FILE. Run setup-aiostreams.sh first, this bolts on to that install."

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    ensure_caddy_dropin_dir
    ensure_shared_network
    write_app_script
    touch "$EVENTS_LOG"

    info "Subdomain for this webhook receiver"
    echo "Needs to be its OWN subdomain, different from your main AIOStreams"
    echo "domain, with its own A record already pointed at this server's IP"
    echo "(same as the main installer required). e.g. hooks.yourdomain.top"
    local domain
    while true; do
        read -rp "Subdomain: " domain
        [[ -n "$domain" && "$domain" != *"/"* && "$domain" != *" "* ]] && break
        warn "That doesn't look like a bare domain (no spaces or slashes). Try again."
    done

    info "Secret path token"
    echo "The receiver only accepts POSTs to /hook/<this-token>, anything else"
    echo "gets a 404. Keep the default unless you have a reason not to."
    local suggestion token
    suggestion=$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 24)
    [[ -z "$suggestion" ]] && suggestion="hook-${RANDOM}${RANDOM}${RANDOM}"
    read -rp "Token [Enter to use '$suggestion']: " token
    token="${token:-$suggestion}"

    info "Where should received events go?"
    echo "This relays every incoming event to an ntfy.sh topic (same idea as"
    echo "the watchdog script, if you've set that up you can reuse a topic"
    echo "or use a separate one)."
    local ntfy_server ntfy_topic
    read -rp "ntfy server [Enter for https://ntfy.sh]: " ntfy_server
    ntfy_server="${ntfy_server:-https://ntfy.sh}"
    read -rp "ntfy topic name: " ntfy_topic
    [[ -n "$ntfy_topic" ]] || error "A topic name is required, that's what your phone subscribes to."

    {
        echo "DOMAIN=$domain"
        echo "WEBHOOK_TOKEN=$token"
        echo "NTFY_SERVER=$ntfy_server"
        echo "NTFY_TOPIC=$ntfy_topic"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    write_compose
    write_caddy_snippet "$domain"

    echo ""
    echo "Full webhook URL to paste into the site's webhook field:"
    echo -e "\033[1;36mhttps://${domain}/hook/${token}\033[0m"
    echo ""
    echo "Make sure you're subscribed to ntfy topic '$ntfy_topic' on your"
    echo "phone/browser before testing (visit ${ntfy_server}/${ntfy_topic} or"
    echo "use the ntfy app), same as any other ntfy topic."

    # Bug fix: a container already running from a previous configure/start
    # keeps its OLD environment (token/topic/etc) baked in until recreated.
    # Without this, the config file and Caddy snippet update immediately but
    # the running container silently keeps answering to the stale token,
    # which looks like a broken test with no obvious cause. Apply it now
    # instead of leaving that gap for Start to (maybe) close later.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        info "Applying the new settings to the running relay container"
        (cd "$STATE_DIR" && WEBHOOK_TOKEN="$token" NTFY_SERVER="$ntfy_server" NTFY_TOPIC="$ntfy_topic" docker compose -f "$RELAY_COMPOSE" up -d)
        restart_caddy_to_pick_up_dropin
        echo "Applied. The URL above is live now."
    else
        echo ""
        echo "Relay isn't running yet, run option 2 (Start) next to bring it up with these settings."
    fi
}

do_start() {
    [[ -f "$CONFIG_FILE" ]] || do_configure
    # Rewritten every Start (not just Reconfigure), so pulling a newer
    # setup-webhook.sh and running Start is enough to pick up code changes,
    # no need to re-answer the Reconfigure prompts just to refresh the app.
    ensure_caddy_dropin_dir
    ensure_shared_network
    write_app_script
    write_compose
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    export WEBHOOK_TOKEN NTFY_SERVER NTFY_TOPIC
    (cd "$STATE_DIR" && docker compose -f "$RELAY_COMPOSE" up -d --force-recreate)
    restart_caddy_to_pick_up_dropin
    info "Webhook relay running. It can take a minute for the HTTPS cert on the new subdomain to issue."
    echo "URL: https://${DOMAIN}/hook/${WEBHOOK_TOKEN}"
}

do_stop() {
    [[ -f "$RELAY_COMPOSE" ]] || error "Not set up yet."
    (cd "$STATE_DIR" && docker compose -f "$RELAY_COMPOSE" down)
    echo "Stopped. Config, token, and event history are kept. Start picks up where it left off."
}

do_status() {
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        echo "Domain:       ${DOMAIN:-unset}"
        echo "Webhook URL:  https://${DOMAIN:-<domain>}/hook/${WEBHOOK_TOKEN:-<token>}"
        echo "ntfy target:  ${NTFY_SERVER:-unset}/${NTFY_TOPIC:-unset}"
    else
        echo "Not configured yet."
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        echo "Relay:        RUNNING"
    else
        echo "Relay:        STOPPED"
    fi
    if [[ -f "$EVENTS_LOG" ]]; then
        echo ""
        echo "Last 5 events:"
        tail -n 5 "$EVENTS_LOG" 2>/dev/null || echo "  (none yet)"
    fi
}

do_view_events() {
    [[ -f "$EVENTS_LOG" ]] || { echo "No events yet."; return; }
    echo ""
    tail -n 30 "$EVENTS_LOG"
}

do_test_event() {
    [[ -f "$CONFIG_FILE" ]] || error "Not configured yet, run Start first."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" || \
        error "Relay isn't running. Start it first (option 2)."
    info "Sending a test POST straight to the container (bypasses Caddy/DNS, just checks the relay + ntfy forward)."
    if docker exec "$CONTAINER_NAME" python3 -c "
import urllib.request
req = urllib.request.Request('http://127.0.0.1:${INTERNAL_PORT}/hook/${WEBHOOK_TOKEN}', data=b'{\"test\":true,\"source\":\"setup-webhook.sh\"}', method='POST')
print(urllib.request.urlopen(req, timeout=5).status)
" ; then
        echo "Sent. Check your ntfy topic ('$NTFY_TOPIC') and/or option 5 (View recent events)."
    else
        warn "Couldn't send the test request. Check option 1 (Status) for whether the relay is actually running."
    fi
}

do_uninstall() {
    warn "This stops and removes the webhook relay container, its Caddy site, and saved config (including your token and event history)."
    read -rp "Continue? [y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|Yes) ;;
        *) echo "Cancelled."; return ;;
    esac
    [[ -f "$RELAY_COMPOSE" ]] && (cd "$STATE_DIR" && docker compose -f "$RELAY_COMPOSE" down 2>/dev/null || true)
    rm -f "$CADDY_SNIPPET"
    restart_caddy_to_pick_up_dropin
    rm -rf "$STATE_DIR"
    echo "Done. Running this script again starts fresh from first-time setup."
}

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash setup-webhook.sh"
command -v docker >/dev/null || error "Docker not found. Run this on the same server as setup-aiostreams.sh."

# Bug fix: same reasoning as the equivalent block in setup-watchdog.sh, under
# sudo $INSTALL_DIR is root's home, so this keeps future runs finding the
# right copy regardless of where the script was downloaded to.
sync_self_into_install_dir() {
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
    local dest="$INSTALL_DIR/setup-webhook.sh"
    [[ -f "$SELF_SCRIPT_PATH" ]] || return 0
    [[ "$SELF_SCRIPT_PATH" == "$dest" ]] && return 0
    if [[ ! -f "$dest" ]] || ! cmp -s "$SELF_SCRIPT_PATH" "$dest"; then
        if cp -- "$SELF_SCRIPT_PATH" "$dest" 2>/dev/null; then
            chmod +x "$dest" 2>/dev/null || true
            echo "(Synced this script into $INSTALL_DIR/setup-webhook.sh.)"
        fi
    fi
    return 0
}
sync_self_into_install_dir

# Non-interactive entrypoint for setup-aiostreams.sh's restore flow to call,
# same pattern as setup-watchdog.sh's 'install-timer'. Requires an existing
# config (restore only calls this after the config file has already landed
# via the extracted tarball), so this never prompts.
if [[ "${1:-}" == "start-relay" ]]; then
    [[ -f "$CONFIG_FILE" ]] || error "No webhook relay config found at $CONFIG_FILE, nothing to start."
    do_start
    exit 0
fi

while true; do
    echo ""
    echo "=== AIOStreams Webhook Relay ==="
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Reconfigure (change subdomain/token/ntfy target)"
    echo "5) Send test event"
    echo "6) View recent events"
    echo "7) Uninstall"
    echo "8) Exit"
    read -rp "Choose an option [1-8]: " CHOICE

    case "$CHOICE" in
        1) do_status ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_configure ;;
        5) do_test_event ;;
        6) do_view_events ;;
        7) do_uninstall ;;
        8) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
