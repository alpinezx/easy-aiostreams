import os
from types import SimpleNamespace

import pytest

os.environ["UI_DEMO"] = "1"     # as test_app.py: settings are read once, at the first import

from app import config, serverip  # noqa: E402


@pytest.fixture(autouse=True)
def fresh(monkeypatch, tmp_path):
    monkeypatch.setattr(serverip, "_cache", {"at": 0.0, "ip": None, "failed": False})
    monkeypatch.setattr(serverip, "OVERRIDE", tmp_path / "no-public-ip")
    monkeypatch.setattr(config, "DEMO", False)


def answer(text, status=200):
    def get(url, **kw):
        def check():
            if status >= 400:
                raise RuntimeError(f"HTTP {status}")
        return SimpleNamespace(text=text, raise_for_status=check)
    return get


def test_demo_uses_a_documentation_address(monkeypatch):
    monkeypatch.setattr(config, "DEMO", True)
    assert serverip.address() == "203.0.113.10"


def test_looks_up_once_then_reuses_it(monkeypatch):
    asked = []
    monkeypatch.setattr(serverip.requests, "get", lambda url, **kw: asked.append(url) or answer("198.51.100.7\n")(url))
    assert serverip.address() == "198.51.100.7"
    assert serverip.address() == "198.51.100.7"
    assert len(asked) == 1


def test_anything_but_an_address_counts_as_not_found(monkeypatch):
    monkeypatch.setattr(serverip.requests, "get", answer("<html>rate limited</html>"))
    assert serverip.address() is None
    assert serverip._cache["failed"] is True


def test_a_failed_lookup_keeps_the_last_good_address(monkeypatch):
    monkeypatch.setattr(serverip.requests, "get", answer("198.51.100.7"))
    serverip.address()
    serverip._cache["at"] -= serverip.FRESH + 1
    monkeypatch.setattr(serverip.requests, "get", answer("", status=503))
    assert serverip.address() == "198.51.100.7"


def test_with_a_public_ip_file_it_uses_the_lan_address(monkeypatch, tmp_path):
    (tmp_path / "public-ip").write_text("203.0.113.50\n")
    monkeypatch.setattr(serverip, "OVERRIDE", tmp_path / "public-ip")
    route = "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.20 uid 0 \n    cache \n"
    monkeypatch.setattr(serverip.subprocess, "run", lambda *a, **kw: SimpleNamespace(stdout=route))
    monkeypatch.setattr(serverip.requests, "get", lambda *a, **kw: pytest.fail("looked up the public address"))
    assert serverip.address() == "192.168.1.20"


def test_with_a_public_ip_file_but_no_lan_address_it_looks_up_as_usual(monkeypatch, tmp_path):
    (tmp_path / "public-ip").write_text("203.0.113.50\n")
    monkeypatch.setattr(serverip, "OVERRIDE", tmp_path / "public-ip")
    monkeypatch.setattr(serverip.subprocess, "run", lambda *a, **kw: SimpleNamespace(stdout=""))
    monkeypatch.setattr(serverip.requests, "get", answer("198.51.100.7"))
    assert serverip.address() == "198.51.100.7"


def test_without_a_public_ip_file_it_never_asks_the_host(monkeypatch, tmp_path):
    monkeypatch.setattr(serverip, "OVERRIDE", tmp_path / "public-ip")
    monkeypatch.setattr(serverip.subprocess, "run", lambda *a, **kw: pytest.fail("asked the host"))
    monkeypatch.setattr(serverip.requests, "get", answer("198.51.100.7"))
    assert serverip.address() == "198.51.100.7"
