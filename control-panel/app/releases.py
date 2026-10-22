"""AIOStreams releases from GitHub, the same list AIOStreams' own dashboard
reads: stable tags (v2.35.9) or nightly ones (2026.10.10.1200-nightly), and
AIOMetadata's (v3.6.1). Kept for a few hours: GitHub allows 60
unauthenticated requests an hour per IP."""
from __future__ import annotations

import re
import threading
import time

import requests

URL = "https://api.github.com/repos/viren070/aiostreams/releases"
META_URL = "https://api.github.com/repos/cedya77/aiometadata/releases"
FRESH = 3 * 3600
RETRY = 10 * 60
FORCE_GAP = 60
MAX_PAGES = 5
KEEP = 20
BODY_MAX = 20000
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
# Not the desktop app's "desktop-nightly".
NIGHTLY = re.compile(r"^\d{4}\.\d{2}\.\d{2}\.\d{4}-nightly$")
CHANNELS = ("stable", "nightly")
# Each list: where it comes from and which tags count. AIOMetadata has only one channel.
SOURCES = {"stable": (URL, STABLE), "nightly": (URL, NIGHTLY), "aiometadata": (META_URL, STABLE)}

_lock = threading.Lock()
_cache: dict = {}


class CheckFailed(Exception):
    pass


def _key(tag: str, channel: str):
    # Nightly tags are timestamps, so sorting them as text is chronological.
    return tag if channel == "nightly" else tuple(int(x) for x in STABLE.match(tag).groups())


def _fetch(channel: str) -> list[dict]:
    api, wanted = SOURCES[channel]
    found = []
    # Nightlies far outnumber stable releases, so a page can hold only a few stable ones.
    for page in range(1, MAX_PAGES + 1):
        r = requests.get(api, params={"per_page": 100, "page": page}, timeout=10,
                         headers={"Accept": "application/vnd.github+json", "User-Agent": "easy-aiostreams-panel"})
        if r.status_code in (403, 429):
            raise CheckFailed("GitHub's rate limit was reached. Try again in a while.")
        if not r.ok:
            raise CheckFailed(f"GitHub answered {r.status_code}.")
        for rel in r.json():
            tag = str(rel.get("tag_name") or "")
            if rel.get("draft") or not wanted.match(tag):
                continue
            url = str(rel.get("html_url") or "")
            found.append({"tag": tag, "published": rel.get("published_at"),
                          "url": url if url.startswith("https://github.com/") else None,
                          "body": str(rel.get("body") or "")[:BODY_MAX]})
        if len(found) >= KEEP or 'rel="next"' not in r.headers.get("link", ""):
            break
    found.sort(key=lambda x: _key(x["tag"], channel), reverse=True)
    return found[:KEEP]


def get(force: bool = False, channel: str = "stable") -> dict:
    if channel not in SOURCES:
        raise ValueError(channel)
    with _lock:
        c = _cache.setdefault(channel, {"at": 0.0, "releases": None, "error": None})
        now = time.time()
        age = now - c["at"]
        never = c["releases"] is None and c["error"] is None
        due = age > (RETRY if c["error"] else FRESH)
        if never or due or (force and age > FORCE_GAP):
            try:
                c["releases"] = _fetch(channel)
                c["error"] = None
            except CheckFailed as e:
                c["error"] = str(e)
            except Exception:
                c["error"] = "Couldn't reach GitHub."
            c["at"] = now
        return {"channel": channel, "checked_at": c["at"], "releases": c["releases"] or [], "error": c["error"], "keep": KEEP}


def demo(channel: str = "stable") -> dict:
    now = time.time()
    if channel == "aiometadata":
        iso = lambda h: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - h * 3600))
        notes = {"v3.6.2": "## What's Changed\n\n* Fix MDBList catalogs paging past 100 items\n* Faster poster lookups when Fanart is down\n",
                 "v3.6.1": "## What's Changed\n\n* Fix TVDB episode titles for anime\n",
                 "v3.6.0": "## What's Changed\n\n* New: Gemini-powered search catalogs\n* Dashboard: per-key usage graphs\n"}
        rels = [{"tag": t, "published": iso(h), "url": f"https://github.com/cedya77/aiometadata/releases/tag/{t}", "body": notes[t]}
                for t, h in (("v3.6.2", 4), ("v3.6.1", 30), ("v3.6.0", 32))]
        return {"channel": channel, "checked_at": now, "error": None, "keep": KEEP, "releases": rels}
    if channel == "nightly":
        def stamp(hours_ago):
            return time.strftime("%Y.%m.%d.%H%M-nightly", time.gmtime(now - hours_ago * 3600))
        tags = [(stamp(h), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - h * 3600))) for h in (0.2, 5, 30, 54)]
        body = "## {v}\n\n* **jellyfin:** page Next Up through up to 200 recent shows ([4f51dc1](https://github.com/Viren070/AIOStreams/commit/4f51dc1))\n* **core:** keep busy instances responsive\n"
        rels = [{"tag": t, "published": p, "url": f"https://github.com/Viren070/AIOStreams/releases/tag/{t}", "body": body.format(v=t)} for t, p in tags]
        return {"channel": channel, "checked_at": now, "error": None, "keep": KEEP, "releases": rels}
    tags = [("v2.36.1", "2026-10-10T12:00:00Z"), ("v2.36.0", "2026-10-07T12:00:00Z"), ("v2.35.9", "2026-10-03T12:00:00Z")]
    body = ("## [{v}](https://github.com/Viren070/AIOStreams/compare/v2.35.8...v{v}) ({d})\n\n### Features\n\n"
            "* **jellyfin:** add watchlisted shows and films to Upcoming ([7814d09](https://github.com/Viren070/AIOStreams/commit/7814d09))\n"
            "* **watch-state:** read `airsAt` on pulled next episodes\n\n### Bug Fixes\n\n"
            "* **desktop:** load a bundled vulkan-1.dll when Windows has none\n")
    return {"channel": channel, "checked_at": now, "error": None, "keep": KEEP,
            "releases": [{"tag": t, "published": p, "url": f"https://github.com/Viren070/AIOStreams/releases/tag/{t}",
                          "body": body.format(v=t[1:], d=p[:10])} for t, p in tags]}
