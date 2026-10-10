"""Turns the web terminal on/off and makes its key. Run by setup-ui.sh inside
the built image:  python -m app.setup_terminal on|new|off|status
The key is printed once to stdout; only its hash is stored."""
import json
import os
import secrets
import sys

from . import auth, config, terminal

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I, it gets typed by hand


def make_key() -> str:
    groups = ["".join(secrets.choice(ALPHABET) for _ in range(5)) for _ in range(5)]
    return "-".join(groups)


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "status"
    path = config.STATE_DIR / "terminal.json"
    if cmd in ("on", "new"):
        old = {}
        try:
            old = json.loads(path.read_text())
        except Exception:
            pass
        key = make_key()
        try:
            idle = int(os.environ.get("UI_TERMINAL_IDLE") or old.get("idle_minutes") or terminal.DEFAULT_IDLE_MINUTES)
        except ValueError:
            idle = terminal.DEFAULT_IDLE_MINUTES
        path.write_text(json.dumps({"hash": auth.hash_password(terminal.normalize(key)),
                                    "idle_minutes": max(1, idle)}))
        os.chmod(path, 0o600)
        print(key)
        return 0
    if cmd == "off":
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return 0
    if cmd == "status":
        print("on" if path.exists() else "off")
        return 0
    print("usage: on | new | off | status", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
