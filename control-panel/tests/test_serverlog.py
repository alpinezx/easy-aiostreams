import os
import time
from datetime import timezone

from app.serverlog import ServerLog, rough

T = 1_800_000_000


class Facts:
    def __init__(self, **kw):
        self.v = {"boot_id": "a", "uptime": 5000, "backup_last": "", "restart_last": "", "quiet": False, "tz": timezone.utc}
        self.v.update(kw)

    def __call__(self):
        return dict(self.v)


def test_a_restart_is_logged_with_its_down_time(tmp_path):
    f = Facts()
    log = ServerLog(tmp_path / "s.json", f)
    log.check(T)                                   # first look: nothing to say
    assert log.events() == []
    log.check(T + 60)                              # same boot: still nothing
    f.v.update(boot_id="b", uptime=100)            # down at T+60, back at T+600-100 = T+500
    log.check(T + 600)
    [e] = log.events()
    assert e["kind"] == "reboot" and e["at"] == T + 500
    assert e["text"] == f"Server restarted at {time.strftime('%H:%M', time.gmtime(T + 500))}. It was down for about 7 min."
    log.check(T + 660)                             # only once
    assert len(log.events()) == 1


def test_a_scheduled_reboot_says_so_and_a_skipped_one_has_its_own_line(tmp_path):
    f = Facts()
    log = ServerLog(tmp_path / "s.json", f)
    log.check(T)
    f.v["restart_last"] = f"{T + 30}|restarted|An update needed it.\n"
    log.check(T + 40)                              # seen before the reboot: no line of its own
    assert log.events() == []
    f.v.update(boot_id="b", uptime=20)
    log.check(T + 100)
    [e] = log.events()
    assert "for its scheduled reboot. It was down for under 2 minutes." in e["text"]
    f.v["restart_last"] = f"{T + 200}|skipped|Not needed: no update was waiting for one."
    log.check(T + 260)
    assert log.events()[0]["text"] == "Scheduled reboot skipped. Not needed: no update was waiting for one."
    assert log.events()[0]["kind"] == "restart-skipped"


def test_scheduled_backups_in_the_watchdogs_words(tmp_path):
    f = Facts(backup_last=f"{T - 86400}|ok|old.tar.gz, 9MB.")
    log = ServerLog(tmp_path / "s.json", f)
    log.check(T)                                   # old news on the first look
    assert log.events() == []
    f.v["backup_last"] = f"{T + 10}|running|It stopped partway."
    log.check(T + 60)                              # still running: wait
    assert log.events() == []
    f.v["backup_last"] = f"{T + 10}|ok|new.tar.gz, 14MB."
    log.check(T + 120)
    assert log.events()[0] == {"at": T + 10, "kind": "backup", "text": "Scheduled backup made: new.tar.gz, 14MB."}
    f.v["backup_last"] = f"{T + 200}|running|It stopped partway. See: journalctl"
    log.check(T + 200 + 3601)                      # running for over an hour: failed
    assert log.events()[0]["kind"] == "backup-failed"
    assert log.events()[0]["text"] == "Scheduled backup failed: It stopped partway. See: journalctl"
    f.v["backup_last"] = f"{T + 9000}|skipped|The disk is full."
    log.check(T + 9060)
    assert log.events()[0]["kind"] == "backup-skipped" and len(log.events()) == 3


def test_a_first_look_reports_a_run_from_the_last_ten_minutes(tmp_path):
    log = ServerLog(tmp_path / "s.json", Facts(backup_last=f"{T - 300}|failed|No space."))
    log.check(T)
    assert [e["kind"] for e in log.events()] == ["backup-failed"]


def test_quiet_with_phone_alerts_but_markers_kept(tmp_path):
    f = Facts(quiet=True)
    log = ServerLog(tmp_path / "s.json", f)
    log.check(T)
    f.v.update(boot_id="b", uptime=50, backup_last=f"{T + 100}|ok|x.tar.gz, 1MB.")
    log.check(T + 200)
    assert log.events() == []                      # the watchdog logs these
    f.v["quiet"] = False                           # Phone alerts removed later: no old news
    log.check(T + 260)
    assert log.events() == []


def test_survives_a_panel_restart_and_ignores_a_restored_file(tmp_path):
    path = tmp_path / "s.json"
    now = time.time()
    f = Facts()
    ServerLog(path, f).check(now)
    f.v.update(boot_id="b", uptime=30)
    log = ServerLog(path, f)                       # the panel came back after the restart
    log.check(now + 300)
    assert [e["kind"] for e in log.events()] == ["reboot"]
    # A restore brings an older copy back: its file changed long after its own "alive"
    old = ServerLog(path, f)
    old.state.update(boot_id="old", alive=int(now - 86400))
    old.save()
    log = ServerLog(path, f)
    log.check(now + 400)
    assert [e["kind"] for e in log.events()] == ["reboot"]     # the list stays, no new restart
    assert log.state["boot_id"] == "b"


def test_remove_and_clear_and_save(tmp_path):
    path = tmp_path / "s.json"
    log = ServerLog(path, None)
    log.add(1, "backup", "a")
    log.add(2, "reboot", "b")
    assert [e["at"] for e in log.events()] == [2, 1]
    assert log.remove(1, "backup", "a") and not log.remove(1, "backup", "a")
    assert [e["at"] for e in ServerLog(path, None).events()] == [2]
    log.clear()
    assert ServerLog(path, None).events() == [] and not (tmp_path / "s.json.tmp").exists()


def test_rough():
    assert [rough(s) for s in (5, 119, 120, 3600, 7200, 3 * 86400)] == \
        ["under 2 minutes", "under 2 minutes", "about 2 min", "about 60 min", "about 2 h", "about 3 days"]


def test_api_lists_removes_and_clears(tmp_path, monkeypatch):
    os.environ["UI_DEMO"] = "1"
    import json
    from fastapi.testclient import TestClient
    from app import auth, config
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    (tmp_path / "auth.json").write_text(json.dumps(
        {"user": "me", "hash": auth.hash_password("correct horse"), "secret": "s3cret"}))
    from app import main
    main.lockout.__init__()
    c = TestClient(main.app, base_url="http://testserver")
    c.headers.update({"X-UI-Request": "1"})
    assert c.get("/api/server-events").status_code == 401
    c.post("/api/login", json={"username": "me", "password": "correct horse"})
    main.serverlog.clear()
    main.serverlog.add(10, "backup", "Scheduled backup made: a.")
    main.serverlog.add(20, "reboot", "Server restarted at 04:31.")
    assert [e["at"] for e in c.get("/api/server-events").json()] == [20, 10]
    assert c.post("/api/server-events/remove", json={"at": 10, "kind": "backup", "text": "Scheduled backup made: a."}).json() == {"removed": True}
    assert c.post("/api/server-events/remove", json={"at": 10, "kind": "backup", "text": "Scheduled backup made: a."}).status_code == 404
    assert c.post("/api/server-events/remove", json={"at": "20", "kind": "reboot", "text": "x"}).status_code == 400
    assert c.post("/api/server-events/clear").json() == {"cleared": True}
    assert c.get("/api/server-events").json() == []
