#!/usr/bin/env bash
#
# Maintenance for Easy AIOStreams: the upkeep that's easy to forget.
#
#   sudo bash /opt/aiostreams/setup-maintenance.sh                   menu
#   sudo bash /opt/aiostreams/setup-maintenance.sh free-space        old images, build leftovers, logs
#   sudo bash /opt/aiostreams/setup-maintenance.sh system-updates    install the system's updates
#   sudo bash /opt/aiostreams/setup-maintenance.sh log-limits        cap each container's log at 10 MB
#
# None of the commands ask anything; the control panel's Maintenance page runs
# them. setup-aiostreams.sh's option 11 and its commands of the same names hand
# over to this script, so either way works.

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

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# The VPN-aware start lives in setup-aiostreams.sh: "_ensure-running" brings back
# what should be running after Docker restarts, "_recreate-stack" recreates the
# main stack. An older copy without them would show its menu instead, so it's
# checked first.
main_cmd() {
    local main="$INSTALL_DIR/setup-aiostreams.sh"
    if ! grep -q -- "^    $1)" "$main" 2>/dev/null; then
        warn "setup-aiostreams.sh is older than this script. Update it on the panel's Scripts tab, then start AIOStreams if it's down."
        return 1
    fi
    bash "$main" "$1" < /dev/null
}

bytes() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

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

# (upgradable_now, upgradable_count and reboot_needed are copies of setup-aiostreams.sh's,
# which View status uses. Keep them the same.)
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

# Whether a restart is needed to finish installing updates. Ubuntu writes
# /var/run/reboot-required; Debian doesn't, so a kernel installed since the
# last boot counts too (its file's change time is when it was installed, even
# when an update keeps the same version name). The control panel's Restart
# tile checks the same two things.
reboot_needed() {
    [[ -e /var/run/reboot-required ]] && return 0
    local boot f
    boot=$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)
    [[ "$boot" =~ ^[0-9]+$ ]] || return 1
    for f in /boot/vmlinuz-*; do
        [[ -e "$f" ]] && (( $(stat -c %Z "$f" 2>/dev/null || echo 0) > boot )) && return 0
    done
    return 1
}

# The system's package updates, as "apt upgrade" over SSH would, keeping any config
# file you've changed. If Docker itself was upgraded it restarts every
# container, so the stack is brought back afterwards (the control panel runs
# this outside its own container for the same reason).
do_system_updates() {
    command -v apt-get >/dev/null 2>&1 || error "This server doesn't use apt, so this can't update it."
    export DEBIAN_FRONTEND=noninteractive
    info "Refreshing the package lists"
    apt-get -q -o DPkg::Lock::Timeout=300 update || error "Couldn't refresh the package lists. Nothing was installed."
    info "Installing updates"
    apt-get -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        upgrade --with-new-pkgs || error "The update stopped partway. Run 'sudo apt upgrade' over SSH to see why."
    info "Making sure everything is running"
    main_cmd _ensure-running || warn "AIOStreams didn't come back by itself. Use Start on the Overview, or option 3 in setup-aiostreams.sh."
    echo ""
    if reboot_needed; then
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
        main_cmd _ensure-running || true
        error "The log limits weren't set. Docker is back on its old settings."
    fi
    rm -f "$f.before-log-limits"
    info "Recreating the containers so they take the limit"
    main_cmd _recreate-stack || true
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
    reboot_needed && echo "  A restart is needed to finish installing updates (sudo reboot, when it suits)."
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
        echo "  2) Install updates (the system's, as apt upgrade would)"
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

case "${1:-}" in
    free-space) do_free_space ;;
    system-updates) do_system_updates ;;
    log-limits) do_log_limits ;;
    "") maintenance_menu ;;
    *) error "Unknown command '$1'. Use: free-space, system-updates or log-limits, or nothing for the menu." ;;
esac
exit 0
