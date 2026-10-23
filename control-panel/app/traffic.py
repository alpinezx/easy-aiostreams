"""The VPN's traffic history, for the graph on the VPN page and the line on its Overview card.

Once a minute the panel reads gluetun's byte counters for the tunnel and adds what went
through since the last reading to that minute, and to that hour. Minutes are kept for a
day and hours for 30 days, saved to a small file in the panel's state every few minutes,
so a panel update or a reboot only loses the minutes in between.

A minute with no entry is a gap (the VPN off, or the panel not running); a quiet tunnel
still gets an entry, of zero, so the graph can tell the two apart. gluetun's counters
start again from zero when it restarts, and a reading lower than the last one is taken as
that: a fresh start, not traffic.
"""
from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Callable

MINUTE_KEEP = 24 * 3600
HOUR_KEEP = 30 * 24 * 3600
MAX_GAP = 300          # readings further apart than this aren't counted: when it went through is unknown
SAVE_EVERY = 300


def dev_counters(text: str, names) -> tuple[int, int] | None:
    """Bytes down and up for the first of names found in a /proc/net/dev listing."""
    rows = {}
    for line in text.splitlines():
        name, sep, rest = line.partition(":")
        f = rest.split()
        if sep and len(f) >= 9:
            rows[name.strip()] = (int(f[0]), int(f[8]))
    return next((rows[n] for n in names if n in rows), None)


def default_iface(net: Path) -> str | None:
    """The network card the default route leaves by, from the kernel's routing tables
    (IPv4 first, then IPv6 for a server without IPv4); the lowest metric wins."""
    best = None
    try:
        for line in (net / "route").read_text().splitlines()[1:]:
            f = line.split()
            if len(f) >= 8 and f[1] == "00000000" and f[7] == "00000000":
                if best is None or int(f[6]) < best[0]:
                    best = (int(f[6]), f[0])
    except Exception:
        pass
    if best:
        return best[1]
    try:
        for line in (net / "ipv6_route").read_text().splitlines():
            f = line.split()
            if len(f) >= 10 and f[0] == "0" * 32 and f[1] == "00" and f[9] != "lo":
                if best is None or int(f[5], 16) < best[0]:
                    best = (int(f[5], 16), f[9])
    except Exception:
        pass
    return best[1] if best else None


def host_net(net: Path) -> tuple[int, int] | None:
    iface = default_iface(net)
    if not iface:
        return None
    try:
        return dev_counters((net / "dev").read_text(), [iface])
    except Exception:
        return None


class Traffic:
    def __init__(self, path: Path, read: Callable[[], tuple[int, int] | None]):
        self.path = path
        self.read = read
        self.lock = threading.Lock()
        self.minutes: dict[int, list[int]] = {}    # minute start -> [down bytes, up bytes]
        self.hours: dict[int, list[int]] = {}      # hour start -> [down, up, busiest minute down, busiest minute up]
        self.last: tuple[float, int, int] | None = None
        self.saved_at = 0.0
        self.load()

    def load(self):
        try:
            d = json.loads(self.path.read_text())
            self.minutes = {int(k): [int(x) for x in v[:2]] for k, v in d.get("minutes", {}).items()}
            self.hours = {int(k): [int(x) for x in v[:4]] for k, v in d.get("hours", {}).items()}
            last = d.get("last")
            self.last = (float(last[0]), int(last[1]), int(last[2])) if last else None
        except Exception:
            pass

    def save(self):
        with self.lock:
            d = {"minutes": self.minutes, "hours": self.hours, "last": self.last}
            text = json.dumps(d, separators=(",", ":"))
        try:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(text)
            os.replace(tmp, self.path)
            self.saved_at = time.time()
        except Exception:
            pass

    def add(self, now: float, counters: tuple[int, int] | None):
        """One reading: the tunnel's total bytes down and up, or None when the VPN isn't on."""
        with self.lock:
            if counters is None:
                self.last = None
                return
            rx, tx = counters
            last, self.last = self.last, (now, rx, tx)
            if not last or now - last[0] > MAX_GAP or now <= last[0]:
                return
            if rx < last[1] or tx < last[2]:
                drx, dtx = rx, tx          # gluetun restarted: its counters began again from zero
            else:
                drx, dtx = rx - last[1], tx - last[2]
            mid = (now + last[0]) / 2      # readings come just after each minute starts: the bytes are the minute before's
            mb = self.minutes.setdefault(int(mid // 60 * 60), [0, 0])
            mb[0] += drx
            mb[1] += dtx
            hb = self.hours.setdefault(int(mid // 3600 * 3600), [0, 0, 0, 0])
            hb[0] += drx
            hb[1] += dtx
            hb[2] = max(hb[2], mb[0])
            hb[3] = max(hb[3], mb[1])
            for k in [k for k in self.minutes if k < now - MINUTE_KEEP]:
                del self.minutes[k]
            for k in [k for k in self.hours if k < now - HOUR_KEEP]:
                del self.hours[k]

    def sample(self, now: float | None = None):
        now = time.time() if now is None else now
        try:
            got = self.read()
        except Exception:
            got = None
        self.add(now, got)
        if now - self.saved_at >= SAVE_EVERY:
            self.save()

    def run(self):
        while True:
            self.sample()
            time.sleep(60 - time.time() % 60 + 1)    # just after each minute starts

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()

    def view(self, now: float | None = None) -> dict:
        """The last day's minutes and the last week's hours, oldest first, for the browser to draw."""
        now = time.time() if now is None else now
        with self.lock:
            return {"now": now,
                    "minutes": [[k, *v] for k, v in sorted(self.minutes.items()) if k >= now - MINUTE_KEEP],
                    "hours": [[k, *v] for k, v in sorted(self.hours.items()) if k >= now - 7 * 24 * 3600 - 3600]}
