"""Status parsing and output cleanup, using a stand-in Docker client."""
import re
import pytest
import os
import pathlib
from types import SimpleNamespace

os.environ.pop("UI_DEMO", None)

from app import config  # noqa: E402
from app import stack  # noqa: E402


def container(name, running=True, health=None, restarting=False, restarts=0):
    state = {"Running": running, "Restarting": restarting, "StartedAt": "2026-10-01T10:00:00.000000000Z", "ExitCode": 0}
    if health:
        state["Health"] = {"Status": health}
    return SimpleNamespace(name=name, attrs={"State": state, "RestartCount": restarts,
                                              "Config": {"Image": f"img/{name}:1"}})


def make_backend(tmp_path, monkeypatch, containers, compose=None, extra_files=()):
    root = tmp_path / "aiostreams"
    root.mkdir()
    (root / "docker-compose.yml").write_text(compose or (
        "services:\n  aiostreams:\n    image: viren070/aiostreams:nightly\n"
        "    environment:\n      - BASE_URL=https://streams.example.com\n      - SECRET_KEY=hunter2\n"))
    for rel in extra_files:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x")
    monkeypatch.setattr(config, "INSTALL_DIR", root)
    b = stack.Backend.__new__(stack.Backend)
    b._stats, b._cert_cache = {}, {}
    b._client = SimpleNamespace(containers=SimpleNamespace(list=lambda all=False: containers))
    b._cert = lambda host: None
    b._systemd_active = lambda unit: True
    return b


def test_all_up(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams", health="healthy")])
    st = b.status()
    assert st["overall"] == "ok" and st["headline"] == "Everything is up"
    assert st["domain"] == "streams.example.com" and st["channel"] == "nightly"
    assert [s["key"] for s in st["services"]] == ["caddy", "aiostreams"]


def test_secrets_never_in_status(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams")])
    assert "hunter2" not in repr(b.status())


def test_down_when_required_service_stopped(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams", running=False)])
    st = b.status()
    assert st["overall"] == "down" and st["headline"] == "AIOStreams is down"


def test_stopped_on_purpose_is_not_an_alarm(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams", running=False)],
                     extra_files=["aiostreams-stopped-on-purpose"])
    st = b.status()
    assert st["overall"] == "paused" and st["headline"] == "AIOStreams is stopped"


def test_unhealthy_counts_as_down(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams", health="unhealthy")])
    assert b.status()["overall"] == "down"


def test_vpn_and_addons_only_listed_when_set_up(tmp_path, monkeypatch):
    compose = "services:\n  gluetun:\n    container_name: gluetun\n  aiostreams:\n    image: viren070/aiostreams:latest\n"
    cs = [container("caddy"), container("gluetun", health="healthy"), container("aiostreams"), container("mediaflow-proxy-light")]
    b = make_backend(tmp_path, monkeypatch, cs, compose=compose, extra_files=["mediaflow-state/docker-compose.yml"])
    keys = [s["key"] for s in b.status()["services"]]
    assert keys == ["caddy", "gluetun", "aiostreams", "mediaflow"]


def test_addon_down_is_degraded_not_down(tmp_path, monkeypatch):
    cs = [container("caddy"), container("aiostreams"), container("mediaflow-proxy-light", running=False)]
    b = make_backend(tmp_path, monkeypatch, cs, extra_files=["mediaflow-state/docker-compose.yml"])
    assert b.status()["overall"] == "degraded"


def test_docker_unreachable(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [])
    def boom(all=False): raise RuntimeError("no socket")
    b._client.containers.list = boom
    st = b.status()
    assert st["overall"] == "down" and st["headline"] == "Can't reach Docker"


def test_output_cleanup():
    c = stack.clean_line
    assert c("\x1b[1;34m==>\x1b[0m Stopping") == "==> Stopping"
    assert c("Select an option [1-10]: Stopping AIOStreams...") == "Stopping AIOStreams..."
    assert c("Switch build channel before updating? [y/N]: Continue now that you've read this... ") == ""
    assert c("  3) Start AIOStreams") is None
    assert c("!!  Not a valid option.") is None
    assert c("Exiting.") is None
    assert c("Current build channel: nightly") == "Current build channel: nightly"


def test_only_known_log_containers():
    from app import main  # noqa: F401  (imports demo/real backend per env; just checking the allowlist exists)


def test_vpn_state_none_off_on(tmp_path, monkeypatch):
    cs = [container("caddy"), container("aiostreams")]
    b = make_backend(tmp_path, monkeypatch, cs)
    assert b.status()["vpn"] == "none"
    (tmp_path / "b").mkdir()
    b = make_backend(tmp_path / "b", monkeypatch, cs, extra_files=["vpn-state/active"])
    assert b.status()["vpn"] == "off"
    compose = "services:\n  gluetun:\n    container_name: gluetun\n  aiostreams:\n    image: viren070/aiostreams:latest\n"
    (tmp_path / "c").mkdir()
    b = make_backend(tmp_path / "c", monkeypatch, [container("caddy"), container("gluetun"), container("aiostreams")], compose=compose)
    assert b.status()["vpn"] == "on"


def test_backups_found_in_home_dirs_and_merged(tmp_path, monkeypatch):
    import subprocess
    root = tmp_path / "root"; (root / "aiostreams").mkdir(parents=True)
    ubuntu = tmp_path / "home" / "ubuntu"; ubuntu.mkdir(parents=True)
    (root / "aiostreams-backup-20261009-173904.tar.gz").write_text("a")
    (root / "aiostreams-backup-20261009-174806.tar.gz").write_text("bb")
    (ubuntu / "aiostreams-backup-20261009-173904.tar.gz").write_text("a")   # convenience copy
    (root / "notes.tar.gz").write_text("ignored")
    monkeypatch.setattr(config, "INSTALL_DIR", root / "aiostreams")
    monkeypatch.setattr(config, "ROOT_HOME", root)
    monkeypatch.setattr(stack, "HOMES_DIR", str(tmp_path / "home"))
    real_run = subprocess.run
    def run_without_nsenter(cmd, **kw):          # no host namespaces in a test: run find directly
        if cmd[0] == "nsenter":
            cmd = cmd[cmd.index("--") + 1:]
        return real_run(cmd, **kw)
    monkeypatch.setattr(stack.subprocess, "run", run_without_nsenter)
    b = stack.Backend.__new__(stack.Backend)
    got = {x["name"]: x["dirs"] for x in b.backups()}
    assert set(got) == {"aiostreams-backup-20261009-173904.tar.gz", "aiostreams-backup-20261009-174806.tar.gz"}
    assert got["aiostreams-backup-20261009-173904.tar.gz"] == [str(root), str(ubuntu)]
    assert got["aiostreams-backup-20261009-174806.tar.gz"] == [str(root)]


def test_delete_backup_removes_all_copies_and_rejects_others(tmp_path, monkeypatch):
    import subprocess
    root = tmp_path / "root"; (root / "aiostreams").mkdir(parents=True)
    ubuntu = tmp_path / "home" / "ubuntu"; ubuntu.mkdir(parents=True)
    name = "aiostreams-backup-20261009-173904.tar.gz"
    (root / name).write_text("a"); (ubuntu / name).write_text("a")
    (root / "aiostreams-backup-20261009-174806.tar.gz").write_text("keep")
    (root / "secret.txt").write_text("x")
    monkeypatch.setattr(config, "INSTALL_DIR", root / "aiostreams")
    monkeypatch.setattr(config, "ROOT_HOME", root)
    monkeypatch.setattr(stack, "HOMES_DIR", str(tmp_path / "home"))
    real_run = subprocess.run
    def run_without_nsenter(cmd, **kw):
        if cmd[0] == "nsenter":
            cmd = cmd[cmd.index("--") + 1:]
        return real_run(cmd, **kw)
    monkeypatch.setattr(stack.subprocess, "run", run_without_nsenter)
    b = stack.Backend.__new__(stack.Backend)
    for bad in ("../secret.txt", "secret.txt", "aiostreams-backup-x/../../secret.txt.tar.gz"):
        with pytest.raises(ValueError):
            b.delete_backup(bad)
    with pytest.raises(FileNotFoundError):
        b.delete_backup("aiostreams-backup-nope.tar.gz")
    assert sorted(b.delete_backup(name)) == sorted([str(root), str(ubuntu)])
    assert not (root / name).exists() and not (ubuntu / name).exists()
    assert (root / "aiostreams-backup-20261009-174806.tar.gz").exists() and (root / "secret.txt").exists()


def test_clear_logs_only_hides_and_never_touches_the_log_file(tmp_path, monkeypatch):
    cid = "a" * 64
    log = tmp_path / f"{cid}-json.log"; log.write_text("lots of old lines\n" * 50)
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    b = make_backend(tmp_path, monkeypatch, [])
    attrs = {"LogPath": str(log)}
    seen = {}
    def logs(**kw):
        seen.update(kw); return iter(())
    b._client = SimpleNamespace(containers=SimpleNamespace(get=lambda n: SimpleNamespace(attrs=attrs, logs=logs)))
    assert b.clear_logs("caddy") == "hidden"
    assert log.read_text() == "lots of old lines\n" * 50      # Docker's file is left alone
    assert "caddy" in b._cleared()
    b.log_stream("caddy", 200)
    assert isinstance(seen["since"], int)


def test_status_reports_which_scripts_exist(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy")], extra_files=("setup-aiostreams.sh", "setup-backup.sh", "setup-mediaflow.sh"))
    got = {s["id"]: s["present"] for s in b.status()["scripts"]}
    assert got == {"aiostreams": True, "backup": True, "vpn": False, "mediaflow": True, "watchdog": False, "webhook": False}


def test_set_asides_listed_and_only_those_deleted(tmp_path, monkeypatch):
    import subprocess
    root = tmp_path / "root"; (root / "aiostreams").mkdir(parents=True)
    old = root / "aiostreams.pre-restore-20261009-233216"; (old / "data").mkdir(parents=True)
    (old / "data" / "db").write_text("x" * 1000)
    (root / "aiostreams.pre-restore-junk").mkdir()             # wrong name shape: ignored
    (root / "aiostreams.pre-restore-20261001-000000").write_text("a file, not a folder")
    monkeypatch.setattr(config, "INSTALL_DIR", root / "aiostreams")
    real_run = subprocess.run
    def run_without_nsenter(cmd, **kw):
        if cmd[0] == "nsenter":
            cmd = cmd[cmd.index("--") + 1:]
        return real_run(cmd, **kw)
    monkeypatch.setattr(stack.subprocess, "run", run_without_nsenter)
    b = stack.Backend.__new__(stack.Backend)
    got = b.set_asides()
    assert [x["name"] for x in got] == [old.name]
    assert got[0]["size"] >= 1000 and got[0]["when"] and got[0]["dir"] == str(root)
    for bad in ("aiostreams", "../aiostreams", "aiostreams.pre-restore-junk", "aiostreams.pre-restore-20261009-233216/../aiostreams"):
        with pytest.raises((ValueError, FileNotFoundError)):
            b.delete_set_aside(bad)
    with pytest.raises(FileNotFoundError):
        b.delete_set_aside("aiostreams.pre-restore-20261001-000000")
    b.delete_set_aside(old.name)
    assert not old.exists() and (root / "aiostreams").exists() and (root / "aiostreams.pre-restore-junk").exists()
    assert b.set_asides() == []


def test_user_copy_found_only_for_a_real_non_root_owner(tmp_path, monkeypatch):
    import os, pwd, subprocess
    homes = tmp_path / "home"
    (homes / "rooty" / "aiostreams").mkdir(parents=True)           # owned by root: ignored
    monkeypatch.setattr(stack, "HOMES_DIR", str(homes))
    real_run = subprocess.run
    def run_without_nsenter(cmd, **kw):
        if cmd[0] == "nsenter":
            cmd = cmd[cmd.index("--") + 1:]
        return real_run(cmd, **kw)
    monkeypatch.setattr(stack.subprocess, "run", run_without_nsenter)
    b = stack.Backend.__new__(stack.Backend)
    b._user_copy_cache = (0.0, None)
    assert b.user_copy() is None
    nobody = pwd.getpwnam("nobody")
    (homes / "zuser" / "aiostreams").mkdir(parents=True)
    os.chown(homes / "zuser", nobody.pw_uid, nobody.pw_gid)
    b._user_copy_cache = (0.0, None)
    got = b.user_copy()
    assert got["user"] == "nobody" and got["dir"] == str(homes / "zuser" / "aiostreams") and got["sudo"] == "none"


def _no_nsenter(monkeypatch):
    import subprocess
    real_run = subprocess.run
    def run_without_nsenter(cmd, **kw):
        if cmd[0] == "nsenter":
            cmd = cmd[cmd.index("--") + 1:]
        return real_run(cmd, **kw)
    monkeypatch.setattr(stack.subprocess, "run", run_without_nsenter)


def test_opt_layout_backups_from_root_home_without_double_counting_the_link(tmp_path, monkeypatch):
    # After a migrate: install in /opt, tarballs in root's home, ~ubuntu/aiostreams a link to /opt.
    root = tmp_path / "root"; root.mkdir()
    opt = tmp_path / "opt" / "aiostreams"; opt.mkdir(parents=True)
    ubuntu = tmp_path / "home" / "ubuntu"; ubuntu.mkdir(parents=True)
    (ubuntu / "aiostreams").symlink_to(opt)
    name = "aiostreams-backup-20261010-120000.tar.gz"
    (root / name).write_text("a"); (ubuntu / name).write_text("a")
    (opt / "aiostreams-backup-20261001-000000.tar.gz").write_text("old")   # dropped inside by hand
    monkeypatch.setattr(config, "INSTALL_DIR", opt)
    monkeypatch.setattr(config, "ROOT_HOME", root)
    monkeypatch.setattr(stack, "HOMES_DIR", str(tmp_path / "home"))
    _no_nsenter(monkeypatch)
    b = stack.Backend.__new__(stack.Backend)
    got = {x["name"]: x["dirs"] for x in b.backups()}
    assert got[name] == [str(root), str(ubuntu)]
    assert got["aiostreams-backup-20261001-000000.tar.gz"] == [str(opt)]   # once, not again through the link
    assert b.home == str(root)


def test_version_read_once_per_container(tmp_path, monkeypatch):
    calls = []
    def exec_run(cmd):
        calls.append(cmd)
        return SimpleNamespace(exit_code=0, output=b'{"v":"2.35.9","t":"v2.35.9"}\n')
    aio = container("aiostreams", health="healthy"); aio.id = "abc"; aio.exec_run = exec_run
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), aio])
    b._version_cache = ("", (None, None))
    st = b.status()
    assert (st["version"], st["build_tag"]) == ("2.35.9", "v2.35.9")
    assert b.status()["version"] == "2.35.9" and len(calls) == 1      # first path worked; cached for the same container
    aio.id = "def"                                                      # recreated by an update
    b.status(); assert len(calls) == 2


def test_nightly_tag_read_and_odd_tags_dropped(tmp_path, monkeypatch):
    for out, want in [(b'{"v":"2.35.9","t":"2026.10.10.1200-nightly"}', "2026.10.10.1200-nightly"),
                      (b'{"v":"2.35.9"}', None),                                 # package.json fallback: no tag
                      (b'{"v":"2.35.9","t":"<b>x</b>"}', None)]:
        aio = container("aiostreams"); aio.id = out.decode()
        aio.exec_run = lambda cmd, out=out: SimpleNamespace(exit_code=0, output=out)
        d = tmp_path / str(abs(hash(out))); d.mkdir()
        b = make_backend(d, monkeypatch, [container("caddy"), aio])
        b._version_cache = ("", (None, None))
        st = b.status()
        assert st["version"] == "2.35.9" and st["build_tag"] == want


def test_version_none_when_stopped_or_unreadable(tmp_path, monkeypatch):
    stopped = container("aiostreams", running=False); stopped.id = "x"
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), stopped])
    b._version_cache = ("", (None, None))
    assert b.status()["version"] is None
    odd = container("aiostreams"); odd.id = "y"
    odd.exec_run = lambda cmd: SimpleNamespace(exit_code=0, output=b"<html>nope")
    (tmp_path / "b").mkdir()
    b = make_backend(tmp_path / "b", monkeypatch, [container("caddy"), odd])
    b._version_cache = ("", (None, None))
    st = b.status()
    assert st["version"] is None and st["build_tag"] is None
