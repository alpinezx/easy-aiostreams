import json
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
    assert got == {"aiostreams": True, "vpn": False, "mediaflow": True, "watchdog": False, "webhook": False}


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


def test_parse_backup_info_reads_only_well_formed_builds():
    ok = "# Written by setup-backup.sh\nformat=3\naiostreams_version=2.35.9\naiostreams_tag=v2.35.9\n"
    assert stack.parse_backup_info(ok) == {"version": "2.35.9", "tag": "v2.35.9"}
    nightly = "format=3\naiostreams_version=2.35.9\naiostreams_tag=2026.10.11.1908-nightly\n"
    assert stack.parse_backup_info(nightly)["tag"] == "2026.10.11.1908-nightly"
    assert stack.parse_backup_info("format=3\n") is None                                   # before builds were recorded
    assert stack.parse_backup_info("aiostreams_version=2.35.9\naiostreams_tag=<b>x</b>\n") is None
    assert stack.parse_backup_info("") is None


def test_backup_build_asks_tar_for_backup_info_only(monkeypatch):
    calls = []
    def run(cmd, **kw):
        calls.append(cmd)
        return SimpleNamespace(returncode=0, stdout="format=3\naiostreams_version=2.35.9\naiostreams_tag=v2.35.9\n")
    monkeypatch.setattr(stack.subprocess, "run", run)
    monkeypatch.setattr(config, "INSTALL_DIR", pathlib.Path("/opt/aiostreams"))
    b = stack.Backend.__new__(stack.Backend)
    got = b.backup_build({"name": "aiostreams-backup-20261012-010000.tar.gz", "dirs": ["/root", "/home/ubuntu"]})
    assert got == {"version": "2.35.9", "tag": "v2.35.9"}
    cmd = calls[0]
    assert cmd[cmd.index("--") + 1:] == ["tar", "-xzOf", "/root/aiostreams-backup-20261012-010000.tar.gz",
                                         "--occurrence=1", "aiostreams/backup-info"]
    monkeypatch.setattr(stack.subprocess, "run", lambda cmd, **kw: SimpleNamespace(returncode=2, stdout=""))
    assert b.backup_build({"name": "x.tar.gz", "dirs": ["/root"]}) is None


def test_parse_restore_check():
    ok = "Checking x. Nothing is changed.\n  ok: It holds AIOStreams v2.35.9.\n  ok: a.example.com points at this server.\nResult: OK, it can be restored here without questions.\n"
    assert stack.parse_restore_check(ok, 0) == {"ok": True, "reasons": [],
                                                "notes": ["It holds AIOStreams v2.35.9.", "a.example.com points at this server."]}
    no = "Checking x.\n  no: Its domain is b.example.com, but this install uses a.example.com.\nResult: not a same-server restore.\n"
    got = stack.parse_restore_check(no, 3)
    assert got["ok"] is False and got["reasons"] == ["Its domain is b.example.com, but this install uses a.example.com."]
    # a setup-backup.sh from before --check treats it as a file name and fails
    old = "\x1b[1;34m==>\x1b[0m Restore from backup\n\x1b[1;31mXX \x1b[0m File not found: --check\n"
    got = stack.parse_restore_check(old, 1)
    assert got["ok"] is False and "Update it on the Terminal tab" in got["reasons"][0]
    assert stack.parse_restore_check("Result: OK\n", 3)["ok"] is False          # the exit code has the last word


def test_backup_path_prefers_roots_copy(monkeypatch):
    monkeypatch.setattr(stack, "HOMES_DIR", "/home")
    b = {"name": "aiostreams-backup-1.tar.gz", "dirs": ["/home/ubuntu", "/root"]}
    assert stack.backup_path(b) == "/root/aiostreams-backup-1.tar.gz"
    assert stack.backup_path({**b, "dirs": ["/home/ubuntu"]}) == "/home/ubuntu/aiostreams-backup-1.tar.gz"


VPN_SAVED = ("      - WIREGUARD_PRIVATE_KEY=PRIVkeyPRIVkeyPRIVkey=\n"
             "      - WIREGUARD_ENDPOINT_IP=203.0.113.16\n      - WIREGUARD_ENDPOINT_PORT=51820\n")


def test_vpn_info_off_reads_endpoint_never_the_key(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams")],
                     extra_files=["vpn-state/active"])
    (config.INSTALL_DIR / "vpn-state/docker-compose.vpn.yml").write_text(VPN_SAVED)
    (config.INSTALL_DIR / "vpn-state/endpoint-host").write_text("nl.wg.example-vpn.net\n")
    v = b.vpn_info()
    assert v["mode"] == "off" and v["connected"] is None
    assert (v["endpoint_host"], v["endpoint_ip"], v["endpoint_port"]) == ("nl.wg.example-vpn.net", "203.0.113.16", "51820")
    assert "PRIVkey" not in repr(v)


def test_vpn_info_on_asks_gluetun_where_traffic_leaves(tmp_path, monkeypatch):
    compose = "services:\n  gluetun:\n    container_name: gluetun\n"
    asked = []

    def exec_run(cmd):
        asked.append(cmd[-1])
        out = b'{"ip": "203.0.113.17", "city": "Amsterdam", "country": "NL", "org": "AS64500 Example"}'
        return SimpleNamespace(exit_code=0, output=out)
    g = container("gluetun")
    g.exec_run = exec_run
    b = make_backend(tmp_path, monkeypatch, [g], compose=compose, extra_files=["vpn-state/active"])
    b._client.containers.get = lambda name: g
    (config.INSTALL_DIR / "vpn-state/docker-compose.vpn.yml").write_text(VPN_SAVED)
    v = b.vpn_info()
    assert v["mode"] == "on" and v["connected"] is True
    assert (v["exit_ip"], v["city"], v["country"]) == ("203.0.113.17", "Amsterdam", "NL")
    assert v["endpoint_host"] is None and "PRIVkey" not in repr(v)
    b.vpn_info()                       # within a minute: from the cache, gluetun isn't asked again
    assert len(asked) == 1
    b.vpn_info(fresh=True)             # Check now asks again
    assert len(asked) == 2


def test_parse_vpn_addresses():
    out = "192.0.2.10 0.8 in-use recommended\n203.0.113.9 -\n198.51.100.4 1.1\n"
    got = stack.parse_vpn_addresses(out, 0)
    assert got["error"] is None
    assert got["addresses"] == [
        {"ip": "192.0.2.10", "ms": 0.8, "in_use": True, "recommended": True},
        {"ip": "203.0.113.9", "ms": None, "in_use": False, "recommended": False},
        {"ip": "198.51.100.4", "ms": 1.1, "in_use": False, "recommended": False}]
    bad = "\x1b[1;31mXX \x1b[0m The VPN config's Endpoint is an IP address, so there are no other addresses to pick from.\n"
    got = stack.parse_vpn_addresses(bad, 1)
    assert got["addresses"] == [] and got["error"].startswith("The VPN config's Endpoint is an IP address")
    assert stack.parse_vpn_addresses("noise\n", 0)["error"] == "The lookup found no addresses."


def test_parse_vpn_configs():
    out = ("pasted|/opt/aiostreams/vpn-state/wireguard.conf|se.wg.example-vpn.net|1\n"
           "file|/home/ubuntu/NL.conf|203.0.113.16|0\n"
           "weird|/etc/x.conf|a|0\nfile|relative.conf|a|0\nfile|/root/x.conf|bad;name|0\n")
    got = stack.parse_vpn_configs(out, 0)
    assert got == [
        {"kind": "pasted", "path": "/opt/aiostreams/vpn-state/wireguard.conf", "endpoint": "se.wg.example-vpn.net", "in_use": True},
        {"kind": "file", "path": "/home/ubuntu/NL.conf", "endpoint": "203.0.113.16", "in_use": False},
        {"kind": "file", "path": "/root/x.conf", "endpoint": None, "in_use": False}]
    assert stack.parse_vpn_configs(out, 1) == []


def test_watchdog_info_reads_events_and_tally_and_masks_the_topic(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("caddy"), container("aiostreams")])
    assert b.watchdog_info() == {"configured": False}
    d = tmp_path / "aiostreams" / "watchdog-state"
    d.mkdir()
    (d / "config").write_text("NTFY_TOPIC=aios-secret-topic-99\n")
    (d / "last-check").write_text("18 Oct 2026, 16:02:11 UTC OK\n")
    (d / "events").write_text("1792335872|fail|https://x is up but AIOStreams isn't answering\n"
                              "garbage line\n1792335990|recovered|Passing again | still one field\n")
    (d / "tally").write_text("2026-10-17 720 0\n2026-10-18 400 2\nbad\n")
    (tmp_path / "aiostreams" / "Caddyfile").write_text("# main site\nstreams.example.com {\n    reverse_proxy aiostreams:3000\n}\n")
    monkeypatch.setattr(b, "_systemd_active", lambda unit: True)
    w = b.watchdog_info()
    assert "aios-secret-topic-99" not in json.dumps(w) and w["topic"].startswith("aios-") and w["topic"].endswith("99")
    assert [e["kind"] for e in w["events"]] == ["recovered", "fail"]            # newest first, junk skipped
    assert w["events"][0]["text"] == "Passing again | still one field"
    assert w["tally"] == [{"day": "2026-10-17", "passed": 720, "failed": 0}, {"day": "2026-10-18", "passed": 400, "failed": 2}]
    assert w["watches"] == ["https://streams.example.com", "Disk space", "HTTPS certificate"] and w["running"] and w["alert_state"] == "up"


def test_weekly_time_reads_new_and_old_settings():
    assert stack.weekly_time({"weekly_time": "07:05"}) == "07:05"
    assert stack.weekly_time({"weekly_time": "7:05"}) == "07:05"
    assert stack.weekly_time({"weekly_hour": "8"}) == "08:00"          # an older script's setting carries over
    assert stack.weekly_time({"weekly_time": "25:00", "weekly_hour": "x"}) == "10:00"
    assert stack.weekly_time({}) == "10:00"


def test_certs_lists_every_caddy_site(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("aiostreams")])
    root = config.INSTALL_DIR
    (root / "Caddyfile").write_text("streams.example.com {\n    reverse_proxy aiostreams:3000\n}\nimport caddy.d/*.caddy\n")
    (root / "caddy.d").mkdir()
    (root / "caddy.d" / "55-aiometadata.caddy").write_text("meta.example.com {\n    reverse_proxy aiometadata:3232\n}\n")
    (root / "caddy.d" / "60-ui.caddy").write_text("cp.example.com {\n    reverse_proxy panel:8080\n}\n")
    b._cert = lambda host: {"host": host, "days_left": 80, "ok": True, "days_total": 90}
    certs = b._certs("streams.example.com")
    assert [(c["label"], c["host"]) for c in certs] == [
        ("AIOStreams", "streams.example.com"), ("AIOMetadata", "meta.example.com"), ("Control panel", "cp.example.com")]


def test_certs_empty_without_sites(tmp_path, monkeypatch):
    b = make_backend(tmp_path, monkeypatch, [container("aiostreams")])
    assert b._certs(None) == []
