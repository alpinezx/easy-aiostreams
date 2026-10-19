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
ALIVE_FILE="$STATE_DIR/last-alive"  # when the last check ran
SHUTDOWN_FILE="$STATE_DIR/shutdown-at"  # written as the server shuts down cleanly
BOOT_ID_FILE="$STATE_DIR/boot-reported" # the kernel's boot ID once that boot is reported
OPTIONS_FILE="$STATE_DIR/options"   # extra alerts: "updates=on", "reboots=on", "scripts=on", "backups=on", "weekly=on", and the
                                    # check-in's "weekly_day=7" (1 Mon .. 7 Sun), "weekly_time=10:15"
                                    # (older copies saved "weekly_hour=10", still read as 10:00)
SCRIPT_COPY="$STATE_DIR/watchdog.sh"
SERVICE_FILE="/etc/systemd/system/aiostreams-watchdog.service"
TIMER_FILE="/etc/systemd/system/aiostreams-watchdog.timer"
BOOT_SERVICE_FILE="/etc/systemd/system/aiostreams-watchdog-boot.service"
WEBHOOK_BOOT_UNIT="aios-webhook-boot-notify.service"

FAIL_THRESHOLD=2        # consecutive failed checks before an alert fires
DISK_WARN_PCT=90        # disk alert at this % used, all-clear once below DISK_CLEAR_PCT
DISK_CLEAR_PCT=85
CERT_WARN_DAYS=10       # Caddy renews well before this (30 days left on a 90-day
                        # certificate, about 15 on a 45-day one), so fewer days
                        # left means renewal has been failing
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
# test, topic, reboot, disk, cert, update, scripts, backup, weekly. Never holds the topic itself. Keeps the last 200.
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

# Disk space and the certificate are warnings, not outages: one alert when
# one goes wrong and one when it's fine again, kept in <name>-state.
# Args: name, now (bad|ok), then for each way: title, message, event text.
flag_change() {
    local f="$STATE_DIR/$1-state" was title msg event prio tags
    was=$(cat "$f" 2>/dev/null || echo ok)
    [[ "$was" == "$2" ]] && return 0
    echo "$2" > "$f"
    if [[ "$2" == bad ]]; then title=$3 msg=$4 event=$5 prio=4 tags=warning
    else title=$6 msg=$7 event=$8 prio=2 tags=white_check_mark
    fi
    local what=alert sent="Alert sent."
    [[ "$2" == ok ]] && what=all-clear sent="All-clear sent."
    if send_ntfy "$msg" "$title" "$prio" "$tags"; then
        log_event "$1" "$event $sent"
    else
        log_event "$1" "$event The $what couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

check_disk() {
    local pct avail free was now
    read -r pct avail < <(df -P -B1 "$INSTALL_DIR" 2>/dev/null | awk 'NR == 2 {sub("%", "", $5); print $5, $4}') || return 0
    [[ "$pct" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] || return 0
    free=$(numfmt --to=iec --suffix=B "$avail" 2>/dev/null || echo "$avail bytes")
    was=$(cat "$STATE_DIR/disk-state" 2>/dev/null || echo ok)
    if (( pct >= DISK_WARN_PCT )); then now=bad
    elif (( pct < DISK_CLEAR_PCT )); then now=ok
    else now=$was
    fi
    flag_change disk "$now" \
        "Disk nearly full" \
        "The server's disk is ${pct}% full (${free} free). Things start failing when it fills. See what's using it: sudo docker system df" \
        "Disk ${pct}% full, ${free} free." \
        "Disk space is fine again" \
        "${pct}% used, ${free} free." \
        "Disk back to ${pct}% used, ${free} free."
}

# Every 6 hours is plenty: Caddy renews weeks ahead. Asks this server's own
# port 443, like the site check. A certificate that's already broken is the
# site check's job.
check_cert() {
    local stamp="$STATE_DIR/cert-checked" domain end days
    if [[ -f "$stamp" ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 21600 )); then return 0; fi
    touch "$stamp"
    domain=$(site_domain)
    [[ -n "$domain" ]] || return 0
    end=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$domain" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || true
    [[ -n "$end" ]] || return 0
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    flag_change cert "$( (( days < CERT_WARN_DAYS )) && echo bad || echo ok)" \
        "Certificate not renewing" \
        "The HTTPS certificate for $domain runs out in $days days and Caddy hasn't renewed it. Check: docker logs caddy" \
        "The certificate for $domain runs out in $days days and hasn't been renewed." \
        "Certificate renewed" \
        "The HTTPS certificate for $domain was renewed ($days days left)." \
        "Certificate for $domain renewed, $days days left."
}

# The control panel's address, if it's installed, for the alert's
# "Open panel" button (its Phone alerts page).
panel_domain() {
    awk 'NF && $1 !~ /^#/ && $2 == "{" {print $1; exit}' "$INSTALL_DIR/caddy.d/60-ui.caddy" 2>/dev/null || true
}

# send_ntfy <message> [title] [priority 1-5] [tags] [panel page, default alerts]
# The tags are ntfy's emoji names, shown before the title. Priority 5 makes
# the phone sound even on silent-ish settings, 2 arrives quietly.
# Saves one setting in the options file (the panel writes the same lines)
set_option() {
    local k=$1 v=$2
    [[ "$v" =~ ^[0-9]+$ ]] && v=$((10#$v))     # "07" -> 7: bash would read 07 as octal, and 08 not at all
    if [[ "$k" == weekly_hour ]]; then k=weekly_time; v=$(printf '%02d:00' "$v"); fi
    if [[ "$k" == weekly_time ]]; then v=$(printf '%02d:%02d' "$((10#${v%%:*}))" "$((10#${v##*:}))"); fi
    mkdir -p "$STATE_DIR"
    # a new time replaces an older copy's weekly_hour; anything else leaves it be
    local drop="^$k="
    [[ "$k" == weekly_time ]] && drop="^(weekly_time|weekly_hour)="
    { grep -v -E "$drop" "$OPTIONS_FILE" 2>/dev/null || true; echo "$k=$v"; } > "$OPTIONS_FILE.tmp" \
        && mv "$OPTIONS_FILE.tmp" "$OPTIONS_FILE"
    echo "$k is now $v."
}

option_on() {
    grep -qx "$1=on" "$OPTIONS_FILE" 2>/dev/null
}

# Restart alerts are off for new setups (do_configure saves reboots=off). A
# watchdog set up before the switch existed has no line at all, and keeps
# the alerts it already sent.
reboots_on() {
    ! grep -qx "reboots=off" "$OPTIONS_FILE" 2>/dev/null
}

# The AIOStreams channel this server follows, from its image tag: stable
# (latest), nightly, or nothing for a pinned version
aio_channel() {
    case "$(grep -oP '^\s*image:\s*viren070/aiostreams:\K\S+' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | head -n 1)" in
        latest) echo stable ;;
        nightly) echo nightly ;;
    esac
}

# Optional, off until switched on (the control panel's Phone alerts page, or
# set-option). Follows the server's channel: one alert per stable release, or
# per nightly build on nightly (those come out daily or more, which nightly
# users opt into). Asks GitHub every 6 hours, so at most 4 a day.
check_updates() {
    option_on updates || return 0
    local stamp="$STATE_DIR/update-checked" latest running node channel what
    if [[ -f "$stamp" ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 21600 )); then return 0; fi
    touch "$stamp"
    channel=$(aio_channel)
    [[ -n "$channel" ]] || return 0
    # The image is distroless: node is at /nodejs/bin/node (plain node on older images)
    if [[ "$channel" == stable ]]; then
        latest=$(curl -fsS -m 15 https://api.github.com/repos/viren070/aiostreams/releases/latest 2>/dev/null \
            | grep -oP '"tag_name":\s*"\Kv[0-9]+\.[0-9]+\.[0-9]+(?=")' | head -n 1) || true
        [[ -n "$latest" ]] || return 0
        for node in /nodejs/bin/node node; do
            running=$(docker exec aiostreams "$node" -p "require('/app/package.json').version" 2>/dev/null) && break
        done
        [[ "$running" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 0
        running="v$running"
        [[ "$running" == "$latest" ]] && return 0
        [[ "$(printf '%s\n%s\n' "$running" "$latest" | sort -V | tail -n 1)" == "$latest" ]] || return 0
        what="AIOStreams $latest is out"
    else
        # Nightly tags are timestamps (2026.10.18.1200-nightly), so text order is time order
        latest=$(curl -fsS -m 15 "https://api.github.com/repos/viren070/aiostreams/releases?per_page=30" 2>/dev/null \
            | grep -oP '"tag_name":\s*"\K[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}-nightly(?=")' | sort | tail -n 1) || true
        [[ -n "$latest" ]] || return 0
        for node in /nodejs/bin/node node; do
            running=$(docker exec aiostreams "$node" -p "require('/app/resources/metadata.json').tag" 2>/dev/null) && break
        done
        [[ "$running" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}-nightly$ ]] || return 0
        [[ "$latest" > "$running" ]] || return 0
        what="A new AIOStreams nightly ($latest) is out"
    fi
    [[ "$(cat "$STATE_DIR/update-notified" 2>/dev/null)" == "$latest" ]] && return 0
    echo "$latest" > "$STATE_DIR/update-notified"
    local how="Update with: sudo bash setup-aiostreams.sh, option 5."
    [[ -n "$(panel_domain)" ]] && how="Use Open panel, then Update on the Overview (it offers a backup first)."
    if send_ntfy "$what; this server runs $running. $how" \
        "Update available" 3 package overview; then
        log_event update "$what (this server runs $running). Alert sent."
    else
        log_event update "$what (this server runs $running). The alert couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

# The branch the control panel follows for its updates (main, or dev while
# testing), so the comparison matches its Scripts tab; main without a panel
script_branch() {
    local b
    b=$(grep -oP 'UI_UPDATE_BRANCH=\K[A-Za-z0-9._/-]+' "$INSTALL_DIR/ui-state/docker-compose.yml" 2>/dev/null | head -n 1)
    echo "${b:-main}"
}

# Git's blob hash of a file, as GitHub lists it: sha1 of "blob <size>\0" + the bytes
blob_sha() {
    { printf 'blob %d\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -c1-40
}

# Optional, off until switched on. Every 6 hours, compares the setup-*.sh
# scripts here with GitHub's copies (as the panel's Scripts tab does). One
# alert per new set of differences, and at most one a day: scripts can
# change several times a week. "Differs", not "out of date": a hash can't
# tell older from newer.
check_scripts() {
    option_on scripts || return 0
    local stamp="$STATE_DIR/scripts-checked" sent="$STATE_DIR/scripts-sent" noted="$STATE_DIR/scripts-notified"
    local branch listing name sha f key="" names=() n msg how
    if [[ -f "$stamp" ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 21600 )); then return 0; fi
    touch "$stamp"
    branch=$(script_branch)
    listing=$(curl -fsS -m 15 "https://api.github.com/repos/alpinezx/easy-aiostreams/contents/?ref=$branch" 2>/dev/null \
        | grep -oP '"(name|sha)":\s*"\K[^"]+') || return 0
    # The listing comes as name, sha, name, sha...
    declare -A remote=()
    while read -r name && read -r sha; do remote[$name]=$sha; done <<< "$listing"
    for f in "$INSTALL_DIR"/setup-*.sh; do
        [[ -f "$f" ]] || continue
        name=${f##*/}
        [[ -n "${remote[$name]:-}" ]] || continue
        if [[ "$(blob_sha "$f")" != "${remote[$name]}" ]]; then
            names+=("$name")
            key+="$name:${remote[$name]} "
        fi
    done
    if (( ${#names[@]} == 0 )); then rm -f "$noted"; return 0; fi
    [[ "$(cat "$noted" 2>/dev/null)" == "$key" ]] && return 0
    if [[ -f "$sent" ]] && (( $(date +%s) - $(stat -c %Y "$sent") < 86400 )); then return 0; fi
    echo "$key" > "$noted"
    touch "$sent"
    n=${#names[@]}
    if (( n == 1 )); then msg="${names[0]} differs from GitHub's copy"
    else msg="$n scripts differ from GitHub's copies: $(IFS=,; echo "${names[*]}" | sed 's/,/, /g')"
    fi
    [[ "$branch" == main ]] || msg+=" ($branch branch)"
    msg+="."
    how="Download $( (( n == 1 )) && echo it || echo them) again with the command in $( (( n == 1 )) && echo its || echo their) guide."
    [[ -n "$(panel_domain)" ]] && how="Use Open panel, then Update on the Scripts tab."
    if send_ntfy "$msg $how" "Script updates" 2 page_facing_up scripts; then
        log_event scripts "$msg Alert sent."
    else
        log_event scripts "$msg The alert couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

# Scheduled backups (setup-backup.sh's timer) leave how they went in
# backup-last-run: "epoch|ok|text", or skipped, failed, or running while one
# is being made. A failed or skipped one always alerts, since that's what
# makes a schedule safe to forget; a good one only with "backups=on". One
# still "running" after an hour stopped without saying why.
check_backup() {
    local f="$INSTALL_DIR/backup-last-run" seen="$STATE_DIR/backup-seen" at status text last now title
    [[ -f "$f" ]] || return 0
    IFS='|' read -r at status text < "$f" || return 0
    [[ "$at" =~ ^[0-9]+$ ]] || return 0
    now=$(date +%s)
    last=$(cat "$seen" 2>/dev/null || echo "")
    # The first look only reports a run from the last few minutes, not old news
    [[ "$last" =~ ^[0-9]+$ ]] || last=$(( now - 600 ))
    (( at > last )) || return 0
    if [[ "$status" == running ]]; then
        (( now - at > 3600 )) || return 0
        status=failed
    fi
    echo "$at" > "$seen"
    case "$status" in
        ok)
            if ! option_on backups; then
                log_event backup "Scheduled backup made: $text"
            elif send_ntfy "$text" "Backup made" 2 floppy_disk backups; then
                log_event backup "Scheduled backup made: $text Alert sent."
            else
                log_event backup "Scheduled backup made: $text The alert couldn't be sent (ntfy.sh unreachable)."
            fi
            return 0
            ;;
        skipped) title="Scheduled backup skipped" ;;
        *) title="Scheduled backup failed" ;;
    esac
    if send_ntfy "$text" "$title" 4 warning backups; then
        log_event backup "$title: $text Alert sent."
    else
        log_event backup "$title: $text The alert couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

# How old the newest backup on this server is ("today", "3 days old"), or nothing
newest_backup_age() {
    local newest days
    newest=$( { find "$(getent passwd root | cut -d: -f6)" -maxdepth 1 -type f -name 'aiostreams-backup-*.tar.gz' -printf '%T@\n'
                find /home -mindepth 2 -maxdepth 2 -type f -name 'aiostreams-backup-*.tar.gz' -printf '%T@\n'; } 2>/dev/null \
              | sort -rn | head -n 1 | cut -d. -f1)
    [[ "$newest" =~ ^[0-9]+$ ]] || return 0
    days=$(( ( $(date +%s) - newest ) / 86400 ))
    if (( days == 0 )); then echo "today"
    elif (( days == 1 )); then echo "1 day old"
    else echo "$days days old"
    fi
}

weekly_day() {
    grep -oP '^weekly_day=\K[1-7]$' "$OPTIONS_FILE" 2>/dev/null || echo 7
}

# HH:MM, from weekly_time, or an older weekly_hour, or 10:00
weekly_time() {
    local t h
    t=$(grep -oP '^weekly_time=\K([01][0-9]|2[0-3]):[0-5][0-9]$' "$OPTIONS_FILE" 2>/dev/null) && { echo "$t"; return; }
    h=$(grep -oP '^weekly_hour=\K([01]?[0-9]|2[0-3])$' "$OPTIONS_FILE" 2>/dev/null) && { printf '%02d:00\n' "$((10#$h))"; return; }
    echo "10:00"
}

# Optional weekly check-in (Sundays from 10:00 unless set otherwise, by the
# server's clock): the week's checks, alerts and disk space. Each check looks
# whether it's due, so any day and hour works. If it ever stops arriving, the
# watchdog itself needs a look.
check_weekly() {
    option_on weekly || return 0
    local now last since passed=0 failed=0 alerts=0 reboots=0 d p f at kind pct msg wday wtime age
    now=$(date +%s)
    wday=$(weekly_day)
    wtime=$(weekly_time)
    # due from that minute on (the first check at or after it, so within 2 minutes)
    (( 10#$(date +%H) * 60 + 10#$(date +%M) >= 10#${wtime%%:*} * 60 + 10#${wtime##*:} )) || return 0
    [[ "$(date +%u)" == "$wday" ]] || return 0
    last=$(cat "$STATE_DIR/weekly-sent" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last > 6 * 86400 )) || return 0
    echo "$now" > "$STATE_DIR/weekly-sent"
    since=$(date -d '6 days ago' +%F)
    while read -r d p f; do
        [[ "$d" > "$since" || "$d" == "$since" ]] || continue
        passed=$((passed + p)); failed=$((failed + f))
    done < <(cat "$TALLY_FILE" 2>/dev/null)
    while IFS='|' read -r at kind _; do
        [[ "$at" =~ ^[0-9]+$ ]] && (( now - at < 7 * 86400 )) || continue
        [[ "$kind" == alert ]] && alerts=$((alerts + 1))
        [[ "$kind" == reboot ]] && reboots=$((reboots + 1))
    done < <(cat "$EVENTS_FILE" 2>/dev/null)
    pct=$(df -P "$INSTALL_DIR" 2>/dev/null | awk 'NR == 2 {print $5}')
    msg="Last 7 days: $((passed + failed)) check$( (( passed + failed == 1 )) || echo s)"
    (( failed )) && msg+=", $failed failed" || msg+=", all passed"
    (( alerts )) && msg+=", $alerts alert$( (( alerts > 1 )) && echo s) sent" || msg+=", no alerts"
    (( reboots )) && msg+=", $reboots restart$( (( reboots > 1 )) && echo s)"
    msg+="."
    [[ -n "$pct" ]] && msg+=" Disk ${pct} used."
    age=$(newest_backup_age)
    [[ -n "$age" ]] && msg+=" Newest backup: $age."
    if send_ntfy "$msg" "Weekly check-in" 2 calendar; then
        log_event weekly "$msg Sent."
    else
        log_event weekly "$msg Couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

send_ntfy() {
    local msg="$1" title="${2:-AIOStreams}" prio="${3:-3}" tags="${4:-}" page="${5:-alerts}" topic panel
    topic=$(grep -oP 'NTFY_TOPIC=\K.*' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$topic" ]] || { warn "No ntfy topic configured, run Reconfigure first."; return 1; }
    local args=(-fsS -m 15 -H "Title: $title" -H "Priority: $prio")
    [[ -n "$tags" ]] && args+=(-H "Tags: $tags")
    panel=$(panel_domain)
    # A button under the alert rather than a tap action, so tapping the alert just opens it in ntfy
    [[ -n "$panel" ]] && args+=(-H "Actions: view, Open panel, https://$panel/#$page")
    curl "${args[@]}" -d "$msg" "https://ntfy.sh/$topic" >/dev/null 2>&1 || { warn "Couldn't reach ntfy.sh."; return 1; }
}

do_run_check() {
    mkdir -p "$STATE_DIR"
    # Just after a boot the containers are still starting: a check now would
    # only log a failure that isn't one. The next check, 2 minutes on, counts.
    (( $(cut -d. -f1 /proc/uptime) >= 120 )) || return 0
    date +%s > "$ALIVE_FILE"

    local fails alert_state
    fails=$(cat "$FAILCOUNT_FILE" 2>/dev/null || echo 0)
    alert_state=$(cat "$ALERTSTATE_FILE" 2>/dev/null || echo "up")

    if run_checks; then
        echo "$(date '+%d %b %Y, %H:%M:%S %Z') OK" > "$LASTCHECK_FILE"
        tally_check ok
        echo 0 > "$FAILCOUNT_FILE"
        if [[ "$alert_state" == "down" ]]; then
            if send_ntfy "All checks passing again." "AIOStreams is back" 3 white_check_mark; then
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
            if send_ntfy "${FAIL_REASON}." "AIOStreams is down" 5 rotating_light; then
                log_event alert "Still failing on the next check. Alert sent."
            else
                log_event alert "Still failing on the next check. The alert couldn't be sent (ntfy.sh unreachable)."
            fi
            echo "down" > "$ALERTSTATE_FILE"
        fi
    fi

    check_disk || true
    check_cert || true
    check_updates || true
    check_scripts || true
    check_backup || true
    check_weekly || true
}

# "7 seconds", "about 4 min", "about 2 h"
rough_duration() {
    local s=$1
    if (( s < 90 )); then echo "$s second$( (( s == 1 )) || echo s)"
    elif (( s < 5400 )); then echo "about $(( (s + 30) / 60 )) min"
    elif (( s < 172800 )); then echo "about $(( (s + 1800) / 3600 )) h"
    else echo "about $(( (s + 43200) / 86400 )) days"
    fi
}

# aiostreams-watchdog-boot.service stays "active" from boot to shutdown, so
# systemd runs --shutdown as the server goes down cleanly. Its timestamp
# tells the next boot exactly how long the server was off.
do_shutdown() {
    mkdir -p "$STATE_DIR"
    date +%s > "$SHUTDOWN_FILE"
}

# Runs at every boot while the watchdog is on. A clean shutdown left its
# time behind; without one (a crash, a power cut, a forced reset by the
# host) the last check, from at most a couple of minutes before, says when
# it was last seen. Only alerts once per boot, and only in its first 15
# minutes, so starting the unit by hand (Start, a restore) sends nothing.
do_boot() {
    mkdir -p "$STATE_DIR"
    local now up boot_at last shut when down="" sent=0 attempt boot_id
    now=$(date +%s)
    up=$(cut -d. -f1 /proc/uptime)
    boot_at=$(( now - up ))
    shut=$(cat "$SHUTDOWN_FILE" 2>/dev/null || echo 0)
    rm -f "$SHUTDOWN_FILE"
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
    [[ "$(cat "$BOOT_ID_FILE" 2>/dev/null)" == "$boot_id" ]] && return 0
    echo "$boot_id" > "$BOOT_ID_FILE"
    (( up < 900 )) || return 0
    last=$(cat "$ALIVE_FILE" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( last < boot_at )) || last=0   # a check from this boot says nothing about the last one
    [[ "$shut" =~ ^[0-9]+$ ]] || shut=0
    when=$(date -d "@$boot_at" '+%H:%M')
    if (( shut > 0 && shut <= boot_at && shut >= last )); then
        down=" after a clean shutdown. It was down for $(rough_duration $(( boot_at - shut )))"
    elif (( last > 0 && last < boot_at )); then
        down=" without a clean shutdown (a crash or power cut?). It was last seen at $(date -d "@$last" '+%H:%M')"
    fi
    # The webhook relay can send its own reboot notification; one is enough
    if systemctl is-enabled --quiet "$WEBHOOK_BOOT_UNIT" 2>/dev/null; then
        log_event reboot "Server restarted at $when$down. The webhook relay sent the notification."
        return 0
    fi
    if ! reboots_on; then
        log_event reboot "Server restarted at $when$down. No alert: restart alerts are off."
        return 0
    fi
    # A few tries: the network can take a moment after boot
    for attempt in 1 2 3 4 5 6; do
        if send_ntfy "The server restarted at $when$down." "Server restarted" 3 arrows_counterclockwise; then sent=1; break; fi
        sleep 10
    done
    if (( sent )); then
        log_event reboot "Server restarted at $when$down. Alert sent."
    else
        log_event reboot "Server restarted at $when$down. The alert couldn't be sent (ntfy.sh unreachable)."
    fi
    return 0
}

# A topic that's hard to guess but easy to read back, like the control panel's:
# aios-xxxx-xxxx-xxxx from 31 letters and digits with no look-alikes. od reads
# exactly 12 bytes, so nothing closes a pipe early (with pipefail on, a
# "tr | head" pipe would kill the script here).
suggest_topic() {
    local abc=abcdefghjkmnpqrstuvwxyz23456789 out="" n=0 b
    for b in $(od -An -N12 -tu1 /dev/urandom); do
        out+=${abc:$(( b % 31 )):1}
        n=$((n + 1))
        if (( n % 4 == 0 && n < 12 )); then out+="-"; fi
    done
    echo "aios-$out"
}

# Sets TOPIC, asking again until it's one ntfy accepts. Returns 1 if the
# input ends (Ctrl+D) so nothing is saved.
ask_topic() {
    local suggestion
    suggestion=$(suggest_topic)
    while true; do
        read -rp "Topic name [Enter to use '$suggestion']: " TOPIC || { echo; return 1; }
        TOPIC="${TOPIC:-$suggestion}"
        TOPIC="${TOPIC//[[:space:]]/}"
        if ! valid_topic "$TOPIC"; then
            warn "Letters, numbers, - and _ only (no #, spaces or other symbols), up to 64 characters."
        elif (( ${#TOPIC} < 12 )); then
            warn "At least 12 characters, so nobody can guess it."
        else
            return 0
        fi
    done
}

# The topic with most of it hidden: it works like a password
mask_topic() {
    local t=$1
    if (( ${#t} >= 10 )); then echo "${t:0:5}••••••${t: -2}"; else echo "••••••••"; fi
}

do_configure() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    info "ntfy.sh alert topic"
    echo "This is just a name, think of it as a private URL. Pick something long"
    echo "and hard to guess (anyone who knows it can see your alerts)."
    ask_topic || return 0

    # A first setup starts with restart alerts off, like the other extra alerts
    [[ -f "$CONFIG_FILE" ]] || grep -q '^reboots=' "$OPTIONS_FILE" 2>/dev/null || set_option reboots off >/dev/null
    echo "NTFY_TOPIC=$TOPIC" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo 0 > "$FAILCOUNT_FILE"
    echo "up" > "$ALERTSTATE_FILE"
    log_event topic "Alert topic set."

    info "Sending a test alert"
    echo -e "Subscribe first so you actually see it: open the ntfy app (or visit"
    echo -e "\033[1;36mhttps://ntfy.sh/$TOPIC\033[0m in a browser) and subscribe to topic '$TOPIC'."
    read -rp "Press Enter once you're subscribed and ready... "
    if send_ntfy "If you see this, alerts are working." "Test alert" 3 bell; then
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
# At boot the timer's catch-up check would otherwise run alongside the
# restart report and overwrite "last seen" before the report reads it
After=aiostreams-watchdog-boot.service

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
RemainAfterExit=yes
Environment=HOME=$HOME
ExecStart=/bin/bash $SCRIPT_COPY --boot
ExecStop=/bin/bash $SCRIPT_COPY --shutdown

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

do_start() {
    [[ -f "$CONFIG_FILE" ]] || do_configure
    install_systemd_units
    systemctl enable --now aiostreams-watchdog.timer
    systemctl start --no-block aiostreams-watchdog.service 2>/dev/null || true   # the first check now, not in up to 2 minutes
    systemctl enable aiostreams-watchdog-boot.service >/dev/null 2>&1 || true
    systemctl start aiostreams-watchdog-boot.service >/dev/null 2>&1 || true   # records this boot's shutdown; sends nothing now
    log_event start "Watchdog started."
    info "Watchdog started, checking every $CHECK_INTERVAL (alerts after $FAIL_THRESHOLD consecutive failures)."
}

do_stop() {
    systemctl disable --now aiostreams-watchdog.timer 2>/dev/null || true
    systemctl disable --now aiostreams-watchdog-boot.service 2>/dev/null || true
    mkdir -p "$STATE_DIR"
    echo "$(date '+%d %b %Y, %H:%M:%S %Z') STOPPED (watchdog disabled, no checks running)" > "$LASTCHECK_FILE"
    log_event stop "Watchdog stopped."
    echo "Watchdog stopped. Config and alert state are kept. Start picks up where it left off."
}

server_timezone() {
    local tz
    tz=$(readlink -f /etc/localtime 2>/dev/null) || true
    tz=${tz##*/zoneinfo/}
    echo "${tz:-$(date +%Z)}"
}

DAY_NAMES=(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

extras_line() {
    local u w r sc
    option_on updates && u="on" || u="off"
    reboots_on && r="on" || r="off"
    option_on scripts && sc="on" || sc="off"
    if option_on weekly; then
        w="on, ${DAY_NAMES[$(( $(weekly_day) - 1 ))]}s from $(weekly_time) ($(server_timezone))"
    else
        w="off"
    fi
    echo "new releases $u; restarts $r; script updates $sc; weekly check-in $w"
}

# One square per day for the last 14: green all passed, amber some failed, grey no checks
days_strip() {
    local n d line p f out=""
    for n in 13 12 11 10 9 8 7 6 5 4 3 2 1 0; do
        d=$(date -d "$n days ago" +%F)
        line=$(grep -m1 "^$d " "$TALLY_FILE" 2>/dev/null) || line=""
        read -r _ p f <<< "$line"
        if [[ -z "$line" || $(( ${p:-0} + ${f:-0} )) -eq 0 ]]; then out+=$'\033[2m■\033[0m'
        elif (( f > 0 )); then out+=$'\033[33m■\033[0m'
        else out+=$'\033[32m■\033[0m'
        fi
    done
    echo -e "$out"
}

today_line() {
    local line p f n
    line=$(grep -m1 "^$(date +%F) " "$TALLY_FILE" 2>/dev/null) || { echo "no checks yet"; return; }
    read -r _ p f <<< "$line"
    n=$((p + f))
    if (( f )); then echo "$n check$( (( n == 1 )) || echo s), $f failed"
    else echo "$n check$( (( n == 1 )) || echo s), all passed"
    fi
}

do_status() {
    echo ""
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Not set up yet. Choose 2) Start."
        return
    fi
    local running=0 last watches warns=()
    systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null && running=1
    if (( running )); then
        echo "Watchdog:      running, checks every $CHECK_INTERVAL_MIN min (alert after $FAIL_THRESHOLD failed in a row)"
    else
        echo "Watchdog:      STOPPED, no checks running"
    fi
    watches="https://$(site_domain), disk space, HTTPS certificate"
    vpn_mode_on && watches+=", VPN tunnel, AIOStreams through the VPN"
    mediaflow_configured && watches+=", MediaFlow Proxy"
    echo "Watches:       $watches"
    if [[ -f "$LASTCHECK_FILE" ]]; then
        last=$(cat "$LASTCHECK_FILE")
        echo "Last check:    $last"
    fi
    [[ "$(cat "$ALERTSTATE_FILE" 2>/dev/null)" == down ]] && echo "Alert state:   DOWN, alert sent, waiting for it to recover"
    [[ "$(cat "$STATE_DIR/disk-state" 2>/dev/null)" == bad ]] && warns+=("disk nearly full")
    [[ "$(cat "$STATE_DIR/cert-state" 2>/dev/null)" == bad ]] && warns+=("certificate not renewing")
    (( ${#warns[@]} )) && echo "Warnings:      ${warns[*]}"
    echo "Today:         $(today_line)"
    echo "Last 14 days:  $(days_strip)"
    echo "Alert topic:   $(mask_topic "$(grep -oP 'NTFY_TOPIC=\K.*' "$CONFIG_FILE" 2>/dev/null)")"
    echo "Extra alerts:  $(extras_line)"
    return 0
}

# Change topic, then offer to start the watchdog if it isn't running
do_change_topic() {
    do_configure
    [[ -f "$CONFIG_FILE" ]] || return 0
    if ! systemctl is-active --quiet aiostreams-watchdog.timer 2>/dev/null; then
        local c
        read -rp "The watchdog isn't running. Start it now? [Y/n]: " c || return 0
        [[ "$c" =~ ^[Nn] ]] || do_start
    fi
    return 0
}

# Extra alerts: the optional ones, as on the panel's Phone alerts page
do_extras() {
    local c d t note
    [[ -f "$CONFIG_FILE" ]] || { warn "Set the watchdog up first (2) Start)."; return 0; }
    while true; do
        echo ""
        echo "=== Extra alerts ==="
        case "$(aio_channel)" in
            nightly) note="one per nightly build; they come out daily or more, so this can be chatty" ;;
            stable) note="one alert per stable release" ;;
            *) note="this server runs a pinned version, so there's nothing to alert about" ;;
        esac
        echo "1) New AIOStreams release: $(option_on updates && echo on || echo off)  ($note)"
        if systemctl is-enabled --quiet "$WEBHOOK_BOOT_UNIT" 2>/dev/null; then
            echo "2) Server restarted: $(reboots_on && echo on || echo off)  (the webhook relay sends these while its own is on)"
        else
            echo "2) Server restarted: $(reboots_on && echo on || echo off)  (with how long it was down)"
        fi
        echo "3) Script updates: $(option_on scripts && echo on || echo off)  (scripts can change several times a week, so this can be chatty; at most one alert a day)"
        echo "4) Scheduled backup made: $(option_on backups && echo on || echo off)  (a failed or skipped one always alerts)"
        echo "5) Weekly check-in: $(option_on weekly && echo "on, ${DAY_NAMES[$(( $(weekly_day) - 1 ))]}s from $(weekly_time)" || echo off)"
        echo "6) Set the check-in's day and time (server time: $(server_timezone))"
        echo "0) Back"
        read -rp "Choose [0-6]: " c || return 0
        case "$c" in
            1) option_on updates && set_option updates off || set_option updates on ;;
            2) reboots_on && set_option reboots off || set_option reboots on ;;
            3) option_on scripts && set_option scripts off || set_option scripts on ;;
            4) option_on backups && set_option backups off || set_option backups on ;;
            5) option_on weekly && set_option weekly off || set_option weekly on ;;
            6)
                echo "Days: 1 Monday, 2 Tuesday, 3 Wednesday, 4 Thursday, 5 Friday, 6 Saturday, 7 Sunday"
                read -rp "Day [Enter for $(weekly_day)]: " d || return 0
                d=${d:-$(weekly_day)}
                [[ "$d" =~ ^[1-7]$ ]] || { warn "Pick 1 to 7."; continue; }
                read -rp "Time, 24-hour HH:MM [Enter for $(weekly_time)]: " t || return 0
                t=${t:-$(weekly_time)}
                [[ "$t" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { warn "Use HH:MM, for example 10:15."; continue; }
                set_option weekly_day "$d" >/dev/null
                set_option weekly_time "$t" >/dev/null
                echo "The check-in goes out on ${DAY_NAMES[$((d - 1))]}s from $(weekly_time), server time ($(server_timezone)), within 2 minutes of it."
                [[ "$(date +%Z)" == UTC ]] && echo "This server is on UTC. For your own time: sudo timedatectl set-timezone Area/City (for example Europe/London)."
                ;;
            0|"") return 0 ;;
            *) warn "Not a valid option." ;;
        esac
    done
}

# Recent events and the daily stats, with Clear history and Reset stats
do_events() {
    local c at kind text n=0
    [[ -f "$CONFIG_FILE" ]] || { warn "Set the watchdog up first (2) Start)."; return 0; }
    echo ""
    echo "Today:         $(today_line)"
    echo "Last 14 days:  $(days_strip)   (green all passed, amber some failed, grey none)"
    echo ""
    if [[ -s "$EVENTS_FILE" ]]; then
        echo "Recent events, newest first:"
        while IFS='|' read -r at kind text; do
            [[ "$at" =~ ^[0-9]+$ ]] || continue
            printf '  %s  %-9s %s\n' "$(date -d "@$at" '+%d %b %H:%M')" "$kind" "$text"
            n=$((n + 1)); (( n >= 20 )) && break
        done < <(tac "$EVENTS_FILE")
    else
        echo "No events yet. Failed checks, alerts and recoveries show here."
    fi
    echo ""
    echo "1) Clear history   2) Reset stats   0) Back"
    read -rp "Choose [0-2]: " c || return 0
    case "$c" in
        1) : > "$EVENTS_FILE"; echo "Event history cleared." ;;
        2) : > "$TALLY_FILE"; echo "Stats reset. The 14 days start again from the next check." ;;
    esac
    return 0
}

do_check_now() {
    echo ""
    echo "Running every check once (nothing is saved or sent)..."
    if run_checks; then echo "All checks passed."
    else echo "FAILED: $FAIL_REASON"
    fi
    return 0
}

do_test_alert() {
    [[ -f "$CONFIG_FILE" ]] || error "Not configured yet, run Start first."
    if send_ntfy "If you see this, alerts from the AIOStreams watchdog are working." "Test alert" 3 bell; then
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
    uninstall_now
}

# The removal itself, shared by the menu and the question-free "uninstall"
# the control panel runs.
uninstall_now() {
    systemctl disable --now aiostreams-watchdog.timer 2>/dev/null || true
    systemctl disable --now aiostreams-watchdog-boot.service 2>/dev/null || true
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

if [[ "${1:-}" == "--shutdown" ]]; then
    do_shutdown
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

# set-option <updates|reboots|scripts|backups|weekly> <on|off>, or set-option weekly_day <1-7> /
# weekly_time <HH:MM>: the optional alerts, without questions
if [[ "${1:-}" == "set-option" ]]; then
    [[ ( "${2:-}" =~ ^(updates|reboots|scripts|backups|weekly)$ && "${3:-}" =~ ^(on|off)$ ) || ( "${2:-}" == weekly_day && "${3:-}" =~ ^[1-7]$ )
       || ( "${2:-}" == weekly_hour && "${3:-}" =~ ^([01]?[0-9]|2[0-3])$ )
       || ( "${2:-}" == weekly_time && "${3:-}" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ) ]] \
        || error "Usage: set-option updates|reboots|scripts|backups|weekly on|off, set-option weekly_day 1-7 (Mon-Sun), set-option weekly_time HH:MM"
    [[ -f "$CONFIG_FILE" ]] || error "Not configured yet. Set the watchdog up first."
    set_option "$2" "$3"
    exit 0
fi

# Uninstall without the question (the control panel asks first)
if [[ "${1:-}" == "uninstall" ]]; then
    [[ -d "$STATE_DIR" ]] || error "The watchdog isn't set up on this server."
    uninstall_now
    exit 0
fi

# After the script itself is replaced (the control panel's Update): bring the
# timer's copy and the systemd units up to date. Starts nothing that's off.
if [[ "${1:-}" == "refresh" ]]; then
    [[ -f "$CONFIG_FILE" ]] || exit 0
    install_systemd_units
    if systemctl is-enabled --quiet aiostreams-watchdog-boot.service 2>/dev/null; then
        systemctl start aiostreams-watchdog-boot.service >/dev/null 2>&1 || true   # sends nothing now
    fi
    echo "The watchdog's running copy is up to date."
    exit 0
fi

if [[ "${1:-}" == "stop" ]]; then
    do_stop
    exit 0
fi

if [[ "${1:-}" == "test" ]]; then
    do_test_alert
    exit $?
fi

if [[ "${1:-}" == "install-timer" ]]; then
    [[ -f "$CONFIG_FILE" ]] || error "No watchdog config found at $CONFIG_FILE, nothing to reinstall."
    install_systemd_units
    systemctl enable --now aiostreams-watchdog.timer
    systemctl start --no-block aiostreams-watchdog.service 2>/dev/null || true   # the first check now, not in up to 2 minutes
    systemctl enable aiostreams-watchdog-boot.service >/dev/null 2>&1 || true
    systemctl start aiostreams-watchdog-boot.service >/dev/null 2>&1 || true   # records this boot's shutdown; sends nothing now
    log_event start "Watchdog started."
    exit 0
fi

# When the input runs out (Ctrl+D, or a control panel that typed its answers
# and closed), leave quietly rather than with an error.
while true; do
    echo ""
    echo "=== AIOStreams Watchdog ==="
    echo "1) Status"
    echo "2) Start"
    echo "3) Stop"
    echo "4) Send test alert"
    echo "5) Change topic"
    echo "6) Extra alerts (releases, restarts, scripts, backups, weekly check-in)"
    echo "7) Recent events and stats"
    echo "8) Check now"
    echo "9) Uninstall"
    echo "0) Exit"
    read -rp "Choose an option [0-9]: " CHOICE || exit 0

    case "$CHOICE" in
        1) do_status ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_test_alert || true ;;
        5) do_change_topic ;;
        6) do_extras ;;
        7) do_events ;;
        8) do_check_now ;;
        9) do_uninstall ;;
        0) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
