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
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterator

import docker

from . import config
from .actions import ADDON_STATE, SCRIPTS, Action
from .traffic import dev_counters, host_net
from .wgconf import check_wireguard_conf

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BACKUP_NAME = re.compile(r"aiostreams-backup-[0-9A-Za-z._-]+\.tar\.gz")
_BUILD_VERSION = re.compile(r"\d+\.\d+\.\d+")
_BUILD_TAG = re.compile(r"v\d+\.\d+\.\d+|\d{4}\.\d\d\.\d\d\.\d{4}-nightly")


def backup_path(b: dict) -> str:
    """Where to restore a backup from: root's copy, not a login user's."""
    d = next((d for d in b["dirs"] if not d.startswith(HOMES_DIR + "/")), b["dirs"][0])
    return f"{d}/{b['name']}"


VPN_CONF_KINDS = ("pasted", "previous", "prev-paste", "upload", "file")


def parse_vpn_configs(out: str, code: int) -> list[dict]:
    """setup-vpn-gluetun.sh list-configs: 'kind|path|endpoint|in-use' per line."""
    rows = []
    if code != 0:
        return rows
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 4 or parts[0] not in VPN_CONF_KINDS or not parts[1].startswith("/") or parts[3] not in ("0", "1"):
            continue
        ep = parts[2] if re.fullmatch(r"[A-Za-z0-9.-]+", parts[2]) else None
        rows.append({"kind": parts[0], "path": parts[1], "endpoint": ep, "in_use": parts[3] == "1"})
    return rows


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
def _proc_stat_cpu() -> str:
    """The "cpu" line of /proc/stat: time all the cores have spent on each kind of work."""
    with open("/proc/stat") as f:
        return f.readline()


# Prints y when a restart would finish installing updates: Ubuntu's flag file, or (Debian has
# none) a kernel installed since the last boot, by its file's change time. setup-aiostreams.sh's
# reboot_needed checks the same.
REBOOT_CHECK = ('if [ -e /var/run/reboot-required ]; then echo y; exit; fi; '
                'b=$(awk \'/^btime /{print $2}\' /proc/stat); '
                'for f in /boot/vmlinuz-*; do '
                'if [ -e "$f" ] && [ "$(stat -c %Z "$f")" -gt "${b:-0}" ]; then echo y; exit; fi; done')

# name, container, display name, what it does, path (relative to install dir) that proves it's set up
SERVICES = [
    ("caddy", "caddy", "Caddy", "HTTPS front door", None),
    ("gluetun", "gluetun", "VPN tunnel", "gluetun, WireGuard", "VPN"),
    ("aiostreams", "aiostreams", "AIOStreams", "Addon aggregator", None),
    ("mediaflow", "mediaflow-proxy-light", "MediaFlow Proxy", "Faster video proxy", "mediaflow-state/docker-compose.yml"),
    ("webhook", "aios-webhook-relay", "Webhook relay", "Webhooks to phone alerts", "webhook-relay-state/docker-compose.yml"),
    ("aiometadata", "aiometadata", "AIOMetadata", "Catalogs and metadata", "aiometadata-state/docker-compose.yml"),
    ("aiomanager", "aiomanager", "AIOManager", "Manages Stremio accounts", "aiomanager-state/docker-compose.yml"),
]
ADDONS = {"mediaflow", "webhook", "aiometadata", "aiomanager"}
# Services the panel may restart on their own. Caddy has the stack-wide Restart,
# and bouncing the VPN tunnel can strand the containers routed through it.
RESTARTABLE = {"aiostreams", "mediaflow", "aiometadata", "aiomanager"}
# AIOManager's logins, counted inside its container (its image has Node, not a shell).
# Rows without a password are its own bookkeeping. Read-only.
_LOGIN_COUNT_JS = ("const D=require('better-sqlite3');"
                   "const db=new D('/app/data/aio.db',{readonly:true,fileMustExist:true});"
                   "console.log(db.prepare(\"SELECT COUNT(*) AS n FROM kv_store WHERE password IS NOT NULL AND password <> ''\").get().n);"
                   "db.close()")


# The AIOStreams menu hands backup and restore, and Maintenance, to these, so the
# Scripts tab's AIOStreams row compares and updates them with it
WITH_MAIN = ("setup-backup.sh", "setup-maintenance.sh")

TIME_RE = re.compile(r"^([01]?\d|2[0-3]):[0-5]\d$")


def weekly_time(kv: dict) -> str:
    """The weekly check-in's HH:MM: weekly_time, or an older script's weekly_hour, or 10:00."""
    t = kv.get("weekly_time", "")
    if TIME_RE.match(t):
        hh, mm = t.split(":")
        return f"{int(hh):02d}:{int(mm):02d}"
    h = kv.get("weekly_hour", "")
    return f"{int(h):02d}:00" if h.isdigit() and int(h) < 24 else "10:00"


def mask_topic(topic: str) -> str | None:
    """Enough of the topic to tell which one it is, never enough to subscribe to it."""
    if not topic:
        return None
    return topic[:5] + "\u2022" * 6 + topic[-2:] if len(topic) >= 10 else "\u2022" * 8


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
        self._netprev: dict[str, tuple[float, int, int]] = {}   # each container's last byte counts, for its speed
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
        # Docker takes a second or two to answer for each container, so they're
        # asked all at once: fresh figures about every 3s, however many there are.
        pool = ThreadPoolExecutor(max_workers=8)
        while True:
            if time.time() - self._last_view > 45:
                self._stats = {}
                time.sleep(2)
                continue
            try:
                list(pool.map(self._sample, self.client.containers.list()))
            except Exception:
                pass
            time.sleep(1)

    def _sample(self, c):
        """One container's CPU, memory and network speed, into _stats."""
        try:
            s = c.stats(stream=False)
            cpu = s["cpu_stats"]["cpu_usage"]["total_usage"] - s["precpu_stats"]["cpu_usage"]["total_usage"]
            sysd = s["cpu_stats"].get("system_cpu_usage", 0) - s["precpu_stats"].get("system_cpu_usage", 0)
            ncpu = s["cpu_stats"].get("online_cpus") or 1
            pct = (cpu / sysd * ncpu * 100.0) if sysd > 0 else 0.0
            ms = s.get("memory_stats", {})
            used = ms.get("usage", 0) - ms.get("stats", {}).get("inactive_file", ms.get("stats", {}).get("cache", 0))
            row = {"cpu": round(max(pct, 0), 1), "mem": max(used, 0)}
            # Network speed, down and up, from its byte counts since the last look. A
            # container on the VPN's network (AIOStreams) has none of its own: gluetun's covers it.
            nets = s.get("networks") or {}
            if nets:
                now = time.time()
                rx = sum(n.get("rx_bytes", 0) for n in nets.values())
                tx = sum(n.get("tx_bytes", 0) for n in nets.values())
                prev = self._netprev.get(c.name)
                self._netprev[c.name] = (now, rx, tx)
                if prev and 0 < now - prev[0] < 120 and rx >= prev[1] and tx >= prev[2]:
                    row["rx"], row["tx"] = (rx - prev[1]) / (now - prev[0]), (tx - prev[2]) / (now - prev[0])
            self._stats[c.name] = row
        except Exception:
            pass

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
                    pc = tls.getpeercert()
            na = ssl.cert_time_to_seconds(pc["notAfter"])
            nb = ssl.cert_time_to_seconds(pc["notBefore"]) if pc.get("notBefore") else None
            # days_total, the certificate's whole life, says when renewal is overdue:
            # Caddy renews with about a third left, whatever the length
            val = {"host": host, "days_left": int((na - now) // 86400), "ok": True,
                   "days_total": round((na - nb) / 86400) if nb else None}
            ttl = 1800
        except Exception as e:
            val = {"host": host, "ok": False, "error": type(e).__name__}
            # Tried again after a minute: a newly added site usually fails only until
            # Caddy has its certificate, a minute or so after the add-on starts
            ttl = 60
        self._cert_cache[host] = (now + ttl, val)
        return val

    # Which add-on owns a caddy.d snippet, by its file name
    _SITE_LABELS = (("mediaflow", "MediaFlow"), ("aiometadata", "AIOMetadata"), ("aiomanager", "AIOManager"),
                    ("webhook", "Webhook relay"), ("ui", "Control panel"))

    def _caddy_sites(self, main_domain: str | None) -> list[tuple[str, str]]:
        """(label, host) for every site Caddy serves: the main domain from the Caddyfile and
        one per add-on snippet in caddy.d. Read from the files, so a new add-on shows up
        without the panel needing to know about it."""
        sites: list[tuple[str, str]] = []
        seen: set[str] = set()

        def add(label: str, host: str):
            host = host.lower()
            if host not in seen and not host.startswith("localhost"):
                seen.add(host)
                sites.append((label, host))
        if main_domain:
            add("AIOStreams", main_domain)
        files = [("Site", self.p("Caddyfile"))]
        try:
            files += [(f.name, f) for f in sorted(self.p("caddy.d").glob("*.caddy"))]
        except OSError:
            pass
        for name, f in files:
            label = next((lbl for key, lbl in self._SITE_LABELS if key in name), "Site")
            for m in re.finditer(r"^([A-Za-z0-9.-]+\.[A-Za-z0-9-]+)(?=\s*\{)", _read(f), re.M):
                add(label if name != "Site" else "AIOStreams", m.group(1))
        return sites

    def _certs(self, main_domain: str | None) -> list[dict]:
        sites = self._caddy_sites(main_domain)
        if not sites:
            return []
        # Parallel, so several unreachable hosts cost one timeout, not one each
        out: list[dict | None] = [None] * len(sites)

        def work(i: int):
            label, host = sites[i]
            c = self._cert(host)
            out[i] = {**c, "label": label} if c else None
        threads = [threading.Thread(target=work, args=(i,), daemon=True) for i in range(len(sites))]
        for t in threads:
            t.start()
        for t in threads:
            t.join(8)
        return [c for c in out if c]

    def _systemd_enabled(self, unit: str) -> bool:
        try:
            r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
                                "systemctl", "is-enabled", "--quiet", unit], timeout=5)
            return r.returncode == 0
        except Exception:
            return False

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

    def host_counters(self) -> tuple[int, int] | None:
        """The server's own bytes down and up since boot, on the network card its internet
        traffic leaves by (named differently on each server: eth0, ens3, enp0s6...). Read from
        the host's /proc (the panel shares its process table), the same on any Linux."""
        return host_net(Path("/proc/1/net"))

    def vpn_counters(self) -> tuple[int, int] | None:
        """The tunnel's bytes down and up since gluetun started, for the traffic graph;
        None unless the VPN is on and gluetun answers."""
        if "container_name: gluetun" not in _read(self.p("docker-compose.yml")):
            return None
        r = self.client.containers.get("gluetun").exec_run(["cat", "/proc/net/dev"])
        if r.exit_code != 0:
            return None
        return dev_counters((r.output or b"").decode(errors="replace"), ["tun0", "wg0"])

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
               "checked_at": None, "error": None, "previous": self._vpn_previous(),
               "has_config": "WIREGUARD_PRIVATE_KEY=" in saved}
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
                if got["connected"]:
                    got["dns"] = self._vpn_dns(c)
                if not got["connected"]:
                    got["error"] = "Couldn't reach the internet through the tunnel."
        except Exception:
            got["error"] = "Docker couldn't reach the VPN container."
        self._vpn_cache = got
        out.update(got)
        return out

    # Which DNS servers gluetun is talking to, and whether over DNS-over-TLS (port
    # 853), as the VPN script's "DNS: encrypted" check: a lookup is made first so
    # there's a connection to see. Read from /proc/net/tcp rather than with ss,
    # which the gluetun image doesn't have.
    _DNS_NAMES = {"1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "9.9.9.9": "Quad9", "149.112.112.112": "Quad9"}

    def _vpn_dns(self, c) -> dict:
        try:
            r = c.exec_run(["sh", "-c", "(nslookup example.com >/dev/null 2>&1 || getent hosts example.com >/dev/null 2>&1) & "
                                        "sleep 1; cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"])
            text = (r.output or b"").decode(errors="replace")
        except Exception:
            return {"state": "unknown", "via": []}
        dot, plain = [], False
        for line in text.splitlines()[1:]:
            f = line.split()
            if len(f) < 4 or ":" not in f[2] or f[3] == "0A":      # 0A: listening, not a connection
                continue
            addr, port = f[2].split(":")
            if len(addr) == 32 and addr.startswith("0000000000000000FFFF0000"):
                addr = addr[-8:]                                  # an IPv4 address in tcp6
            if len(addr) != 8:
                continue
            ip = ".".join(str(int(addr[i:i + 2], 16)) for i in (6, 4, 2, 0))
            p = int(port, 16)
            if p == 853:
                dot.append(self._DNS_NAMES.get(ip, ip))
            elif p == 53 and not ip.startswith("127."):
                plain = True
        via = sorted(set(dot))
        return {"state": "encrypted" if via else "plain" if plain else "unknown", "via": via}

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
            "aiometadata": self.p("aiometadata-state/stopped-on-purpose").exists(),
            "aiomanager": self.p("aiomanager-state/stopped-on-purpose").exists(),
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
            "scripts": [{"id": i, "label": l, "file": f, "present": self.p(f).exists(),
                         "in_use": i not in ADDON_STATE or self.addon_set_up(i)} for i, l, f in SCRIPTS],
            "user_copy": self.user_copy(),
            "overall": overall, "headline": headline,
            "services": services, "watchdog": watchdog, "host": host,
            "cert": self._cert(domain) if domain and not domain.startswith("localhost") else None,
            "certs": self._certs(domain),
            "backup": self.backup_summary() if installed else None,
            "aiometadata": self._aiometadata(by_name.get("aiometadata")),
            "aiomanager": self._aiomanager(by_name.get("aiomanager")),
            "mediaflow": self._mediaflow(by_name.get("mediaflow-proxy-light")),
            "actions": self.available_actions(),
        }

    def _mediaflow(self, container) -> dict | None:
        """MediaFlow's domain and the release it runs, once it's set up. version is None
        while it still runs "latest" (set up before pinning; its next Start pins it).
        The API password in the same file is never read here."""
        c = self._addon_conf("mediaflow")
        domain, version = c.get("DOMAIN"), c.get("MF_VERSION") or None
        if container is not None:
            m = re.search(r":(\d+\.\d+\.\d+)$", container.attrs.get("Config", {}).get("Image") or "")
            version = m.group(1) if m else None
        if not domain:
            return None
        if version and not re.fullmatch(r"\d+\.\d+\.\d+", version):
            version = None
        return {"domain": domain, "version": version}

    def _aiomanager(self, container) -> dict | None:
        """AIOManager's domain, release, sign-ups and logins, once it's installed. Its
        settings file holds no secrets (server_secret.key is in its data folder, never read)."""
        c = self._addon_conf("aiomanager")
        domain, version = c.get("DOMAIN"), c.get("AIOMAN_VERSION")
        running = False
        if container is not None:
            m = re.search(r":(\d+\.\d+\.\d+)$", container.attrs.get("Config", {}).get("Image") or "")
            if m:
                version = m.group(1)
            running = bool(container.attrs.get("State", {}).get("Running"))
        if not domain or not version or not re.fullmatch(r"\d+\.\d+\.\d+", version):
            return None
        until = c.get("SIGNUPS_UNTIL") or ""
        return {"domain": domain, "version": version,
                "signups": "open" if c.get("SIGNUPS") == "open" else "closed",
                "signups_until": int(until) if until.isdigit() else None,
                "logins": self._login_count(container) if running else None}

    def _login_count(self, container) -> int | None:
        """How many logins AIOManager holds, asked of its own container once a minute at most."""
        now = time.time()
        at, n = getattr(self, "_logins_cache", (0.0, None))
        if now - at < 60:
            return n
        n = None
        try:
            r = container.exec_run(["/nodejs/bin/node", "-e", _LOGIN_COUNT_JS], workdir="/app/server")
            out = (r.output or b"").decode(errors="replace").strip()
            if r.exit_code == 0 and out.isdigit():
                n = int(out)
        except Exception:
            pass
        self._logins_cache = (now, n)
        return n

    def _aiometadata(self, container) -> dict | None:
        """AIOMetadata's domain and the release it runs, once it's installed. Only those two
        are read from its saved settings: the same file holds its passwords."""
        conf = _read(self.p("aiometadata-state/config"))
        if not conf:
            return None

        def get(key):
            m = re.search(rf"^{key}=['\"]?([^'\"\s]+)", conf, re.M)
            return m.group(1) if m else None
        domain, version = get("DOMAIN"), get("AIOM_VERSION")
        # The running image's tag is the truth when the container is there; the pinned one otherwise
        if container is not None:
            m = re.search(r":(\d+\.\d+\.\d+)$", container.attrs.get("Config", {}).get("Image") or "")
            if m:
                version = m.group(1)
        if not domain or not version or not re.fullmatch(r"\d+\.\d+\.\d+", version):
            return None
        return {"domain": domain, "version": version}

    # The Add-ons page. Each add-on's saved settings, as its script writes them (KEY='value').
    _ADDON_CONF = {"aiometadata": "aiometadata-state/config", "aiomanager": "aiomanager-state/config",
                   "mediaflow": "mediaflow-state/config",
                   "webhook": "webhook-relay-state/config"}
    # The secrets the page can show, each read only when asked for, one at a time
    _ADDON_SECRETS = {
        ("aiometadata", "addon_password"): lambda c: c.get("ADDON_PASSWORD"),
        ("aiometadata", "admin_key"): lambda c: c.get("ADMIN_KEY"),
        ("mediaflow", "api_password"): lambda c: c.get("MEDIAFLOW_API_PASSWORD"),
    }

    def _addon_conf(self, addon: str) -> dict:
        out = {}
        for m in re.finditer(r"^([A-Z][A-Z0-9_]*)=(.*)$", _read(self.p(self._ADDON_CONF[addon])), re.M):
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            out[m.group(1)] = v
        return out

    def addons_info(self) -> list[dict]:
        """What each installed add-on's script shows (its Status and Show options), with
        the secrets left out: the page asks for one with addon_secret when the eye or
        Copy is pressed. VPN and Phone alerts have their own pages' data."""
        out = []
        c = self._addon_conf("aiometadata")
        if c.get("DOMAIN"):
            out.append({"id": "aiometadata", "domain": c["DOMAIN"], "version": c.get("AIOM_VERSION") or None})
        c = self._addon_conf("aiomanager")
        if c.get("DOMAIN"):
            # Sign-ups and logins come from the status, which the page already has
            out.append({"id": "aiomanager", "domain": c["DOMAIN"], "version": c.get("AIOMAN_VERSION") or None})
        c = self._addon_conf("mediaflow")
        if c.get("DOMAIN"):
            # An outbound proxy's address without its login, as the script's Status prints it
            m = re.match(r"^([a-z0-9]+://)(?:[^@/]*@)?([^/?#]+)", c.get("MEDIAFLOW_PROXY_URL") or "", re.I)
            # url: what AIOStreams' URL field takes, MediaFlow's address between the containers
            out.append({"id": "mediaflow", "domain": c["DOMAIN"], "url": "http://mediaflow-proxy-light:8888",
                        "proxy": m.group(1) + m.group(2) if m else None})
        # The retired webhook relay: only its address, for a card whose one job is Uninstall
        c = self._addon_conf("webhook")
        if c.get("DOMAIN"):
            out.append({"id": "webhook", "domain": c["DOMAIN"], "retired": True})
        return out

    def addon_secret(self, addon: str, name: str) -> str | None:
        get = self._ADDON_SECRETS.get((addon, name))
        return get(self._addon_conf(addon)) or None if get else None

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
        return "ok", "All running"

    def _cpu_pct(self) -> float | None:
        """How busy all the CPUs were since the last look, worked out as AIOStreams' own
        dashboard does, so the two agree. The first look, or one after a long gap,
        measures a quarter of a second instead."""
        def read() -> tuple[float, int, int]:
            f = [int(x) for x in _proc_stat_cpu().split()[1:9]]
            return time.monotonic(), sum(f), f[3] + f[4]      # all time, then idle + iowait
        now = read()
        prev = getattr(self, "_cpu_prev", None)
        if prev is None or now[0] - prev[0] > 60:
            time.sleep(0.25)
            prev, now = now, read()
        total, idle = now[1] - prev[1], now[2] - prev[2]
        if total <= 0:                  # two looks within one tick: keep the last figure
            return getattr(self, "_cpu_last", None)
        self._cpu_prev = now
        self._cpu_last = round(100 * (total - idle) / total, 1)
        return self._cpu_last

    def _host(self) -> dict:
        out: dict = {"cpus": os.cpu_count()}
        try:
            out["cpu_pct"] = self._cpu_pct()
        except Exception:
            pass
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

    # ---- detached actions (the Maintenance page) ---------------------------
    # Run as a systemd unit on the host, writing to ui-state/maint.log, with the
    # exit code in maint.log.code once it ends. The panel follows the log; if
    # Docker restarts this container meanwhile, the unit carries on and the
    # Maintenance page shows how it ended from the same files.
    MAINT_UNIT = "aios-maintenance"

    def _maint_running(self) -> bool:
        return self._systemd_active(self.MAINT_UNIT + ".service")

    def _run_detached(self, action: Action, emit: Callable[[str], None]) -> int:
        if self._maint_running():
            emit("XX Another maintenance job is still running. Wait for it to finish.")
            return 1
        log_host = str(config.INSTALL_DIR / "ui-state" / "maint.log")
        log_here = config.STATE_DIR / "maint.log"
        code_here = config.STATE_DIR / "maint.log.code"
        for f in (log_here, code_here):
            try:
                f.unlink()
            except FileNotFoundError:
                pass
        (config.STATE_DIR / "maint.what").write_text(action.label + "\n")
        who = ('u=""; for h in /home/*/; do [ -d "${h}aiostreams" ] && u=$(stat -c %U "$h" 2>/dev/null) && break; done; '
               'if [ -n "$u" ] && [ "$u" != root ] && id "$u" >/dev/null 2>&1; then '
               'export SUDO_USER="$u" SUDO_UID="$(id -u "$u")" SUDO_GID="$(id -g "$u")"; fi; ')
        inner = who + 'cd {d} && bash {s} {a} > {l} 2>&1 < /dev/null; echo $? > {l}.code'.format(
            d=shlex.quote(str(config.INSTALL_DIR)), s=shlex.quote(action.script),
            a=" ".join(shlex.quote(x) for x in action.args), l=shlex.quote(log_host))
        cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "systemd-run",
               f"--unit={self.MAINT_UNIT}", "--collect", "--quiet", f"--property=RuntimeMaxSec={action.timeout}",
               f"--setenv=HOME={self.home}", f"--setenv=PATH={HOST_PATH}", "--setenv=TERM=dumb",
               "--setenv=LANG=C.UTF-8", "/bin/bash", "-c", inner]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            emit(f"XX Couldn't start it ({(r.stderr or r.stdout).strip() or 'systemd-run failed'}).")
            return 1
        emit("==> Running on the server itself, so it carries on even if this page reconnects.")
        pos, start = 0, time.time()
        while True:
            try:
                with open(log_here, encoding="utf-8", errors="replace") as fh:
                    fh.seek(pos)
                    chunk = fh.read()
                    pos = fh.tell()
                for raw in chunk.splitlines():
                    line = clean_line(raw)
                    if line is not None:
                        emit(line)
            except FileNotFoundError:
                pass
            if code_here.exists():
                try:
                    return int(code_here.read_text().strip() or 1)
                except ValueError:
                    return 1
            if time.time() - start > action.timeout + 60 or (time.time() - start > 20 and not self._maint_running()):
                emit("XX It stopped without saying how it ended.")
                return 1
            time.sleep(1)

    _maint_cache: tuple[float, dict | None] = (0.0, None)

    def _on_host(self, *args: str, timeout: int = 20) -> str:
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", *args],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""

    def maintenance_info(self, force: bool = False) -> dict:
        """The Maintenance page. The looking-up is slow-ish (apt, Docker's disk
        usage), so it's kept for 5 minutes unless asked again; Restart needed isn't."""
        now = time.time()
        at, hit = self._maint_cache
        if hit and not force and now - at < 300:
            # Restart needed is one quick look, so it's always fresh (an update over SSH, say)
            updates = hit["updates"]
            if updates.get("available"):
                updates = {**updates, "reboot": self.reboot_needed()}
            return {**hit, "updates": updates, "last": self._maint_last()}
        info = {"space": self._maint_space(), "updates": self._maint_updates(), "logs": self._maint_logs(),
                "checked_at": now}
        self._maint_cache = (now, info)
        return {**info, "last": self._maint_last()}

    def _maint_space(self) -> dict:
        images = count = build = journal = 0
        try:
            df = self.client.df()
            # What free-space removes: untagged images and AIOStreams images no
            # container uses, counted by the space only they hold (layers shared
            # with an image that stays aren't freed)
            for im in df.get("Images") or []:
                tags = [t for t in (im.get("RepoTags") or []) if t != "<none>:<none>"]
                if im.get("Containers", 0) == 0 and (not tags or all(t.startswith("viren070/aiostreams:") for t in tags)):
                    shared = int(im.get("SharedSize") or 0)
                    images += max(0, int(im.get("Size") or 0) - max(shared, 0))
                    count += 1
            # Shared records belong to an image that stays, so Docker keeps them
            build = sum(int(c.get("Size") or 0) for c in (df.get("BuildCache") or [])
                        if not c.get("InUse") and not c.get("Shared"))
        except Exception:
            pass
        try:
            m = re.search(r"take up ([\d.]+)([KMGT]?)", self._on_host("journalctl", "--disk-usage"))
            if m:
                total = float(m.group(1)) * 1024 ** "BKMGT".index(m.group(2) or "B")
                journal = max(0, int(total - 100 * 1024 ** 2))
        except Exception:
            pass
        return {"images": images, "image_count": count, "build": build, "journal": journal}

    def _maint_updates(self) -> dict:
        try:
            out = self._on_host("apt", "list", "--upgradable", timeout=40)
        except Exception:
            return {"available": False}
        if not out and not self._on_host("sh", "-c", "command -v apt"):
            return {"available": False}
        lines = [l for l in out.splitlines() if "/" in l and "[upgradable" in l]
        # Only what Install updates would install now: Ubuntu phases some updates in (a growing
        # share of servers over a few days) and apt holds those back until this server's turn.
        # A simulated upgrade, as Install updates runs it, says which; they're counted apart.
        phased = 0
        if lines:
            sim = self._on_host("apt-get", "-s", "-o", "Debug::NoLocking=1", "upgrade", "--with-new-pkgs", timeout=60)
            if sim:
                ready = {l.split()[1] for l in sim.splitlines() if l.startswith("Inst ") and len(l.split()) > 1}
                now = [l for l in lines if l.split("/", 1)[0] in ready]
                phased, lines = len(lines) - len(now), now
        stamp = self._on_host("sh", "-c", "stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null "
                                       "|| stat -c %Y /var/lib/apt/lists 2>/dev/null").strip()
        return {"available": True, "count": len(lines), "security": sum("-security" in l for l in lines), "phased": phased,
                "reboot": self.reboot_needed(),
                "checked_at": int(stamp) if stamp.isdigit() else None}

    def _maint_logs(self) -> dict:
        conf = self._on_host("sh", "-c", "cat /etc/docker/daemon.json 2>/dev/null")
        limited = '"max-size"' in conf
        size, pending = 0, False
        try:
            paths = []
            for c in self.client.containers.list():
                if c.attrs.get("LogPath"):
                    paths.append(c.attrs["LogPath"])
                opts = ((c.attrs.get("HostConfig") or {}).get("LogConfig") or {}).get("Config") or {}
                if limited and "max-size" not in opts:
                    pending = True
            if paths:
                size = sum(int(x) for x in self._on_host("stat", "-c", "%s", *paths).split() if x.isdigit())
        except Exception:
            pass
        return {"limited": limited, "pending": pending, "size": size}

    def _maint_last(self) -> dict | None:
        log = config.STATE_DIR / "maint.log"
        if not log.exists():
            return None
        code = config.STATE_DIR / "maint.log.code"
        try:
            what = (config.STATE_DIR / "maint.what").read_text().strip()
        except Exception:
            what = "Maintenance"
        ended = code.exists()
        try:
            rc = int(code.read_text().strip()) if ended else None
        except ValueError:
            rc = 1
        tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-60:]
        return {"what": what, "running": not ended and self._maint_running(), "code": rc,
                "at": int((code if ended else log).stat().st_mtime), "tail": [l for l in (clean_line(x) for x in tail) if l is not None]}

    def available_actions(self) -> list[dict]:
        from .actions import catalog
        res = []
        for a in catalog():
            ok = all(self.p(n).exists() for n in a.needs) and (not a.script_has or a.script_has in _read(self.p(a.script)))
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

    # ---- scheduled backups ------------------------------------------------
    # setup-backup.sh's schedule: backup-schedule says when (absent: off), a
    # systemd timer runs it, and backup-last-run says how the last run went
    # ("epoch|ok|text", or failed, skipped, running while it works).
    def backup_schedule(self) -> dict:
        kv = dict(l.split("=", 1) for l in _read(self.p("backup-schedule")).splitlines()
                  if "=" in l and not l.startswith("#"))
        every = kv.get("every") if kv.get("every") in ("daily", "weekly") else "off"
        day = int(kv["day"]) if kv.get("day", "") in {str(i) for i in range(1, 8)} else 7
        t = kv.get("time", "").strip()
        last = None
        parts = _read(self.p("backup-last-run")).strip().split("|", 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1] in ("ok", "failed", "skipped", "running"):
            at, state = int(parts[0]), parts[1]
            if state == "running" and time.time() - at > 3600:
                state = "failed"      # stopped without saying why, as the watchdog reports it
            last = {"at": at, "status": state, "text": parts[2]}
        return {"every": every, "day": day, "time": t if TIME_RE.match(t) else "04:00", "keep": 7,
                "available": self.p("setup-backup.sh").exists(),
                "timer": every != "off" and self._systemd_active("aiostreams-backup.timer"),
                "timezone": self._host_timezone(), "last": last}

    def set_backup_schedule(self, every, day, t) -> dict:
        """Off, daily at a time, or weekly on a day (1 Monday .. 7 Sunday) at a
        time, through setup-backup.sh schedule, which writes the timer on the host."""
        if every == "off":
            args = ["off"]
        elif every == "daily" and isinstance(t, str) and TIME_RE.match(t.strip()):
            args = ["daily", t.strip()]
        elif every == "weekly" and type(day) is int and 1 <= day <= 7 and isinstance(t, str) and TIME_RE.match(t.strip()):
            args = ["weekly", str(day), t.strip()]
        else:
            raise ValueError("Pick daily or weekly, and a time.")
        if not self.p("setup-backup.sh").exists():
            raise ValueError("setup-backup.sh isn't on this server.")
        cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env", "-i",
               f"HOME={self.home}", f"PATH={HOST_PATH}", "TERM=dumb", "LANG=C.UTF-8",
               "bash", str(config.INSTALL_DIR / "setup-backup.sh"), "schedule", *args]
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            why = [ANSI.sub("", l).replace("XX", "", 1).strip() for l in (r.stdout + r.stderr).splitlines() if "XX" in l]
            raise ValueError(why[-1] if why else "Couldn't set it.")
        self._bsum = (0.0, None)
        return self.backup_schedule()

    # For the Overview: when the newest backup was made and the schedule. The
    # status is asked for every few seconds, so this is kept for a minute.
    _bsum: tuple[float, dict | None] = (0.0, None)

    def backup_summary(self) -> dict | None:
        now = time.time()
        at, hit = self._bsum
        if hit is not None and now - at < 60:
            return hit
        try:
            items = self.backups()
            sched = self.backup_schedule()
        except Exception:
            return hit
        hit = {"newest": items[0]["mtime"] if items else None, "every": sched["every"], "day": sched["day"],
               "time": sched["time"], "last": sched["last"]}
        self._bsum = (now, hit)
        return hit

    def backup_build(self, b: dict) -> dict | None:
        """The AIOStreams build a backup holds, from its backup-info, or None
        when it doesn't say (made before setup-backup.sh recorded it). Backups
        are written sorted, so tar finds backup-info near the start and stops."""
        path = f"{b['dirs'][0]}/{b['name']}"
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "tar", "-xzOf", path,
                            "--occurrence=1", f"{config.INSTALL_DIR.name}/backup-info"],
                           capture_output=True, text=True, timeout=180)
        return parse_backup_info(r.stdout) if r.returncode == 0 else None

    def _vpn_previous(self) -> dict | None:
        """The config used before the last change (Previous config), and the address it used."""
        if not (self.p("vpn-state/previous/endpoint-ip").exists() and self.p("vpn-state/previous/wireguard.conf").exists()):
            return None
        try:
            changed = int(_read(self.p("vpn-state/previous/changed-at")).strip())
        except ValueError:
            changed = None
        host = _read(self.p("vpn-state/previous/endpoint-host")).strip()
        ip = _read(self.p("vpn-state/previous/endpoint-ip")).strip()
        return {"changed_at": changed, "endpoint_host": host if re.fullmatch(r"[A-Za-z0-9.-]+", host) else None,
                "endpoint_ip": ip if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip) else None}

    def vpn_stage_config(self, conf: str) -> dict:
        """Checks a pasted config and saves it where only root can read it,
        for the script's use-config. Raises ValueError with a reason."""
        if not self.p("vpn-state/active").exists():
            raise ValueError("The VPN isn't set up on this server.")
        body, info = check_wireguard_conf(conf)
        # The install folder is mounted read-only here, so it's written on the host,
        # through stdin (never a command line, where the key would show in ps).
        path = str(config.INSTALL_DIR / "vpn-state" / "upload.conf")
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c",
                            'umask 077 && cat > "$1" && chmod 600 "$1"', "sh", path],
                           input=body, capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise ValueError("Couldn't save it on the server.")
        return info

    def vpn_staged_addresses(self) -> dict:
        """The addresses the saved new config's endpoint name has, fastest first."""
        try:
            _, info = check_wireguard_conf(_read(self.p("vpn-state/upload.conf")))
        except ValueError:
            return {"host": None, "addresses": [], "error": "Paste the config again."}
        if not info["endpoint_host"]:
            return {"host": None, "addresses": [], "error": "Its Endpoint is already an address."}
        return {"host": info["endpoint_host"], **self._run_addresses(info["endpoint_host"])}

    # Who is at the keyboard, for the scripts (see run): the owner of the home with a ~/aiostreams shortcut
    _WHO = ('u=""; for h in /home/*/; do [ -d "${h}aiostreams" ] && u=$(stat -c %U "$h" 2>/dev/null) && break; done; '
            'if [ -n "$u" ] && [ "$u" != root ] && id "$u" >/dev/null 2>&1; then '
            'export SUDO_USER="$u" SUDO_UID="$(id -u "$u")" SUDO_GID="$(id -g "$u")"; fi; ')

    def _vpn_script(self, args: list[str], timeout: int) -> subprocess.CompletedProcess:
        """A quick, question-free setup-vpn-gluetun.sh command, as the login user would run it."""
        inner = self._WHO + "cd {d} && exec bash setup-vpn-gluetun.sh {a}".format(
            d=shlex.quote(str(config.INSTALL_DIR)), a=" ".join(shlex.quote(x) for x in args))
        cmd = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env", "-i",
               f"HOME={self.home}", f"PATH={HOST_PATH}", "TERM=dumb", "LANG=C.UTF-8", "bash", "-c", inner]
        return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)

    def _run_addresses(self, host: str | None = None) -> dict:
        try:
            r = self._vpn_script(["addresses", *([host] if host else [])], 90)
            return parse_vpn_addresses(r.stdout + r.stderr, r.returncode)
        except subprocess.TimeoutExpired:
            return {"addresses": [], "error": "The lookup took too long."}

    def addon_set_up(self, script_id: str) -> bool:
        """Whether an add-on is set up: its state folder has something in it. Each script makes
        the folder before its first question, so a setup cancelled part-way leaves it empty."""
        d = self.p(ADDON_STATE[script_id])
        try:
            return d.is_dir() and any(d.iterdir())
        except OSError:
            return d.exists()

    def remove_script(self, script_id: str) -> str:
        """Deletes an add-on's script from the install folder once the add-on
        isn't set up, and the empty state folder a cancelled setup leaves (rmdir
        only ever removes an empty one). Never the AIOStreams script."""
        found = next(((i, f) for i, _, f in SCRIPTS if i == script_id), None)
        if not found or script_id not in ADDON_STATE:
            raise ValueError("Only an add-on's script can be removed.")
        if self.addon_set_up(script_id):
            raise ValueError("It's still set up. Uninstall it with its own menu first.")
        host = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--"]
        path = str(config.INSTALL_DIR / found[1])
        r = subprocess.run([*host, "rm", "-f", "--", path], capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise ValueError("Couldn't remove it.")
        state = self.p(ADDON_STATE[script_id])
        if state.is_dir():
            subprocess.run([*host, "rmdir", "--", str(state)], capture_output=True, text=True, timeout=20)
        return found[1]

    def watchdog_info(self) -> dict:
        """The Phone alerts page: the watchdog's state, its recent events and
        daily tally (setup-watchdog.sh writes them), what it watches, and the
        topic masked. The topic itself never leaves the server."""
        d = self.p("watchdog-state")
        if not (d / "config").exists():
            return {"configured": False}
        topic = (re.search(r"^NTFY_TOPIC=(.*)$", _read(d / "config"), re.M) or [None, ""])[1].strip()
        last = _read(d / "last-check").strip()
        events = []
        for line in _read(d / "events").splitlines()[-100:]:
            parts = line.split("|", 2)
            if len(parts) == 3 and parts[0].isdigit():
                events.append({"at": int(parts[0]), "kind": parts[1], "text": parts[2]})
        tally = []
        for line in _read(d / "tally").splitlines()[-14:]:
            parts = line.split()
            if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
                tally.append({"day": parts[0], "passed": int(parts[1]), "failed": int(parts[2])})
        domain = None
        m = re.search(r"^(\S+)\s*\{", _read(self.p("Caddyfile")), re.M)
        if m:
            domain = m.group(1)
        n_sites = len(self._caddy_sites(domain))
        watches = ([f"https://{domain}"] if domain else ["The site"]) + [
            "Disk space", f"HTTPS certificates ({n_sites} sites)" if n_sites > 1 else "HTTPS certificate"]
        img = re.search(r"^\s*image:\s*viren070/aiostreams:(\S+)\s*$", _read(self.p("docker-compose.yml")), re.M)
        if self.vpn_mode() == "on":
            watches += ["VPN tunnel", "AIOStreams through the VPN"]
        if (self.p("mediaflow-state") / "config").exists():
            watches.append("MediaFlow Proxy")
        if (self.p("aiometadata-state") / "config").exists():
            watches.append("AIOMetadata")
        if (self.p("aiomanager-state") / "config").exists():
            watches.append("AIOManager")
        return {
            "configured": True,
            "running": self._systemd_active("aiostreams-watchdog.timer"),
            "last_check": last or None,
            "alert_state": _read(d / "alert-state").strip() or "up",
            "fails": int(_read(d / "failcount").strip() or 0) if _read(d / "failcount").strip().isdigit() else 0,
            # warnings that stand until they clear: disk nearly full, certificate not renewing
            "warnings": [w for w, f in (("disk", "disk-state"), ("cert", "cert-state")) if _read(d / f).strip() == "bad"],
            "topic": mask_topic(topic),
            "events": events[::-1],
            "tally": tally,
            "watches": watches,
            "every_min": 2, "threshold": 2,
            "options": self._watchdog_options(),
            "timezone": self._host_timezone(),
            # the release alert follows the channel; a pinned version gets none
            "channel": {"latest": "stable", "nightly": "nightly"}.get(img.group(1)) if img else None,
            # its release switch only shows once it's installed
            "aiometadata": (self.p("aiometadata-state") / "config").exists(),
            "aiomanager": (self.p("aiomanager-state") / "config").exists(),
            "mediaflow": (self.p("mediaflow-state") / "config").exists(),
        }

    def _host_timezone(self) -> str | None:
        """The server's time zone (Europe/London), which the weekly check-in's
        Sunday 10:00 goes by. Asked of the host; the container has its own."""
        try:
            r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "readlink", "-f", "/etc/localtime"],
                               capture_output=True, text=True, timeout=5)
        except Exception:
            return None
        tz = r.stdout.strip().split("/zoneinfo/")[-1] if r.returncode == 0 and "/zoneinfo/" in r.stdout else ""
        return tz or None

    def _watchdog_options(self) -> dict:
        kv = dict(l.split("=", 1) for l in _read(self.p("watchdog-state/options")).split() if "=" in l)
        day = kv.get("weekly_day", "7")
        # reboots: off for new setups (the script saves reboots=off); a watchdog set up
        # before the switch existed has no line, and keeps the restart alerts it had
        return {"updates": kv.get("updates") == "on", "reboots": kv.get("reboots", "on") == "on",
                "scripts": kv.get("scripts") == "on", "backups": kv.get("backups") == "on",
                "security": kv.get("security") == "on",
                "weekly": kv.get("weekly") == "on", "metadata": kv.get("metadata") == "on",
                "manager": kv.get("manager") == "on", "mediaflow": kv.get("mediaflow") == "on",
                "weekly_day": int(day) if day in {str(i) for i in range(1, 8)} else 7,
                "weekly_time": weekly_time(kv)}

    def set_watchdog_option(self, name: str, value) -> None:
        """The Phone alerts page's switches (update available, weekly check-in)
        and the check-in's day and hour. Kept in watchdog-state/options, which
        the script reads; written on the host, since the install folder is
        read-only here."""
        if name in ("updates", "reboots", "scripts", "backups", "security", "weekly", "metadata", "manager", "mediaflow") and isinstance(value, bool):
            text = "on" if value else "off"
        elif name == "weekly_day" and isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 7:
            text = str(value)
        elif name == "weekly_time" and isinstance(value, str) and TIME_RE.match(value.strip()):
            hh, mm = value.strip().split(":")
            text = f"{int(hh):02d}:{int(mm):02d}"
        else:
            raise ValueError("Unknown option.")
        if not self.p("watchdog-state/config").exists():
            raise ValueError("The watchdog isn't set up on this server.")
        # a new time replaces an older script's weekly_hour, as the script's set-option does
        drop = (name + "=",) + (("weekly_hour=",) if name == "weekly_time" else ())
        lines = [l for l in _read(self.p("watchdog-state/options")).split() if not l.startswith(drop)]
        body = "\n".join(lines + [f"{name}={text}"]) + "\n"
        path = str(config.INSTALL_DIR / "watchdog-state" / "options")
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c",
                            'cat > "$1.tmp" && mv "$1.tmp" "$1"', "sh", path],
                           input=body, capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise ValueError("Couldn't save it.")

    def clear_watchdog_events(self, which: str = "events") -> None:
        """Clear history (the event list) or Reset (the daily tally) on the
        Phone alerts page. The install folder is read-only here, so it's done
        on the host."""
        if which not in ("events", "tally"):
            raise ValueError("Unknown list.")
        path = str(config.INSTALL_DIR / "watchdog-state" / which)
        if not self.p("watchdog-state/config").exists():
            raise ValueError("The watchdog isn't set up on this server.")
        r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c",
                            '[ ! -e "$1" ] || : > "$1"', "sh", path], capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            raise ValueError("Couldn't clear it.")

    def update_script(self, script_id: str) -> dict:
        """The Scripts tab's Update: replaces a script (and, for the AIOStreams
        menu, setup-backup.sh and setup-maintenance.sh, fetched too when missing)
        with GitHub's main copy, verified, on the host.
        The watchdog's timer runs a copy of its script, so that's refreshed too."""
        from . import scriptsync
        found = next(((i, f) for i, _, f in SCRIPTS if i == script_id), None)
        if not found:
            raise ValueError("Unknown script.")
        extra = list(WITH_MAIN) if script_id == "aiostreams" and self.p(found[1]).exists() else []
        files = [f for f in [found[1]] if self.p(f).exists()] + extra
        if not files:
            raise ValueError("It isn't on this server. Use Get and run instead.")
        try:
            got = {f: scriptsync.fetch_main(f) for f in files}     # all downloaded and checked before any is replaced
        except RuntimeError as e:
            raise ValueError(str(e))
        for f, data in got.items():
            path = str(config.INSTALL_DIR / f)
            r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c",
                                'cat > "$1.new" && chmod --reference="$1" "$1.new" && chown --reference="$1" "$1.new" && mv -f "$1.new" "$1"',
                                "sh", path], input=data, capture_output=True, timeout=30)
            if r.returncode != 0:
                raise ValueError(f"Couldn't write {f}.")
        note = None
        if script_id == "watchdog" and self.p("watchdog-state/config").exists():
            r = subprocess.run(["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env", "-i",
                                f"HOME={self.home}", f"PATH={HOST_PATH}", "LANG=C.UTF-8", "bash",
                                str(config.INSTALL_DIR / "setup-watchdog.sh"), "refresh"],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            note = None if r.returncode == 0 else "The script is updated, but the watchdog's running copy wasn't. Use Start on the Phone alerts page."
        return {"updated": files, "note": note}

    def vpn_mode(self) -> str:
        """on, off or none, from the files alone (quick, unlike vpn_info)."""
        if "container_name: gluetun" in _read(self.p("docker-compose.yml")):
            return "on"
        return "off" if self.p("vpn-state/active").exists() else "none"

    def vpn_configs(self) -> list[dict]:
        """Every WireGuard config on the server (vpn-state, /root, the login
        user's home), which is in use, and each one's endpoint. Never the keys."""
        if not self.p("vpn-state/active").exists():
            return []
        try:
            r = self._vpn_script(["list-configs"], 30)
        except subprocess.TimeoutExpired:
            return []
        return parse_vpn_configs(r.stdout, r.returncode)

    def vpn_host_addresses(self, host: str) -> dict:
        """The addresses a listed config's endpoint name has, fastest first."""
        return {"host": host, **self._run_addresses(host)}

    def vpn_addresses(self) -> dict:
        """The VPN config's server addresses, fastest first, timed from this
        server by setup-vpn-gluetun.sh. Changes nothing."""
        host = _read(self.p("vpn-state/endpoint-host")).strip() or None
        return {"host": host, **self._run_addresses()}

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
        self._bsum = (0.0, None)
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

    def reboot_needed(self) -> bool:
        """Whether an installed update is waiting for a restart (REBOOT_CHECK)."""
        return bool(self._on_host("sh", "-c", REBOOT_CHECK).strip())

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
        if action.detached:
            return self._run_detached(action, emit)
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
