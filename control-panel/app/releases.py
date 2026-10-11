"""Stable AIOStreams releases from GitHub, the same list AIOStreams' own
dashboard reads. Kept for a few hours: GitHub allows 60 unauthenticated
requests an hour per IP."""
from __future__ import annotations

import re
import threading
import time

import requests

URL = "https://api.github.com/repos/viren070/aiostreams/releases"
FRESH = 6 * 3600
RETRY = 10 * 60
FORCE_GAP = 60
MAX_PAGES = 5
KEEP = 20
BODY_MAX = 20000
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "releases": None, "error": None}


class CheckFailed(Exception):
    pass


def _key(tag: str) -> tuple[int, ...]:
    return tuple(int(x) for x in STABLE.match(tag).groups())


def _fetch() -> list[dict]:
    found = []
    # Nightlies far outnumber stable releases, so a page can hold only a few.
    for page in range(1, MAX_PAGES + 1):
        r = requests.get(URL, params={"per_page": 100, "page": page}, timeout=10,
                         headers={"Accept": "application/vnd.github+json", "User-Agent": "easy-aiostreams-panel"})
        if r.status_code in (403, 429):
            raise CheckFailed("GitHub's rate limit was reached. Try again in a while.")
        if not r.ok:
            raise CheckFailed(f"GitHub answered {r.status_code}.")
        for rel in r.json():
            tag = str(rel.get("tag_name") or "")
            if rel.get("draft") or not STABLE.match(tag):
                continue
            url = str(rel.get("html_url") or "")
            found.append({"tag": tag, "published": rel.get("published_at"),
                          "url": url if url.startswith("https://github.com/") else None,
                          "body": str(rel.get("body") or "")[:BODY_MAX]})
        if len(found) >= KEEP or 'rel="next"' not in r.headers.get("link", ""):
            break
    found.sort(key=lambda x: _key(x["tag"]), reverse=True)
    return found[:KEEP]


def get(force: bool = False) -> dict:
    with _lock:
        now = time.time()
        age = now - _cache["at"]
        never = _cache["releases"] is None and _cache["error"] is None
        due = age > (RETRY if _cache["error"] else FRESH)
        if never or due or (force and age > FORCE_GAP):
            try:
                _cache["releases"] = _fetch()
                _cache["error"] = None
            except CheckFailed as e:
                _cache["error"] = str(e)
            except Exception:
                _cache["error"] = "Couldn't reach GitHub."
            _cache["at"] = now
        return {"checked_at": _cache["at"], "releases": _cache["releases"] or [], "error": _cache["error"], "keep": KEEP}


def demo() -> dict:
    tags = [("v2.36.1", "2026-10-10T12:00:00Z"), ("v2.36.0", "2026-10-07T12:00:00Z"), ("v2.35.9", "2026-10-03T12:00:00Z")]
    body = ("## [{v}](https://github.com/Viren070/AIOStreams/compare/v2.35.8...v{v}) ({d})\n\n### Features\n\n"
            "* **jellyfin:** add watchlisted shows and films to Upcoming ([7814d09](https://github.com/Viren070/AIOStreams/commit/7814d09))\n"
            "* **watch-state:** read `airsAt` on pulled next episodes\n\n### Bug Fixes\n\n"
            "* **desktop:** load a bundled vulkan-1.dll when Windows has none\n")
    return {"checked_at": time.time(), "error": None, "keep": KEEP,
            "releases": [{"tag": t, "published": p, "url": f"https://github.com/Viren070/AIOStreams/releases/tag/{t}",
                          "body": body.format(v=t[1:], d=p[:10])} for t, p in tags]}
