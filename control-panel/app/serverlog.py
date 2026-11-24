"""What the server did on its own, for Activity when Phone alerts isn't set up.

The watchdog (Phone alerts) logs restarts and scheduled backups itself. Without it nothing
did, so the panel looks once a minute instead:

- a restart: the kernel's boot_id differs from the one saved last time (the panel container
  shares the host's kernel). The boot time comes from the uptime, and how long the server
  was down from the last time the panel saw it running (saved every minute).
- scheduled backups and skipped scheduled reboots: a newer line in backup-last-run or
  restart-last-run than the last one seen. A scheduled reboot that went ahead isn't its own
  entry: the restart after it says "for its scheduled reboot".
- automatic updates for Caddy and the tunnel: a newer line in auto-update-last-run. The
  watchdog doesn't report these, so they're logged with Phone alerts on too.

While Phone alerts is set up and on, the panel stays quiet (no duplicates) but keeps its markers up to
date, so switching Phone alerts off later doesn't bring back old news. A first look only
reports runs from the last ten minutes, like the watchdog's.
"""
from __future__ import annotations

import json
import os
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Callable

KEEP = 100
FRESH = 600          # a first look only reports runs from the last ten minutes
PLANNED = 900        # a scheduled reboot this long before a boot was that boot
STALE_RUN = 3600     # a backup still "running" after an hour stopped without saying why
EVERY = 60
TRUST = 300          # the file changed this close to its own "alive": written by the panel, not a restore


def host_tz(path: Path = Path("/proc/1/root/etc/localtime")):
    """The server's own time zone (this container's may differ), or None for the container's."""
    try:
        from zoneinfo import ZoneInfo
        with open(path, "rb") as f:
            return ZoneInfo.from_file(f)
    except Exception:
        return None


def hhmm(at: float, tz) -> str:
    return datetime.fromtimestamp(at, tz).strftime("%H:%M")


def rough(s: float) -> str:
    """How long, roughly. The last-seen time is up to a minute old, so nothing finer than that."""
    s = int(s)
    if s < 120:
        return "under 2 minutes"
    if s < 5400:
        return f"about {(s + 30) // 60} min"
    if s < 172800:
        return f"about {(s + 1800) // 3600} h"
    return f"about {(s + 43200) // 86400} days"


def last_run(text: str, states: tuple) -> tuple[int, str, str] | None:
    """A last-run file's "epoch|state|text", or None."""
    parts = (text or "").strip().split("|", 2)
    if len(parts) == 3 and parts[0].isdigit() and parts[1] in states:
        return int(parts[0]), parts[1], parts[2].strip()
    return None


class ServerLog:
    def __init__(self, path: Path | None, facts: Callable[[], dict] | None):
        self.path = path          # None: kept in memory only (the demo)
        self.facts = facts        # None: never looks (the demo)
        self.lock = threading.Lock()
        self.state = {"boot_id": None, "alive": 0, "backup": None, "restart": None, "auto": None, "events": []}
        try:
            saved = json.loads(path.read_text()) if path else None
            if isinstance(saved, dict):
                self.state.update({k: saved[k] for k in self.state if k in saved})
                # Saved every minute, so the file changed when "alive" was written. One that changed
                # long after came back from a backup (tar can't keep a file's ctime): its markers are
                # another time's, so this is a first look again. The list itself stays.
                if not isinstance(self.state["alive"], int) or abs(path.stat().st_ctime - self.state["alive"]) > TRUST:
                    self.state.update({"boot_id": None, "alive": 0, "backup": None, "restart": None, "auto": None})
        except Exception:
            pass

    # ---- the list -----------------------------------------------------------
    def events(self) -> list[dict]:
        with self.lock:
            return sorted((dict(e) for e in self.state["events"]), key=lambda e: e["at"], reverse=True)

    def add(self, at: int, kind: str, text: str) -> None:
        with self.lock:
            self.state["events"] = (self.state["events"] + [{"at": int(at), "kind": kind, "text": text}])[-KEEP:]

    def remove(self, at, kind, text) -> bool:
        with self.lock:
            before = len(self.state["events"])
            self.state["events"] = [e for e in self.state["events"] if (e["at"], e["kind"], e["text"]) != (at, kind, text)]
            gone = len(self.state["events"]) < before
        if gone:
            self.save()
        return gone

    def clear(self) -> None:
        with self.lock:
            self.state["events"] = []
        self.save()

    def save(self, path: Path | None = None) -> None:
        target = path or self.path
        if not target:
            return
        try:
            with self.lock:
                data = json.dumps(self.state)
            tmp = target.with_name(target.name + ".tmp")
            tmp.write_text(data)
            os.replace(tmp, target)
        except Exception:
            pass

    # ---- the look -----------------------------------------------------------
    def check(self, now: float | None = None) -> None:
        if not self.facts:
            return
        f = self.facts()
        now = now or time.time()
        tz = f.get("tz")
        st = self.state
        new = []

        # Scheduled reboots that were skipped; one that went ahead only marks the restart after it
        for key in ("restart", "backup", "auto"):
            if not isinstance(st[key], int):
                st[key] = int(now - FRESH)
        r = last_run(f.get("restart_last", ""), ("restarted", "skipped"))
        if r and r[0] > st["restart"]:
            if r[1] == "skipped":
                new.append((r[0], "restart-skipped", f"Scheduled reboot skipped. {r[2]}"))
            st["restart"] = r[0]

        # Scheduled backups, in the watchdog's words
        b = last_run(f.get("backup_last", ""), ("ok", "failed", "skipped", "running"))
        if b and b[0] > st["backup"] and (b[1] != "running" or now - b[0] > STALE_RUN):
            kind, words = {"ok": ("backup", "Scheduled backup made"), "skipped": ("backup-skipped", "Scheduled backup skipped")} \
                .get(b[1], ("backup-failed", "Scheduled backup failed"))
            new.append((b[0], kind, f"{words}: {b[2]}"))
            st["backup"] = b[0]

        # Automatic updates for Caddy and the tunnel: logged even while Phone alerts is on
        loud = []
        a = last_run(f.get("auto_last", ""), ("updated", "nothing", "failed", "skipped"))
        if a and a[0] > st["auto"]:
            kind, words = {"updated": ("auto-update", "Automatic update"), "nothing": ("auto-update", "Automatic update check"),
                           "skipped": ("auto-update-skipped", "Automatic update skipped")}.get(a[1], ("auto-update-failed", "Automatic update failed"))
            loud.append((a[0], kind, f"{words}: {a[2]}"))
            st["auto"] = a[0]

        # A restart since the panel last ran. Only when it ran in the boot before (alive from before
        # this boot): a first start, or a restore that brought an old file back, says nothing.
        bid = (f.get("boot_id") or "").strip()
        boot_at = int(now - float(f.get("uptime") or 0))
        if bid and st["boot_id"] and bid != st["boot_id"] and 0 < st["alive"] <= boot_at:
            why = " for its scheduled reboot" if r and r[1] == "restarted" and 0 <= boot_at - r[0] < PLANNED else ""
            new.append((boot_at, "reboot", f"Server restarted at {hhmm(boot_at, tz)}{why}. "
                                           f"It was down for {rough(boot_at - st['alive'])}."))
        if bid:
            st["boot_id"] = bid
        st["alive"] = int(now)

        for e in (new if not f.get("quiet") else []) + loud:
            self.add(*e)
        self.save()

    def start(self) -> None:
        if not self.facts:
            return

        def loop():
            while True:
                try:
                    self.check()
                except Exception:
                    pass
                time.sleep(EVERY)
        threading.Thread(target=loop, daemon=True).start()
