import os
from types import SimpleNamespace

import pytest

os.environ["UI_DEMO"] = "1"     # as test_app.py: settings are read once, at the first import

from app import config, panelupdate  # noqa: E402


@pytest.fixture(autouse=True)
def fresh(monkeypatch):
    monkeypatch.setattr(panelupdate, "_cache", {"at": 0.0, "latest": None, "error": None, "branch": None})
    monkeypatch.setattr(config, "VERSION", "1.0.0")
    monkeypatch.setattr(config, "UPDATE_BRANCH", "main")


def test_version_file_is_read():
    from pathlib import Path
    text = (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip()
    assert panelupdate.VERSION_RE.fullmatch(text)


def test_newer_compares_numbers_not_text(monkeypatch):
    monkeypatch.setattr(panelupdate, "_fetch", lambda branch: "1.0.10")
    monkeypatch.setattr(config, "VERSION", "1.0.9")
    assert panelupdate.latest()["newer"] is True
    panelupdate._cache.update(at=0.0, latest=None)
    monkeypatch.setattr(panelupdate, "_fetch", lambda branch: "1.0.0")
    monkeypatch.setattr(config, "VERSION", "1.0.1")         # a test build ahead of GitHub
    assert panelupdate.latest()["newer"] is False


def test_checks_its_own_branch_and_starts_over_when_it_changes(monkeypatch):
    asked = []
    monkeypatch.setattr(panelupdate, "_fetch", lambda branch: asked.append(branch) or "1.1.0")
    panelupdate.latest(); panelupdate.latest()
    monkeypatch.setattr(config, "UPDATE_BRANCH", "dev")
    out = panelupdate.latest()
    assert asked == ["main", "dev"] and out["branch"] == "dev" and out["newer"] is True


def test_github_trouble_is_reported(monkeypatch):
    def boom(branch):
        raise RuntimeError("GitHub answered 404.")
    monkeypatch.setattr(panelupdate, "_fetch", boom)
    out = panelupdate.latest()
    assert out["latest"] is None and out["error"] == "GitHub answered 404." and out["newer"] is False


def test_last_update_reads_the_log(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "STATE_DIR", tmp_path)
    assert panelupdate.last_update() is None
    (tmp_path / panelupdate.LOG_NAME).write_text("\x1b[1;34m==>\x1b[0m Downloading\nDownloaded.\nRebuilt. Your login and unlock link are unchanged.\n")
    got = panelupdate.last_update()
    assert got["ok"] is True and got["tail"][0] == "==> Downloading"
    (tmp_path / panelupdate.LOG_NAME).write_text("!!  Couldn't download it. Nothing was changed; the panel keeps running as it is.\n")
    assert panelupdate.last_update()["ok"] is False


def test_start_runs_the_update_outside_the_container(monkeypatch):
    calls = []
    monkeypatch.setattr(panelupdate, "running", lambda: False)
    monkeypatch.setattr(panelupdate.subprocess, "run", lambda cmd, **kw: calls.append(cmd) or SimpleNamespace(returncode=0, stdout="", stderr=""))
    monkeypatch.setattr(config, "UPDATE_BRANCH", "dev")
    panelupdate.start()
    cmd = calls[0]
    assert cmd[:cmd.index("--") + 2] == panelupdate.NSENTER + ["systemd-run"]
    assert "--unit=aios-ui-update" in cmd and "--setenv=AIOS_UI_BRANCH=dev" in cmd
    assert cmd[-1].endswith('setup-ui.sh" update-unattended > "/opt/aiostreams/ui-state/last-update.log" 2>&1')


def test_start_refuses_a_second_update_and_reports_failures(monkeypatch):
    monkeypatch.setattr(panelupdate, "running", lambda: True)
    with pytest.raises(RuntimeError, match="already running"):
        panelupdate.start()
    monkeypatch.setattr(panelupdate, "running", lambda: False)
    monkeypatch.setattr(panelupdate.subprocess, "run",
                        lambda cmd, **kw: SimpleNamespace(returncode=127, stdout="", stderr="nsenter: failed to execute systemd-run: No such file or directory"))
    with pytest.raises(RuntimeError, match="systemd-run isn't available"):
        panelupdate.start()
