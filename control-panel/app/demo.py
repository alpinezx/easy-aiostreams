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
        self.wd_options = {"updates": False, "weekly": False}
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
        self.running = {"caddy": True, "gluetun": True, "aiostreams": True, "mediaflow-proxy-light": True, "aios-webhook-relay": True}
        if scenario == "down":
            self.running["aiostreams"] = False
        self.stopped_on_purpose = scenario == "paused"
        if scenario == "paused":
            self.running["aiostreams"] = False
        self.started = {k: datetime.now(timezone.utc) - timedelta(hours=random.randint(30, 400)) for k in self.running}
        self.hist = {k: [random.uniform(0.5, 6) for _ in range(30)] for k in self.running}

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
                       region="North Holland", country="NL", org="AS64500 Example VPN", checked_at=time.time())
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

    def set_watchdog_option(self, name: str, on: bool) -> None:
        self.wd_options[name] = on

    def clear_watchdog_events(self) -> None:
        self.wd_events = []

    def watchdog_info(self) -> dict:
        from .stack import mask_topic
        watches = ["https://streams.example.com", "Disk space", "HTTPS certificate"] + (["VPN tunnel", "AIOStreams through the VPN"] if self.vpn == "on" else []) + ["MediaFlow Proxy"]
        return {"configured": True, "running": self.wd_running, "alert_state": "up", "fails": 0,
                "warnings": [w for w in os.environ.get("UI_DEMO_WD_WARN", "").split(",") if w],
                "last_check": time.strftime("%d %b %Y, %H:%M:%S UTC", time.gmtime(time.time() - 40)) + " OK" if self.wd_running
                else time.strftime("%d %b %Y, %H:%M:%S UTC", time.gmtime(time.time() - 40)) + " STOPPED (watchdog disabled, no checks running)",
                "topic": mask_topic(self.wd_topic), "events": self.wd_events, "tally": self.wd_tally,
                "watches": watches, "every_min": 2, "threshold": 2,
                "options": dict(self.wd_options), "stable": self.channel != "nightly",
                "timezone": os.environ.get("UI_DEMO_TZ", "Europe/London")}

    def remove_script(self, script_id: str) -> str:
        from .actions import ADDON_STATE, SCRIPTS
        found = next(((i, f) for i, _, f in SCRIPTS if i == script_id), None)
        if not found or script_id not in ADDON_STATE:
            raise ValueError("Only an add-on's script can be removed.")
        if script_id == "vpn" and self.vpn != "none":
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
                ("mediaflow", "mediaflow-proxy-light", "MediaFlow Proxy", "Faster video proxy", True, "ghcr.io/mhdzumair/mediaflow-proxy-light:latest"),
                ("webhook", "aios-webhook-relay", "Webhook relay", "Webhooks to phone alerts", True, "python:3.13-alpine")]
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
                         mem=int({"caddy": 31, "gluetun": 44, "aiostreams": 318, "mediaflow": 22, "webhook": 19}[key] * MB * random.uniform(0.97, 1.03)))
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
                         "present": i in ("aiostreams", "vpn", "mediaflow", "watchdog", "webhook") and i not in self.removed_scripts,
                         "in_use": i != "vpn" or self.vpn != "none"} for i, l, f in SCRIPTS], "overall": overall, "headline": headline, "services": services,
            "watchdog": {"configured": True, "running": self.wd_running, "alert_state": "up",
                         "last_check": time.strftime("%d %b %Y, %H:%M:%S UTC", time.gmtime(time.time() - 40)) + (" OK" if self.wd_running else "")},
            "host": {"cpus": 2, "load": [0.21, 0.34, 0.29], "mem_total": 4 * GB, "mem_used": int(1.6 * GB),
                     "uptime": 41 * 86400 + 3 * 3600, "disk_total": 80 * GB, "disk_used": 23 * GB},
            "cert": {"host": "streams.example.com", "days_left": 61, "ok": True},
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

    def backups(self) -> list[dict]:
        now = int(time.time())
        return [b for b in self._all_backups(now) if b["name"] not in self._gone]

    def _all_backups(self, now):
        return self._made + [{"name": "aiostreams-backup-20261007-031500.tar.gz", "size": 4_812_330, "mtime": now - 2 * 86400, "dirs": ["/root", "/home/ubuntu"]},
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
