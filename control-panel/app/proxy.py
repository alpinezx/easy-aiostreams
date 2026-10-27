"""Takes X-Forwarded-For and X-Forwarded-Proto only from Caddy.

uvicorn's own --forwarded-allow-ips can't name a container, and Caddy's
address on the shared Docker network changes whenever it's recreated. So the
panel looks Caddy up by name (kept for a minute, looked up again sooner when
an unknown address calls) and trusts the headers from that address alone.
Another container on the network then can't pose as a visitor to get round
the login lockout. Caddy replaces any X-Forwarded-For a visitor sends, so its
last entry is the visitor's own address.
"""
from __future__ import annotations

import asyncio
import socket
import time

PROXY_HOST = "caddy"
KEEP = 60.0     # how long a lookup is trusted
RETRY = 5.0     # an address we don't know looks Caddy up again after this


def _lookup(host: str) -> frozenset[str]:
    try:
        return frozenset(ai[4][0] for ai in socket.getaddrinfo(host, None))
    except OSError:
        return frozenset()


def _last(headers: list[tuple[bytes, bytes]], name: bytes) -> str:
    vals = [v for k, v in headers if k.lower() == name]
    return vals[-1].decode("latin-1").split(",")[-1].strip() if vals else ""


class CaddyProxyHeaders:
    def __init__(self, app, host: str = PROXY_HOST, lookup=_lookup):
        self.app, self.host, self.lookup = app, host, lookup
        self.ips: frozenset[str] = frozenset()
        self.at = float("-inf")

    async def trusted(self, peer: str) -> bool:
        age = time.monotonic() - self.at
        if age > KEEP or (peer not in self.ips and age > RETRY):
            self.ips = await asyncio.to_thread(self.lookup, self.host)
            self.at = time.monotonic()
        return peer in self.ips

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket") and scope.get("client"):
            if await self.trusted(scope["client"][0]):
                scope = dict(scope)
                ip = _last(scope["headers"], b"x-forwarded-for")
                if ip:
                    scope["client"] = (ip, 0)
                proto = _last(scope["headers"], b"x-forwarded-proto").lower()
                if proto in ("http", "https"):
                    secure = proto == "https"
                    scope["scheme"] = ("wss" if secure else "ws") if scope["type"] == "websocket" else proto
        await self.app(scope, receive, send)
