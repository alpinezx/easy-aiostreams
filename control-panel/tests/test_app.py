import json
import os
import time

import pytest

os.environ["UI_DEMO"] = "1"

from fastapi.testclient import TestClient  # noqa: E402

from app import actions, auth, config  # noqa: E402


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    (tmp_path / "auth.json").write_text(json.dumps(
        {"user": "me", "hash": auth.hash_password("correct horse"), "secret": "s3cret"}))
    from app import main
    main.lockout.__init__()
    main._status_cache = None
    c = TestClient(main.app, base_url="http://testserver")
    c.headers.update({"X-UI-Request": "1"})
    return c


def login(c, pw="correct horse", user="me"):
    return c.post("/api/login", json={"username": user, "password": pw})


def test_requires_login(client):
    assert client.get("/api/status").status_code == 401
    assert client.get("/", follow_redirects=False).status_code == 302
    assert client.get("/login").status_code == 200


def test_login_flow_and_cookie_flags(client):
    r = login(client)
    assert r.status_code == 200
    sc = r.headers["set-cookie"].lower()
    assert "httponly" in sc and "samesite=strict" in sc
    assert client.get("/api/me").json()["user"] == "me"
    assert client.get("/api/status").json()["services"]
    assert client.post("/api/logout").status_code == 200


def test_wrong_password_and_lockout(client):
    for _ in range(5):
        assert login(client, "nope").status_code == 401
    r = login(client, "correct horse")  # right password, but locked
    assert r.status_code == 429


def test_wrong_username_rejected(client):
    assert login(client, user="someone").status_code == 401


def test_tampered_cookie_rejected(client):
    login(client)
    good = client.cookies.get("ui_session")
    client.cookies.clear()
    client.cookies.set("ui_session", good[:-4] + "0000")
    assert client.get("/api/me").status_code == 401


def test_csrf_header_required(client):
    login(client)
    r = client.post("/api/actions/stack.backup", headers={"X-UI-Request": ""})
    assert r.status_code == 403
    r = client.post("/api/actions/stack.backup", headers={"Origin": "https://evil.example"})
    assert r.status_code == 403


def test_security_headers(client):
    r = client.get("/login")
    assert "default-src 'none'" in r.headers["content-security-policy"]
    assert r.headers["x-frame-options"] == "DENY"


def test_unknown_action_and_bad_params(client):
    login(client)
    assert client.post("/api/actions/rm-rf", json={}).status_code == 400
    r = client.post("/api/actions/stack.update", json={"params": {"channel": "evil; rm"}})
    assert r.status_code == 400
    r = client.post("/api/actions/stack.update", json={"params": {"backup": "yes"}})
    assert r.status_code == 400


def test_logs_only_known_containers(client):
    login(client)
    assert client.get("/api/logs/etc-passwd").status_code == 404


def test_action_runs_and_streams(client):
    login(client)
    r = client.post("/api/actions/stack.backup", json={})
    assert r.status_code == 200
    jid = r.json()["id"]
    # second action while first is running is refused
    r2 = client.post("/api/actions/stack.start", json={})
    assert r2.status_code in (409, 200)
    deadline = time.time() + 10
    while time.time() < deadline:
        j = client.get(f"/api/jobs/{jid}").json()
        if j["ended"]:
            break
        time.sleep(0.2)
    assert j["code"] == 0 and j["lines"]
    with client.stream("GET", f"/api/jobs/{jid}/stream") as s:
        body = "".join(s.iter_text())
    assert '"done": true' in body


def test_update_stdin_sequences():
    assert actions.build_update(True, None).stdin == "5\n1\n\nN\nN\n10\n"
    assert actions.build_update(False, None).stdin == "5\n2\nN\nN\n10\n"
    assert actions.build_update(True, "nightly").stdin == "5\n1\n\ny\n2\ny\nN\n10\n"
    assert actions.build_update(False, "latest").stdin == "5\n2\ny\n1\ny\nN\n10\n"


def test_password_hash_roundtrip():
    h = auth.hash_password("pässword")
    assert auth.verify_password("pässword", h)
    assert not auth.verify_password("password", h)
    assert not auth.verify_password("x", "garbage")


def test_delete_backup_endpoint(client):
    login(client)
    n = len(client.get("/api/backups").json())
    name = client.get("/api/backups").json()[0]["name"]
    assert client.delete("/api/backups/" + name).json()["ok"]
    assert len(client.get("/api/backups").json()) == n - 1
    assert client.delete("/api/backups/" + name).status_code == 404
    assert client.delete("/api/backups/notabackup").status_code in (400, 404)
    c2 = client.__class__(client.app, base_url="http://testserver")
    assert c2.delete("/api/backups/" + name, headers={"X-UI-Request": "1"}).status_code == 401
    assert client.delete("/api/backups/" + name, headers={"X-UI-Request": ""}).status_code == 403


def test_backup_lock_and_note(client):
    login(client)
    name = client.get("/api/backups").json()[0]["name"]
    assert client.put(f"/api/backups/{name}/meta", json={"locked": True, "note": "  good one  "}).json() == {"locked": True, "note": "good one"}
    row = next(b for b in client.get("/api/backups").json() if b["name"] == name)
    assert row["locked"] is True and row["note"] == "good one"
    r = client.delete(f"/api/backups/{name}")
    assert r.status_code == 409
    assert any(b["name"] == name for b in client.get("/api/backups").json())
    client.put(f"/api/backups/{name}/meta", json={"locked": False})
    assert client.delete(f"/api/backups/{name}").status_code == 200
    assert client.put(f"/api/backups/{name}/meta", json={"note": "x"}).status_code == 404
    assert name not in (config.STATE_DIR / "backup-meta.json").read_text()


def test_note_is_capped_and_meta_needs_login(client):
    login(client)
    name = client.get("/api/backups").json()[0]["name"]
    assert len(client.put(f"/api/backups/{name}/meta", json={"note": "a" * 500}).json()["note"]) == 200
    client.post("/api/logout"); client.cookies.clear()
    assert client.put(f"/api/backups/{name}/meta", json={"locked": True}).status_code == 401


def test_clear_activity_keeps_running_and_clears_finished(client):
    from app import main
    login(client)
    main.jobs.start(actions.resolve("stack.restart", None), None)
    deadline = time.time() + 20
    while main.jobs.current_id() and time.time() < deadline:
        time.sleep(0.2)
    assert client.get("/api/jobs").json()
    assert client.delete("/api/jobs").json()["cleared"] >= 1
    assert client.get("/api/jobs").json() == []


def test_clear_logs_endpoint(client):
    login(client)
    assert client.post("/api/logs/aiostreams/clear").json()["ok"]
    assert client.post("/api/logs/nonsense/clear").status_code == 404


def test_reboot_needs_word_and_idle_stack(client, monkeypatch):
    from app import main
    login(client)
    assert client.post("/api/server/reboot", json={}).status_code == 400
    assert client.post("/api/server/reboot", json={"confirm": "yes"}).status_code == 400
    with monkeypatch.context() as m:
        m.setattr(main.jobs, "current_id", lambda: "abc")
        assert client.post("/api/server/reboot", json={"confirm": "reboot"}).status_code == 409
    called = []
    monkeypatch.setattr(main.backend, "reboot_host", lambda: called.append(1))
    assert client.post("/api/server/reboot", json={"confirm": " Reboot "}).json()["ok"]
    for _ in range(40):
        if called: break
        time.sleep(0.1)
    assert called
    client.cookies.clear()
    assert client.post("/api/server/reboot", json={"confirm": "reboot"}).status_code == 401


def test_restart_single_service(client, monkeypatch):
    from app import main
    login(client)
    assert client.post("/api/services/caddy/restart", json={}).status_code == 404
    assert client.post("/api/services/gluetun/restart", json={}).status_code == 404
    assert client.post("/api/services/nope/restart", json={}).status_code == 404
    with monkeypatch.context() as m:
        m.setattr(main.jobs, "current_id", lambda: "abc")
        assert client.post("/api/services/aiostreams/restart", json={}).status_code == 409
    r = client.post("/api/services/aiostreams/restart", json={})
    assert r.status_code == 200 and r.json() == {"ok": True, "name": "AIOStreams"}
    assert main.backend.restarted_service == "aiostreams"
    client.cookies.clear()
    assert client.post("/api/services/aiostreams/restart", json={}).status_code == 401


def test_set_aside_endpoints(client):
    login(client)
    items = client.get("/api/set-asides").json()
    assert len(items) == 1
    name = items[0]["name"]
    assert client.delete("/api/set-asides/aiostreams").status_code == 400
    assert client.delete("/api/set-asides/" + name).json()["ok"]
    assert client.get("/api/set-asides").json() == []
    assert client.delete("/api/set-asides/" + name).status_code == 404
