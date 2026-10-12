import pytest

from app import scriptsync


@pytest.fixture(autouse=True)
def fresh_cache(monkeypatch):
    monkeypatch.setattr(scriptsync, "_cache", {"at": 0.0, "shas": None, "error": None})


def test_blob_sha_matches_git():
    # git hash-object of "hello\n"
    assert scriptsync.blob_sha(b"hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a"


def test_compare_flags_only_real_differences(tmp_path, monkeypatch):
    (tmp_path / "setup-aiostreams.sh").write_bytes(b"same\n")
    (tmp_path / "setup-mediaflow.sh").write_bytes(b"edited here\n")
    (tmp_path / "setup-local-only.sh").write_bytes(b"x\n")
    remote = {"setup-aiostreams.sh": scriptsync.blob_sha(b"same\n"),
              "setup-mediaflow.sh": scriptsync.blob_sha(b"as on github\n")}
    monkeypatch.setattr(scriptsync, "_fetch", lambda: remote)
    out = scriptsync.compare(tmp_path, ["setup-aiostreams.sh", "setup-mediaflow.sh", "setup-webhook.sh", "setup-local-only.sh"])
    f = out["files"]
    assert f["setup-aiostreams.sh"] == {"present": True, "differs": False}
    assert f["setup-mediaflow.sh"] == {"present": True, "differs": True}
    assert f["setup-webhook.sh"] == {"present": False, "differs": None}
    assert f["setup-local-only.sh"] == {"present": True, "differs": None}     # not on GitHub: can't tell
    assert out["error"] is None


def test_github_answer_is_kept_and_force_is_throttled(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(scriptsync, "_fetch", lambda: calls.append(1) or {})
    scriptsync.compare(tmp_path, [])
    scriptsync.compare(tmp_path, [], force=True)
    assert len(calls) == 1
    scriptsync._cache["at"] -= scriptsync.FORCE_GAP + 1
    scriptsync.compare(tmp_path, [], force=True)
    assert len(calls) == 2


def test_local_edit_shows_at_once_without_asking_github_again(tmp_path, monkeypatch):
    p = tmp_path / "setup-aiostreams.sh"
    p.write_bytes(b"v1\n")
    monkeypatch.setattr(scriptsync, "_fetch", lambda: {"setup-aiostreams.sh": scriptsync.blob_sha(b"v2\n")})
    assert scriptsync.compare(tmp_path, ["setup-aiostreams.sh"])["files"]["setup-aiostreams.sh"]["differs"] is True
    p.write_bytes(b"v2\n")      # Update fetched GitHub's
    assert scriptsync.compare(tmp_path, ["setup-aiostreams.sh"])["files"]["setup-aiostreams.sh"]["differs"] is False


def test_github_failure_is_reported_not_guessed(tmp_path, monkeypatch):
    (tmp_path / "setup-aiostreams.sh").write_bytes(b"x\n")
    def boom():
        raise RuntimeError("GitHub's rate limit was reached. Try again in a while.")
    monkeypatch.setattr(scriptsync, "_fetch", boom)
    out = scriptsync.compare(tmp_path, ["setup-aiostreams.sh"])
    assert "rate limit" in out["error"] and out["files"]["setup-aiostreams.sh"]["differs"] is None
