"""Runtime settings, all from environment variables set by setup-ui.sh."""
import os
from pathlib import Path

DEMO = os.environ.get("UI_DEMO") == "1"

# Where setup-aiostreams.sh keeps everything on the host. Mounted into this
# container read-only at the SAME path, so what we read lines up with what
# the scripts use.
INSTALL_DIR = Path(os.environ.get("UI_INSTALL_DIR", "/opt/aiostreams"))

# Root's home on the host. Scripts run with HOME set to this, and backup
# tarballs land here, whichever layout the install folder uses.
ROOT_HOME = Path(os.environ.get("UI_ROOT_HOME", "/root"))

# Our own writable state: auth.json, history.json.
STATE_DIR = Path(os.environ.get("UI_STATE_DIR", "/state"))

WEB_DIR = Path(os.environ.get("UI_WEB_DIR", str(Path(__file__).resolve().parent.parent / "web")))

SESSION_DAYS = 7

# The panel's own version: VERSION is copied into the image next to app/.
try:
    VERSION = (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip() or "unknown"
except OSError:
    VERSION = "unknown"

# The branch its Update checks and downloads from. setup-ui.sh sets it from
# AIOS_UI_BRANCH (main unless testing dev).
UPDATE_BRANCH = os.environ.get("UI_UPDATE_BRANCH", "main")
