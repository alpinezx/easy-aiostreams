"""Web terminal. Off unless setup-ui.sh turned it on (which creates
terminal.json). Guarded by a second, separate key: a stolen dashboard login
or unlock link is not enough to get a shell.

Flow: POST /api/terminal/unlock {key} -> single-use ticket (60 s) ->
WebSocket /api/terminal/ws?ticket=... -> a login shell on the HOST.
Keystrokes are never logged; only session start/end, address and duration."""
from __future__ import annotations

import base64
import fcntl
import hashlib
import hmac
import json
import os
import pty
import secrets
import select
import signal
import struct
import subprocess
import termios
import threading
import time
from pathlib import Path

from . import auth, config

TICKET_TTL = 60
MAX_SESSION_SECONDS = 2 * 60 * 60
DEFAULT_IDLE_MINUTES = 10
DEMO_KEY = "demo-terminal-key"
HOST_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NSENTER = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--"]


def _path() -> Path:
    return config.STATE_DIR / "terminal.json"


_demo_hash_cache: str | None = None


def _demo_hash() -> str:
    global _demo_hash_cache
    if _demo_hash_cache is None:       # scrypt is slow on purpose, so do it once
        _demo_hash_cache = auth.hash_password(normalize(DEMO_KEY))
    return _demo_hash_cache


def load() -> dict | None:
    """Terminal settings, or None when the feature is switched off."""
    try:
        data = json.loads(_path().read_text())
        if data.get("hash"):
            return data
    except Exception:
        pass
    if config.DEMO:
        return {"hash": _demo_hash(), "idle_minutes": 1}
    return None


def enabled() -> bool:
    return load() is not None


def normalize(key: str) -> str:
    """Keys are typed by hand, so case, dashes and stray spaces don't matter."""
    return "".join(c for c in key if c.isalnum()).upper()


def check_key(key: str) -> bool:
    cfg = load()
    return bool(cfg) and auth.verify_password(normalize(key), cfg["hash"])


class Tickets:
    """One-time tickets so the key never travels in a URL."""

    def __init__(self):
        self._t: dict[str, tuple[str, float]] = {}
        self._lock = threading.Lock()

    def issue(self, user: str) -> str:
        t = secrets.token_urlsafe(24)
        with self._lock:
            now = time.time()
            self._t = {k: v for k, v in self._t.items() if v[1] > now}
            self._t[t] = (user, now + TICKET_TTL)
        return t

    def redeem(self, ticket: str, user: str) -> bool:
        with self._lock:
            item = self._t.pop(ticket, None)
        return bool(item) and item[1] > time.time() and secrets.compare_digest(item[0], user)


tickets = Tickets()


# ---- "stay unlocked while signed in" ------------------------------------
# A signed cookie, so it survives panel restarts. It is tied to the exact
# login cookie it was issued alongside (so signing out or logging in again
# drops it) and to the current terminal key (so a new key from setup-ui.sh
# drops it). It never contains the key.
UNLOCK_COOKIE = "aios_term"


def _bind(login_token: str) -> str:
    cfg = load() or {}
    return hashlib.sha256((cfg.get("hash", "") + "|" + (login_token or "")).encode()).hexdigest()[:32]


def make_unlock(secret: str, user: str, login_token: str, seconds: int) -> str:
    body = base64.urlsafe_b64encode(json.dumps(
        {"u": user, "exp": int(time.time()) + seconds, "b": _bind(login_token)}).encode()).decode()
    sig = hmac.new(("term|" + secret).encode(), body.encode(), hashlib.sha256).hexdigest()
    return f"{body}.{sig}"


def read_unlock(secret: str, token: str | None, user: str, login_token: str) -> bool:
    if not token or "." not in token or not enabled():
        return False
    body, _, sig = token.rpartition(".")
    want = hmac.new(("term|" + secret).encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, want):
        return False
    try:
        d = json.loads(base64.urlsafe_b64decode(body.encode()))
        return (d["exp"] > time.time() and hmac.compare_digest(str(d["u"]), user)
                and hmac.compare_digest(str(d["b"]), _bind(login_token)))
    except Exception:
        return False
unlock_lockout = auth.Lockout(max_fails=3, window=3600)

def log(msg: str) -> None:
    try:
        with open(config.STATE_DIR / "terminal.log", "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        os.chmod(config.STATE_DIR / "terminal.log", 0o600)
    except Exception:
        pass


def idle_seconds() -> int:
    cfg = load() or {}
    try:
        return max(1, int(cfg.get("idle_minutes", DEFAULT_IDLE_MINUTES))) * 60
    except Exception:
        return DEFAULT_IDLE_MINUTES * 60


class Shell:
    """A shell in a pty. On the host through nsenter, or a harmless fake in demo mode."""

    def __init__(self, cols: int = 100, rows: int = 30, argv: list[str] | None = None, as_user: str = "root"):
        self.master, slave = pty.openpty()
        self.resize(cols, rows)
        if argv is None:
            if config.DEMO:
                argv = ["bash", "--norc", "--noprofile", "-c",
                        f"echo 'demo shell as {as_user} (nothing here touches a server)'; exec bash --norc --noprofile -i"]
            elif as_user != "root":
                # A login shell as that user, exactly like SSHing in as them. Their own sudo
                # then sets SUDO_USER, so the scripts handle the home copy themselves.
                argv = NSENTER + ["env", "-i", f"PATH={HOST_PATH}", "TERM=xterm-256color", "LANG=C.UTF-8",
                                  "runuser", "-l", as_user]
            else:
                argv = NSENTER + ["env", "-i", f"HOME={config.ROOT_HOME}", f"PATH={HOST_PATH}",
                                  "TERM=xterm-256color", "LANG=C.UTF-8", "AIOS_UI_TERMINAL=1",
                                  "bash", "-c", 'cd "$HOME" 2>/dev/null; exec bash -l']

        def child():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                                     preexec_fn=child, close_fds=True)
        os.close(slave)
        self.closed = False

    def resize(self, cols: int, rows: int) -> None:
        cols, rows = max(10, min(int(cols), 500)), max(4, min(int(rows), 200))
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def write(self, data: bytes) -> None:
        if not self.closed:
            os.write(self.master, data)

    def read(self, timeout: float = 0.2) -> bytes | None:
        """Bytes, b'' for nothing yet, None when the shell is gone."""
        if self.closed:
            return None
        r, _, _ = select.select([self.master], [], [], timeout)
        if not r:
            return b"" if self.proc.poll() is None else None
        try:
            data = os.read(self.master, 65536)
        except OSError:
            return None
        return data or None

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            os.killpg(self.proc.pid, signal.SIGHUP)
        except Exception:
            pass
        try:
            self.proc.terminate()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        try:
            os.close(self.master)
        except OSError:
            pass


# ---- a session outlives the browser connection --------------------------
# The restore script ends by recreating Caddy, which is what carries this
# page's WebSocket. If the shell died with the connection, the restore would
# be cut off half way. So the shell keeps running when the browser drops, and
# the next unlock re-attaches to it with the recent output replayed.

DETACH_GRACE = 30 * 60      # a shell nobody has come back to is closed after this
BUF_MAX = 256 * 1024


class Session:
    def __init__(self, shell: Shell, user: str, ip: str, as_user: str = "root"):
        self.shell, self.user, self.ip, self.as_user = shell, user, ip, as_user
        self.started = self.last_activity = time.time()
        self.detached_at: float | None = None
        self.buf = bytearray()
        self.loop = None
        self.q = None
        self.reason: str | None = None
        self.lock = threading.Lock()
        self.dead = threading.Event()
        self._idle, self._idle_checked = idle_seconds(), time.time()
        log(f"session opened by {user} from {ip}, shell as {as_user}")

    def start(self) -> None:
        # Started only once the browser's queue is hooked up, so the shell's very
        # first output (login banner, prompt) can't be read before anyone is listening.
        threading.Thread(target=self._run, daemon=True).start()

    def _push(self, item) -> None:          # call with self.lock held
        if self.q is not None and self.loop is not None:
            try:
                self.loop.call_soon_threadsafe(self.q.put_nowait, item)
            except RuntimeError:
                pass

    def _run(self) -> None:
        reason = "shell exited"
        while True:
            data = self.shell.read(0.3)
            if data is None:
                break
            now = time.time()
            if data:
                with self.lock:
                    self.last_activity = now
                    self.buf += data
                    if len(self.buf) > BUF_MAX:
                        del self.buf[:len(self.buf) - BUF_MAX]
                    self._push(data)
            if self.reason:
                reason = self.reason
                break
            if now - self._idle_checked > 5:
                self._idle, self._idle_checked = idle_seconds(), now
            idle = self._idle
            if self.detached_at is None:
                if now - self.last_activity > idle:
                    reason = "closed after being idle"
                    break
                if now - self.started > MAX_SESSION_SECONDS:
                    reason = "reached the 2 hour limit"
                    break
            elif now - self.detached_at > DETACH_GRACE:
                reason = "closed 30 minutes after you disconnected"
                break
        self.shell.close()
        log(f"session ended ({reason}) after {int(time.time() - self.started)}s, opened from {self.ip}")
        with _reg:
            global _current
            if _current is self:
                _current = None
        self.dead.set()
        with self.lock:
            self._push(("end", reason))

    def write(self, data: bytes) -> None:
        self.last_activity = time.time()
        self.shell.write(data)

    def end(self, reason: str) -> None:
        self.reason = reason


_reg = threading.Lock()
_current: Session | None = None


def attach(loop, q, user: str, ip: str, as_user: str = "root"):
    """Returns (session, replay_bytes, resumed), or None when someone is
    already looking at the session. Asking for a different user than the
    running shell's ends that shell and starts a new one."""
    global _current
    with _reg:
        s = _current
        if s is not None and not s.dead.is_set():
            if s.as_user != as_user:
                s.end(f"switched to {as_user}")
                with s.lock:
                    s._push(("end", f"switched to a shell as {as_user}"))
                    s.q = None
            else:
                with s.lock:
                    if s.q is not None:
                        return None
                    s.loop, s.q, s.detached_at = loop, q, None
                    s.last_activity = time.time()
                    return s, bytes(s.buf), True
        s = Session(Shell(as_user=as_user), user, ip, as_user)
        s.loop, s.q = loop, q
        _current = s
        s.start()
        return s, b"", False


def detach(s: Session, q) -> None:
    with s.lock:
        if s.q is q:
            s.q, s.loop, s.detached_at = None, None, time.time()
            log(f"browser disconnected, shell left running (from {s.ip})")


def reset() -> None:
    """End whatever session exists (tests, and anything that needs a clean slate)."""
    s = _current
    if s is not None:
        s.end("reset")
        s.dead.wait(5)
