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
            "scripts": [{"id": i, "label": l, "file": f, "present": i in ("aiostreams", "mediaflow", "webhook")} for i, l, f in SCRIPTS], "overall": overall, "headline": headline, "services": services,
            "watchdog": {"configured": True, "running": True, "last_check": "09 Oct 2026, 16:02:11 UTC OK", "alert_state": "up"},
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
        elif action.id == "stack.backup":
            say("==> Creating backup"); say("Backup written to /root/aiostreams-backup-20261009-161500.tar.gz")
            say("!! This file contains your SECRET_KEY, all logins and your WireGuard private key.")
        else:
            say("Done.")
        return 0
