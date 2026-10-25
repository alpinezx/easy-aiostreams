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
    assert "httponly" in sc and "samesite=lax" in sc
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
    with pytest.raises(actions.BadAction):
        actions.build_update(False, "nightly")       # the backup is the way back to stable


def wait_job(client, jid, secs=20):
    deadline = time.time() + secs
    while time.time() < deadline:
        j = client.get(f"/api/jobs/{jid}").json()
        if j["ended"]:
            return j
        time.sleep(0.2)
    raise AssertionError("job didn't finish")


@pytest.mark.parametrize("params,note", [
    ({"backup": True, "channel": "nightly"}, "Before switching stable → nightly (was v2.35.9)"),
    ({"backup": True}, "Before updating from v2.35.9"),
])
def test_update_notes_the_backup_it_makes(client, params, note):
    login(client)
    before = {b["name"] for b in client.get("/api/backups").json()}
    jid = client.post("/api/actions/stack.update", json={"params": params}).json()["id"]
    assert wait_job(client, jid)["code"] == 0
    new = [b for b in client.get("/api/backups").json() if b["name"] not in before]
    assert len(new) == 1 and new[0]["note"] == note


def test_update_without_backup_notes_nothing_and_nightly_needs_one(client):
    login(client)
    assert client.post("/api/actions/stack.update", json={"params": {"backup": False, "channel": "nightly"}}).status_code == 400
    names = lambda: [(b["name"], b["note"]) for b in client.get("/api/backups").json()]
    before = names()
    jid = client.post("/api/actions/stack.update", json={"params": {"backup": False}}).json()["id"]
    wait_job(client, jid)
    assert names() == before


def test_update_note_wording():
    from app.main import update_note
    nightly = {"channel": "nightly", "version": "2.35.9", "build_tag": "2026.10.11.1908-nightly"}
    assert update_note(nightly, {"channel": "latest"}) == "Before switching nightly → stable (was nightly 2026.10.11.1908)"
    assert update_note(nightly, {}) == "Before updating from nightly 2026.10.11.1908"
    assert update_note({"channel": "latest", "version": "2.35.9"}, {"channel": "latest"}) == "Before updating from v2.35.9"
    assert update_note({"channel": "latest"}, {}) == "Before updating"


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


def test_remove_one_activity_entry(client):
    from app import main
    login(client)
    ids = []
    for _ in range(2):
        ids.append(main.jobs.start(actions.resolve("stack.restart", None), None)["id"])
        deadline = time.time() + 20
        while main.jobs.current_id() and time.time() < deadline:
            time.sleep(0.2)
    assert client.delete(f"/api/jobs/{ids[0]}").json() == {"removed": ids[0]}
    left = [j["id"] for j in client.get("/api/jobs").json()]
    assert ids[0] not in left and ids[1] in left
    assert client.delete(f"/api/jobs/{ids[0]}").status_code == 404
    with pytest.MonkeyPatch.context() as m:
        m.setitem(main.jobs.items[ids[1]], "ended", None)
        assert client.delete(f"/api/jobs/{ids[1]}").status_code == 409


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


def test_backup_builds_are_read_in_the_background_and_kept(client):
    from app import main
    login(client)
    first = client.get("/api/backups").json()
    assert all(b["build_pending"] and b["build"] is None for b in first)
    deadline = time.time() + 15
    while time.time() < deadline:
        rows = client.get("/api/backups").json()
        if not any(b["build_pending"] for b in rows):
            break
        time.sleep(0.2)
    by = {b["name"]: b["build"] for b in rows}
    assert by["aiostreams-backup-20261007-031500.tar.gz"] == {"version": "2.35.9", "tag": "2026.10.06.2045-nightly"}
    assert by["aiostreams-backup-20260930-221042.tar.gz"] is None          # made before builds were recorded
    cached = json.loads((config.STATE_DIR / "backup-builds.json").read_text())
    assert set(cached) == set(by)
    calls = []
    real = main.backend.backup_build
    main.backend.backup_build = lambda b: calls.append(b) or real(b)
    try:
        client.get("/api/backups")
        time.sleep(0.5)
        assert calls == []                                                   # nothing read twice
    finally:
        main.backend.backup_build = real


def test_restore_action_is_same_server_and_marks_itself_as_from_the_panel():
    a = actions.build_restore("/root/aiostreams-backup-20261012-010000.tar.gz")
    assert a.args == ("restore", "--same-server", "/root/aiostreams-backup-20261012-010000.tar.gz")
    assert "AIOS_UI_TERMINAL=1" in a.env and a.stdin == ""


def test_restore_check_endpoint(client):
    login(client)
    names = [b["name"] for b in client.get("/api/backups").json()]
    good = client.get(f"/api/backups/{names[0]}/restore-check").json()
    assert good["ok"] is True and good["notes"]
    bad = client.get("/api/backups/aiostreams-backup-20260914-094407.tar.gz/restore-check").json()
    assert bad["ok"] is False and any("domain" in r for r in bad["reasons"])
    assert client.get("/api/backups/notabackup/restore-check").status_code == 400
    assert client.get("/api/backups/aiostreams-backup-19990101-000000.tar.gz/restore-check").status_code == 404


def test_restore_needs_the_typed_word_and_a_real_backup(client):
    login(client)
    name = client.get("/api/backups").json()[0]["name"]
    assert client.post("/api/actions/stack.restore", json={"params": {"name": name}}).status_code == 400
    assert client.post("/api/actions/stack.restore", json={"params": {"name": "../../etc/passwd", "confirm": "restore"}}).status_code == 400
    assert client.post("/api/actions/stack.restore", json={"params": {"name": "aiostreams-backup-19990101-000000.tar.gz", "confirm": "restore"}}).status_code == 404
    r = client.post("/api/actions/stack.restore", json={"params": {"name": name, "confirm": "Restore "}})
    assert r.status_code == 200
    j = wait_job(client, r.json()["id"])
    assert j["code"] == 0 and j["action"] == "stack.restore"


def test_scripts_compare_endpoint_covers_every_script_and_the_backup_one(client):
    login(client)
    out = client.get("/api/scripts/compare").json()
    assert set(out["files"]) == {"setup-aiostreams.sh", "setup-vpn-gluetun.sh", "setup-mediaflow.sh",
                                 "setup-watchdog.sh", "setup-aiometadata.sh", "setup-aiomanager.sh", "setup-backup.sh"}
    assert out["files"]["setup-mediaflow.sh"]["differs"] is True
    client.post("/api/logout"); client.cookies.clear()
    assert client.get("/api/scripts/compare").status_code == 401


def test_panel_version_and_update_endpoints(client):
    login(client)
    me = client.get("/api/me").json()
    assert me["version"] == config.VERSION
    v = client.get("/api/panel/version").json()
    assert v["current"] == config.VERSION and v["latest"] == "1.1.0" and "running" in v
    assert client.post("/api/panel/update", json={}).status_code == 400
    assert client.post("/api/panel/update", json={"confirm": "Update "}).json() == {"ok": True, "demo": True}
    client.post("/api/logout"); client.cookies.clear()
    assert client.post("/api/panel/update", json={"confirm": "update"}).status_code == 401


def test_vpn_page_needs_login_and_shows_no_keys(client):
    assert client.get("/api/vpn").status_code == 401
    login(client)
    v = client.get("/api/vpn").json()
    assert v["mode"] in ("on", "off", "none")
    assert not any("key" in k.lower() for k in v)


def test_vpn_change_server_takes_only_an_ipv4_address(client):
    assert client.get("/api/vpn/addresses").status_code == 401
    assert client.post("/api/actions/vpn.use", json={"params": {"ip": "203.0.113.24"}}).status_code == 401
    login(client)
    r = client.get("/api/vpn/addresses").json()
    assert r["host"] and r["addresses"] and sum(a["in_use"] for a in r["addresses"]) == 1
    for bad in ("", "nope", "1.2.3", "300.1.1.1", "1.2.3.4; reboot", "::1", None):
        assert client.post("/api/actions/vpn.use", json={"params": {"ip": bad}}).status_code == 400
    act = actions.resolve("vpn.use", {"ip": "203.0.113.24"})
    assert act.args == ("use-address", "203.0.113.24") and act.confirm is None
    assert actions.resolve("vpn.update").args == ("update",)


def test_vpn_change_config_checks_it_and_never_sends_keys_back(client):
    from tests.test_wgconf import GOOD, PRIV, PUB
    assert client.post("/api/vpn/config", json={"conf": GOOD}).status_code == 401
    login(client)
    for bad in ({}, {"conf": ""}, {"conf": "hello"}, {"conf": GOOD * 40}):
        assert client.post("/api/vpn/config", json=bad).status_code == 400
    r = client.post("/api/vpn/config", json={"conf": GOOD})
    assert r.status_code == 200 and r.json()["endpoint_host"] == "nl.wg.example-vpn.net"
    assert PRIV not in r.text and PUB not in r.text
    assert client.get("/api/vpn/config/addresses").json()["addresses"]
    assert client.post("/api/actions/vpn.config", json={"params": {"ip": "1.2.3.4; reboot"}}).status_code == 400
    act = actions.resolve("vpn.config", {"ip": "203.0.113.120"})
    assert act.args == ("use-config", "203.0.113.120") and act.confirm is None


def test_vpn_config_list_delete_and_use_only_listed_files(client):
    assert client.get("/api/vpn/configs").status_code == 401
    login(client)
    rows = client.get("/api/vpn/configs").json()
    in_use = next(c for c in rows if c["in_use"])
    spare = next(c for c in rows if c["kind"] == "file" and not c["in_use"])
    assert not any("key" in k.lower() for c in rows for k in c)
    for path in (in_use["path"], "/etc/passwd", "/home/ubuntu/../../etc/shadow", ""):
        assert client.post("/api/actions/vpn.delete", json={"params": {"path": path}}).status_code == 400
        assert client.post("/api/actions/vpn.file", json={"params": {"path": path, "ip": "203.0.113.120"}}).status_code == 400
    assert client.post("/api/actions/vpn.file", json={"params": {"path": spare["path"], "ip": "nope"}}).status_code == 400
    assert client.get("/api/vpn/configs/addresses", params={"path": "/etc/passwd"}).status_code == 400
    assert client.get("/api/vpn/configs/addresses", params={"path": spare["path"]}).json()["addresses"]
    r = client.post("/api/actions/vpn.delete", json={"params": {"path": spare["path"]}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0


def test_vpn_config_in_use_deletable_only_with_the_vpn_off(client, monkeypatch):
    from app import main
    login(client)
    in_use = next(c for c in client.get("/api/vpn/configs").json() if c["in_use"])
    monkeypatch.setattr(main.backend, "vpn", "on")
    assert client.post("/api/actions/vpn.delete", json={"params": {"path": in_use["path"]}}).status_code == 400
    monkeypatch.setattr(main.backend, "vpn", "off")
    r = client.post("/api/actions/vpn.delete", json={"params": {"path": in_use["path"]}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0
    assert client.get("/api/vpn").json()["has_config"] is False
    assert actions.resolve("vpn.config", {"ip": "203.0.113.120", "on": True}).args == ("use-config", "203.0.113.120", "on")
    assert actions.resolve("vpn.config", {"ip": "203.0.113.120", "on": "yes"}).args == ("use-config", "203.0.113.120")


def test_vpn_uninstall_needs_the_word_then_its_script_can_go(client, monkeypatch):
    from app import main
    assert client.post("/api/scripts/vpn/remove").status_code == 401
    login(client)
    monkeypatch.setattr(main.backend, "vpn", "on")
    assert client.post("/api/scripts/vpn/remove").status_code == 400          # still set up
    assert client.post("/api/scripts/aiostreams/remove").status_code == 400   # never the main script
    assert client.post("/api/scripts/nope/remove").status_code == 400
    for word in ("", "yes", "Uninstal"):
        r = client.post("/api/actions/vpn.uninstall", json={"params": {"confirm": word, "remove_image": True}})
        assert r.status_code == 400
    assert actions.resolve("vpn.uninstall", {"remove_image": True, "delete_confs": True}).args == ("uninstall", "remove-image", "delete-confs")
    assert actions.resolve("vpn.uninstall", {"remove_image": "yes"}).args == ("uninstall",)
    r = client.post("/api/actions/vpn.uninstall", json={"params": {"confirm": " Uninstall ", "remove_image": True}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0
    assert client.get("/api/vpn").json()["mode"] == "none"
    vpn = next(s for s in client.get("/api/status").json()["scripts"] if s["id"] == "vpn")
    assert vpn["present"] and vpn["in_use"] is False
    assert client.post("/api/scripts/vpn/remove").json() == {"removed": "setup-vpn-gluetun.sh"}
    assert not next(s for s in client.get("/api/status").json()["scripts"] if s["id"] == "vpn")["present"]


def test_phone_alerts_page_never_shows_the_topic_and_changes_it_by_stdin(client):
    from app.stack import mask_topic
    assert client.get("/api/watchdog").status_code == 401
    login(client)
    w = client.get("/api/watchdog").json()
    assert w["configured"] and w["topic"] == "aios-••••••81"
    assert "7f3k29xq81" not in json.dumps(w)
    assert w["events"] and w["tally"] and w["watches"][0].startswith("https://")
    assert mask_topic("") is None and mask_topic("abc") == "•" * 8
    for bad in ("short", "has spaces in it", "x" * 65, "semi;colon-topic", ""):
        assert client.post("/api/actions/watchdog.topic", json={"params": {"topic": bad}}).status_code == 400
    a = actions.resolve("watchdog.topic", {"topic": " aios-abcdefghijkl "})
    assert a.args == ("set-topic",) and a.stdin == "aios-abcdefghijkl\n"   # never on a command line
    assert actions.resolve("watchdog.test").args == ("test",)
    r = client.post("/api/actions/watchdog.topic", json={"params": {"topic": "aios-newtopic12345"}})
    assert r.status_code == 200
    job = wait_job(client, r.json()["id"])
    assert job["code"] == 0 and "aios-newtopic12345" not in json.dumps(job)
    w = client.get("/api/watchdog").json()
    assert w["topic"].endswith("45") and w["events"][0]["kind"] == "test" and w["events"][1]["kind"] == "topic"


def test_phone_alerts_history_can_be_cleared(client):
    assert client.post("/api/watchdog/events/clear").status_code == 401
    login(client)
    assert client.get("/api/watchdog").json()["events"]
    assert client.post("/api/watchdog/events/clear").json() == {"cleared": True}
    w = client.get("/api/watchdog").json()
    assert w["events"] == [] and w["tally"]          # the daily tally stays


def test_phone_alerts_switches(client):
    assert client.post("/api/watchdog/options", json={"name": "weekly", "on": True}).status_code == 401
    login(client)
    assert client.get("/api/watchdog").json()["options"] == {"updates": False, "reboots": False, "scripts": False, "backups": False, "security": False, "weekly": False, "metadata": False, "weekly_day": 7, "weekly_time": "10:00"}
    for bad in ({"name": "nope", "on": True}, {"name": "weekly", "on": "yes"}, {}, {"name": "weekly_day", "value": 8},
                {"name": "weekly_time", "value": "24:00"}, {"name": "weekly_time", "value": "9"}, {"name": "weekly_time", "value": 9},
                {"name": "weekly_day", "value": True}, {"name": "weekly_hour", "value": 9}, {"name": "reboots", "on": "off"}):
        assert client.post("/api/watchdog/options", json=bad).status_code == 400
    assert client.post("/api/watchdog/options", json={"name": "weekly", "on": True}).json() == {"weekly": True}
    assert client.post("/api/watchdog/options", json={"name": "weekly_day", "value": 1}).status_code == 200
    assert client.post("/api/watchdog/options", json={"name": "weekly_time", "value": "7:05"}).status_code == 200
    assert client.post("/api/watchdog/options", json={"name": "reboots", "on": True}).json() == {"reboots": True}
    assert client.post("/api/watchdog/options", json={"name": "scripts", "on": True}).json() == {"scripts": True}
    assert client.post("/api/watchdog/options", json={"name": "backups", "on": True}).json() == {"backups": True}
    assert client.post("/api/watchdog/options", json={"name": "security", "on": True}).json() == {"security": True}
    assert client.post("/api/watchdog/options", json={"name": "metadata", "on": True}).json() == {"metadata": True}
    assert client.get("/api/watchdog").json()["options"] == {"updates": False, "reboots": True, "scripts": True, "backups": True, "security": True, "weekly": True, "metadata": True, "weekly_day": 1, "weekly_time": "07:05"}
    assert client.post("/api/watchdog/tally/clear").json() == {"cleared": True}
    assert client.get("/api/watchdog").json()["tally"] == []


def test_phone_alerts_uninstall_then_its_script_can_go(client):
    login(client)
    a = actions.resolve("watchdog.uninstall")
    assert a.args == ("uninstall",) and a.confirm
    assert client.post("/api/scripts/watchdog/remove").status_code == 400          # still set up
    r = client.post("/api/actions/watchdog.uninstall", json={"params": {}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0
    assert client.get("/api/watchdog").json() == {"configured": False}
    assert client.get("/api/status").json()["watchdog"]["configured"] is False
    wd = next(s for s in client.get("/api/status").json()["scripts"] if s["id"] == "watchdog")
    assert wd["present"] and wd["in_use"] is False
    assert client.post("/api/scripts/watchdog/remove").json() == {"removed": "setup-watchdog.sh"}


def test_scripts_update_replaces_with_mains_copy(client):
    assert client.post("/api/scripts/mediaflow/update").status_code == 401
    login(client)
    differs = lambda: client.get("/api/scripts/compare").json()["files"]["setup-mediaflow.sh"]["differs"]
    assert differs() is True
    assert client.post("/api/scripts/nope/update").status_code == 400
    r = client.post("/api/scripts/mediaflow/update").json()
    assert r["updated"] == ["setup-mediaflow.sh"]
    assert differs() is False
    assert client.post("/api/scripts/aiostreams/update").json()["updated"] == ["setup-aiostreams.sh", "setup-backup.sh"]


def test_no_method_is_defined_twice():
    # A second def with the same name silently replaces the first (panel 1.24.0
    # lost the server's uptime, load, memory and disk that way)
    import ast
    from pathlib import Path
    for f in ("stack.py", "demo.py", "main.py"):
        tree = ast.parse((Path(__file__).parent.parent / "app" / f).read_text(encoding="utf-8"))
        for cls in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
            names = [n.name for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
            assert len(names) == len(set(names)), (f, cls.name, sorted({n for n in names if names.count(n) > 1}))


def test_backup_schedule(client):
    assert client.get("/api/backup-schedule").status_code == 401
    login(client)
    s = client.get("/api/backup-schedule").json()
    assert s["every"] in ("off", "daily", "weekly") and s["keep"] == 7
    for bad in ({"every": "hourly", "time": "04:00"}, {"every": "daily", "time": "25:00"}, {"every": "weekly", "day": 8, "time": "04:00"},
                {"every": "weekly", "day": True, "time": "04:00"}, {"every": "daily"}):
        assert client.put("/api/backup-schedule", json=bad).status_code == 400
    r = client.put("/api/backup-schedule", json={"every": "weekly", "day": 3, "time": "5:30"}).json()
    assert (r["every"], r["day"], r["time"]) == ("weekly", 3, "05:30")
    assert client.put("/api/backup-schedule", json={"every": "off"}).json()["every"] == "off"
    assert client.get("/api/status").json()["backup"]["every"] == "off"


def test_overview_layout(client):
    login(client)
    ids = lambda r: [(c["id"], c["show"]) for c in r.json()["cards"]]
    default = [("flow", True), ("aiostreams", True), ("aiometadata", True), ("aiomanager", True), ("alerts", True), ("vpn", True), ("server", True), ("services", True)]
    assert ids(client.get("/api/overview-layout")) == default
    # unknown and repeated cards are dropped; ones left out go back to their default place
    r = client.put("/api/overview-layout", json={"cards": [{"id": "services", "show": True}, {"id": "nope"},
                                                         {"id": "alerts", "show": False}, {"id": "services", "show": False}]})
    assert ids(r) == [("flow", True), ("aiostreams", True), ("aiometadata", True), ("aiomanager", True), ("services", True), ("alerts", False), ("vpn", True), ("server", True)]
    # layout.js lists the cards in the same default order
    import re
    from pathlib import Path
    js = (Path(__file__).resolve().parents[1] / "web" / "js" / "layout.js").read_text(encoding="utf-8")
    block = js[js.index("const CARDS = {"):js.index("};", js.index("const CARDS = {"))]
    assert re.findall(r"^\s+(\w+): \[", block, re.M) == [c for c, _ in default]
    assert ids(client.get("/api/overview-layout")) == ids(r)
    assert client.put("/api/overview-layout", json={"cards": "x"}).status_code == 400
    assert ids(client.put("/api/overview-layout", json={"cards": []})) == default


def test_rail_layout(client):
    login(client)
    from app.main import RAIL_PAGES
    ids = lambda r: [c["id"] for c in r.json()["cards"]]
    assert ids(client.get("/api/rail-layout")) == RAIL_PAGES
    r = client.put("/api/rail-layout", json={"cards": [{"id": "maint", "show": True}, {"id": "overview"}, {"id": "logs", "show": False}]})
    assert ids(r)[:2] == ["maint", "logs"] and r.json()["cards"][1]["show"] is False   # Overview isn't one: always first
    assert sorted(ids(r)) == sorted(RAIL_PAGES)
    assert ids(client.get("/api/overview-layout"))[0] == "flow"                     # the Overview's own layout untouched
    assert ids(client.put("/api/rail-layout", json={"cards": []})) == RAIL_PAGES
    # layout.js lists the same pages in the same order, and each has its tab on the rail
    import re
    from pathlib import Path
    web = Path(__file__).resolve().parents[1] / "web"
    js = (web / "js" / "layout.js").read_text(encoding="utf-8")
    block = js[js.index("const PAGES = {"):js.index("};", js.index("const PAGES = {"))]
    assert re.findall(r"^\s+(\w+): \[", block, re.M) == RAIL_PAGES
    html = (web / "index.html").read_text(encoding="utf-8")
    links = html[html.index('<div class="rail-links">'):html.index('<div class="rail-end">')]
    assert re.findall(r'data-view="(\w+)"', links) == ["overview"] + RAIL_PAGES


def test_aiometadata_status_reads_only_domain_and_version(tmp_path):
    from types import SimpleNamespace
    from app import stack
    (tmp_path / "aiometadata-state").mkdir()
    conf = tmp_path / "aiometadata-state" / "config"
    conf.write_text("DOMAIN='meta.example.com'\nADDON_PASSWORD='s3cret'\nADMIN_KEY='k3y'\nAIOM_VERSION='3.6.1'\n")
    me = SimpleNamespace(p=lambda rel: tmp_path / rel)
    read = lambda c: stack.Backend._aiometadata(me, c)
    assert read(None) == {"domain": "meta.example.com", "version": "3.6.1"}
    # the running image's tag wins over the pinned one
    running = SimpleNamespace(attrs={"Config": {"Image": "ghcr.io/cedya77/aiometadata:3.6.2"}})
    assert read(running) == {"domain": "meta.example.com", "version": "3.6.2"}
    conf.write_text("DOMAIN='meta.example.com'\nAIOM_VERSION='latest'\n")
    assert read(None) is None
    conf.unlink()
    assert read(None) is None


def test_aiometadata_update_action():
    a = actions.resolve("aiometadata.update", {"backup": True})
    assert a.script == "setup-aiometadata.sh" and a.args == ("update-aiometadata", "--backup")
    assert actions.resolve("aiometadata.update", {"backup": False}).args == ("update-aiometadata",)
    with pytest.raises(actions.BadAction):
        actions.resolve("aiometadata.update", {"backup": "yes"})


def test_aiomanager_status_reads_its_settings_and_counts_logins(tmp_path):
    from types import SimpleNamespace
    from app import stack
    (tmp_path / "aiomanager-state").mkdir()
    conf = tmp_path / "aiomanager-state" / "config"
    conf.write_text("DOMAIN='manager.example.com'\nAIOMAN_VERSION='2.0.0'\nSIGNUPS='closed'\nSIGNUPS_UNTIL=''\n")
    me = SimpleNamespace(p=lambda rel: tmp_path / rel, _ADDON_CONF=stack.Backend._ADDON_CONF)
    me._addon_conf = lambda a: stack.Backend._addon_conf(me, a)
    me._login_count = lambda c: stack.Backend._login_count(me, c)
    read = lambda c: stack.Backend._aiomanager(me, c)
    assert read(None) == {"domain": "manager.example.com", "version": "2.0.0", "signups": "closed",
                          "signups_until": None, "logins": None}
    asked = []

    def exec_run(cmd, workdir=None):
        asked.append((cmd[0], workdir))
        return SimpleNamespace(exit_code=0, output=b"3\n")
    running = SimpleNamespace(attrs={"Config": {"Image": "ghcr.io/sonicx161/aiomanager:2.0.1"}, "State": {"Running": True}},
                              exec_run=exec_run)
    conf.write_text("DOMAIN='manager.example.com'\nAIOMAN_VERSION='2.0.0'\nSIGNUPS='open'\nSIGNUPS_UNTIL='1792892521'\n")
    got = read(running)
    assert got == {"domain": "manager.example.com", "version": "2.0.1", "signups": "open",
                   "signups_until": 1792892521, "logins": 3}
    # asked inside its own container, then kept for a minute rather than every status poll
    assert asked == [("/nodejs/bin/node", "/app/server")]
    read(running)
    assert len(asked) == 1
    conf.unlink()
    assert read(None) is None


def test_aiomanager_actions():
    a = actions.resolve("aiomanager.update", {"backup": True})
    assert a.script == "setup-aiomanager.sh" and a.args == ("update-aiomanager", "--backup")
    assert actions.resolve("aiomanager.update", {"backup": False}).args == ("update-aiomanager",)
    with pytest.raises(actions.BadAction):
        actions.resolve("aiomanager.update", {"backup": "yes"})
    assert actions.resolve("aiomanager.signups_open").args == ("signups", "open", "30")
    assert actions.resolve("aiomanager.signups_close").args == ("signups", "close")
    assert actions.resolve("aiomanager.uninstall", {"remove_image": True}).args == ("uninstall", "remove-image")


def test_aiomanager_signups_switch(client):
    login(client)
    assert client.get("/api/status").json()["aiomanager"]["signups"] == "closed"
    r = client.post("/api/actions/aiomanager.signups_open", json={"params": {}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0
    m = client.get("/api/status").json()["aiomanager"]
    assert m["signups"] == "open" and m["signups_until"] > time.time() + 25 * 60
    r = client.post("/api/actions/aiomanager.signups_close", json={"params": {}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0
    assert client.get("/api/status").json()["aiomanager"]["signups"] == "closed"
    # It's left out of the request flow: a stream never passes through it
    svc = {s["key"]: s for s in client.get("/api/status").json()["services"]}
    assert svc["aiomanager"]["flow"] is False and svc["aiometadata"]["flow"] is True


def test_maintenance_leaves_phased_updates_out():
    from types import SimpleNamespace
    from app import stack
    listing = ("Listing...\n"
               "systemd/noble-updates 255.4-1ubuntu8.8 amd64 [upgradable from: 255.4-1ubuntu8.6]\n"
               "tmux/noble-updates 3.4-1ubuntu0.2 amd64 [upgradable from: 3.4-1ubuntu0.1]\n"
               "openssl/noble-updates,noble-security 3.0.13-0ubuntu3.6 amd64 [upgradable from: 3.0.13-0ubuntu3.5]\n")
    sim = ("The following upgrades have been deferred due to phasing:\n  systemd tmux\n"
           "Inst openssl [3.0.13-0ubuntu3.5] (3.0.13-0ubuntu3.6 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])\n"
           "Conf openssl (3.0.13-0ubuntu3.6 Ubuntu:24.04/noble-updates [amd64])\n")

    def host(answers):
        def on_host(*args, timeout=20):
            return answers.get(args[0], "")
        return SimpleNamespace(_on_host=on_host)
    u = stack.Backend._maint_updates(host({"apt": listing, "apt-get": sim, "sh": ""}))
    assert (u["count"], u["security"], u["phased"]) == (1, 1, 2)
    # if the simulation can't run, every waiting update still shows
    u = stack.Backend._maint_updates(host({"apt": listing, "apt-get": "", "sh": ""}))
    assert (u["count"], u["phased"]) == (3, 0)


def test_the_page_offers_restart_for_exactly_what_the_server_allows():
    import re
    from pathlib import Path
    from app import stack
    js = (Path(__file__).resolve().parents[1] / "web" / "js" / "overview.js").read_text(encoding="utf-8")
    m = re.search(r"const RESTARTABLE = new Set\(\[([^\]]*)\]\)", js)
    assert m and set(re.findall(r'"([^"]+)"', m.group(1))) == stack.RESTARTABLE


def test_add_ons_page_leaves_the_secrets_out_until_asked(client):
    assert client.get("/api/addons").status_code == 401
    assert client.get("/api/addons/mediaflow/secret/api_password").status_code == 401
    login(client)
    r = client.get("/api/addons")
    assert r.status_code == 200
    assert [a["id"] for a in r.json()] == ["aiometadata", "aiomanager", "mediaflow"]
    for s in ("demo-addon-password", "demo-admin-key", "demo-api-password"):
        assert s not in r.text
    r = client.get("/api/addons/mediaflow/secret/api_password")
    assert r.status_code == 200 and r.json()["value"] and r.headers["cache-control"] == "no-store"
    assert client.get("/api/addons/mediaflow/secret/admin_key").status_code == 404
    assert client.get("/api/addons/nope/secret/url").status_code == 404


def test_add_on_uninstall_needs_the_word(client):
    login(client)
    for addon in ("aiometadata", "aiomanager", "mediaflow", "webhook"):
        for word in ("", "yes", "Uninstal"):
            r = client.post(f"/api/actions/{addon}.uninstall", json={"params": {"confirm": word}})
            assert r.status_code == 400, (addon, word)
        if addon != "webhook":
            a = actions.resolve(f"{addon}.uninstall")
            assert a.args == ("uninstall",) and a.script.startswith("setup-")
    r = client.post("/api/actions/mediaflow.uninstall", json={"params": {"confirm": " Uninstall "}})
    assert r.status_code == 200 and wait_job(client, r.json()["id"])["code"] == 0


def test_no_class_names_an_ad_blocker_hides():
    """uBlock Origin's lists hide elements with classes like ad-card or ad-row, which blanked
    the Add-ons page. Keep the panel's names clear of them."""
    import re
    from pathlib import Path
    web = Path(__file__).resolve().parents[1] / "web"
    for f in [*web.glob("js/*.js"), *web.glob("css/*.css"), web / "index.html"]:
        found = re.findall(r"(?<![\w-])(?:ad|ads|advert|sponsor)[-_][\w-]+", f.read_text(encoding="utf-8"))
        assert not found, (f.name, found[:5])
