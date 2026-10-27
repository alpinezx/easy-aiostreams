"""Forwarded headers count only when Caddy sends them."""
import asyncio

from app.proxy import CaddyProxyHeaders

CADDY = "172.20.0.2"
OTHER = "172.20.0.5"


def run(peer, headers, kind="http", ips=(CADDY,)):
    seen = {}

    async def inner(scope, receive, send):
        seen.update(client=scope["client"][0], scheme=scope["scheme"])

    mw = CaddyProxyHeaders(inner, lookup=lambda host: frozenset(ips))
    scope = {"type": kind, "client": (peer, 1234), "scheme": "ws" if kind == "websocket" else "http",
             "headers": [(k.encode(), v.encode()) for k, v in headers]}
    asyncio.run(mw(scope, None, None))
    return seen


def test_caddy_forwards_visitor_and_https():
    s = run(CADDY, [("x-forwarded-for", "203.0.113.7"), ("x-forwarded-proto", "https")])
    assert s == {"client": "203.0.113.7", "scheme": "https"}


def test_other_container_cannot_pose_as_visitor():
    s = run(OTHER, [("x-forwarded-for", "203.0.113.7"), ("x-forwarded-proto", "https")])
    assert s == {"client": OTHER, "scheme": "http"}


def test_last_entry_is_the_one_caddy_added():
    s = run(CADDY, [("x-forwarded-for", "198.51.100.1, 203.0.113.7")])
    assert s["client"] == "203.0.113.7"


def test_websocket_gets_wss():
    s = run(CADDY, [("x-forwarded-for", "203.0.113.7"), ("x-forwarded-proto", "https")], kind="websocket")
    assert s == {"client": "203.0.113.7", "scheme": "wss"}


def test_no_caddy_found_trusts_nobody():
    s = run(CADDY, [("x-forwarded-for", "203.0.113.7")], ips=())
    assert s["client"] == CADDY


def test_odd_proto_ignored():
    s = run(CADDY, [("x-forwarded-proto", "javascript")])
    assert s == {"client": CADDY, "scheme": "http"}
