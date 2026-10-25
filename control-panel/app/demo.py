"""Fake server for previewing the UI (UI_DEMO=1). Same interface as stack.Backend."""
from __future__ import annotations

import os
import random
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Callable

from .actions import SCRIPTS, Action, catalog

GB = 1024 ** 3
MB = 1024 ** 2

AIO_LINES = [
    "info: [Server] AIOStreams listening on port 3000",
    "info: [Resolver] Fetching streams for tt0111161 from 6 addons",
    "info: [Torrentio] 24 streams in 412ms",
    "info: [Comet] 18 streams in 530ms",
    "info: [MediaFusion] 31 streams in 780ms",
    "warn: [Knightcrawler] Request timed out after 5000ms, skipping",
    "info: [Filter] 73 streams kept, 12 removed by your rules",
    "info: [Sort] Sorted 73 streams in 6ms",
    "info: [Response] Sent 73 streams in 903ms",
    "error: [Orionoid] 429 Too Many Requests, backing off 30s",
    "info: [Cache] Hit for tt0944947:1:1",
]
CADDY_LINES = [
    '{"level":"info","ts":%f,"logger":"http.log.access","msg":"handled request","request":{"method":"GET","host":"streams.example.com","uri":"/stremio/manifest.json"},"status":200,"duration":0.004}',
    '{"level":"info","ts":%f,"logger":"http.log.access","msg":"handled request","request":{"method":"GET","host":"streams.example.com","uri":"/api/v1/status"},"status":200,"duration":0.002}',
    '{"level":"info","ts":%f,"logger":"tls","msg":"certificate is not due for renewal","identifiers":["streams.example.com"]}',
    '{"level":"warn","ts":%f,"logger":"http.handlers.reverse_proxy","msg":"aborting with incomplete response","upstream":"aios-ui:8080","request":{"method":"GET","uri":"/api/logs/caddy?tail=300"},"error":"reading: context canceled"}',
    '{"level":"warn","ts":%f,"msg":"Caddyfile input is not formatted; run \'caddy fmt --overwrite\' to fix inconsistencies","adapter":"caddyfile","line":2}',
    '{"level":"warn","ts":%f,"logger":"http","msg":"HTTP/3 skipped because it requires TLS","network":"tcp","addr":":80"}',
]


class FakeStream:
    def __init__(self, container: str, tail: int):
        self.container, self.tail, self._stop = container, tail, threading.Event()

    def _line(self, pool):
        line = random.choice(pool)
        return line % time.time() if "%f" in line else line

    def __iter__(self):
        pool = CADDY_LINES if self.container == "caddy" else AIO_LINES
        now = datetime.now(timezone.utc)
        for i in range(min(self.tail, 40)):
            ts = (now - timedelta(seconds=(40 - i) * 7)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            yield f"{ts} {self._line(pool)}"
        while not self._stop.wait(random.uniform(0.6, 2.2)):
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            yield f"{ts} {self._line(pool)}"

    def close(self):
        self._stop.set()


def demo_rate(t: float) -> float:
    """Made-up bytes a second down the VPN at time t: quiet with search blips, streaming most
    evenings (a 4K film two nights ago), and a weekend afternoon."""
    lt = datetime.fromtimestamp(t)
    day, hr = (datetime.now().date() - lt.date()).days, lt.hour + lt.minute / 60
    rnd = random.Random(int(t // 60))
    mbit = 0.02 + (rnd.uniform(2, 6) if rnd.random() < 0.03 else 0)
    if 0 <= time.time() - t < 1800:
        return rnd.uniform(25, 40) * 1e6 / 8     # someone watching right now, so the demo has speeds to show
    if 19.5 <= hr < 22.5 and day not in (3, 5):
        mbit = (rnd.uniform(60, 85) if day == 2 else rnd.uniform(18, 40))
    if lt.weekday() >= 5 and 14 <= hr < 16.2:
        mbit = rnd.uniform(15, 30)
    return mbit * 1e6 / 8


def host_rate(t: float, rx: float) -> tuple[float, float]:
    """The server's own card: the VPN's traffic (encrypted, a little bigger) coming in and the
    streams going back out to viewers, plus visitors and updates."""
    return rx * 1.04 + 9000, rx * 0.97 + 6000


def demo_traffic(now: float, host: bool = False) -> tuple[dict, dict]:
    """A week of history for the demo's traffic graphs, with the VPN off for a while yesterday
    (the server's own card carries on through it)."""
    minutes, hours = {}, {}
    start = int(now // 60 * 60) - 7 * 24 * 3600
    off = datetime.combine(datetime.now().date() - timedelta(days=1), datetime.min.time()).timestamp() + 13 * 3600
    for m in range(start, int(now // 60 * 60), 60):
        if off <= m < off + 2.5 * 3600 and not host:
            continue
        rx = int(demo_rate(m) * 60)
        tx = int(rx * 0.015 + 4000)
        if host:
            rx, tx = (int(x * 60) for x in host_rate(m, rx / 60))
        if m >= now - 24 * 3600:
            minutes[m] = [rx, tx]
        hb = hours.setdefault(m // 3600 * 3600, [0, 0, 0, 0])
        hb[0] += rx; hb[1] += tx; hb[2] = max(hb[2], rx); hb[3] = max(hb[3], tx)
    return minutes, hours


class DemoBackend:
    def __init__(self, scenario: str = "ok"):
        self.scenario = scenario
        self._gone: set[str] = set()
        self._cleared_logs: set[str] = set()
        self.vpn = os.environ.get("UI_DEMO_VPN", "on")   # on | off | none, to preview the header chip
        self.vpn_ip = "203.0.113.16"
        self.vpn_host = "nl.wg.example-vpn.net"
        self.staged = None
        self.previous = None
        self.has_config = True
        self.removed_scripts: set[str] = set()
        self.wd_running = True
        self.wd_configured = True
        self.wd_options = {"updates": False, "reboots": False, "scripts": False, "backups": False, "security": False, "weekly": False, "metadata": False, "manager": False, "mediaflow": False, "weekly_day": 7, "weekly_time": "10:00"}
        self.schedule = {"every": "daily", "day": 7, "time": "04:00"}
        self.wd_topic = "aios-7f3k29xq81"
        now = time.time()
        # A quiet fortnight with one blip and one real outage, for the Phone alerts page
        self.wd_events = [
            {"at": int(now - 5 * 3600), "kind": "recovered", "text": "Passing again before an alert was due, so none was sent."},
            {"at": int(now - 5 * 3600 - 120), "kind": "fail", "text": "https://streams.example.com didn't answer within 15 seconds. Check: docker logs caddy, docker logs aiostreams"},
            {"at": int(now - 3 * 86400 + 1800), "kind": "recovered", "text": "All checks passing again. All-clear sent."},
            {"at": int(now - 3 * 86400 + 240), "kind": "alert", "text": "Still failing on the next check. Alert sent."},
            {"at": int(now - 3 * 86400 + 120), "kind": "fail", "text": "gluetun tunnel appears to be DOWN (health check failing)"},
            {"at": int(now - 9 * 86400), "kind": "test", "text": "Test alert sent."},
            {"at": int(now - 9 * 86400 - 60), "kind": "start", "text": "Watchdog started."},
            {"at": int(now - 9 * 86400 - 90), "kind": "topic", "text": "Alert topic set."},
        ]
        day = lambda n: time.strftime("%Y-%m-%d", time.localtime(now - n * 86400))
        self.wd_tally = [{"day": day(n), "passed": 720 if n else int((now % 86400) / 120), "failed": 0} for n in range(9, -1, -1)]
        self.wd_tally[-4]["passed"] -= 14
        self.wd_tally[-4]["failed"] = 14
        self.wd_tally[-1]["failed"] = 1
        self.demo_files = [
            {"kind": "file", "path": "/home/ubuntu/NL-Amsterdam.conf", "endpoint": "nl.wg.example-vpn.net", "in_use": False},
            {"kind": "file", "path": "/home/ubuntu/SE-Stockholm.conf", "endpoint": "se.wg.example-vpn.net", "in_use": False}]
        self.channel = os.environ.get("UI_DEMO_CHANNEL", "latest")   # latest | nightly
        self._made: list[dict] = []    # backups "made" by demo actions, newest first
        self.signups_until = 0.0       # AIOManager's sign-ups, closed until a demo action opens them
        self.mf_version = "1.1.1"      # MediaFlow's pinned release, one behind until a demo Update
        self.running = {"caddy": True, "gluetun": True, "aiostreams": True, "mediaflow-proxy-light": True, "aiometadata": True, "aiomanager": True}
        if scenario == "down":
            self.running["aiostreams"] = False
        self.stopped_on_purpose = scenario == "paused"
        if scenario == "paused":
            self.running["aiostreams"] = False
        self.started = {k: datetime.now(timezone.utc) - timedelta(hours=random.randint(30, 400)) for k in self.running}
        self.hist = {k: [random.uniform(0.5, 6) for _ in range(30)] for k in self.running}

    _ctr = None
    _hctr = None

    def host_counters(self):
        now = time.time()
        if self._hctr is None:
            self._hctr = [now, 154 * GB + int(now * 3000), 150 * GB + int(now * 2900)]   # grows across demo restarts, as a real counter would
        d, u = host_rate(now, demo_rate(now) * random.uniform(0.85, 1.15))
        dt = now - self._hctr[0]
        self._hctr = [now, self._hctr[1] + int(d * dt), self._hctr[2] + int(u * dt)]
        return self._hctr[1], self._hctr[2]

    def vpn_counters(self):
        if self.vpn != "on":
            self._ctr = None
            return None
        now = time.time()
        if self._ctr is None:
            self._ctr = [now, 5 * GB + int(now * 2000), 80 * MB + int(now * 30)]
        rx = int(demo_rate(now) * (now - self._ctr[0]))
        self._ctr = [now, self._ctr[1] + rx, self._ctr[2] + int(rx * 0.015 + 70 * (now - self._ctr[0]))]
        return self._ctr[1], self._ctr[2]

    def vpn_info(self, fresh: bool = False) -> dict:
        out = {"mode": self.vpn, "endpoint_host": None, "endpoint_ip": None, "endpoint_port": None,
               "connected": None, "exit_ip": None, "city": None, "region": None, "country": None, "org": None,
               "checked_at": None, "error": None}
        if self.vpn == "none":
            return out
        out.update(endpoint_host=self.vpn_host if self.has_config else None, endpoint_ip=self.vpn_ip if self.has_config else None,
                   endpoint_port="51820" if self.has_config else None, previous=self.previous, has_config=self.has_config)
        if self.vpn == "on":
            out.update(connected=self.running.get("gluetun", False), exit_ip="203.0.113.17", city="Amsterdam",
                       region="North Holland", country="NL", org="AS64500 Example VPN", checked_at=time.time(),
                       dns={"state": "encrypted", "via": ["Cloudflare"]})
        return out

    def vpn_stage_config(self, conf: str) -> dict:
        from .wgconf import check_wireguard_conf
        _, self.staged = check_wireguard_conf(conf)
        return self.staged

    def vpn_staged_addresses(self) -> dict:
        time.sleep(1.5)
        ips = [("203.0.113.120", 7.9), ("203.0.113.131", 8.2), ("203.0.113.145", 8.6), ("203.0.113.160", None)]
        return {"host": (self.staged or {}).get("endpoint_host"), "error": None,
                "addresses": [{"ip": ip, "ms": ms, "in_use": False, "recommended": n == 0} for n, (ip, ms) in enumerate(ips)]}

    def vpn_mode(self) -> str:
        return self.vpn

    def addons_info(self) -> list[dict]:
        return [{"id": "aiometadata", "domain": "meta.example.com", "version": "3.6.1"},
                {"id": "aiomanager", "domain": "manager.example.com", "version": "2.0.0"},
                {"id": "mediaflow", "domain": "mediaflow.example.com", "url": "http://mediaflow-proxy-light:8888", "proxy": None}]

    def addon_secret(self, addon: str, name: str) -> str | None:
        # Plainly made up, so nothing mistakes them for real ones
        return {("aiometadata", "addon_password"): "demo-addon-password",
                ("aiometadata", "admin_key"): "demo-admin-key",
                ("mediaflow", "api_password"): "demo-api-password"}.get((addon, name))

    def set_watchdog_option(self, name: str, value) -> None:
        from .stack import TIME_RE
        ok = (name in ("updates", "reboots", "scripts", "backups", "security", "weekly", "metadata", "manager", "mediaflow") and isinstance(value, bool)) or \
            (name == "weekly_day" and type(value) is int and 1 <= value <= 7) or \
            (name == "weekly_time" and isinstance(value, str) and bool(TIME_RE.match(value.strip())))
        if not ok:
            raise ValueError("Unknown option.")
        if name == "weekly_time":
            hh, mm = value.strip().split(":")
            value = f"{int(hh):02d}:{int(mm):02d}"
        self.wd_options[name] = value

    def clear_watchdog_events(self, which: str = "events") -> None:
        if which == "tally":
            self.wd_tally = []
        else:
            self.wd_events = []

    def maintenance_info(self, force: bool = False) -> dict:
        return {"space": {"images": 149_000_000, "image_count": 2, "build": 503_100_000, "journal": 184_000_000},
                "updates": {"available": True, "count": 8, "security": 2, "phased": 3, "reboot": False, "checked_at": time.time() - 3 * 3600},
                "logs": {"limited": False, "pending": False, "size": 488_000},
                "checked_at": time.time(), "last": None}

    def watchdog_info(self) -> dict:
        from .stack import mask_topic
        if not self.wd_configured:
            return {"configured": False}
        watches = ["https://streams.example.com", "Disk space", "HTTPS certificates (5 sites)"] + (["VPN tunnel", "AIOStreams through the VPN"] if self.vpn == "on" else []) + ["MediaFlow Proxy", "AIOMetadata", "AIOManager"]
        return {"configured": True, "running": self.wd_running, "alert_state": "up", "fails": 0,
                "warnings": [w for w in os.environ.get("UI_DEMO_WD_WARN", "").split(",") if w],
                "last_check": time.strftime("%d %b %Y, %H:%M:%S UTC", time.gmtime(time.time() - 40)) + " OK" if self.wd_running
                else time.strftime("%d %b %Y, %H:%M:%S UTC", time.gmtime(time.time() - 40)) + " STOPPED (watchdog disabled, no checks running)",
                "topic": mask_topic(self.wd_topic), "events": self.wd_events, "tally": self.wd_tally,
                "watches": watches, "every_min": 2, "threshold": 2,
                "options": dict(self.wd_options), "channel": "nightly" if self.channel == "nightly" else "stable",
                "aiometadata": True, "aiomanager": True, "mediaflow": True,
                "timezone": os.environ.get("UI_DEMO_TZ", "Europe/London")}

    def update_script(self, script_id: str) -> dict:
        from .actions import SCRIPTS
        from . import scriptsync
        found = next(((i, f) for i, _, f in SCRIPTS if i == script_id), None)
        if not found:
            raise ValueError("Unknown script.")
        files = [found[1]] + (["setup-backup.sh"] if script_id == "aiostreams" else [])
        scriptsync.DEMO_SAME.update(files)
        return {"updated": files, "note": None}

    def remove_script(self, script_id: str) -> str:
        from .actions import ADDON_STATE, SCRIPTS
        found = next(((i, f) for i, _, f in SCRIPTS if i == script_id), None)
        if not found or script_id not in ADDON_STATE:
            raise ValueError("Only an add-on's script can be removed.")
        if (script_id == "vpn" and self.vpn != "none") or (script_id == "watchdog" and self.wd_configured):
            raise ValueError("It's still set up. Uninstall it with its own menu first.")
        self.removed_scripts.add(script_id)
        return found[1]

    def vpn_configs(self) -> list[dict]:
        if self.vpn == "none":
            return []
        rows = [{"kind": "pasted", "path": "/opt/aiostreams/vpn-state/wireguard.conf", "endpoint": self.vpn_host, "in_use": True}] if self.has_config else []
        if self.previous:
            rows.append({"kind": "previous", "path": "/opt/aiostreams/vpn-state/previous/wireguard.conf", "endpoint": self.previous["endpoint_host"], "in_use": False})
        rows += [c for c in self.demo_files if c["path"] not in self._gone]
        return rows

    def vpn_host_addresses(self, host: str) -> dict:
        r = self.vpn_staged_addresses()
        r["host"] = host
        return r

    def vpn_addresses(self) -> dict:
        time.sleep(1.5)
        ips = [("203.0.113.24", 0.8), ("203.0.113.16", 0.9), ("203.0.113.40", 0.9), ("203.0.113.71", 1.2), ("203.0.113.9", None)]
        if self.vpn_ip not in [i for i, _ in ips]:
            ips.insert(1, (self.vpn_ip, 1.0))
        return {"host": "nl.wg.example-vpn.net", "error": None, "addresses": [
            {"ip": ip, "ms": ms, "in_use": ip == self.vpn_ip, "recommended": n == 0} for n, (ip, ms) in enumerate(ips)]}

    def status(self) -> dict:
        defs = [("caddy", "caddy", "Caddy", "HTTPS front door", False, "caddy:2"),
                ("gluetun", "gluetun", "VPN tunnel", "gluetun, WireGuard", False, "qmcgaw/gluetun:v3"),
                ("aiostreams", "aiostreams", "AIOStreams", "Addon aggregator", False, "viren070/aiostreams:latest"),
                ("mediaflow", "mediaflow-proxy-light", "MediaFlow Proxy", "Faster video proxy", True, f"ghcr.io/mhdzumair/mediaflow-proxy-light:{self.mf_version}"),
                ("aiometadata", "aiometadata", "AIOMetadata", "Catalogs and metadata", True, "ghcr.io/cedya77/aiometadata:3.6.1"),
                ("aiomanager", "aiomanager", "AIOManager", "Manages Stremio accounts", True, "ghcr.io/sonicx161/aiomanager:2.0.0")]
        if self.vpn != "on":
            defs = [x for x in defs if x[0] != "gluetun"]
        services = []
        for key, cname, name, role, addon, image in defs:
            run = self.running[cname]
            s = {"key": key, "container": cname, "name": name, "role": role, "addon": addon,
                 "present": True, "state": "running" if run else "stopped", "health": "healthy" if run else None,
                 "restarts": 0, "image": image,
                 "on_purpose": (not run) and key == "aiostreams" and self.stopped_on_purpose}
            if run:
                s.update(started_at=self.started[cname].isoformat().replace("+00:00", "Z"),
                         cpu=round(random.uniform(0.2, 9.0) if key == "aiostreams" else random.uniform(0.0, 1.5), 1),
                         mem=int({"caddy": 31, "gluetun": 44, "aiostreams": 318, "mediaflow": 22, "aiometadata": 452, "aiomanager": 182}[key] * MB * random.uniform(0.97, 1.03)))
                # Network speeds: a stream comes in through the VPN (or straight to AIOStreams
                # without one), over to Caddy and out to the viewer; AIOStreams on the VPN's
                # network has no counters of its own
                r = demo_rate(time.time()) * random.uniform(0.9, 1.1)
                net = {"caddy": (r + 9000, r * 0.98 + 6000), "gluetun": (r * 1.04, r * 0.98 + 2000),
                       "aiostreams": None if self.vpn == "on" else (r * 1.02, r * 0.98),
                       "mediaflow": (4000, 3000), "aiometadata": (30000, 12000), "aiomanager": (1500, 2500)}[key]
                if net:
                    s.update(rx=net[0], tx=net[1])
            services.append(s)
        down = [s for s in services if s["state"] != "running" and not s["on_purpose"]]
        if down:
            overall, headline = "down", f"{down[0]['name']} is down"
        elif self.stopped_on_purpose:
            overall, headline = "paused", "AIOStreams is stopped"
        else:
            overall, headline = "ok", "Everything is up"
        return {
            "installed": True, "docker_ok": True, "domain": "streams.example.com", "channel": self.channel, "version": "2.35.9",
            "build_tag": time.strftime("%Y.%m.%d.%H%M-nightly", time.gmtime(time.time() - 30 * 3600)) if self.channel == "nightly" else "v2.35.9",
            "vpn": self.vpn, "install_dir": "/opt/aiostreams", "user_copy": self.user_copy(),
            "scripts": [{"id": i, "label": l, "file": f,
                         "present": i in ("aiostreams", "vpn", "mediaflow", "watchdog", "aiometadata", "aiomanager") and i not in self.removed_scripts,
                         "in_use": (i != "vpn" or self.vpn != "none") and (i != "watchdog" or self.wd_configured)} for i, l, f in SCRIPTS], "overall": overall, "headline": headline, "services": services,
            "watchdog": {"configured": self.wd_configured, "running": self.wd_running, "alert_state": "up",
                         "last_check": time.strftime("%d %b %Y, %H:%M:%S UTC", time.gmtime(time.time() - 40)) + (" OK" if self.wd_running else "")},
            "host": {"cpus": 2, "load": [0.21, 0.34, 0.29], "mem_total": 4 * GB, "mem_used": int(1.6 * GB),
                     "uptime": 41 * 86400 + 3 * 3600, "disk_total": 80 * GB, "disk_used": 23 * GB},
            "cert": {"host": "streams.example.com", "days_left": 61, "ok": True, "days_total": 90},
            "certs": [{"host": "streams.example.com", "label": "AIOStreams", "days_left": 61, "ok": True, "days_total": 90},
                      {"host": "meta.example.com", "label": "AIOMetadata", "ok": True, "days_total": 90,
                       "days_left": 12 if os.environ.get("UI_DEMO_CERT_WARN") else 84},
                      {"host": "manager.example.com", "label": "AIOManager", "days_left": 79, "ok": True, "days_total": 90},
                      {"host": "mediaflow.example.com", "label": "MediaFlow", "days_left": 58, "ok": True, "days_total": 90},
                      {"host": "cp.example.com", "label": "Control panel", "days_left": 73, "ok": True, "days_total": 90}],
            "backup": {"newest": max(b["mtime"] for b in self.backups()) if self.backups() else None,
                       **self.schedule, "last": self._last_run()},
            # AIOMetadata's card, only once it's installed; its newer releases come from GitHub
            "aiometadata": {"domain": "meta.example.com", "version": "3.6.1"},
            # AIOManager's: sign-ups closed unless a demo action opened them
            "aiomanager": {"domain": "manager.example.com", "version": "2.0.0", "logins": 3,
                           "signups": "open" if self.signups_until > time.time() else "closed",
                           "signups_until": int(self.signups_until) if self.signups_until > time.time() else None},
            # MediaFlow pinned to a release, one behind
            "mediaflow": {"domain": "mediaflow.example.com", "version": self.mf_version},
            "actions": [{"id": a.id, "label": a.label, "confirm": a.confirm, "available": True} for a in catalog()],
        }

    def delete_backup(self, name: str) -> list[str]:
        item = next((b for b in self.backups() if b["name"] == name), None)
        if not item:
            raise FileNotFoundError(name)
        self._gone.add(name)
        return item["dirs"]

    def user_copy(self) -> dict | None:
        return {"user": "ubuntu", "dir": "/home/ubuntu/aiostreams", "sudo": "nopass",
                "files": ["setup-aiostreams.sh", "setup-mediaflow.sh"]}

    def set_asides(self) -> list[dict]:
        now = int(time.time())
        items = [{"name": "aiostreams.pre-restore-20261009-233216", "dir": "/root", "size": 41_208_331, "when": now - 3 * 3600}]
        return [x for x in items if x["name"] not in self._gone]

    def delete_set_aside(self, name: str) -> None:
        from .stack import SET_ASIDE_NAME
        if not SET_ASIDE_NAME.fullmatch(name):
            raise ValueError(name)
        if not any(x["name"] == name for x in self.set_asides()):
            raise FileNotFoundError(name)
        self._gone.add(name)

    def _last_run(self) -> dict | None:
        if self.schedule["every"] == "off":
            return None
        return {"at": int(time.time()) - 5 * 3600, "status": "ok",
                "text": "aiostreams-backup-scheduled-20261019-040000.tar.gz, 4.7MB."}

    def backup_schedule(self) -> dict:
        return {**self.schedule, "keep": 7, "available": True, "timer": self.schedule["every"] != "off",
                "timezone": "Europe/London", "last": self._last_run()}

    def set_backup_schedule(self, every, day, t) -> dict:
        from .stack import TIME_RE
        if every == "off":
            self.schedule["every"] = "off"
        elif every in ("daily", "weekly") and isinstance(t, str) and TIME_RE.match(t.strip()) \
                and (every == "daily" or (type(day) is int and 1 <= day <= 7)):
            hh, mm = t.strip().split(":")
            self.schedule.update(every=every, time=f"{int(hh):02d}:{int(mm):02d}")
            if every == "weekly":
                self.schedule["day"] = day
        else:
            raise ValueError("Pick daily or weekly, and a time.")
        return self.backup_schedule()

    def backups(self) -> list[dict]:
        now = int(time.time())
        return [b for b in self._all_backups(now) if b["name"] not in self._gone]

    def _all_backups(self, now):
        day = time.strftime("%Y%m%d", time.localtime(now - 5 * 3600))
        prev = time.strftime("%Y%m%d", time.localtime(now - 29 * 3600))
        return self._made + [
                {"name": f"aiostreams-backup-scheduled-{day}-040000.tar.gz", "size": 4_820_114, "mtime": now - 5 * 3600, "dirs": ["/root"]},
                {"name": f"aiostreams-backup-scheduled-{prev}-040000.tar.gz", "size": 4_818_993, "mtime": now - 29 * 3600, "dirs": ["/root"]},
                {"name": "aiostreams-backup-20261007-031500.tar.gz", "size": 4_812_330, "mtime": now - 2 * 86400, "dirs": ["/root", "/home/ubuntu"]},
                {"name": "aiostreams-backup-20260930-221042.tar.gz", "size": 4_790_114, "mtime": now - 9 * 86400, "dirs": ["/root", "/home/ubuntu"]},
                {"name": "aiostreams-backup-20260914-094407.tar.gz", "size": 4_611_802, "mtime": now - 25 * 86400, "dirs": ["/root"]}]

    def backup_build(self, b: dict) -> dict | None:
        time.sleep(0.3)
        if b["name"].startswith("aiostreams-backup-202609"):
            return None     # made before backups recorded their build
        if b["name"] == "aiostreams-backup-20261007-031500.tar.gz":
            return {"version": "2.35.9", "tag": "2026.10.06.2045-nightly"}
        return {"version": "2.35.9", "tag": "v2.35.9"}

    def restore_check(self, b: dict) -> dict:
        time.sleep(0.6)
        if b["name"] == "aiostreams-backup-20260914-094407.tar.gz":
            return {"ok": False, "notes": [], "reasons": [
                "Its domain is old.example.com, but this install uses streams.example.com.",
                "Control panel: panel.old.example.com doesn't point at this server."]}
        return {"ok": True, "reasons": [], "notes": ["It holds AIOStreams v2.35.9.",
                "streams.example.com points at this server.", "Control panel: panel.example.com points at this server."]}

    def log_stream(self, container: str, tail: int) -> FakeStream:
        return FakeStream(container, 0 if container in self._cleared_logs else tail)

    def restart_service(self, key: str) -> str:
        from .stack import RESTARTABLE, SERVICES
        if key not in RESTARTABLE:
            raise KeyError(key)
        self.restarted_service = key      # demo mode never touches anything
        return next(x[2] for x in SERVICES if x[0] == key)

    def reboot_host(self) -> None:
        self.rebooted = True      # demo mode never touches anything

    def clear_logs(self, container: str) -> str:
        self._cleared_logs.add(container)
        return "hidden"

    def run(self, action: Action, emit: Callable[[str], None]) -> int:
        def say(t, d=0.35):
            emit(t)
            time.sleep(d)
        say(f"==> {action.running} (demo mode, nothing really runs)")
        if action.id == "stack.backup" or (action.id == "stack.update" and action.stdin.startswith("5\n1\n")):
            name = time.strftime("aiostreams-backup-%Y%m%d-%H%M%S.tar.gz")
            self._made.insert(0, {"name": name, "size": 4_830_112, "mtime": int(time.time()), "dirs": ["/root", "/home/ubuntu"]})
        if action.id == "stack.update":
            for l in ["Update AIOStreams:", "Current build channel: latest", "Updating AIOStreams (pull + recreate)...",
                      " Container gluetun  Running", " Image viren070/aiostreams:latest  Pulling", " Image viren070/aiostreams:latest  Pulled",
                      "VPN mode detected, recreating gluetun+caddy first...", "  Tunnel confirmed, starting aiostreams",
                      "Update complete. Current images:"]:
                say(l, 0.5)
        elif action.id == "aiometadata.update":
            for l in (["==> Creating backup", "Backup written to /root/aiostreams-backup-20261022-101500.tar.gz"] if "--backup" in action.args else []) + [
                      "Updating AIOMetadata from 3.6.1 to 3.6.2", " Image ghcr.io/cedya77/aiometadata:3.6.2  Pulled",
                      "Waiting for it to report healthy...", "AIOMetadata 3.6.2 is running and healthy.", "Removed the old 3.6.1 image."]:
                say(l, 0.5)
        elif action.id == "mediaflow.update":
            for l in (["==> Backing up first", "Backup written: /root/aiostreams-backup-20261025-101500.tar.gz"] if "--backup" in action.args else []) + [
                      f"==> Switching MediaFlow Proxy Light from {self.mf_version} to 1.1.2", " Container mediaflow-proxy-light  Recreated",
                      "Waiting for it to answer (up to a minute)...", "MediaFlow Proxy Light is on 1.1.2 and answering."]:
                say(l, 0.5)
            self.mf_version = "1.1.2"
        elif action.id == "aiomanager.signups_open":
            say("Recreating aiomanager with sign-ups open...", 0.8)
            self.signups_until = time.time() + 30 * 60
            say(f"Sign-ups are open until {time.strftime('%H:%M', time.localtime(self.signups_until))} (server time), then close by themselves.")
        elif action.id == "aiomanager.signups_close":
            say("Recreating aiomanager with sign-ups closed...", 0.8)
            self.signups_until = 0.0
            say("Sign-ups are closed. Existing logins keep working.")
        elif action.id == "stack.stop":
            say("Stopping AIOStreams..."); self.running["aiostreams"] = False; self.stopped_on_purpose = True
            say("Stopped. Caddy is still up (visitors get a 502).")
        elif action.id in ("stack.start", "stack.restart"):
            say("VPN mode detected, bringing the tunnel up before starting AIOStreams...", 0.6)
            say("  Tunnel confirmed, starting aiostreams", 0.6)
            self.running["aiostreams"] = True; self.stopped_on_purpose = False
            self.started["aiostreams"] = datetime.now(timezone.utc)
            say("Started.")
        elif action.id == "stack.restore":
            for l in ["Checking the backup for a same-server restore. Nothing is changed.", "  ok: streams.example.com points at this server.",
                      "Result: OK, it can be restored here without questions.", "==> Restore from backup",
                      "Moving the current install aside (same-server restore).", "==> Extracting backup", "==> Starting the restored stack",
                      "==> Restore complete!", "  - Control panel (panel.example.com): restart it (Restart panel) so it picks up the restored install."]:
                say(l, 0.4)
        elif action.id in ("vpn.on", "vpn.off"):
            on = action.id == "vpn.on"
            for l in ["==> Stopping the current stack", f"==> Starting the stack in '{'vpn' if on else 'direct'}' mode",
                      "==> Confirming the WireGuard tunnel is actually connected..." if on else "==> Verifying caddy and aiostreams are running",
                      "VPN is up. gluetun's exit IP: 203.0.113.17" if on else "Direct mode: AIOStreams uses this server's own IP.",
                      "Confirm at https://streams.example.com"]:
                say(l, 0.5)
            self.vpn = "on" if on else "off"
        elif action.id == "vpn.use":
            ip = action.args[1]
            for l in [f"Server address: {ip}:51820 (was {self.vpn_ip})", "==> Stopping the current stack", "==> Starting the stack in 'vpn' mode",
                      "==> Confirming the WireGuard tunnel is actually connected...", "VPN is up. gluetun's exit IP: 203.0.113.17",
                      "==> Tunnel confirmed, starting AIOStreams"]:
                say(l, 0.5)
            self.vpn_ip = ip
        elif action.id == "vpn.config":
            ip = action.args[1]
            st = self.staged or {}
            for l in [f"Config: {st.get('endpoint_host') or ip}, server address {ip}:51820", "Kept the config used until now, as Previous config.",
                      "==> Stopping the current stack", "==> Starting the stack in 'vpn' mode",
                      "==> Confirming the WireGuard tunnel is actually connected...", "VPN is up. gluetun's exit IP: 203.0.113.121",
                      "==> Tunnel confirmed, starting AIOStreams"]:
                say(l, 0.5)
            if self.has_config:
                self.previous = {"changed_at": time.time(), "endpoint_host": self.vpn_host, "endpoint_ip": self.vpn_ip}
            self.vpn_host, self.vpn_ip, self.has_config = st.get("endpoint_host") or ip, ip, True
            if action.args[-1] == "on":
                self.vpn = "on"
        elif action.id == "vpn.delete":
            path = action.args[1]
            say(f"Deleted {path}.")
            if path == "/opt/aiostreams/vpn-state/wireguard.conf":
                say("That was the VPN's config, so none is saved now. Turning the VPN on asks for a new one.")
                self.has_config = False
            if path.endswith("previous/wireguard.conf"):
                self.previous = None
            self._gone.add(path)
        elif action.id == "vpn.file":
            path, ip = action.args[1], action.args[2]
            prev = self.previous if path.endswith("previous/wireguard.conf") else None
            host = prev["endpoint_host"] if prev else next((c["endpoint"] for c in self.demo_files if c["path"] == path), ip)
            for l in [f"Using {path} (copied into vpn-state, so the file can be deleted afterwards).",
                      f"New config: endpoint {host}, server address {ip}:51820", "Kept the config used until now, as Previous config.",
                      "==> Stopping the current stack", "==> Starting the stack in 'vpn' mode", "VPN is up. gluetun's exit IP: 203.0.113.121",
                      "==> Tunnel confirmed, starting AIOStreams"]:
                say(l, 0.5)
            if self.has_config:
                self.previous = {"changed_at": time.time(), "endpoint_host": self.vpn_host, "endpoint_ip": self.vpn_ip}
            self.vpn_host, self.vpn_ip, self.has_config = host, ip, True
            if action.args[-1] == "on":
                self.vpn = "on"
        elif action.id == "watchdog.uninstall":
            say("Removed the watchdog's timer, services and saved state.", 0.4)
            self.wd_configured = False
            self.wd_running = False
        elif action.id in ("watchdog.start", "watchdog.stop", "watchdog.test", "watchdog.topic"):
            if action.id == "watchdog.topic":
                self.wd_topic = action.stdin.strip()
                self.wd_events.insert(0, {"at": int(time.time()), "kind": "topic", "text": "Alert topic changed."})
                say("Topic saved. Sending a test alert to it...", 0.4)
            if action.id in ("watchdog.test", "watchdog.topic"):
                self.wd_events.insert(0, {"at": int(time.time()), "kind": "test", "text": "Test alert sent."})
                say("Sent. Check your device.", 0.4)
            else:
                self.wd_running = action.id == "watchdog.start"
                self.wd_events.insert(0, {"at": int(time.time()), "kind": "start" if self.wd_running else "stop",
                                          "text": "Watchdog started." if self.wd_running else "Watchdog stopped."})
                say("Watchdog started, checking every 2min." if self.wd_running else "Watchdog stopped.", 0.4)
        elif action.id == "vpn.uninstall":
            for l in ["==> Switching back to direct mode first", "==> Removing gluetun container, if it still exists",
                      *(["==> Removing the gluetun Docker image"] if "remove-image" in action.args else []),
                      "==> Removing saved VPN state (vpn-state/). This is where the private key was stored for toggling",
                      *([f"Deleted {c['path']}." for c in self.demo_files] if "delete-confs" in action.args else []),
                      "Done. You're back on a plain AIOStreams + Caddy stack with no VPN layer."]:
                say(l, 0.5)
            self.vpn = "none"
        elif action.id == "vpn.update":
            for l in ["==> Pulling latest gluetun (v3 stable channel)", "Status: Image is up to date for qmcgaw/gluetun:v3",
                      "gluetun is already on the newest v3 release. Nothing restarted."]:
                say(l, 0.5)
        elif action.id == "stack.backup":
            say("==> Creating backup"); say("Backup written to /root/aiostreams-backup-20261009-161500.tar.gz")
            say("!! This file contains your SECRET_KEY, all logins and your WireGuard private key.")
        else:
            say("Done.")
        return 0
