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
    monkeypatch.setattr(releases, "_cache", {"at": 0.0, "releases": None, "error": None})


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
    releases._cache["at"] -= releases.FORCE_GAP + 1
    releases.get(force=True)
    assert calls == [1, 1]


def test_rate_limit_is_reported(monkeypatch):
    monkeypatch.setattr(releases.requests, "get", lambda *a, **k: FakeResp({}, status=403))
    out = releases.get()
    assert out["releases"] == [] and "rate limit" in out["error"]


def test_failed_refresh_keeps_the_last_list(monkeypatch):
    monkeypatch.setattr(releases.requests, "get", fake_get([[rel("v2.35.9")]], []))
    releases.get()
    releases._cache["at"] -= releases.FRESH + 1
    def boom(*a, **k):
        raise OSError("no network")
    monkeypatch.setattr(releases.requests, "get", boom)
    out = releases.get()
    assert [r["tag"] for r in out["releases"]] == ["v2.35.9"] and out["error"] == "Couldn't reach GitHub."


def test_non_github_links_are_dropped(monkeypatch):
    bad = {**rel("v2.35.9"), "html_url": "javascript:alert(1)"}
    monkeypatch.setattr(releases.requests, "get", fake_get([[bad]], []))
    assert releases.get()["releases"][0]["url"] is None
