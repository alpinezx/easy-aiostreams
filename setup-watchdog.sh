#!/usr/bin/env bash

set -euo pipefail

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
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
VPN_ACTIVE_MARKER="$INSTALL_DIR/vpn-state/active"
STATE_DIR="$INSTALL_DIR/watchdog-state"
CONFIG_FILE="$STATE_DIR/config"
FAILCOUNT_FILE="$STATE_DIR/failcount"
ALERTSTATE_FILE="$STATE_DIR/alert-state"
LASTCHECK_FILE="$STATE_DIR/last-check"
EVENTS_FILE="$STATE_DIR/events"     # what happened, newest last: "epoch|kind|text"
TALLY_FILE="$STATE_DIR/tally"       # checks per day: "YYYY-MM-DD passed failed"
ALIVE_FILE="$STATE_DIR/last-alive"  # when the last check ran, to tell how long a reboot took
SCRIPT_COPY="$STATE_DIR/watchdog.sh"
SERVICE_FILE="/etc/systemd/system/aiostreams-watchdog.service"
TIMER_FILE="/etc/systemd/system/aiostreams-watchdog.timer"
BOOT_SERVICE_FILE="/etc/systemd/system/aiostreams-watchdog-boot.service"
WEBHOOK_BOOT_UNIT="aios-webhook-boot-notify.service"

FAIL_THRESHOLD=2        # consecutive failed checks before an alert fires
CHECK_INTERVAL="2min"   # how often the timer runs (display string)
                         # (2 fails x 2min = ~4min worst-case detection lag)
CHECK_INTERVAL_MIN="2"  # same interval, as a bare number of minutes —
                         # feeds the systemd OnCalendar=*:0/N pattern.
                         # Keep this in sync with CHECK_INTERVAL above.

# `docker exec` on a missing container fails too, so this also naturally
# catches gluetun being gone entirely (crashed, force-removed).

STOPPED_MARKER="$INSTALL_DIR/aiostreams-stopped-on-purpose"
MEDIAFLOW_STATE_DIR="$INSTALL_DIR/mediaflow-state"
MEDIAFLOW_STOPPED_MARKER="$MEDIAFLOW_STATE_DIR/stopped-on-purpose"

vpn_mode_on() {
    [[ "$(cat "$VPN_ACTIVE_MARKER" 2>/dev/null)" == "vpn" ]]
}

mediaflow_configured() {
    [[ -f "$MEDIAFLOW_STATE_DIR/config" ]]
}

check_gluetun_tunnel() {
    docker exec gluetun wget -qO- --timeout=5 http://127.0.0.1:9999 >/dev/null 2>&1
}

# Asks from INSIDE gluetun, not from aiostreams itself. That catches two
# things a plain "is the container running" check misses:
#   - aiostreams crashed (in VPN mode it's restart: "no", so nothing
#     brings it back on its own)
#   - gluetun's container restarted and got a fresh network namespace,
#     leaving aiostreams "running" but stranded in the old dead one, so
#     Caddy can't reach it and it has no internet
# Any HTTP answer at all (even a 401/404) means aiostreams is listening in
# gluetun's current namespace. Only "nothing there" counts as down.
check_aiostreams_reachable() {
    local out
    out=$(docker exec gluetun wget -q -O /dev/null -T 5 http://127.0.0.1:3000/ 2>&1) && return 0
    ! grep -qiE "refused|timed out|can't connect|unable to connect|bad address|no route" <<< "$out"
}

aiostreams_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' aiostreams 2>/dev/null)" == "true" ]]
}

# The main site, the first one in the Caddyfile (the add-ons live in caddy.d/).
site_domain() {
    awk 'NF && $1 !~ /^#/ && $2 == "{" {print $1; exit}' "$INSTALL_DIR/Caddyfile" 2>/dev/null || true
}

# Loads the site the way a visitor would, HTTPS and certificate included, but
# through this server's own port 443 (--resolve) rather than DNS, so a DNS
# hiccup elsewhere or a cloud that can't reach its own public IP doesn't
# count as the site being down. Any answer below 500 means it's up (AIOStreams
# answers / with a page or a redirect).
check_site() {
    local domain code rc=0
    domain=$(site_domain)
    [[ -n "$domain" ]] || return 0
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 --resolve "$domain:443:127.0.0.1" "https://$domain/") || rc=$?
    case "$rc" in
        0) ;;
        7) FAIL_REASON="nothing is answering on port 443, so Caddy looks down and https://$domain is unreachable. Fix: sudo bash setup-aiostreams.sh, option 4 (Restart the stack)"; return 1 ;;
        28) FAIL_REASON="https://$domain didn't answer within 15 seconds. Check: docker logs caddy, docker logs aiostreams"; return 1 ;;
        35|51|58|60) FAIL_REASON="the HTTPS certificate for $domain isn't valid (expired, or Caddy couldn't get one). Check: docker logs caddy"; return 1 ;;
        *) FAIL_REASON="https://$domain couldn't be loaded (curl error $rc). Check: docker logs caddy"; return 1 ;;
    esac
    case "$code" in
        502|503|504) FAIL_REASON="https://$domain is up but AIOStreams isn't answering behind it (HTTP $code). Fix: sudo bash setup-aiostreams.sh, option 4 (Restart the stack)"; return 1 ;;
        5??) FAIL_REASON="https://$domain answered with a server error (HTTP $code). Check: docker logs aiostreams"; return 1 ;;
    esac
    return 0
}

# MediaFlow Proxy Light has no published port, so the health check goes
# through the caddy container (same aios_shared network, and its image has
# wget). Caddy being down is checked first, since that takes out the
# public MediaFlow URL and the main site together.
check_mediaflow() {
    if [[ -f "$MEDIAFLOW_STOPPED_MARKER" ]]; then
        if [[ "$(docker inspect -f '{{.State.Running}}' mediaflow-proxy-light 2>/dev/null)" == "true" ]]; then
            rm -f "$MEDIAFLOW_STOPPED_MARKER"
        else
            return 0
        fi
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" != "true" ]]; then
        FAIL_REASON="caddy is NOT running, so the main site and MediaFlow are both unreachable. Fix: sudo bash setup-aiostreams.sh, option 4 (Restart the stack)"
        return 1
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' mediaflow-proxy-light 2>/dev/null)" != "true" ]]; then
        FAIL_REASON="MediaFlow Proxy is NOT running. Fix: sudo bash setup-mediaflow.sh, option 2 (Start)"
        return 1
    fi
    if ! docker exec caddy wget -q -O /dev/null -T 5 http://mediaflow-proxy-light:8888/health >/dev/null 2>&1; then
        FAIL_REASON="MediaFlow Proxy is running but not answering its health check. Check: docker logs mediaflow-proxy-light"
        return 1
    fi
    return 0
}

# Sets FAIL_REASON on failure, for the alert text. The site is checked in
# every mode; the VPN checks only in VPN mode, MediaFlow only if it's set up.
run_checks() {
    FAIL_REASON=""
    if vpn_mode_on && ! check_gluetun_tunnel; then
        FAIL_REASON="gluetun tunnel appears to be DOWN (health check failing)"
        return 1
    fi

    # "Stop AIOStreams" in setup-aiostreams.sh leaves this marker. Honor it
    # only while aiostreams is actually stopped; once anything starts it
    # again, the marker is stale, so clear it and go back to checking.
    local aio_paused=0
    if [[ -f "$STOPPED_MARKER" ]]; then
        if aiostreams_running; then
            rm -f "$STOPPED_MARKER"
        else
            aio_paused=1
        fi
    fi

    if (( ! aio_paused )); then
        if vpn_mode_on; then
            if ! aiostreams_running; then
                FAIL_REASON="aiostreams is NOT running (tunnel is fine). In VPN mode nothing restarts it automatically. Fix: sudo bash setup-aiostreams.sh, option 4 (Restart the stack)"
                return 1
            fi
            if ! check_aiostreams_reachable; then
                FAIL_REASON="aiostreams is running but unreachable through gluetun (likely stranded after a gluetun restart). Fix: sudo bash setup-aiostreams.sh, option 4 (Restart the stack)"
                return 1
            fi
        fi
        check_site || return 1
    fi
    if mediaflow_configured; then
        check_mediaflow || return 1
    fi
    return 0
}

# A short record for "did anything happen overnight?" (the control panel's
# Phone alerts page reads it). Kinds: fail, alert, recovered, start, stop,
# test, topic, reboot. Never holds the topic itself. Keeps the last 200.
log_event() {
    mkdir -p "$STATE_DIR"
    printf '%s|%s|%s\n' "$(date +%s)" "$1" "${2//$'\n'/ }" >> "$EVENTS_FILE"
    if (( $(wc -l < "$EVENTS_FILE") > 220 )); then
        tail -n 200 "$EVENTS_FILE" > "$EVENTS_FILE.tmp" && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
    fi
    return 0
}

# One line per day with how many checks passed and failed. Keeps 14 days.
tally_check() {
    local today passed=0 failed=0 d p f
    today=$(date +%F)
    if [[ -f "$TALLY_FILE" ]] && read -r d p f < <(tail -n 1 "$TALLY_FILE") && [[ "$d" == "$today" ]]; then
        passed=$p failed=$f
        sed -i '$d' "$TALLY_FILE"
    fi
    if [[ "$1" == ok ]]; then passed=$((passed + 1)); else failed=$((failed + 1)); fi
    echo "$today $passed $failed" >> "$TALLY_FILE"
    if (( $(wc -l < "$TALLY_FILE") > 14 )); then
        tail -n 14 "$TALLY_FILE" > "$TALLY_FILE.tmp" && mv "$TALLY_FILE.tmp" "$TALLY_FILE"
    fi
    return 0
}

send_ntfy() {
    local msg="$1" topic
    topic=$(grep -oP 'NTFY_TOPIC=\K.*' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$topic" ]] || { warn "No ntfy topic configured, run Reconfigure first."; return 1; }
    curl -fsS -d "$msg" "https://ntfy.sh/$topic" >/dev/null 2>&1 || { warn "Couldn't reach ntfy.sh."; return 1; }
}

do_run_check() {
    mkdir -p "$STATE_DIR"
    date +%s > "$ALIVE_FILE"

    local fails alert_state
    fails=$(cat "$FAILCOUNT_FILE" 2>/dev/null || echo 0)
    alert_state=$(cat "$ALERTSTATE_FILE" 2>/dev/null || echo "up")

    if run_checks; then
        echo "$(date '+%d %b %Y, %H:%M:%S %Z') OK" > "$LASTCHECK_FILE"
        tally_check ok
        echo 0 > "$FAILCOUNT_FILE"
        if [[ "$alert_state" == "down" ]]; then
            if send_ntfy "✅ AIOStreams: all checks passing again."; then
                log_event recovered "All checks passing again. All-clear sent."
            else
                log_event recovered "All checks passing again. The all-clear couldn't be sent (ntfy.sh unreachable)."
            fi
            echo "up" > "$ALERTSTATE_FILE"
        elif [[ "$fails" -gt 0 ]]; then
            log_event recovered "Passing again before an alert was due, so none was sent."
        fi
    else
        echo "$(date '+%d %b %Y, %H:%M:%S %Z') FAIL: ${FAIL_REASON}" > "$LASTCHECK_FILE"
        tally_check fail
        fails=$((fails + 1))
        echo "$fails" > "$FAILCOUNT_FILE"
        [[ "$fails" -eq 1 && "$alert_state" == "up" ]] && log_event fail "$FAIL_REASON"
        if [[ "$fails" -ge "$FAIL_THRESHOLD" && "$alert_state" == "up" ]]; then
            if send_ntfy "🔴 AIOStreams: ${FAIL_REASON}."; then
                log_event alert "Still failing on the next check. Alert sent."
            else
                log_event alert "Still failing on the next check. The alert couldn't be sent (ntfy.sh unreachable)."
            fi
            echo "down" > "$ALERTSTATE_FILE"
        fi
    fi
}

# "about 4 min", "about 2 h"
rough_duration() {
    local s=$1
    if (( s < 180 )); then echo "a minute or two"
    elif (( s < 5400 )); then echo "about $(( (s + 30) / 60 )) min"
    elif (( s < 172800 )); then echo "about $(( (s + 1800) / 3600 )) h"
    else echo "about $(( (s + 43200) / 86400 )) days"
    fi
}

# Runs once at every boot (aiostreams-watchdog-boot.service), while the
# watchdog is on. How long the server was down comes from the last check
# before it went (they run every couple of minutes), so it's rough.
do_boot() {
    mkdir -p "$STATE_DIR"
    local now boot_at last when down="" sent=0 attempt
    now=$(date +%s)
    boot_at=$(( now - $(cut -d. -f1 /proc/uptime) ))
    last=$(cat "$ALIVE_FILE" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    when=$(date -d "@$boot_at" '+%H:%M')
    (( last > 0 && boot_at > last )) && down=" It was down for $(rough_duration $(( boot_at - last )))."
    # The webhook relay can send its own reboot notification; one is enough
    if systemctl is-enabled --quiet "$WEBHOOK_BOOT_UNIT" 2>/dev/null; then
        log_event reboot "Server restarted at $when.$down The webhook relay sent the notification."
        return 0
    fi
    # A few tries: the network can take a moment after boot
    for attempt in 1 2 3 4 5 6; do
        if send_ntfy "🔄 AIOStreams: the server restarted at $when.$down"; then sent=1; break; fi
        sleep 10
    done
    if (( sent )); then
        log_event reboot "Server restarted at $when.$down Alert sent."
    else
        log_event reboot "Server restarted at $when.$down The alert couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

do_configure() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    info "ntfy.sh alert topic"
    echo "This is just a name, think of it as a private URL. Pick something long"
    echo "and hard to guess (anyone who knows it can see your alerts)."
    # $RANDOM rather than piping /dev/urandom through tr | head. That pipe
    # dies to SIGPIPE the instant head closes it early, and with pipefail
    # on (needed for this script's other error-checking) that silently
    # kills the whole script here with no error message. Not cryptographic,
    # just a convenience suggestion, type your own topic for something
    # stronger.
    local suggestion
    suggestion="aios-${RANDOM}${RANDOM}"
    read -rp "Topic name [Enter to use '$suggestion']: " TOPIC
    TOPIC="${TOPIC:-$suggestion}"

    echo "NTFY_TOPIC=$TOPIC" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo 0 > "$FAILCOUNT_FILE"
    echo "up" > "$ALERTSTATE_FILE"
    log_event topic "Alert topic set."

    info "Sending a test alert"
    echo -e "Subscribe first so you actually see it: open the ntfy app (or visit"
    echo -e "\033[1;36mhttps://ntfy.sh/$TOPIC\033[0m in a browser) and subscribe to topic '$TOPIC'."
    read -rp "Press Enter once you're subscribed and ready... "
    if send_ntfy "🔔 Test alert from AIOStreams watchdog, if you see this, alerts are working."; then
        echo "Sent. Confirm it arrived before continuing."
    else
        warn "Couldn't send it. Check network/DNS, then try option 4 (Send test alert) later."
    fi
}

install_systemd_units() {
    cp "$0" "$SCRIPT_COPY"
    chmod 700 "$SCRIPT_COPY"

    # systemd does NOT set $HOME for root-owned units unless User= is
    # specified. Without this, the script's first line (which builds every
    # path off $HOME) throws "unbound variable" and dies instantly every
    # time the timer fires, with nothing written anywhere to show it even
    # tried. Baking in the real value here (from this interactive, sudo'd
    # run) sidesteps relying on systemd's default environment.
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AIOStreams watchdog check (run by aiostreams-watchdog.timer)

[Service]
Type=oneshot
Environment=HOME=$HOME
ExecStart=/bin/bash $SCRIPT_COPY --run-check
EOF

    # Wall-clock scheduling (OnCalendar) rather than monotonic
    # (OnBootSec/OnUnitActiveSec): monotonic timers rely on the boot-time
    # monotonic clock, which cloud VMs can invalidate via suspend,
    # snapshot/restore, or live migration, and when that happens systemd
    # silently stops scheduling the next run, and only a reboot fixes it.
    # OnCalendar reads the wall clock instead and is immune to that.
    # Also timezone-safe; worst case is one skipped/doubled tick at a
    # clock jump (DST etc.), which self-corrects next cycle.
    #
    # CHECK_INTERVAL_MIN drives the */N pattern below; only whole-minute
    # intervals are supported by this generator.
    cat > "$TIMER_FILE" << EOF
[Unit]
Description=Run the AIOStreams watchdog check every $CHECK_INTERVAL

[Timer]
OnCalendar=*:0/$CHECK_INTERVAL_MIN
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > "$BOOT_SERVICE_FILE" << EOF
[Unit]
Description=AIOStreams watchdog: alert when the server has restarted
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=$HOME
ExecStart=/bin/bash $SCRIPT_COPY --boot

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

do_start() {
    [[ -f "$CONFIG_FILE" ]] || do_configure
    install_systemd_units
    systemctl enable --now aiostreams-watchdog.timer
    systemctl enable aiostreams-watchdog-boot.service >/dev/null 2>&1 || true
    log_event start "Watchdog started."
    info "Watchdog started, checking every $CHECK_INTERVAL (alerts after $FAIL_THRESHOLD consecutive failures)."
}

do_stop() {
    systemctl disable --now aiostreams-watchdog.timer 2>/dev/null || true
    systemctl disable aiostreams-watchdog-boot.service 2>/dev/null || true
    mkdir -p "$STATE_DIR"
    echo "$(date '+%d %b %Y, %H:%M:%S %Z') STOPPED (watchdog disabled, no checks running)" > "$LASTCHECK_FILE"
    log_event stop "Watchdog stopped."
    echo "Watchdog stopped. Config and alert state are kept. Start picks up where it left off."
}

do_status() {
    echo ""
    local running=0
    if systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
        echo "Watchdog:     RUNNING (checking every $CHECK_INTERVAL)"
        running=1
    else
        echo "Watchdog:     STOPPED"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "ntfy topic:   $(grep -oP 'NTFY_TOPIC=\K.*' "$CONFIG_FILE" 2>/dev/null || echo unknown)"
    else
        echo "ntfy topic:   not configured yet"
    fi
    if [[ -f "$LASTCHECK_FILE" ]]; then
        echo "Last check:   $(cat "$LASTCHECK_FILE")"
    fi
    if [[ -f "$ALERTSTATE_FILE" ]]; then
        if [[ "$running" -eq 1 ]]; then
            echo "Alert state: $(cat "$ALERTSTATE_FILE")"
        else
            echo "Alert state: $(cat "$ALERTSTATE_FILE")  (last known, watchdog is stopped, not live)"
        fi
    fi
}

do_test_alert() {
    [[ -f "$CONFIG_FILE" ]] || error "Not configured yet, run Start first."
    if send_ntfy "🔔 Test alert from AIOStreams watchdog."; then
        log_event test "Test alert sent."
        echo "Sent. Check your device."
    else
        log_event test "Test alert couldn't be sent (ntfy.sh unreachable)."
        return 1
    fi
}

# ntfy topics: letters, digits, - and _, up to 64 characters.
valid_topic() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

# Question-free topic change for the control panel. The topic comes in on
# stdin, so it never shows in a process list or the panel's Activity, and
# isn't printed. A test alert goes to the new topic straight away.
do_set_topic() {
    [[ -f "$CONFIG_FILE" ]] || error "Not configured yet. Set the watchdog up over SSH first."
    local topic
    IFS= read -r topic || true
    topic="${topic//[[:space:]]/}"
    valid_topic "$topic" || error "That topic isn't valid: use letters, numbers, - and _ only, up to 64 characters."
    (( ${#topic} >= 12 )) || error "That topic is too short to be private. Use at least 12 characters."
    echo "NTFY_TOPIC=$topic" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_event topic "Alert topic changed."
    echo "Topic saved. Sending a test alert to it..."
    do_test_alert
}

do_uninstall() {
    warn "This removes the watchdog entirely: timer, service, and saved state (including your ntfy topic)."
    read -rp "Continue? [y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|Yes) ;;
        *) echo "Cancelled."; return ;;
    esac
    systemctl disable --now aiostreams-watchdog.timer 2>/dev/null || true
    systemctl disable aiostreams-watchdog-boot.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$BOOT_SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$STATE_DIR"
    echo "Done. Running this script again starts fresh from first-time setup."
}

if [[ "${1:-}" == "--run-check" ]]; then
    do_run_check
    exit 0
fi

if [[ "${1:-}" == "--boot" ]]; then
    do_boot
    exit 0
fi

# Runs the checks once and prints the result, without touching the saved
# state or sending anything. Exit 1 if a check fails.
if [[ "${1:-}" == "check" ]]; then
    if run_checks; then echo "OK"; exit 0; fi
    echo "FAIL: ${FAIL_REASON}"
    exit 1
fi

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash setup-watchdog.sh"
command -v docker    >/dev/null || error "Docker not found. Run this on the same server as setup-aiostreams.sh."
command -v curl      >/dev/null || error "curl not found. Install it first (apt install curl)."
command -v systemctl >/dev/null || error "systemd not found. This script relies on systemd timers."


# Errors out rather than risking a hang on an interactive prompt if the
# config is somehow missing here.
if [[ "${1:-}" == "set-topic" ]]; then
    do_set_topic
    exit $?
fi

if [[ "${1:-}" == "test" ]]; then
    do_test_alert
    exit $?
fi

if [[ "${1:-}" == "install-timer" ]]; then
    [[ -f "$CONFIG_FILE" ]] || error "No watchdog config found at $CONFIG_FILE, nothing to reinstall."
    install_systemd_units
    systemctl enable --now aiostreams-watchdog.timer
    systemctl enable aiostreams-watchdog-boot.service >/dev/null 2>&1 || true
    log_event start "Watchdog started."
    exit 0
fi

while true; do
    echo ""
    echo "=== AIOStreams Watchdog ==="
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Send test alert"
    echo "5) Reconfigure (change ntfy topic)"
    echo "6) Uninstall"
    echo "7) Exit"
    read -rp "Choose an option [1-7]: " CHOICE

    case "$CHOICE" in
        1) do_status ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_test_alert || true ;;
        5) do_configure ;;
        6) do_uninstall ;;
        7) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
