"""Login, signed session cookie and failed-login lockout. Stdlib only."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from pathlib import Path

from . import config

# scrypt parameters. setup-ui.sh hashes the password on the host with the
# same numbers, so keep them in sync with the heredoc in that script.
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2 ** 15, 8, 1
SCRYPT_MAXMEM = 128 * 1024 * 1024


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R,
                        p=SCRYPT_P, maxmem=SCRYPT_MAXMEM, dklen=32)
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, n, r, p, salt, want = stored.split("$")
        if scheme != "scrypt":
            return False
        dk = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=int(n),
                            r=int(r), p=int(p), maxmem=SCRYPT_MAXMEM, dklen=32)
        return hmac.compare_digest(dk.hex(), want)
    except Exception:
        return False


class AuthConfig:
    def __init__(self, user: str, pw_hash: str, secret: str):
        self.user, self.pw_hash, self.secret = user, pw_hash, secret


def load_auth() -> AuthConfig | None:
    path: Path = config.STATE_DIR / "auth.json"
    try:
        data = json.loads(path.read_text())
        return AuthConfig(data["user"], data["hash"], data["secret"])
    except Exception:
        if config.DEMO:
            return AuthConfig("demo", hash_password("demo"), "demo-secret-not-for-production")
        return None


# ---- session cookie: base64(json).hexsig -------------------------------

def make_session(secret: str, user: str, days: int = config.SESSION_DAYS) -> str:
    now = int(time.time())
    body = base64.urlsafe_b64encode(json.dumps(
        {"u": user, "iat": now, "exp": now + days * 86400}).encode()).decode()
    sig = hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()
    return f"{body}.{sig}"


def read_session(secret: str, token: str | None) -> str | None:
    if not token or "." not in token:
        return None
    body, _, sig = token.rpartition(".")
    want = hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, want):
        return None
    try:
        data = json.loads(base64.urlsafe_b64decode(body.encode()))
        if data["exp"] < time.time():
            return None
        return data["u"]
    except Exception:
        return None


# ---- lockout -----------------------------------------------------------

class Lockout:
    """5 wrong passwords from one address locks that address out for 15 minutes."""

    def __init__(self, max_fails: int = 5, window: int = 900):
        self.max_fails, self.window = max_fails, window
        self._fails: dict[str, list[float]] = {}

    def _recent(self, ip: str) -> list[float]:
        cutoff = time.time() - self.window
        kept = [t for t in self._fails.get(ip, []) if t > cutoff]
        if kept:
            self._fails[ip] = kept
        else:
            self._fails.pop(ip, None)
        return kept

    def locked_for(self, ip: str) -> int:
        recent = self._recent(ip)
        if len(recent) >= self.max_fails:
            return int(recent[0] + self.window - time.time()) + 1
        return 0

    def record_fail(self, ip: str) -> None:
        self._fails.setdefault(ip, []).append(time.time())
        # keep the table from growing without bound under a flood
        if len(self._fails) > 5000:
            for k in list(self._fails)[:1000]:
                self._fails.pop(k, None)

    def clear(self, ip: str) -> None:
        self._fails.pop(ip, None)
