"""The panel's own version, the newest one on GitHub, and updating itself.

The update can't run inside this container: it rebuilds and replaces it, which
would kill it halfway. So it's started on the host with systemd-run, as a unit
of its own, and writes its output to ui-state where the new panel can read it."""
from __future__ import annotations

import re
import subprocess
import threading
import time

import requests

from . import config

RAW = "https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/{branch}/control-panel/VERSION"
FRESH = 6 * 3600
RETRY = 10 * 60
FORCE_GAP = 60
UNIT = "aios-ui-update"
LOG_NAME = "last-update.log"
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")
NSENTER = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--"]

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "latest": None, "error": None, "branch": None}


def key(v: str) -> tuple:
    return tuple(int(x) for x in v.split(".")) if VERSION_RE.fullmatch(v or "") else ()


def _fetch(branch: str) -> str:
    r = requests.get(RAW.format(branch=branch), timeout=10, headers={"User-Agent": "easy-aiostreams-panel"})
    if not r.ok:
        raise RuntimeError(f"GitHub answered {r.status_code}.")
    v = r.text.strip()
    if not VERSION_RE.fullmatch(v):
        raise RuntimeError("GitHub's VERSION file isn't a version number.")
    return v


def latest(force: bool = False) -> dict:
    branch = config.UPDATE_BRANCH
    with _lock:
        now = time.time()
        if _cache["branch"] != branch:
            _cache.update(at=0.0, latest=None, error=None, branch=branch)
        age = now - _cache["at"]
        never = _cache["latest"] is None and _cache["error"] is None
        due = age > (RETRY if _cache["error"] else FRESH)
        if never or due or (force and age > FORCE_GAP):
            try:
                _cache["latest"], _cache["error"] = _fetch(branch), None
            except RuntimeError as e:
                _cache["error"] = str(e)
            except Exception:
                _cache["error"] = "Couldn't reach GitHub."
            _cache["at"] = now
        cur, new = config.VERSION, _cache["latest"]
        return {"current": cur, "latest": new, "branch": branch, "checked_at": _cache["at"],
                "error": _cache["error"] if new is None else None,
                "newer": bool(new and key(cur) and key(new) > key(cur))}


def _log_path():
    return config.STATE_DIR / LOG_NAME


def running() -> bool:
    r = subprocess.run(NSENTER + ["systemctl", "is-active", "--quiet", UNIT], capture_output=True, timeout=10)
    return r.returncode == 0


def last_update() -> dict | None:
    """The last update's output, or None if there never was one."""
    try:
        p = _log_path()
        text = p.read_text(errors="replace")
        at = p.stat().st_mtime
    except OSError:
        return None
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in text.splitlines()]
    ok = any(l.startswith("Rebuilt.") for l in lines)
    return {"at": at, "ok": ok, "tail": lines[-40:]}


def start() -> None:
    """Starts the update on the host, outside this container. Raises
    RuntimeError with a message for the person when it can't."""
    if running():
        raise RuntimeError("An update is already running.")
    script = (config.INSTALL_DIR / "control-panel" / "setup-ui.sh").as_posix()
    log = (config.INSTALL_DIR / "ui-state" / LOG_NAME).as_posix()
    cmd = NSENTER + ["systemd-run", f"--unit={UNIT}", "--collect", "--quiet",
                     "--property=RuntimeMaxSec=1800", f"--setenv=AIOS_UI_BRANCH={config.UPDATE_BRANCH}",
                     "/bin/bash", "-c", f'exec bash "{script}" update-unattended > "{log}" 2>&1']
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise RuntimeError("Couldn't start it. Update over SSH instead: sudo bash setup-ui.sh, option 4.")
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip().splitlines()
        hint = "systemd-run isn't available here. " if "No such file" in (r.stderr or "") else ""
        raise RuntimeError(f"{hint}Couldn't start the update ({msg[-1] if msg else 'no message'}). "
                           "Update over SSH instead: sudo bash setup-ui.sh, option 4.")


def demo_latest() -> dict:
    return {"current": config.VERSION, "latest": "1.1.0", "branch": "main", "checked_at": time.time(),
            "error": None, "newer": key("1.1.0") > key(config.VERSION)}
