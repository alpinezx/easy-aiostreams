"""A short record of what was done from the panel and by whom (panel updates,
reboots, time zone changes, restarts), in ui-state/panel.log. Owner-only."""
from __future__ import annotations

import os
import time

from . import config


def log(msg: str) -> None:
    path = config.STATE_DIR / "panel.log"
    try:
        with open(path, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        os.chmod(path, 0o600)
    except Exception:
        pass
