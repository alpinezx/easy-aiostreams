"""This server's public address, for the scp command on the Backup & Restore tab.

Asked of the same service setup-ui.sh uses at install. The network card isn't
enough: on hosts behind NAT (Oracle, AWS) it only has a private address.

With a public-ip file in the install folder (setup-backup.sh reads it too), the
domains point at an address that isn't this server's own, and neither that nor
the looked-up one reaches it over SSH. The server's LAN address is used then."""
from __future__ import annotations

import ipaddress
import re
import subprocess
import threading
import time

import requests

from . import config

URL = "https://ifconfig.me/ip"
OVERRIDE = config.INSTALL_DIR / "public-ip"
NSENTER = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--"]
FRESH = 24 * 3600
RETRY = 10 * 60
DEMO_IP = "203.0.113.10"   # reserved for documentation, never a real server

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "ip": None, "failed": False}


def _fetch() -> str:
    r = requests.get(URL, timeout=5, headers={"User-Agent": "easy-aiostreams-panel"})
    r.raise_for_status()
    return str(ipaddress.ip_address(r.text.strip()))


def _lan() -> str | None:
    """The host's own source address for outside traffic: its LAN address behind a router."""
    try:
        r = subprocess.run([*NSENTER, "ip", "-4", "route", "get", "1.1.1.1"],
                           capture_output=True, text=True, timeout=5)
        m = re.search(r"\bsrc (\S+)", r.stdout)
        return str(ipaddress.ip_address(m.group(1))) if m else None
    except Exception:
        return None


def address() -> str | None:
    """The public IP, or None when it couldn't be found (the page then shows a placeholder)."""
    if config.DEMO:
        return DEMO_IP
    if OVERRIDE.is_file():
        lan = _lan()
        if lan:
            return lan
    with _lock:
        now = time.time()
        due = now - _cache["at"] > (RETRY if _cache["failed"] else FRESH)
        if _cache["at"] == 0.0 or due:
            try:
                _cache["ip"], _cache["failed"] = _fetch(), False
            except Exception:
                _cache["failed"] = True
            _cache["at"] = now
        return _cache["ip"]
