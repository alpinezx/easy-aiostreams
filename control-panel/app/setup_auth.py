"""Writes /state/auth.json. Run by setup-ui.sh inside the built image so the
password is hashed by the exact same code that later checks it.
Reads UI_USER and UI_PW from the environment (never from arguments)."""
import json
import os
import secrets
import sys
from pathlib import Path

from . import auth, config


def main() -> int:
    user, pw = os.environ.get("UI_USER", ""), os.environ.get("UI_PW", "")
    if not user or len(pw) < 10:
        print("Username is required and the password needs at least 10 characters.", file=sys.stderr)
        return 1
    path: Path = config.STATE_DIR / "auth.json"
    secret = None
    try:
        secret = json.loads(path.read_text()).get("secret")   # keep existing sessions' key unless asked to rotate
    except Exception:
        pass
    if os.environ.get("UI_ROTATE_SESSIONS") == "1" or not secret:
        secret = secrets.token_hex(32)
    path.write_text(json.dumps({"user": user, "hash": auth.hash_password(pw), "secret": secret}))
    os.chmod(path, 0o600)
    return 0


if __name__ == "__main__":
    sys.exit(main())
