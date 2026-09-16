#!/usr/bin/env bash

set -euo pipefail

# Resolved to an absolute path HERE, at the very top, before anything below
# can cd elsewhere, same reasoning as the equivalent line in
# setup-aiostreams.sh and setup-vpn-gluetun.sh.
SELF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

INSTALL_DIR="$HOME/aiostreams"
VPN_ACTIVE_MARKER="$INSTALL_DIR/vpn-state/active"
STATE_DIR="$INSTALL_DIR/watchdog-state"
CONFIG_FILE="$STATE_DIR/config"
FAILCOUNT_FILE="$STATE_DIR/failcount"
ALERTSTATE_FILE="$STATE_DIR/alert-state"
LASTCHECK_FILE="$STATE_DIR/last-check"
SCRIPT_COPY="$STATE_DIR/watchdog.sh"
SERVICE_FILE="/etc/systemd/system/aiostreams-watchdog.service"
TIMER_FILE="/etc/systemd/system/aiostreams-watchdog.timer"

FAIL_THRESHOLD=2        # consecutive failed checks before an alert fires
CHECK_INTERVAL="2min"   # how often the timer runs (display string)
                         # (2 fails x 2min = ~4min worst-case detection lag)
CHECK_INTERVAL_MIN="2"  # same interval, as a bare number of minutes —
                         # feeds the systemd OnCalendar=*:0/N pattern.
                         # Keep this in sync with CHECK_INTERVAL above.

# `docker exec` on a missing container fails too, so this also naturally
# catches gluetun being gone entirely (crashed, force-removed).

check_gluetun_tunnel() {
    docker exec gluetun wget -qO- --timeout=5 http://127.0.0.1:9999 >/dev/null 2>&1
}

run_checks() {
    check_gluetun_tunnel
}

send_ntfy() {
    local msg="$1" topic
    topic=$(grep -oP 'NTFY_TOPIC=\K.*' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$topic" ]] || { warn "No ntfy topic configured, run Reconfigure first."; return 1; }
    curl -fsS -d "$msg" "https://ntfy.sh/$topic" >/dev/null 2>&1 || { warn "Couldn't reach ntfy.sh."; return 1; }
}

do_run_check() {
    mkdir -p "$STATE_DIR"

    # Skip entirely if VPN mode isn't meant to be on, since flipping to direct
    # mode on purpose shouldn't page you.
    if [[ ! -f "$VPN_ACTIVE_MARKER" ]] || [[ "$(cat "$VPN_ACTIVE_MARKER" 2>/dev/null)" != "vpn" ]]; then
        echo "$(date '+%d %b %Y, %H:%M:%S %Z') SKIPPED (VPN mode not active)" > "$LASTCHECK_FILE"
        return 0
    fi

    local fails alert_state
    fails=$(cat "$FAILCOUNT_FILE" 2>/dev/null || echo 0)
    alert_state=$(cat "$ALERTSTATE_FILE" 2>/dev/null || echo "up")

    if run_checks; then
        echo "$(date '+%d %b %Y, %H:%M:%S %Z') OK" > "$LASTCHECK_FILE"
        echo 0 > "$FAILCOUNT_FILE"
        if [[ "$alert_state" == "down" ]]; then
            send_ntfy "✅ AIOStreams: gluetun tunnel is back up." || true
            echo "up" > "$ALERTSTATE_FILE"
        fi
    else
        echo "$(date '+%d %b %Y, %H:%M:%S %Z') FAIL" > "$LASTCHECK_FILE"
        fails=$((fails + 1))
        echo "$fails" > "$FAILCOUNT_FILE"
        if [[ "$fails" -ge "$FAIL_THRESHOLD" && "$alert_state" == "up" ]]; then
            send_ntfy "🔴 AIOStreams: gluetun tunnel appears to be DOWN (health check failing)." || true
            echo "down" > "$ALERTSTATE_FILE"
        fi
    fi
}

do_configure() {
    [[ -f "$VPN_ACTIVE_MARKER" ]] || \
        error "Couldn't find $VPN_ACTIVE_MARKER. Run setup-vpn-gluetun.sh first (this watchdog checks gluetun's tunnel, so the VPN layer needs to exist first)."

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

    systemctl daemon-reload
}

do_start() {
    [[ -f "$CONFIG_FILE" ]] || do_configure
    install_systemd_units
    systemctl enable --now aiostreams-watchdog.timer
    info "Watchdog started, checking every $CHECK_INTERVAL (alerts after $FAIL_THRESHOLD consecutive failures)."
}

do_stop() {
    systemctl disable --now aiostreams-watchdog.timer 2>/dev/null || true
    mkdir -p "$STATE_DIR"
    echo "$(date '+%d %b %Y, %H:%M:%S %Z') STOPPED (watchdog disabled, no checks running)" > "$LASTCHECK_FILE"
    echo "Watchdog stopped. Config and tunnel state are kept. Start picks up where it left off."
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
            echo "Tunnel state: $(cat "$ALERTSTATE_FILE")"
        else
            echo "Tunnel state: $(cat "$ALERTSTATE_FILE")  (last known, watchdog is stopped, not live)"
        fi
    fi
}

do_test_alert() {
    [[ -f "$CONFIG_FILE" ]] || error "Not configured yet, run Start first."
    send_ntfy "🔔 Test alert from AIOStreams watchdog." && echo "Sent. Check your device."
}

do_uninstall() {
    warn "This removes the watchdog entirely: timer, service, and saved state (including your ntfy topic)."
    read -rp "Continue? [y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|Yes) ;;
        *) echo "Cancelled."; return ;;
    esac
    systemctl disable --now aiostreams-watchdog.timer 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
    rm -rf "$STATE_DIR"
    echo "Done. Running this script again starts fresh from first-time setup."
}

if [[ "${1:-}" == "--run-check" ]]; then
    do_run_check
    exit 0
fi

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash setup-watchdog.sh"
command -v docker    >/dev/null || error "Docker not found. Run this on the same server as setup-aiostreams.sh."
command -v curl      >/dev/null || error "curl not found. Install it first (apt install curl)."
command -v systemctl >/dev/null || error "systemd not found. This script relies on systemd timers."

# Bug fix: under sudo, $INSTALL_DIR is root's home, not a non-root sudo
# user's, so a script downloaded into that user's home never lands here,
# and do_restore's lookup checks $INSTALL_DIR first, silently breaking the
# automatic timer reinstall on restore otherwise. Deliberately not called
# on --run-check above, which systemd fires every couple minutes. This is
# the TOP-LEVEL script; separate from install_systemd_units' own copy into
# watchdog-state/, which is what the systemd unit actually executes.
sync_self_into_install_dir() {
    local dest="$INSTALL_DIR/setup-watchdog.sh"
    [[ -f "$SELF_SCRIPT_PATH" ]] || return 0
    [[ "$SELF_SCRIPT_PATH" == "$dest" ]] && return 0
    if [[ ! -f "$dest" ]] || ! cmp -s "$SELF_SCRIPT_PATH" "$dest"; then
        if cp -- "$SELF_SCRIPT_PATH" "$dest" 2>/dev/null; then
            chmod +x "$dest" 2>/dev/null || true
            echo "(Synced this script into $INSTALL_DIR/setup-watchdog.sh. That's the copy future backups/restores will use.)"
        fi
    fi
    return 0
}
sync_self_into_install_dir

# Errors out rather than risking a hang on an interactive prompt if the
# config is somehow missing here.
if [[ "${1:-}" == "install-timer" ]]; then
    [[ -f "$CONFIG_FILE" ]] || error "No watchdog config found at $CONFIG_FILE, nothing to reinstall."
    install_systemd_units
    systemctl enable --now aiostreams-watchdog.timer
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
        4) do_test_alert ;;
        5) do_configure ;;
        6) do_uninstall ;;
        7) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
