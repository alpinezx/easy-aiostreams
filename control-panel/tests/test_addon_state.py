import shutil
from types import SimpleNamespace

import pytest


@pytest.fixture
def backend(tmp_path, monkeypatch):
    """A Backend on a scratch install folder, with the host's rm and rmdir done locally."""
    from app import config, stack
    monkeypatch.setattr(config, "INSTALL_DIR", tmp_path)
    ran = []

    def run(cmd, **kw):
        args = cmd[cmd.index("--") + 1:]
        ran.append(args[0])
        target = tmp_path / args[-1].split("/")[-1]
        if args[0] == "rm" and target.is_dir():
            shutil.rmtree(target)
        elif args[0] == "rm":
            target.unlink(missing_ok=True)
        elif args[0] == "rmdir":
            target.rmdir()          # fails, like rmdir, if anything is in it
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(stack.subprocess, "run", run)
    b = stack.Backend.__new__(stack.Backend)
    b.p = lambda rel: tmp_path / rel
    b.ran = ran
    return b


def test_an_empty_state_folder_is_a_cancelled_setup(backend, tmp_path):
    assert not backend.addon_set_up("mediaflow")                 # no folder
    (tmp_path / "mediaflow-state").mkdir()
    assert not backend.addon_set_up("mediaflow")                 # empty: setup cancelled part-way
    (tmp_path / "mediaflow-state" / "config").write_text("DOMAIN='m.example.com'\n")
    assert backend.addon_set_up("mediaflow")


def test_remove_takes_the_script_and_the_empty_folder(backend, tmp_path):
    (tmp_path / "setup-mediaflow.sh").write_text("#!/bin/bash\n")
    (tmp_path / "mediaflow-state").mkdir()
    assert backend.remove_script("mediaflow") == "setup-mediaflow.sh"
    assert not (tmp_path / "setup-mediaflow.sh").exists()
    assert not (tmp_path / "mediaflow-state").exists()
    assert backend.ran == ["rm", "rmdir"]


def test_a_vpn_setup_stopped_part_way_isnt_set_up_and_can_be_removed(backend, tmp_path):
    (tmp_path / "setup-vpn-gluetun.sh").write_text("#!/bin/bash\n")
    (tmp_path / "docker-compose.yml").write_text("services:\n  aiostreams:\n")
    state = tmp_path / "vpn-state"
    state.mkdir()
    (state / "docker-compose.direct.yml").write_text("x\n")
    (state / "wireguard.conf").write_text("x\n")
    assert not backend.addon_set_up("vpn")
    assert backend.remove_script("vpn") == "setup-vpn-gluetun.sh"
    assert not state.exists() and not (tmp_path / "setup-vpn-gluetun.sh").exists()


def test_a_vpn_thats_set_up_stays_set_up(backend, tmp_path):
    (tmp_path / "setup-vpn-gluetun.sh").write_text("#!/bin/bash\n")
    (tmp_path / "vpn-state").mkdir()
    (tmp_path / "docker-compose.yml").write_text("    container_name: gluetun\n")
    assert backend.addon_set_up("vpn")                           # switched on, marker or not
    (tmp_path / "docker-compose.yml").write_text("services:\n")
    (tmp_path / "vpn-state" / "active").write_text("direct\n")
    assert backend.addon_set_up("vpn")                           # set up, switched off
    with pytest.raises(ValueError):
        backend.remove_script("vpn")
    assert (tmp_path / "vpn-state" / "active").exists() and backend.ran == []


def test_remove_refuses_while_set_up(backend, tmp_path):
    (tmp_path / "setup-mediaflow.sh").write_text("#!/bin/bash\n")
    (tmp_path / "mediaflow-state").mkdir()
    (tmp_path / "mediaflow-state" / "config").write_text("x\n")
    with pytest.raises(ValueError):
        backend.remove_script("mediaflow")
    assert (tmp_path / "setup-mediaflow.sh").exists() and backend.ran == []
    with pytest.raises(ValueError):
        backend.remove_script("aiostreams")                      # never the main script


def test_resumes_read_the_backup_record_and_guess_without_it(backend, tmp_path):
    """Backups' resume times come from setup-backup.sh's backup-resumes. Without that file
    (older scripts) the backup files and the last scheduled run stand in."""
    import time
    now = int(time.time())
    backend._client = SimpleNamespace(containers=SimpleNamespace(list=lambda: []))
    backend.backups = lambda: [{"mtime": now - 600}]
    (tmp_path / "backup-last-run").write_text(f"{now - 300}|ok|aiostreams-backup-scheduled-x.tar.gz, 36MB.\n")
    assert sorted(backend.resumes()["*"]) == [now - 600, now - 300]
    # The record wins, files and last run aside; a day-old line and junk are left out
    (tmp_path / "backup-resumes").write_text(f"{now - 2 * 86400}\nnot-a-time\n{now - 3600}\n{now - 60}\n")
    assert backend.resumes()["*"] == [now - 3600, now - 60]
