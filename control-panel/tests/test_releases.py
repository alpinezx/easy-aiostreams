import pytest

from app import releases


class FakeResp:
    def __init__(self, data, status=200, link=""):
        self._data, self.status_code, self.headers = data, status, {"link": link}
        self.ok = status < 400

    def json(self):
        return self._data


def rel(tag, draft=False):
    return {"tag_name": tag, "draft": draft, "published_at": "2026-10-03T12:00:00Z",
            "html_url": f"https://github.com/Viren070/AIOStreams/releases/tag/{tag}"}


@pytest.fixture(autouse=True)
def fresh_cache(monkeypatch):
    monkeypatch.setattr(releases, "_cache", {})


def fake_get(pages, calls):
    def get(url, params, **kw):
        calls.append(params["page"])
        data = pages[params["page"] - 1]
        more = params["page"] < len(pages)
        return FakeResp(data, link='<x>; rel="next"' if more else "")
    return get


def test_keeps_only_stable_tags_across_pages(monkeypatch):
    calls = []
    pages = [[rel("2026.10.10.1200-nightly"), rel("v2.36.0"), rel("desktop-nightly")],
             [rel("v2.35.9"), rel("v2.37.0", draft=True), rel("2026.10.01.0800-nightly")]]
    monkeypatch.setattr(releases.requests, "get", fake_get(pages, calls))
    out = releases.get()
    assert [r["tag"] for r in out["releases"]] == ["v2.36.0", "v2.35.9"]
    assert out["error"] is None and calls == [1, 2]


def test_answer_is_cached_and_force_is_throttled(monkeypatch):
    calls = []
    monkeypatch.setattr(releases.requests, "get", fake_get([[rel("v2.35.9")]], calls))
    releases.get()
    releases.get()
    releases.get(force=True)
    assert calls == [1]
    releases._cache["stable"]["at"] -= releases.FORCE_GAP + 1
    releases.get(force=True)
    assert calls == [1, 1]


def test_rate_limit_is_reported(monkeypatch):
    monkeypatch.setattr(releases.requests, "get", lambda *a, **k: FakeResp({}, status=403))
    out = releases.get()
    assert out["releases"] == [] and "rate limit" in out["error"]


def test_failed_refresh_keeps_the_last_list(monkeypatch):
    monkeypatch.setattr(releases.requests, "get", fake_get([[rel("v2.35.9")]], []))
    releases.get()
    releases._cache["stable"]["at"] -= releases.FRESH + 1
    def boom(*a, **k):
        raise OSError("no network")
    monkeypatch.setattr(releases.requests, "get", boom)
    out = releases.get()
    assert [r["tag"] for r in out["releases"]] == ["v2.35.9"] and out["error"] == "Couldn't reach GitHub."


def test_notes_are_kept_and_capped(monkeypatch):
    big = {**rel("v2.35.9"), "body": "x" * (releases.BODY_MAX + 500)}
    none = {**rel("v2.35.8"), "body": None}
    monkeypatch.setattr(releases.requests, "get", fake_get([[big, none]], []))
    out = releases.get()["releases"]
    assert len(out[0]["body"]) == releases.BODY_MAX and out[1]["body"] == ""


def test_nightly_channel_keeps_only_server_nightlies_newest_first(monkeypatch):
    pages = [[rel("v2.36.0"), rel("2026.10.09.0800-nightly"), rel("desktop-nightly"),
              rel("2026.10.10.1200-nightly"), rel("2026.10.08.2300-nightly", draft=True)]]
    monkeypatch.setattr(releases.requests, "get", fake_get(pages, []))
    out = releases.get(channel="nightly")
    assert [r["tag"] for r in out["releases"]] == ["2026.10.10.1200-nightly", "2026.10.09.0800-nightly"]
    assert out["channel"] == "nightly"


def test_channels_are_cached_separately(monkeypatch):
    calls = []
    pages = [[rel("v2.35.9"), rel("2026.10.10.1200-nightly")]]
    monkeypatch.setattr(releases.requests, "get", fake_get(pages, calls))
    assert releases.get()["releases"][0]["tag"] == "v2.35.9"
    assert releases.get(channel="nightly")["releases"][0]["tag"] == "2026.10.10.1200-nightly"
    releases.get(); releases.get(channel="nightly")
    assert calls == [1, 1]


def test_unknown_channel_is_refused():
    with pytest.raises(ValueError):
        releases.get(channel="dev")


def test_non_github_links_are_dropped(monkeypatch):
    bad = {**rel("v2.35.9"), "html_url": "javascript:alert(1)"}
    monkeypatch.setattr(releases.requests, "get", fake_get([[bad]], []))
    assert releases.get()["releases"][0]["url"] is None
