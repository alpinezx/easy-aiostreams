"""Log lines that look alarming but are expected: every rule that keeps them off the Overview's
Recent log alerts card, or greys or hides them on the Logs page, in one table.

Two kinds of row:
- where "NOISE", "QUIET" or "CUT_BY_AIOS": run in the browser (web/js/logs.js keeps a copy of
  each pattern in that list, same order; test_noise_rules_match_logs_js checks it). They act on
  the Logs page (NOISE hidden by Hide noise, QUIET shown grey) and on the card, which sorts its
  lines with the Logs page's rules. logs.js tries its lists on every log; `services` says whose
  lines a row was written for.
- where "card": run here, on the card's lines only. The Logs page keeps those lines.

`when` says when a row applies: always, only within 10 s before a Caddy stop line, during or a
minute after a panel action, the first minutes after boot, a minute after a backup resumed the
containers, a minute after that container's own start, or when the VPN came back by itself.

Adding a rule: add a row. A browser row also needs its pattern added to that list in logs.js.
The user's own choices (the card's Clear, its cog's hidden services) live in main.py.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

ALWAYS = "always"
BEFORE_CADDY_STOP = "before a Caddy stop"
ACTION = "panel action"
BOOT = "boot"
BACKUP = "backup"
OWN_START = "own start"
HEALED = "VPN back by itself"

# How long each `when` lasts, in seconds
RESTART_WINDOW = 10   # logs.js: an AIOStreams cut this long before Caddy's stop line
JOB_GRACE = 60        # after a panel action ends (and 5 s before it starts)
BOOT_GRACE = 180      # after the server boots, while Caddy is up before AIOStreams and the VPN
RESUME_GRACE = 60     # after a backup resumes the containers, or a container's own start (and 5 s before)
VPN_HEAL_WITHIN = 300  # gluetun finds its public address again within this long of the drop
VPN_HEAL_MAX = 2       # healed restarts a day kept off the card; from the next one every one shows


@dataclass(frozen=True)
class Rule:
    name: str
    services: tuple[str, ...]   # "*": any service
    pattern: str | None         # a regex searched in the raw line; None: every line
    when: tuple[str, ...]
    where: str                  # "card", or the logs.js list holding the same pattern
    why: str
    regex: re.Pattern | None = field(default=None, compare=False, repr=False)

    def __post_init__(self):
        if self.pattern is not None:
            object.__setattr__(self, "regex", re.compile(self.pattern))


CADDY, CF, VPN, AIOM = ("caddy",), ("cloudflared",), ("gluetun",), ("aiometadata",)
A = (ALWAYS,)

RULES: tuple[Rule, ...] = (
    # Caddy lines hidden by Hide noise, and kept off the card
    Rule("logs-page-closed", CADDY, r'aborting with incomplete response.*\/api\/logs\/', A, "NOISE",
         "The Logs page's own live log connection closing."),
    Rule("live-page-left", CADDY, r'aborting with incomplete response.*"error":"[^"]*context canceled"', A, "NOISE",
         "A browser left a live page (an event stream)."),
    Rule("viewer-hung-up", CADDY, r'aborting with incomplete response.*"error":"writing: ', A, "NOISE",
         "The viewer's player or browser hung up mid-transfer (skip, seek, stop), or Caddy's write_idle cut a "
         "paused stream; players reconnect by themselves."),
    Rule("dashboard-cut", CADDY,
         r'aborting with incomplete response.*"uri":"\/api\/v1\/dashboard\/[^"]*\/stream".*"error":"reading: unexpected EOF"',
         A, "NOISE", "AIOStreams restarted under an open dashboard page."),
    Rule("dashboard-reconnect", CADDY, r'dial tcp [0-9.]+:3000: connect: connection refused.*"uri":"\/api\/v1\/dashboard\/[^"]*\/stream"',
         A, "NOISE", "An open dashboard page reconnecting while AIOStreams starts."),
    Rule("caddy-stop-byeee", CADDY, r'exiting; byeee', A, "NOISE", "Caddy stopping for a restart."),
    Rule("caddy-stop-apps", CADDY, r'shutting down apps, then terminating', A, "NOISE", "Caddy stopping for a restart."),
    Rule("caddy-stop-grace", CADDY, r'servers shutting down with eternal grace period', A, "NOISE", "Caddy stopping for a restart."),
    Rule("caddyfile-format", CADDY, r'Caddyfile input is not formatted', A, "NOISE", "Whitespace only."),
    Rule("http3-needs-tls", CADDY, r'HTTP\/[23] skipped because it requires TLS', A, "NOISE",
         "Port 80 is plain HTTP by design (Cloudflare Tunnel mode)."),
    Rule("panel-restarting", CADDY, r'dial tcp [0-9.]+:8080: connect: connection refused', A, "NOISE",
         "The panel itself restarting."),
    Rule("panel-gone", CADDY, r'lookup aios-ui on [^ ]+: (server misbehaving|no such host)', A, "NOISE",
         "The panel container stopped or being rebuilt."),
    Rule("aiostreams-cut-by-restart", CADDY,
         r'aborting with incomplete response.*"error":"reading: [^"]*(:3000: read: connection reset by peer|unexpected EOF)"',
         (BEFORE_CADDY_STOP,), "CUT_BY_AIOS",
         "AIOStreams cutting a response is noise only next to a stack restart (Caddy's stop line within "
         "RESTART_WINDOW after it); on its own it means a viewer's stream broke."),

    # Tunnel, VPN and AIOMetadata lines shown grey, and kept off the card
    Rule("vpn-dns-retry", VPN, r'WARN \[dns\] (exchanging over|renewing|getting) tls connection ', A, "QUIET",
         "One DNS query's encrypted connection closed or was slow (EOF, a timeout), so gluetun asked again over "
         "another connection or provider. Every wording and ending: real DNS trouble shows elsewhere (its health "
         "check restarting the VPN, AIOStreams' searches failing), and ERROR lines stay."),
    Rule("vpn-stopping", VPN, r'WARN Caught OS signal terminated, shutting down$', A, "QUIET",
         "gluetun asked to stop, as a restart or reboot does."),
    Rule("vpn-startup-check", VPN, r'WARN \[vpn\] restarting VPN because it failed to pass the healthcheck: startup check: ',
         A, "QUIET",
         "gluetun's first health check, seconds after it starts, ran before its own DNS was ready, so it restarted "
         "the tunnel itself and the next try passed. Only the startup check wording: a tunnel unhealthy later says "
         "something else and stays."),
    Rule("vpn-version-403", VPN, r'ERROR \[vpn\] cannot get version information: bad response HTTP status code: 403 403 Forbidden$',
         A, "QUIET", "gluetun's start-up release check hit GitHub's hourly limit, common on a shared exit address."),
    Rule("tunnel-stopping", CF, r'Serve tunnel error error="control stream error: Error shutting down control stream: ', A, "QUIET",
         "cloudflared told to stop (a restart, update or reboot) closes its connections to Cloudflare. A tunnel "
         "that can't reach Cloudflare says something else and stays."),
    Rule("tunnel-already-connected", CF, r'error="control stream error: already connected to this server, trying another address"',
         A, "QUIET",
         "Back up after a restart, one connection reached a Cloudflare server still holding its old one and moved "
         "to another (both lines of the pair). Other connection failures stay."),
    Rule("tunnel-closed-no-error", CF, r'error="datagram manager error: Application error 0x0 \(remote\)"', A, "QUIET",
         "Cloudflare closed one connection with code 0 (no error) as its servers restart or rebalance; it registers "
         "again within seconds. Other codes stay."),
    Rule("tunnel-visitor-closed", CF, r'canceled by remote with error code 0\b', A, "QUIET",
         "A visitor closed a connection still open (left a live page, stopped a video)."),
    Rule("tunnel-visitor-gave-up", CF, r'error="Incoming request ended abruptly: context canceled"', A, "QUIET",
         "The visitor's side gave up before the answer came (a reload, a closed tab, the panel restarting): both halves."),
    Rule("tunnel-cut-first-half", CF, r'ERR {2}error="unexpected EOF" .*originService=', A, "QUIET",
         "A cut connection's first half (cloudflared logs each failure twice); its Request failed line says what it was."),
    Rule("tunnel-live-page-cut", CF, r'Request failed error="unexpected EOF" .*dest=https?:\/\/[^/ ]+\/api\/(logs\/[^ ]*|[^ ?]*\/stream) ',
         A, "QUIET", "A restart cut a live page: any live /api/.../stream or the panel's own Logs."),
    Rule("aiometadata-cache-stats", AIOM, r'\[Cache-Health\] ℹ ', A, "QUIET",
         "Cache statistics logged at info level during scheduled warm-ups; \"Error Rate\" and \"Errors: 2\" are "
         "counts, not failures. Its WARN and ERROR lines stay."),
    Rule("aiometadata-slow-answer", AIOM, r'\[HTTP-Timing\]\s+WARN\s.* took \d+ms', A, "QUIET",
         "A download or lookup that took a few seconds: a slow answer from the other end, not a failure."),
    Rule("aiometadata-unclean-close", AIOM, r'WARN\s+Did not close cleanly: ', A, "QUIET",
         "A connection (Redis or another store) not closed neatly as it stopped (a restart, update or backup's "
         "pause). A lost or refused connection says something else and stays."),

    # The card only
    Rule("vpn-drop-healed", VPN, r'restarting VPN because it failed to pass the healthcheck|getting public IP address information',
         (HEALED,), "card",
         "gluetun restarts its own tunnel when a health check fails, and its public address look-up can fail while "
         "it does. When '[ip getter] Public IP address is' follows within VPN_HEAL_WITHIN, the drop fixed itself. "
         "Only while rare: from VPN_HEAL_MAX + 1 healed restarts in the day every one shows. gluetun's startup check "
         "restart during a panel action or after boot (switching the VPN on, trying a config, a reboot) isn't counted: "
         "someone did that on purpose. The same restart at any other time (gluetun restarting by itself) is."),
    Rule("away-during-action", ("caddy", "cloudflared"), None, (ACTION,), "card",
         "While a panel action runs (Restart stack, Update, a VPN switch, a backup) and JOB_GRACE after, the tunnel "
         "can't reach Caddy and Caddy can't reach AIOStreams. Only these two: AIOStreams' start-up checks and the "
         "VPN failing to connect always show."),
    Rule("away-after-boot", ("caddy", "cloudflared"), None, (BOOT,), "card",
         "The first BOOT_GRACE after the server boots, while services start in turn."),
    Rule("event-loop-stall", ("*",), r'\bEvent loop stalled for \d+ ?ms\b', (BACKUP, OWN_START), "card",
         "Node add-ons (AIOMetadata) see a backup's pause as their event loop stalling for as long as it lasted. "
         "At any other time a stall is worth a look."),
    Rule("caddy-missing-panel", CADDY, r'\blookup aios-ui\b', (OWN_START,), "card",
         "Caddy recreated by any script comes back without the panel's network, until the panel connects it again "
         "(Backend.keep_caddy_connected, a second or so later). panel-gone already hides the usual endings always."),
)

_CARD = [r for r in RULES if r.where == "card"]
# Services whose every line is held back during actions and after boot (main._job_windows)
QUIET_WINDOW_SERVICES = {s for r in _CARD if r.pattern is None for s in r.services}
_AFTER_EVENT = [r for r in _CARD if r.regex and {BACKUP, OWN_START} & set(r.when)]
_VPN_DROP = next(r.regex for r in _CARD if HEALED in r.when)
_VPN_RESTART = re.compile(r"restarting VPN because it failed to pass the healthcheck")
_VPN_STARTUP = re.compile(r"restarting VPN because it failed to pass the healthcheck: startup check: ")
_VPN_BACK = re.compile(r"\[ip getter\] Public IP address is ")


def line_time(line: str) -> float | None:
    """Docker's timestamp at the start of a line ("2026-11-12T18:10:36.123456789Z ..."), as epoch seconds."""
    try:
        return datetime.strptime(line[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def drop_self_healed(lines: list[str], windows: list[tuple[float, float]] = ()) -> list[str]:
    """gluetun's log less its drops that fixed themselves (rule vpn-drop-healed). Runs on the whole
    log, before warn_hints keeps warning-like lines: the line it looks for is an INFO one.
    windows (main._job_windows): panel actions and boot, whose startup check restarts don't count."""
    backs = [t for t in (line_time(ln) for ln in lines if _VPN_BACK.search(ln)) if t is not None]

    def healed(ln):
        if not _VPN_DROP.search(ln):
            return False
        t = line_time(ln)
        return t is not None and any(t <= b <= t + VPN_HEAL_WITHIN for b in backs)
    gone = [ln for ln in lines if healed(ln)]
    def planned(ln):
        t = line_time(ln)
        return bool(_VPN_STARTUP.search(ln)) and t is not None and any(a <= t <= b for a, b in windows)
    if sum(1 for ln in gone if _VPN_RESTART.search(ln) and not planned(ln)) > VPN_HEAL_MAX:
        return lines
    return [ln for ln in lines if ln not in gone]


def after_resumes(services: list[dict], resumes: dict[str, list[float]]) -> list[dict]:
    """The rules for a minute after a backup or a container's own start. resumes (Backend.resumes):
    a container's own starts under its name, and backups (every container) under "*"."""
    def near(t, times):
        return any(a - 5 <= t <= a + RESUME_GRACE for a in times)

    def keep(cname, line):
        hits = [r for r in _AFTER_EVENT if ("*" in r.services or cname in r.services) and r.regex.search(line)]
        if not hits:
            return True
        t = line_time(line)
        if t is None:
            return True
        for r in hits:
            times = [*(resumes.get("*", ()) if BACKUP in r.when else ()),
                     *(resumes.get(cname, ()) if OWN_START in r.when else ())]
            if near(t, times):
                return False
        return True
    return [{**s, "lines": [ln for ln in s["lines"] if keep(s.get("container"), ln)]} for s in services]


def outside_jobs(services: list[dict], windows: list[tuple[float, float]]) -> list[dict]:
    """The QUIET_WINDOW_SERVICES' lines less those inside windows (main._job_windows: panel actions
    and boot). Lines without a time stay."""
    def keep(line):
        t = line_time(line)
        return t is None or not any(a <= t <= b for a, b in windows)
    return [{**s, "lines": [ln for ln in s["lines"] if keep(ln)]} if s.get("container") in QUIET_WINDOW_SERVICES else s
            for s in services]


def card_lines(services: list[dict], resumes: dict[str, list[float]], windows: list[tuple[float, float]]) -> list[dict]:
    """Every server-side rule for the card, after warn_hints (which ran drop_self_healed on gluetun's log)."""
    return outside_jobs(after_resumes(services, resumes), windows)
