"""Talks to the real server: Docker for container state and logs, the install
folder for config/state files, and the existing setup-*.sh scripts (run on the
HOST through nsenter) for every action."""
from __future__ import annotations

import json
import os
import pty
import re
import shlex
import signal
import socket
import ssl
import subprocess
import termios
import threading
import time
from datetime import datetime, timezone
from typing import Callable, Iterator

import docker

from . import config
from .actions import SCRIPTS, Action

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BACKUP_NAME = re.compile(r"aiostreams-backup-[0-9A-Za-z._-]+\.tar\.gz")
_BUILD_VERSION = re.compile(r"\d+\.\d+\.\d+")
_BUILD_TAG = re.compile(r"v\d+\.\d+\.\d+|\d{4}\.\d\d\.\d\d\.\d{4}-nightly")


def backup_path(b: dict) -> str:
    """Where to restore a backup from: root's copy, not a login user's."""
    d = next((d for d in b["dirs"] if not d.startswith(HOMES_DIR + "/")), b["dirs"][0])
    return f"{d}/{b['name']}"


def parse_vpn_addresses(out: str, code: int) -> dict:
    """setup-vpn-gluetun.sh addresses prints '<ip> <ms or -> [in-use] [recommended]'
    per line, fastest first; on failure, an 'XX  reason' line."""
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", l).strip() for l in out.splitlines()]
    if code != 0:
        why = next((l[2:].strip() for l in reversed(lines) if l.startswith("XX")), "") or "Couldn't look the addresses up."
        return {"addresses": [], "error": why}
    rows = []
    for l in lines:
        parts = l.split()
        if len(parts) < 2 or not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", parts[0]):
            continue
        try:
            ms = None if parts[1] == "-" else float(parts[1])
        except ValueError:
            continue
        rows.append({"ip": parts[0], "ms": ms, "in_use": "in-use" in parts[2:], "recommended": "recommended" in parts[2:]})
    return {"addresses": rows, "error": None if rows else "The lookup found no addresses."}


def parse_restore_check(out: str, code: int) -> dict:
    """setup-backup.sh restore --check prints '  ok: ...' and '  no: ...' lines
    and a 'Result:' line. One from before the check existed prints none."""
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.splitlines()]
    if not any(l.startswith("Result:") for l in lines):
        return {"ok": False, "notes": [], "reasons": [
            "This server's setup-backup.sh is from before restores could start here. "
            "Update it on the Terminal tab (AIOStreams menu, Update), then try again."]}
    reasons = [l.strip()[4:] for l in lines if l.strip().startswith("no: ")]
    notes = [l.strip()[4:] for l in lines if l.strip().startswith("ok: ")]
    return {"ok": code == 0 and not reasons, "reasons": reasons, "notes": notes}


def parse_backup_info(text: str) -> dict | None:
    kv = dict(l.split("=", 1) for l in text.splitlines() if "=" in l and not l.startswith("#"))
    v, t = kv.get("aiostreams_version", "").strip(), kv.get("aiostreams_tag", "").strip()
    if _BUILD_VERSION.fullmatch(v) and _BUILD_TAG.fullmatch(t):
        return {"version": v, "tag": t}
    return None
SET_ASIDE_NAME = re.compile(r"aiostreams\.pre-restore-(\d{8}-\d{6})")
HOMES_DIR = "/home"      # where other users keep their convenience copy (tests point this elsewhere)
HOST_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# name, container, display name, what it does, path (relative to install dir) that proves it's set up
SERVICES = [
    ("caddy", "caddy", "Caddy", "HTTPS front door", None),
    ("gluetun", "gluetun", "VPN tunnel", "gluetun, WireGuard", "VPN"),
    ("aiostreams", "aiostreams", "AIOStreams", "Addon aggregator", None),
    ("mediaflow", "mediaflow-proxy-light", "MediaFlow Proxy", "Faster video proxy", "mediaflow-state/docker-compose.yml"),
    ("webhook", "aios-webhook-relay", "Webhook relay", "Webhooks to phone alerts", "webhook-relay-state/docker-compose.yml"),
]
ADDONS = {"mediaflow", "webhook"}
# Services the panel may restart on their own. Caddy has the stack-wide Restart,
# and bouncing the VPN tunnel can strand the containers routed through it.
RESTARTABLE = {"aiostreams", "mediaflow", "webhook"}


def _read(path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


MENU_NOISE = re.compile(
    r"^\s*\d{1,2}\) "                                   # "  3) Start AIOStreams" menu rows
    r"|^What would you like to do\?"
    r"|^Existing AIOStreams installation detected"
    r"|^=== AIOStreams (Watchdog|Webhook Relay) ===$"
    r"|^=== MediaFlow Proxy Light control ===$"
    r"|^Update AIOStreams:$"
    r"|^Exiting\.$")


# Prompts the scripts print without a newline (we answer them ourselves).
PROMPT = re.compile(
    r"^(?:(?:Select an option|Choose an option|Choice) \[[^\]]*\](?: \(current[^)]*\))?: "
    r"|[^\n:]*\? \[[yY]/[nN]\]: "
    r"|Continue now that you've read this\.\.\. )+")


def clean_line(line: str) -> str | None:
    line = ANSI.sub("", line.rstrip("\r\n"))
    line = PROMPT.sub("", line)
    if MENU_NOISE.match(line):
        return None
    # Absorbed padding answer from actions.py, not a real problem.
    if line.strip() in ("!!  Not a valid option.", "!! Not a valid option.", "Not a valid option."):
        return None
    return line


class LogStream:
    """Iterates decoded log lines; close() ends it from another thread."""

    def __init__(self, raw):
        self._raw = raw

    def __iter__(self) -> Iterator[str]:
        buf = b""
        for chunk in self._raw:
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                yield line.decode("utf-8", "replace").rstrip("\r")
        if buf:
            yield buf.decode("utf-8", "replace")

    def close(self):
        try:
            self._raw.close()
        except Exception:
            pass


class Backend:
    def __init__(self):
        self._client = None
        self._stats: dict[str, dict] = {}
        self._last_view = 0.0          # when /api/status was last asked for
        self._cert_cache: dict = {}
        threading.Thread(target=self._stats_loop, daemon=True).start()

    @property
    def client(self):
        # Created on first use, not at startup, so the panel still opens (and
        # says "can't reach Docker") if Docker is down when the container starts.
        # A pinned API version avoids a connection attempt in the constructor.
        if self._client is None:
            self._client = docker.DockerClient(base_url="unix:///var/run/docker.sock", timeout=15, version="1.41")
        return self._client

    # ---- paths ---------------------------------------------------------
    @property
    def home(self) -> str:
        return str(config.ROOT_HOME)

    def p(self, rel: str):
        return config.INSTALL_DIR / rel

    # ---- container stats (background, so /api/status stays fast) --------
    def _stats_loop(self):
        # Sampling every container costs Docker real CPU, so only do it while
        # somebody has the panel open (status polls keep _last_view fresh).
        while True:
            if time.time() - self._last_view > 45:
                self._stats = {}
                time.sleep(2)
                continue
            try:
                for c in self.client.containers.list():
                    try:
                        s = c.stats(stream=False)
                        cpu = s["cpu_stats"]["cpu_usage"]["total_usage"] - s["precpu_stats"]["cpu_usage"]["total_usage"]
                        sysd = s["cpu_stats"].get("system_cpu_usage", 0) - s["precpu_stats"].get("system_cpu_usage", 0)
                        ncpu = s["cpu_stats"].get("online_cpus") or 1
                        pct = (cpu / sysd * ncpu * 100.0) if sysd > 0 else 0.0
                        ms = s.get("memory_stats", {})
                        used = ms.get("usage", 0) - ms.get("stats", {}).get("inactive_file", ms.get("stats", {}).get("cache", 0))
                        self._stats[c.name] = {"cpu": round(max(pct, 0), 1), "mem": max(used, 0)}
                    except Exception:
                        pass
            except Exception:
                pass
            time.sleep(5)

    # ---- status --------------------------------------------------------
    def _cert(self, host: str) -> dict | None:
        now = time.time()
        hit = self._cert_cache.get(host)
        if hit and hit[0] > now:
            return hit[1]
        try:
            ctx = ssl.create_default_context()
            with socket.create_connection((host, 443), timeout=4) as raw:
                with ctx.wrap_socket(raw, server_hostname=host) as tls:
                    na = ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"])
            val = {"host": host, "days_left": int((na - now) // 86400), "ok": True}
            ttl = 1800
        except Exception as e:
            val = {"host": host, "ok": False, "error": type(e).__name__}
            ttl = 300
        self._cert_cache[host] = (now + ttl, val)
        return val

    def _systemd_active(self, unit: str) -> bool:
        try:
            r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
                                "systemctl", "is-active", "--quiet", unit], timeout=5)
            return r.returncode == 0
        except Exception:
            return False

    # The login user: the owner of a home with a ~/aiostreams shortcut to the
    # install folder. Asked of the host, cached for a minute.
    _user_copy_cache: tuple[float, dict | None] = (0.0, None)

    def user_copy(self) -> dict | None:
        now = time.time()
        if now - self._user_copy_cache[0] < 15:
            return self._user_copy_cache[1]
        found = None
        try:
            r = subprocess.run(
                ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c",
                 'for h in "$1"/*/; do [ -d "${h}aiostreams" ] || continue; u=$(stat -c %U "$h" 2>/dev/null); '
                 '[ -n "$u" ] && [ "$u" != root ] && id "$u" >/dev/null 2>&1 || continue; '
                 'echo "U $u ${h}aiostreams"; '
                 # sudo: "nopass" (no password asked), "password", or "none"
                 'if runuser -u "$u" -- sudo -n true >/dev/null 2>&1; then echo "S nopass"; '
                 'elif sudo -l -U "$u" 2>/dev/null | grep -q "may run"; then echo "S password"; else echo "S none"; fi; '
                 'break; done',
                 "sh", HOMES_DIR],
                capture_output=True, text=True, timeout=10)
            info: dict = {}
            for line in r.stdout.splitlines():
                kind, _, rest = line.partition(" ")
                if kind == "U":
                    user, _, d = rest.partition(" ")
                    info["user"], info["dir"] = user, d.replace("//", "/")
                elif kind == "S":
                    info["sudo"] = rest.strip()
            if (re.fullmatch(r"[a-z_][a-z0-9_.-]{0,31}", info.get("user", ""))
                    and re.fullmatch(r"/[A-Za-z0-9_./-]+/aiostreams", info.get("dir", ""))):
                info.setdefault("sudo", "none")
                found = info
        except Exception:
            pass
        self._user_copy_cache = (now, found)
        return found

    # The AIOStreams build actually running, read from inside the container (the
    # image carries no version label). resources/metadata.json has the release
    # tag (v2.35.9, or 2026.10.10.1200-nightly); package.json covers images
    # without it. Asked once per container: an update recreates it, with a new id.
    _version_cache: tuple[str, tuple[str | None, str | None]] = ("", (None, None))
    _BUILD_JS = ("let o={};try{const m=require('/app/resources/metadata.json');o={v:m.version,t:m.tag}}catch(e){}"
                 "if(!o.v){try{o.v=require('/app/package.json').version}catch(e){}}JSON.stringify(o)")

    def _aio_build(self, c) -> tuple[str | None, str | None]:
        if c is None or not (c.attrs.get("State") or {}).get("Running"):
            return None, None
        cid = getattr(c, "id", "") or ""
        if cid and self._version_cache[0] == cid:
            return self._version_cache[1]
        ver = tag = None
        # The image is distroless: node lives at /nodejs/bin/node and isn't on
        # PATH. Plain "node" covers older images built on node:*-slim.
        for node in ("/nodejs/bin/node", "node"):
            try:
                r = c.exec_run([node, "-p", self._BUILD_JS])
                got = json.loads((r.output or b"").decode(errors="replace").strip()) if r.exit_code == 0 else None
            except Exception:
                continue
            if not isinstance(got, dict):
                continue
            v, t = str(got.get("v") or ""), str(got.get("t") or "")
            if re.fullmatch(r"\d+\.\d+\.\d+[0-9A-Za-z.+-]*", v):
                ver = v
                tag = t if re.fullmatch(r"v\d+\.\d+\.\d+|\d{4}\.\d\d\.\d\d\.\d{4}-nightly", t) else None
                break
        if cid:
            self._version_cache = (cid, (ver, tag))
        return ver, tag

    # The VPN page. Reads only the endpoint lines and the remembered name from
    # vpn-state, never the keys. With the tunnel on, asks from inside gluetun
    # where traffic leaves (so the answer is the VPN's exit, not this server),
    # at most once a minute unless asked to check now.
    _VPN_FRESH = 60
    _vpn_cache: dict | None = None

    def vpn_info(self, fresh: bool = False) -> dict:
        compose = _read(self.p("docker-compose.yml"))
        mode = "on" if "container_name: gluetun" in compose else ("off" if self.p("vpn-state/active").exists() else "none")
        saved = _read(self.p("vpn-state/docker-compose.vpn.yml"))
        ip = re.search(r"WIREGUARD_ENDPOINT_IP=(\S+)", saved)
        port = re.search(r"WIREGUARD_ENDPOINT_PORT=(\d+)", saved)
        host = _read(self.p("vpn-state/endpoint-host")).strip()
        out = {"mode": mode, "endpoint_host": host if re.fullmatch(r"[A-Za-z0-9.-]+", host) else None,
               "endpoint_ip": ip.group(1) if ip else None, "endpoint_port": port.group(1) if port else None,
               "connected": None, "exit_ip": None, "city": None, "region": None, "country": None, "org": None,
               "checked_at": None, "error": None}
        if mode != "on":
            return out
        now = time.time()
        cached = self._vpn_cache
        if cached and not fresh and now - cached["checked_at"] < self._VPN_FRESH:
            out.update(cached)
            return out
        got: dict = {"connected": False, "checked_at": now}
        try:
            c = self.client.containers.get("gluetun")
            if not (c.attrs.get("State") or {}).get("Running"):
                got["error"] = "The VPN container isn't running."
            else:
                for url in ("http://ipinfo.io/json", "http://ifconfig.me/ip", "http://icanhazip.com"):
                    r = c.exec_run(["wget", "-qO-", "-T", "6", url])
                    text = (r.output or b"").decode(errors="replace").strip() if r.exit_code == 0 else ""
                    if not text:
                        continue
                    if text.startswith("{"):
                        try:
                            j = json.loads(text)
                        except ValueError:
                            continue
                        if not isinstance(j, dict) or not j.get("ip"):
                            continue
                        got.update(exit_ip=str(j["ip"]), city=j.get("city"), region=j.get("region"),
                                   country=j.get("country"), org=j.get("org"))
                    elif re.fullmatch(r"[0-9a-fA-F.:]+", text):
                        got["exit_ip"] = text
                    else:
                        continue
                    got["connected"] = True
                    break
                if not got["connected"]:
                    got["error"] = "Couldn't reach the internet through the tunnel."
        except Exception:
            got["error"] = "Docker couldn't reach the VPN container."
        self._vpn_cache = got
        out.update(got)
        return out

    def status(self) -> dict:
        self._last_view = time.time()
        compose = _read(self.p("docker-compose.yml"))
        installed = bool(compose)
        vpn_mode = "container_name: gluetun" in compose
        # "on": tunnel in use. "off": set up once, now switched off. "none": never installed.
        vpn = "on" if vpn_mode else ("off" if self.p("vpn-state/active").exists() else "none")
        m = re.search(r"image:\s*viren070/aiostreams:(\S+)", compose)
        tag = m.group(1) if m else None
        m = re.search(r"BASE_URL=https?://([^\s\"']+)", compose)
        domain = m.group(1).strip("/") if m else None

        try:
            by_name = {c.name: c for c in self.client.containers.list(all=True)}
            docker_ok = True
        except Exception:
            by_name, docker_ok = {}, False

        stopped_marker = {
            "aiostreams": self.p("aiostreams-stopped-on-purpose").exists(),
            "mediaflow": self.p("mediaflow-state/stopped-on-purpose").exists(),
        }

        services = []
        for key, cname, title, role, needs in SERVICES:
            if needs == "VPN" and not vpn_mode:
                continue
            if needs and needs != "VPN" and not self.p(needs).exists():
                continue
            c = by_name.get(cname)
            svc = {"key": key, "container": cname, "name": title, "role": role,
                   "addon": key in ADDONS, "present": c is not None}
            if c is not None:
                st = c.attrs.get("State", {})
                health = (st.get("Health") or {}).get("Status")
                running = bool(st.get("Running"))
                if st.get("Restarting"):
                    state = "restarting"
                elif running and health == "unhealthy":
                    state = "unhealthy"
                elif running and health == "starting":
                    state = "starting"
                elif running:
                    state = "running"
                else:
                    state = "stopped"
                started = st.get("StartedAt") if running else None
                svc.update(
                    state=state, health=health, started_at=started,
                    exit_code=st.get("ExitCode"), restarts=c.attrs.get("RestartCount", 0),
                    image=(c.attrs.get("Config", {}).get("Image") or ""),
                    on_purpose=bool(stopped_marker.get(key)) and not running,
                    **{k: v for k, v in self._stats.get(cname, {}).items()} if running else {},
                )
            else:
                svc.update(state="missing", on_purpose=bool(stopped_marker.get(key)))
            services.append(svc)

        overall, headline = self._summarize(installed, docker_ok, services)

        # watchdog
        wd_dir = self.p("watchdog-state")
        watchdog = {"configured": (wd_dir / "config").exists()}
        if watchdog["configured"]:
            watchdog.update(
                running=self._systemd_active("aiostreams-watchdog.timer"),
                last_check=_read(wd_dir / "last-check").strip() or None,
                alert_state=_read(wd_dir / "alert-state").strip() or None,
            )

        host = self._host()
        version, build_tag = self._aio_build(by_name.get("aiostreams"))
        return {
            "installed": installed, "docker_ok": docker_ok,
            "domain": domain, "channel": tag, "version": version, "build_tag": build_tag,
            "vpn": vpn, "install_dir": str(config.INSTALL_DIR),
            "scripts": [{"id": i, "label": l, "file": f, "present": self.p(f).exists()} for i, l, f in SCRIPTS],
            "user_copy": self.user_copy(),
            "overall": overall, "headline": headline,
            "services": services, "watchdog": watchdog, "host": host,
            "cert": self._cert(domain) if domain and not domain.startswith("localhost") else None,
            "actions": self.available_actions(),
        }

    @staticmethod
    def _summarize(installed, docker_ok, services):
        if not docker_ok:
            return "down", "Can't reach Docker"
        if not installed:
            return "down", "No AIOStreams install found"
        bad, soft = [], []
        for s in services:
            if s["state"] in ("running",):
                continue
            if s.get("on_purpose"):
                soft.append(s)
            elif s["state"] == "starting":
                soft.append(s)
            else:
                bad.append(s)
        required_bad = [s for s in bad if not s["addon"]]
        if required_bad:
            names = " and ".join(s["name"] for s in required_bad)
            verb = "is" if len(required_bad) == 1 else "are"
            return "down", f"{names} {verb} down"
        if bad:
            return "degraded", f"{bad[0]['name']} is down"
        stopped = [s for s in soft if s.get("on_purpose")]
        if stopped:
            return "paused", f"{stopped[0]['name']} is stopped"
        if soft:
            return "degraded", f"{soft[0]['name']} is starting"
        return "ok", "Everything is up"

    def _host(self) -> dict:
        out: dict = {"cpus": os.cpu_count()}
        try:
            out["load"] = [float(x) for x in open("/proc/loadavg").read().split()[:3]]
            mi = {l.split(":")[0]: int(l.split()[1]) * 1024 for l in open("/proc/meminfo")}
            out["mem_total"], out["mem_used"] = mi["MemTotal"], mi["MemTotal"] - mi["MemAvailable"]
            out["uptime"] = int(float(open("/proc/uptime").read().split()[0]))
            sv = os.statvfs(config.INSTALL_DIR)
            out["disk_total"], out["disk_used"] = sv.f_blocks * sv.f_frsize, (sv.f_blocks - sv.f_bfree) * sv.f_frsize
        except Exception:
            pass
        return out

    def available_actions(self) -> list[dict]:
        from .actions import catalog
        res = []
        for a in catalog():
            ok = all(self.p(n).exists() for n in a.needs)
            res.append({"id": a.id, "label": a.label, "confirm": a.confirm, "available": ok})
        return res

    # ---- backups ---------------------------------------------------------
    # Asked of the host itself (through nsenter), not read from this container:
    # the container only has the install folder mounted, but the script saves
    # tarballs in root's home, plus a copy in the login user's home when it
    # was run through sudo. Also looked for inside the install folder, where
    # people sometimes drop one by hand.
    def _host_find(self, start: list[str], depth: int) -> list[str]:
        try:
            r = subprocess.run(
                ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "find", *start,
                 "-maxdepth", str(depth), "-type", "f", "-name", "aiostreams-backup-*.tar.gz",
                 "-printf", "%f\t%s\t%T@\t%h\n"],
                capture_output=True, text=True, timeout=10)
            return r.stdout.splitlines()
        except Exception:
            return []

    def backups(self) -> list[dict]:
        starts = list(dict.fromkeys([str(config.ROOT_HOME), str(config.INSTALL_DIR)]))
        rows = self._host_find(starts, 1)
        rows += self._host_find([HOMES_DIR], 2)
        found: dict[str, dict] = {}
        for row in rows:
            try:
                name, size, mtime, d = row.split("\t")
                b = found.setdefault(name, {"name": name, "size": int(size), "mtime": int(float(mtime)), "dirs": []})
                if d not in b["dirs"]:
                    b["dirs"].append(d)
            except ValueError:
                continue
        return sorted(found.values(), key=lambda b: b["mtime"], reverse=True)

    def backup_build(self, b: dict) -> dict | None:
        """The AIOStreams build a backup holds, from its backup-info, or None
        when it doesn't say (made before setup-backup.sh recorded it). Backups
        are written sorted, so tar finds backup-info near the start and stops."""
        path = f"{b['dirs'][0]}/{b['name']}"
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "tar", "-xzOf", path,
                            "--occurrence=1", f"{config.INSTALL_DIR.name}/backup-info"],
                           capture_output=True, text=True, timeout=180)
        return parse_backup_info(r.stdout) if r.returncode == 0 else None

    def vpn_addresses(self) -> dict:
        """The VPN config's server addresses, fastest first, timed from this
        server by setup-vpn-gluetun.sh. Changes nothing."""
        host = _read(self.p("vpn-state/endpoint-host")).strip() or None
        cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env", "-i",
               f"HOME={self.home}", f"PATH={HOST_PATH}", "TERM=dumb", "LANG=C.UTF-8",
               "bash", str(config.INSTALL_DIR / "setup-vpn-gluetun.sh"), "addresses"]
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
            out = parse_vpn_addresses(r.stdout + r.stderr, r.returncode)
        except subprocess.TimeoutExpired:
            out = {"addresses": [], "error": "The lookup took too long."}
        return {"host": host, **out}

    def restore_check(self, b: dict) -> dict:
        """Asks setup-backup.sh whether this backup restores here without
        questions (restore --check). Changes nothing."""
        cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env", "-i",
               f"HOME={self.home}", f"PATH={HOST_PATH}", "TERM=dumb", "LANG=C.UTF-8",
               "bash", str(config.INSTALL_DIR / "setup-aiostreams.sh"), "restore", "--check", backup_path(b)]
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
            out = r.stdout + r.stderr
        except subprocess.TimeoutExpired:
            return {"ok": False, "reasons": ["The check took too long."], "notes": []}
        return parse_restore_check(out, r.returncode)

    def delete_backup(self, name: str) -> list[str]:
        """Remove every copy of one backup. Only a name that backups() just
        found is accepted, and only in the folders it was found in."""
        if not BACKUP_NAME.fullmatch(name):
            raise ValueError("Not a backup file name.")
        item = next((b for b in self.backups() if b["name"] == name), None)
        if not item:
            raise FileNotFoundError(name)
        gone = []
        for d in item["dirs"]:
            r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "rm", "-f", "--", f"{d}/{name}"],
                               capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                gone.append(d)
        if not gone:
            raise OSError("Couldn't delete it.")
        return gone

    # ---- folders a restore set aside ------------------------------------
    # The restore moves the old install to aiostreams.pre-restore-<stamp>,
    # right next to the install folder, as a rollback copy and never removes
    # it. Listed here so they can be cleared from the panel. Only real
    # directories with exactly that name, next to the install folder, are
    # ever touched.
    def set_asides(self) -> list[dict]:
        out = self._set_asides_in(str(config.INSTALL_DIR.parent))
        return sorted(out, key=lambda x: x["name"], reverse=True)

    def _set_asides_in(self, parent: str) -> list[dict]:
        try:
            r = subprocess.run(
                ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "find", parent,
                 "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-name", "aiostreams.pre-restore-*", "-printf", "%f\t%C@\n"],
                capture_output=True, text=True, timeout=10)
            # %C@ is the change time, which the restore's mv sets: when it was set aside
            found = dict(l.split("\t", 1) for l in r.stdout.splitlines() if "\t" in l)
            names = [n for n in found if SET_ASIDE_NAME.fullmatch(n)]
        except Exception:
            return []
        sizes: dict[str, int] = {}
        if names:
            try:
                r = subprocess.run(
                    ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "du", "-sxb", "--",
                     *[f"{parent}/{n}" for n in names]],
                    capture_output=True, text=True, timeout=30)
                for line in r.stdout.splitlines():
                    size, _, path = line.partition("\t")
                    sizes[path.rsplit("/", 1)[-1]] = int(size)
            except Exception:
                pass
        out = []
        for n in names:
            try:
                when = int(float(found[n]))
            except ValueError:
                when = None
            out.append({"name": n, "dir": parent, "size": sizes.get(n), "when": when})
        return out

    def delete_set_aside(self, name: str) -> None:
        if not SET_ASIDE_NAME.fullmatch(name):
            raise ValueError("Not a set-aside folder name.")
        item = next((x for x in self.set_asides() if x["name"] == name), None)
        if not item:
            raise FileNotFoundError(name)
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
                            "rm", "-rf", "--one-file-system", "--", f"{item['dir']}/{name}"],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise OSError("Couldn't delete it.")

    def restart_service(self, key: str) -> str:
        """Restart one container and nothing else. Returns its display name."""
        if key not in RESTARTABLE:
            raise KeyError(key)
        _, cname, title, *_ = next(x for x in SERVICES if x[0] == key)
        c = self.client.containers.get(cname)      # NotFound when it isn't installed
        if c.status != "running":
            raise RuntimeError(f"{title} isn't running. Use Start instead.")
        c.restart(timeout=15)
        return title

    def reboot_host(self) -> None:
        """Reboot the whole server through the host's own systemd. Everything
        here has restart: unless-stopped, so the stack and this panel come back."""
        subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "systemctl", "reboot"],
                       capture_output=True, text=True, timeout=30, check=True)

    # ---- logs ------------------------------------------------------------
    def _cleared_path(self):
        return config.STATE_DIR / "logs-cleared.json"

    def _cleared(self) -> dict:
        try:
            return json.loads(self._cleared_path().read_text())
        except Exception:
            return {}

    def log_stream(self, container: str, tail: int) -> LogStream:
        c = self.client.containers.get(container)
        kw = {}
        since = self._cleared().get(container)
        if since:
            kw["since"] = since
        return LogStream(c.logs(stream=True, follow=True, tail=tail, timestamps=True, **kw))

    def clear_logs(self, container: str) -> str:
        """Hide everything logged so far, and keep it hidden after a reload.

        This only records a 'show only newer than' time. It never touches
        Docker's own log file: emptying that file behind Docker's back leaves
        Docker believing it is still the old size, and `docker logs --tail`
        then hangs and spins the daemon."""
        self.client.containers.get(container)          # NotFound if it doesn't exist
        marks = self._cleared()
        marks[container] = int(time.time())
        self._cleared_path().write_text(json.dumps(marks))
        return "hidden"

    # ---- run an action on the host ---------------------------------------
    def run(self, action: Action, emit: Callable[[str], None]) -> int:
        for need in action.needs:
            if not self.p(need).exists():
                emit(f"XX {need} was not found in {config.INSTALL_DIR}. Nothing was run.")
                return 127
        # The scripts learn who is at the keyboard from SUDO_USER, which sudo sets. The panel has no sudo,
        # so pass on the same user here (the owner of the home with a ~/aiostreams shortcut). That is
        # what makes a backup also land in that user's home, exactly as from the menu.
        who = ('u=""; for h in /home/*/; do [ -d "${h}aiostreams" ] && u=$(stat -c %U "$h" 2>/dev/null) && break; done; '
               'if [ -n "$u" ] && [ "$u" != root ] && id "$u" >/dev/null 2>&1; then '
               'export SUDO_USER="$u" SUDO_UID="$(id -u "$u")" SUDO_GID="$(id -g "$u")"; fi; ')
        inner = who + "cd {d} && exec bash {s} {a}".format(
            d=shlex.quote(str(config.INSTALL_DIR)), s=shlex.quote(action.script),
            a=" ".join(shlex.quote(x) for x in action.args))
        cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env", "-i",
               f"HOME={self.home}", f"PATH={HOST_PATH}", "TERM=dumb", "LANG=C.UTF-8", *action.env,
               "bash", "-c", inner]
        # Pseudo-terminal for stdin only (stdout stays a pipe so docker compose
        # prints plain progress, not cursor-movement escapes). Echo is off so
        # our typed answers don't show up in the output.
        master, slave = pty.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        proc = subprocess.Popen(cmd, stdin=slave, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1,
                                start_new_session=True)
        os.close(slave)
        timed_out = threading.Event()

        def killer():
            timed_out.set()
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                pass
        timer = threading.Timer(action.timeout, killer)
        timer.start()
        try:
            os.write(master, action.stdin.encode())
            last_blank = True
            for raw in proc.stdout:
                line = clean_line(raw)
                if line is None:
                    continue
                blank = not line.strip()
                if blank and last_blank:
                    continue            # collapse the gaps the hidden menus leave behind
                last_blank = blank
                emit(line)
            code = proc.wait()
        finally:
            timer.cancel()
            try:
                os.close(master)
            except OSError:
                pass
        if timed_out.is_set():
            emit(f"XX Stopped after {action.timeout}s without finishing.")
            return 124
        return code
