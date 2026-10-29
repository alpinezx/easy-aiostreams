"""Whether the setup-*.sh scripts on this server match the ones on GitHub's
branch the panel follows for its own updates (main, or dev while testing). One request lists every file in the repo's root with its git
blob SHA, kept for a few hours like the release check; each script here is
hashed the same way on every ask, so an Update shows at once."""
from __future__ import annotations

import hashlib
import threading
import time
from pathlib import Path

import requests

from . import config

URL = "https://api.github.com/repos/alpinezx/easy-aiostreams/contents/"
FRESH = 3 * 3600
RETRY = 10 * 60
FORCE_GAP = 60

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "shas": None, "error": None}


def blob_sha(data: bytes) -> str:
    """The SHA git gives a file's contents, the same one GitHub lists."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _fetch() -> dict[str, str]:
    r = requests.get(URL, params={"ref": config.UPDATE_BRANCH}, timeout=10,
                     headers={"Accept": "application/vnd.github+json", "User-Agent": "easy-aiostreams-panel"})
    if r.status_code in (403, 429):
        raise RuntimeError("GitHub's rate limit was reached. Try again in a while.")
    if not r.ok:
        raise RuntimeError(f"GitHub answered {r.status_code}.")
    return {str(f.get("name")): str(f.get("sha")) for f in r.json() if f.get("type") == "file"}


def _remote(force: bool) -> tuple[dict | None, str | None, float]:
    with _lock:
        now = time.time()
        age = now - _cache["at"]
        never = _cache["shas"] is None and _cache["error"] is None
        due = age > (RETRY if _cache["error"] else FRESH)
        if never or due or (force and age > FORCE_GAP):
            try:
                _cache["shas"], _cache["error"] = _fetch(), None
            except RuntimeError as e:
                _cache["error"] = str(e)
            except Exception:
                _cache["error"] = "Couldn't reach GitHub."
            _cache["at"] = now
        return _cache["shas"], _cache["error"], _cache["at"]


def compare(install_dir: Path, files: list[str], force: bool = False) -> dict:
    """For each file: on this server or not, and whether it differs from
    main (None when that can't be told: not here, or GitHub couldn't say)."""
    shas, error, at = _remote(force)
    out = {}
    for name in files:
        path = install_dir / name
        try:
            local = blob_sha(path.read_bytes())
        except OSError:
            out[name] = {"present": False, "differs": None}
            continue
        remote = (shas or {}).get(name)
        out[name] = {"present": True, "differs": None if remote is None else local != remote}
    return {"checked_at": at, "error": error if not shas else None, "files": out, "branch": config.UPDATE_BRANCH}


def fetch_main(name: str) -> bytes:
    """GitHub's copy of one file on the panel's branch (main, or dev while testing), through the API (the raw links can be
    minutes stale after a push), checked against the SHA GitHub lists for it.
    Raises RuntimeError with a reason."""
    shas, error, _ = _remote(True)
    want = (shas or {}).get(name)
    if not want:
        raise RuntimeError(error or f"GitHub doesn't list {name}.")
    try:
        r = requests.get(URL + name, params={"ref": config.UPDATE_BRANCH}, timeout=20,
                         headers={"Accept": "application/vnd.github.raw", "User-Agent": "easy-aiostreams-panel"})
    except Exception:
        raise RuntimeError("Couldn't reach GitHub.")
    if r.status_code in (403, 429):
        raise RuntimeError("GitHub's rate limit was reached. Try again in a while.")
    if not r.ok:
        raise RuntimeError(f"GitHub answered {r.status_code}.")
    data = r.content
    if blob_sha(data) != want or not data.startswith(b"#!"):
        raise RuntimeError("The download didn't match GitHub's listing. GitHub may still be updating; try again in a few minutes.")
    return data


DEMO_SAME: set[str] = set()     # demo scripts "updated" this run


def demo(files: list[str]) -> dict:
    here = {"setup-aiostreams.sh", "setup-backup.sh", "setup-maintenance.sh", "setup-mediaflow.sh", "setup-watchdog.sh", "setup-aiometadata.sh", "setup-aiomanager.sh"}
    return {"checked_at": time.time(), "error": None,
            "files": {f: {"present": f in here, "differs": (f == "setup-mediaflow.sh" and f not in DEMO_SAME) if f in here else None}
                      for f in files}, "branch": "main"}
