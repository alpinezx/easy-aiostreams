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
        if args[0] == "rm":
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


def test_remove_refuses_while_set_up(backend, tmp_path):
    (tmp_path / "setup-mediaflow.sh").write_text("#!/bin/bash\n")
    (tmp_path / "mediaflow-state").mkdir()
    (tmp_path / "mediaflow-state" / "config").write_text("x\n")
    with pytest.raises(ValueError):
        backend.remove_script("mediaflow")
    assert (tmp_path / "setup-mediaflow.sh").exists() and backend.ran == []
    with pytest.raises(ValueError):
        backend.remove_script("aiostreams")                      # never the main script
