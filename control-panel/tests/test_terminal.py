import json
import os
import time

import pytest

os.environ["UI_DEMO"] = "1"

from fastapi.testclient import TestClient  # noqa: E402
from starlette.websockets import WebSocketDisconnect  # noqa: E402

from app import auth, config, terminal  # noqa: E402


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    (tmp_path / "auth.json").write_text(json.dumps(
        {"user": "me", "hash": auth.hash_password("correct horse"), "secret": "s3cret"}))
    from app import main
    main.lockout.__init__()
    terminal.unlock_lockout.__init__(max_fails=3, window=3600)
    c = TestClient(main.app, base_url="http://testserver")
    c.headers.update({"X-UI-Request": "1"})
    terminal.reset()               # no shell left over from a previous test
    assert c.post("/api/login", json={"username": "me", "password": "correct horse"}).status_code == 200
    return c


def unlock(c, key="demo-terminal-key"):
    return c.post("/api/terminal/unlock", json={"key": key})


def test_off_by_default_outside_demo(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    monkeypatch.setattr(config, "DEMO", False)
    assert terminal.enabled() is False


def test_key_normalisation_and_hash_only_stored(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    monkeypatch.setattr(config, "DEMO", False)
    from app import setup_terminal
    from io import StringIO
    import contextlib
    buf = StringIO()
    with contextlib.redirect_stdout(buf):
        assert setup_terminal.main(["x", "on"]) == 0
    key = buf.getvalue().strip()
    assert len(key.split("-")) == 5
    assert key not in (tmp_path / "terminal.json").read_text()
    assert terminal.check_key(key.lower().replace("-", " "))
    assert not terminal.check_key("WRONG")
    assert (tmp_path / "terminal.json").stat().st_mode & 0o077 == 0
    setup_terminal.main(["x", "off"])
    assert not terminal.enabled()


def test_me_reports_terminal(client):
    assert client.get("/api/me").json()["terminal"] is True


def test_unlock_needs_login(client):
    client.post("/api/logout")
    client.cookies.clear()
    assert unlock(client).status_code == 401


def test_wrong_key_lockout(client):
    for _ in range(3):
        assert unlock(client, "nope").status_code == 403
    assert unlock(client).status_code == 429


def test_ticket_single_use_and_ws(client):
    t = unlock(client).json()["ticket"]
    with client.websocket_connect(f"/api/terminal/ws?ticket={t}", headers={"origin": "http://testserver"}) as ws:
        ws.send_text(json.dumps({"r": [80, 24]}))
        ws.send_text(json.dumps({"i": "echo hello-$((20+22))\n"}))
        got = b""
        deadline = time.time() + 5
        while b"hello-42" not in got.replace(b"\r", b"") .split(b"echo")[-1] and time.time() < deadline:
            m = ws.receive()
            got += m.get("bytes") or b""
        assert b"hello-42" in got
        ws.send_text(json.dumps({"i": "exit\n"}))
        end = None
        for _ in range(50):
            m = ws.receive()
            if m.get("text"):
                end = json.loads(m["text"]); break
        assert end and "ended" in end["end"]
    # same ticket again is dead
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(f"/api/terminal/ws?ticket={t}", headers={"origin": "http://testserver"}):
            pass
    assert "session opened" in (config.STATE_DIR / "terminal.log").read_text()


def test_ws_rejects_bad_origin_and_no_cookie(client):
    t = unlock(client).json()["ticket"]
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(f"/api/terminal/ws?ticket={t}", headers={"origin": "http://evil.example"}):
            pass
    t = unlock(client).json()["ticket"]
    client.cookies.clear()
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(f"/api/terminal/ws?ticket={t}", headers={"origin": "http://testserver"}):
            pass


def test_one_session_at_a_time(client):
    t1 = unlock(client).json()["ticket"]
    with client.websocket_connect(f"/api/terminal/ws?ticket={t1}", headers={"origin": "http://testserver"}) as ws:
        ws.receive()
        t2 = unlock(client).json()["ticket"]
        with client.websocket_connect(f"/api/terminal/ws?ticket={t2}", headers={"origin": "http://testserver"}) as ws2:
            assert "already has this session open" in json.loads(ws2.receive_text())["end"]


def test_idle_timeout(client, monkeypatch):
    monkeypatch.setattr(terminal, "idle_seconds", lambda: 1)
    t = unlock(client).json()["ticket"]
    with client.websocket_connect(f"/api/terminal/ws?ticket={t}", headers={"origin": "http://testserver"}) as ws:
        end = None
        for _ in range(100):
            m = ws.receive()
            if m.get("text"):
                end = json.loads(m["text"]); break
        assert end and "idle" in end["end"]


def test_panel_restart_demo(client):
    assert client.post("/api/panel/restart").json()["ok"]


def _open(c):
    t = unlock(c).json()["ticket"]
    return c.websocket_connect(f"/api/terminal/ws?ticket={t}", headers={"origin": "http://testserver"})


def _read_until(ws, needle, secs=8):
    got, end = b"", time.time() + secs
    while needle not in got and time.time() < end:
        m = ws.receive()
        got += m.get("bytes") or b""
    return got


def test_shell_survives_disconnect_and_reattach_replays(client):
    with _open(client) as ws:
        ws.receive()
        ws.send_text(json.dumps({"i": "sleep 1; echo persisted-$((40+2))\n"}))
        _read_until(ws, b"persisted-$")          # the shell has taken the command
    # browser gone while the command is still running
    time.sleep(2)
    with _open(client) as ws2:
        first = ws2.receive()
        assert json.loads(first["text"]) == {"resumed": True}
        assert b"persisted-42" in _read_until(ws2, b"persisted-42")


def test_detached_shell_is_closed_after_grace(client, monkeypatch):
    monkeypatch.setattr(terminal, "DETACH_GRACE", 1)
    with _open(client) as ws:
        ws.receive()
    s = terminal._current
    assert s.dead.wait(6)
    assert "30 minutes" in (config.STATE_DIR / "terminal.log").read_text() or "disconnected" in (config.STATE_DIR / "terminal.log").read_text()


def test_end_session_button_kills_shell(client):
    with _open(client) as ws:
        ws.receive()
        s = terminal._current
        ws.send_text(json.dumps({"x": 1}))
        end = None
        for _ in range(50):
            m = ws.receive()
            if m.get("text"):
                end = json.loads(m["text"]); break
        assert end and "ended by you" in end["end"]
    assert s.dead.wait(5)


def test_stay_unlocked_is_opt_in_and_ends_on_lock_logout_or_new_key(client, tmp_path):
    assert unlock(client).status_code == 200                    # no remember
    assert client.post("/api/terminal/ticket").status_code == 403
    r = client.post("/api/terminal/unlock", json={"key": "demo-terminal-key", "remember": True})
    assert r.status_code == 200 and "aios_term" in r.cookies
    assert "demo" not in r.cookies["aios_term"].lower()         # the key itself is never in the cookie
    for _ in range(2):
        assert client.post("/api/terminal/ticket").json()["ticket"]
    # the cookie alone, without the login it was issued with, is useless
    stolen = r.cookies["aios_term"]
    other = client.__class__(client.app, base_url="http://testserver")
    other.headers.update({"X-UI-Request": "1"})
    assert other.post("/api/login", json={"username": "me", "password": "correct horse"}).status_code == 200
    time.sleep(1.1)
    other.post("/api/login", json={"username": "me", "password": "correct horse"})  # a different login token
    other.cookies.set("aios_term", stolen, path="/api/terminal")
    assert other.post("/api/terminal/ticket").status_code == 403
    # Lock
    assert client.post("/api/terminal/lock").json()["ok"]
    assert client.post("/api/terminal/ticket").status_code == 403
    # Sign out drops it too
    client.post("/api/terminal/unlock", json={"key": "demo-terminal-key", "remember": True})
    assert client.post("/api/terminal/ticket").status_code == 200
    client.post("/api/logout")
    assert "aios_term" not in {c.name for c in client.cookies.jar}
    # A new terminal key drops it
    client.post("/api/login", json={"username": "me", "password": "correct horse"})
    client.post("/api/terminal/unlock", json={"key": "demo-terminal-key", "remember": True})
    assert client.post("/api/terminal/ticket").status_code == 200
    (tmp_path / "terminal.json").write_text(json.dumps({"hash": auth.hash_password("NEWKEY"), "idle_minutes": 10}))
    assert client.post("/api/terminal/ticket").status_code == 403


def _read_until(ws, needle, secs=5):
    got, deadline = b"", time.time() + secs
    while needle not in got and time.time() < deadline:
        m = ws.receive()
        got += m.get("bytes") or (m.get("text") or "").encode()
    return got


def test_open_as_only_detected_user_and_switch_starts_new_shell(client):
    hdr = {"origin": "http://testserver"}
    prev = terminal._current            # wait out any shell left from an earlier test
    if prev is not None:
        prev.end("reset"); assert prev.dead.wait(3)
    # an unknown name is ignored: you get root
    t = unlock(client).json()["ticket"]
    with client.websocket_connect(f"/api/terminal/ws?ticket={t}&as=mallory", headers=hdr) as ws:
        assert b"demo shell as root" in _read_until(ws, b"demo shell as")
    assert terminal._current.as_user == "root"
    first = terminal._current
    # the detected login user (demo: ubuntu) gets a fresh shell, and the root one is ended
    t = unlock(client).json()["ticket"]
    with client.websocket_connect(f"/api/terminal/ws?ticket={t}&as=ubuntu", headers=hdr) as ws:
        assert b"demo shell as ubuntu" in _read_until(ws, b"demo shell as")
    assert terminal._current.as_user == "ubuntu" and terminal._current is not first
    assert first.dead.wait(3)
    # same user again re-attaches to the same shell
    cur = terminal._current
    t = unlock(client).json()["ticket"]
    with client.websocket_connect(f"/api/terminal/ws?ticket={t}&as=ubuntu", headers=hdr) as ws:
        assert b"resumed" in _read_until(ws, b"resumed")
    assert terminal._current is cur
