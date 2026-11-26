"""Web server: login, JSON API, server-sent events. No shell access from the
browser, only the allowlisted actions in actions.py."""
from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import audit, auth, config, panelupdate, releases, scriptsync, serverip
from .actions import SCRIPTS, BadAction, build_delete_config, build_restore, build_use_file, resolve
from .proxy import CaddyProxyHeaders
from .stack import BACKUP_NAME, RESTARTABLE, WITH_MAIN, backup_path, note_planned

if config.DEMO:
    from .demo import DemoBackend
    import os
    backend = DemoBackend(os.environ.get("UI_DEMO_SCENARIO", "ok"))
else:
    from .stack import Backend
    backend = Backend()

# Network traffic, read once a minute whether or not the panel is open: the VPN's tunnel
# (from gluetun) and the server's own network card
from .traffic import Traffic

if not config.DEMO:
    releases.CACHE_FILE = config.STATE_DIR / "release-cache.json"
vpn_traffic = Traffic(config.STATE_DIR / "vpn-traffic.json", backend.vpn_counters)
host_traffic = Traffic(config.STATE_DIR / "host-traffic.json", backend.host_counters)
if config.DEMO:
    from .demo import demo_traffic
    for _t, _host in ((vpn_traffic, False), (host_traffic, True)):
        if not _t.hours:
            _t.minutes, _t.hours = demo_traffic(time.time(), _host)
vpn_traffic.start()
host_traffic.start()

# Restarts and scheduled runs for Activity, when Phone alerts isn't there to log them
from .serverlog import ServerLog

serverlog = ServerLog(None, None) if config.DEMO else ServerLog(config.STATE_DIR / "server-events.json", backend.server_facts)
if config.DEMO:
    for _e in backend.demo_server_events():
        serverlog.add(**_e)
serverlog.start()

# And every few seconds while the panel is open, for the speeds "now": the counters as they
# stand, which the page turns into a speed from one status check to the next
_net_cache: tuple[float, dict] | None = None


def net_now() -> dict:
    global _net_cache
    now = time.time()
    if _net_cache is None or now - _net_cache[0] > 2:
        out = {"t": now, "host": None, "vpn": None}
        for k, read in (("host", backend.host_counters), ("vpn", backend.vpn_counters)):
            try:
                out[k] = read()
            except Exception:
                pass
        _net_cache = (now, out)
    return _net_cache[1]

app =FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
lockout = auth.Lockout()
PASSWORD_MAX = 1024
_login_slots = asyncio.Semaphore(2)
COOKIE = "ui_session"
LOGGABLE = {"cloudflared", "caddy", "gluetun", "aiostreams", "mediaflow-proxy-light", "aiometadata", "aiomanager", "aios-ui"}


# ---- security headers + CSRF ------------------------------------------

@app.middleware("http")
async def guard(request: Request, call_next):
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        origin = request.headers.get("origin")
        host = request.headers.get("host", "")
        same = origin is None or origin.split("://", 1)[-1] == host
        if request.headers.get("x-ui-request") != "1" or not same:
            return JSONResponse({"error": "Blocked: request did not come from this page."}, status_code=403)
    resp = await call_next(request)
    resp.headers["Content-Security-Policy"] = (
        "default-src 'none'; script-src 'self'; style-src 'self'; style-src-elem 'self' 'unsafe-inline'; font-src 'self'; "
        "img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Cache-Control"] = "no-store" if request.url.path.startswith("/api") else resp.headers.get("Cache-Control", "no-cache")
    return resp


# Added last, so it runs first: the visitor's address and https, but only when Caddy sends them
app.add_middleware(CaddyProxyHeaders)


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def current_user(request: Request) -> str:
    cfg = auth.load_auth()
    user = auth.read_session(cfg.secret, request.cookies.get(COOKIE)) if cfg else None
    if not user:
        raise HTTPException(401, "Sign in required")
    return user


# ---- pages ---------------------------------------------------------------

def _authed(request: Request) -> bool:
    cfg = auth.load_auth()
    return bool(cfg and auth.read_session(cfg.secret, request.cookies.get(COOKIE)))


@app.get("/", include_in_schema=False)
async def index(request: Request):
    if not _authed(request):
        return RedirectResponse("/login", status_code=302)
    return FileResponse(config.WEB_DIR / "index.html")


@app.get("/login", include_in_schema=False)
async def login_page(request: Request):
    if _authed(request):
        return RedirectResponse("/", status_code=302)
    return FileResponse(config.WEB_DIR / "login.html")


# ---- auth ----------------------------------------------------------------

@app.post("/api/login")
async def login(request: Request, response: Response):
    cfg = auth.load_auth()
    if cfg is None:
        raise HTTPException(503, "Login is not set up yet. Run setup-ui.sh again.")
    ip = client_ip(request)
    try:
        body = await request.json()
        username, password = str(body.get("username", "")), str(body.get("password", ""))
    except Exception:
        raise HTTPException(400, "Bad request")
    wait = lockout.locked_for(ip)
    if wait:
        raise HTTPException(429, f"Too many wrong passwords. Try again in {wait // 60 + 1} minutes.")
    # Counted before the hash, with no await in between, so many tries sent at
    # once can't all slip past the lockout. A right password clears it again.
    lockout.record_fail(ip)
    if len(password) > PASSWORD_MAX or len(username) > PASSWORD_MAX:
        await asyncio.sleep(0.5)
        raise HTTPException(401, "Wrong username or password.")
    # Always run the hash so a wrong username takes as long as a wrong password.
    # A few at a time: each one takes 32 MB, and a small server has little to spare.
    async with _login_slots:
        pw_ok = await asyncio.to_thread(auth.verify_password, password, cfg.pw_hash)
    user_ok = secrets.compare_digest(username.encode(), cfg.user.encode())
    if not (pw_ok and user_ok):
        await asyncio.sleep(0.5)
        raise HTTPException(401, "Wrong username or password.")
    lockout.clear(ip)
    token = auth.make_session(cfg.secret, cfg.user)
    secure = request.url.scheme == "https"
    response.set_cookie(COOKIE, token, max_age=config.SESSION_DAYS * 86400, httponly=True,
                        secure=secure, samesite="lax", path="/")   # lax: tapping a phone alert opens the panel
    return {"ok": True}


@app.post("/api/logout")
async def logout(response: Response):
    response.delete_cookie(COOKIE, path="/")
    return {"ok": True}


@app.get("/api/me")
async def me(user: str = Depends(current_user)):
    # boot: changes each time this process starts, so a page can tell the panel restarted
    return {"user": user, "demo": config.DEMO, "version": config.VERSION, "boot": BOOT_ID}


# ---- status --------------------------------------------------------------

BOOT_ID = uuid.uuid4().hex[:12]
_status_cache: tuple[float, dict] | None = None


@app.get("/api/status")
async def status(user: str = Depends(current_user)):
    global _status_cache
    now = time.time()
    if _status_cache is None or now - _status_cache[0] > 2:
        data = await asyncio.to_thread(backend.status)
        _status_cache = (now, data)
    data = dict(_status_cache[1])
    data["busy"] = jobs.current_id()
    data["net"] = await asyncio.to_thread(net_now)
    return data


@app.get("/api/panel/version")
async def panel_version(force: bool = False, user: str = Depends(current_user)):
    """This panel's version, the newest on its update branch, and how the last update went."""
    if config.DEMO:
        return {**panelupdate.demo_latest(), "running": False, "last": None}
    info = await asyncio.to_thread(panelupdate.latest, force)
    running = await asyncio.to_thread(panelupdate.running)
    return {**info, "running": running, "last": await asyncio.to_thread(panelupdate.last_update)}


@app.get("/api/panel/changelog")
async def panel_changelog(user: str = Depends(current_user)):
    """The project's changelog, with the entries newer than this panel marked."""
    if config.DEMO:
        return panelupdate.demo_changelog()
    return await asyncio.to_thread(panelupdate.changelog)


@app.post("/api/panel/update")
async def panel_update(request: Request, user: str = Depends(current_user)):
    """Downloads the newest panel and rebuilds it, from outside this container."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict) or str(body.get("confirm", "")).strip().lower() != "update":
        raise HTTPException(400, "Type update to confirm.")
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    if config.DEMO:
        return {"ok": True, "demo": True}
    try:
        await asyncio.to_thread(panelupdate.start)
    except RuntimeError as e:
        raise HTTPException(409, str(e))
    audit.log(f"panel update started by {user} from {client_ip(request)}")
    return {"ok": True}


@app.get("/api/scripts/compare")
async def scripts_compare(force: bool = False, user: str = Depends(current_user)):
    """Which of the stack's scripts on this server differ from GitHub's main.
    setup-backup.sh and setup-maintenance.sh are included: the AIOStreams menu row updates them too."""
    files = [f for _, _, f in SCRIPTS] + list(WITH_MAIN)
    if config.DEMO:
        return scriptsync.demo(files)
    return await asyncio.to_thread(scriptsync.compare, config.INSTALL_DIR, files, force)


@app.get("/api/aiometadata-releases")
async def aiometadata_releases(force: bool = False, user: str = Depends(current_user)):
    if config.DEMO:
        return releases.demo("aiometadata")
    return await asyncio.to_thread(releases.get, force, "aiometadata")


@app.get("/api/aiomanager-releases")
async def aiomanager_releases(force: bool = False, user: str = Depends(current_user)):
    if config.DEMO:
        return releases.demo("aiomanager")
    return await asyncio.to_thread(releases.get, force, "aiomanager")


@app.get("/api/mediaflow-releases")
async def mediaflow_releases(force: bool = False, user: str = Depends(current_user)):
    if config.DEMO:
        return releases.demo("mediaflow")
    return await asyncio.to_thread(releases.get, force, "mediaflow")


@app.get("/api/gluetun-releases")
async def gluetun_releases(force: bool = False, user: str = Depends(current_user)):
    if config.DEMO:
        return releases.demo("gluetun")
    return await asyncio.to_thread(releases.get, force, "gluetun")


@app.get("/api/caddy-releases")
async def caddy_releases(force: bool = False, user: str = Depends(current_user)):
    if config.DEMO:
        return releases.demo("caddy")
    return await asyncio.to_thread(releases.get, force, "caddy")


@app.get("/api/cloudflared-releases")
async def cloudflared_releases(force: bool = False, user: str = Depends(current_user)):
    if config.DEMO:
        return releases.demo("cloudflared")
    return await asyncio.to_thread(releases.get, force, "cloudflared")


@app.get("/api/aiostreams-releases")
async def aiostreams_releases(force: bool = False, channel: str = "stable", user: str = Depends(current_user)):
    if channel not in releases.CHANNELS:
        raise HTTPException(400, "channel must be stable or nightly")
    if config.DEMO:
        return releases.demo(channel)
    return await asyncio.to_thread(releases.get, force, channel)


# Lock + note per backup, kept in the panel's own state (so it rides along in backups).
_meta_lock = threading.Lock()
NOTE_MAX = 200


def _meta_path() -> Path:
    return config.STATE_DIR / "backup-meta.json"


def load_meta() -> dict:
    try:
        data = json.loads(_meta_path().read_text())
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_meta(data: dict) -> None:
    tmp = _meta_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(_meta_path())


# The AIOStreams build each backup holds, read out of the tarball once, in the
# background, and kept with the panel's state. Keyed by name and size, so a
# file replaced under the same name is read again.
_builds_lock = threading.Lock()
_builds_busy = False


def _builds_path() -> Path:
    return config.STATE_DIR / "backup-builds.json"


def load_builds() -> dict:
    try:
        data = json.loads(_builds_path().read_text())
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_builds(data: dict) -> None:
    tmp = _builds_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(_builds_path())


def _read_builds(todo: list[dict]) -> None:
    global _builds_busy
    try:
        for b in todo:
            try:
                build = backend.backup_build(b)
            except Exception:
                continue        # not saved, so the next listing tries again
            with _builds_lock:
                cache = load_builds()
                cache[b["name"]] = {"size": b["size"], "build": build}
                try:
                    _save_builds(cache)
                except OSError:
                    pass
    finally:
        with _builds_lock:
            _builds_busy = False


def builds_for(items: list[dict]) -> tuple[dict, set]:
    """Known builds by name, and the names still being read."""
    global _builds_busy
    with _builds_lock:
        cache = load_builds()
        names = {b["name"] for b in items}
        if set(cache) - names:
            cache = {k: v for k, v in cache.items() if k in names}
            try:
                _save_builds(cache)
            except OSError:
                pass
        todo = [b for b in items if cache.get(b["name"], {}).get("size") != b["size"]]
        if todo and not _builds_busy:
            _builds_busy = True
            threading.Thread(target=_read_builds, args=(todo,), daemon=True).start()
    known = {k: v["build"] for k, v in cache.items() if k not in {b["name"] for b in todo}}
    return known, {b["name"] for b in todo}


@app.get("/api/server-address")
async def server_address(user: str = Depends(current_user)):
    return {"ip": await asyncio.to_thread(serverip.address)}


@app.get("/api/maintenance")
async def maintenance(force: bool = False, user: str = Depends(current_user)):
    """The Maintenance page: what could be freed, system updates, container log limits,
    and how the last maintenance job ended (it may have outlived a panel restart)."""
    return await asyncio.to_thread(backend.maintenance_info, force)


@app.get("/api/watchdog")
async def watchdog(user: str = Depends(current_user)):
    """The Phone alerts page: state, recent events, daily tally. The topic only masked."""
    return await asyncio.to_thread(backend.watchdog_info)


@app.post("/api/watchdog/options")
async def watchdog_option(request: Request, user: str = Depends(current_user)):
    """The Phone alerts page's settings: {"name": "updates"|"reboots"|"scripts"|"backups"|"security"|"weekly", "on": bool},
    or {"name": "weekly_day", "value": 1 (Mon) .. 7 (Sun)}, or {"name": "weekly_time", "value": "HH:MM"}."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    name = body.get("name") if isinstance(body, dict) else None
    value = body.get("on", body.get("value")) if isinstance(body, dict) else None
    try:
        await asyncio.to_thread(backend.set_watchdog_option, name, value)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {name: value}


@app.post("/api/watchdog/events/clear")
async def watchdog_clear_events(user: str = Depends(current_user)):
    """Clear history on the Phone alerts page."""
    try:
        await asyncio.to_thread(backend.clear_watchdog_events, "events")
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"cleared": True}


@app.post("/api/watchdog/events/remove")
async def watchdog_remove_event(request: Request, user: str = Depends(current_user)):
    """One event's bin on the Phone alerts page: {"at": epoch, "kind": "...", "text": "..."} as listed."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    try:
        await asyncio.to_thread(backend.remove_watchdog_event, body.get("at"), body.get("kind"), body.get("text"))
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"removed": True}


@app.get("/api/server-events")
async def server_events(user: str = Depends(current_user)):
    """Restarts and scheduled runs the panel logged itself (without Phone alerts), newest first."""
    return serverlog.events()


@app.post("/api/server-events/remove")
async def server_events_remove(request: Request, user: str = Depends(current_user)):
    """One entry's bin in Activity: {"at": epoch, "kind": "...", "text": "..."} as listed."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict) or type(body.get("at")) is not int or not isinstance(body.get("kind"), str) \
            or not isinstance(body.get("text"), str):
        raise HTTPException(400, "Pick an entry from the list.")
    if not serverlog.remove(body["at"], body["kind"], body["text"]):
        raise HTTPException(404, "That entry isn't there any more. Reload the page.")
    return {"removed": True}


@app.post("/api/server-events/clear")
async def server_events_clear(user: str = Depends(current_user)):
    serverlog.clear()
    return {"cleared": True}


@app.post("/api/watchdog/tally/clear")
async def watchdog_clear_tally(user: str = Depends(current_user)):
    """Reset on the Phone alerts page: the 14-day strip starts again."""
    try:
        await asyncio.to_thread(backend.clear_watchdog_events, "tally")
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"cleared": True}


@app.get("/api/vpn")
async def vpn(fresh: bool = False, user: str = Depends(current_user)):
    """The VPN page: mode, endpoint and, with the tunnel on, where traffic leaves. Never the keys."""
    return await asyncio.to_thread(backend.vpn_info, fresh)


@app.get("/api/vpn/traffic")
async def vpn_traffic_history(user: str = Depends(current_user)):
    """Bytes through the tunnel: each minute of the last day, each hour of the last week."""
    return vpn_traffic.view()


@app.get("/api/host/traffic")
async def host_traffic_history(user: str = Depends(current_user)):
    """The same for the server's own network card."""
    return host_traffic.view()


@app.post("/api/{kind}/traffic/clear")
async def clear_traffic(kind: str, user: str = Depends(current_user)):
    """Clear history, on the Network page (vpn or host): it starts again from now."""
    store = {"vpn": vpn_traffic, "host": host_traffic}.get(kind)
    if store is None:
        raise HTTPException(404, "Not found")
    await asyncio.to_thread(store.clear)
    return {"cleared": True}


@app.get("/api/addons")
async def addons(user: str = Depends(current_user)):
    """The Add-ons page: what each add-on's script shows, its secrets left out."""
    return await asyncio.to_thread(backend.addons_info)


@app.get("/api/addons/{addon}/secret/{name}")
async def addon_secret(addon: str, name: str, user: str = Depends(current_user)):
    """One secret, when the Add-ons page's eye or Copy is pressed. Never kept or logged."""
    value = await asyncio.to_thread(backend.addon_secret, addon, name)
    if not value:
        raise HTTPException(404, "Not found.")
    return JSONResponse({"value": value}, headers={"Cache-Control": "no-store"})


@app.post("/api/vpn/config")
async def vpn_config(request: Request, user: str = Depends(current_user)):
    """Checks a pasted WireGuard config and keeps it, readable only by root, for
    Change config. Sends back the endpoint and address, never the keys."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    conf = body.get("conf") if isinstance(body, dict) else None
    if not isinstance(conf, str) or not conf.strip() or len(conf) > 8192:
        raise HTTPException(400, "Paste the whole WireGuard config.")
    try:
        return await asyncio.to_thread(backend.vpn_stage_config, conf)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.get("/api/vpn/config/addresses")
async def vpn_config_addresses(user: str = Depends(current_user)):
    """The addresses the staged config's endpoint name has, fastest first."""
    return await asyncio.to_thread(backend.vpn_staged_addresses)


@app.post("/api/scripts/{script_id}/remove")
async def remove_script(script_id: str, user: str = Depends(current_user)):
    """Deletes an add-on's script once the add-on isn't set up."""
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    try:
        name = await asyncio.to_thread(backend.remove_script, script_id)
    except ValueError as e:
        raise HTTPException(400, str(e))
    global _status_cache
    _status_cache = None
    return {"removed": name}


@app.post("/api/scripts/{script_id}/update")
async def update_script(script_id: str, user: str = Depends(current_user)):
    """Replaces a script with GitHub's main copy (verified), on the host."""
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    try:
        res = await asyncio.to_thread(backend.update_script, script_id)
    except ValueError as e:
        raise HTTPException(400, str(e))
    global _status_cache
    _status_cache = None
    return res


@app.get("/api/vpn/configs")
async def vpn_configs(user: str = Depends(current_user)):
    """The WireGuard configs on the server: where, which endpoint, which is in use. Never the keys."""
    return await asyncio.to_thread(backend.vpn_configs)


@app.get("/api/vpn/configs/addresses")
async def vpn_config_file_addresses(path: str, user: str = Depends(current_user)):
    """The addresses a listed config's endpoint name has, fastest first, for its Use button."""
    found = next((c for c in await asyncio.to_thread(backend.vpn_configs) if c["path"] == path), None)
    if not found or not found["endpoint"]:
        raise HTTPException(400, "That config isn't on the list any more. Reload the page.")
    return await asyncio.to_thread(backend.vpn_host_addresses, found["endpoint"])


@app.get("/api/vpn/addresses")
async def vpn_addresses(user: str = Depends(current_user)):
    """The addresses the VPN config's server name has, fastest first, for Change server."""
    return await asyncio.to_thread(backend.vpn_addresses)


@app.get("/api/backups")
async def backups(user: str = Depends(current_user)):
    items = await asyncio.to_thread(backend.backups)
    meta = load_meta()
    known, pending = builds_for(items)
    return [{**b, "locked": bool(meta.get(b["name"], {}).get("locked")),
             "note": str(meta.get(b["name"], {}).get("note", "")),
             "build": known.get(b["name"]), "build_pending": b["name"] in pending} for b in items]


# Which Overview cards show, and in what order; and the same for the rail's pages (Overview
# always first, so not among them). One layout each for the install, kept with the panel's
# state (so phone and desktop match, and a restore brings it back).
# The default order: the request flow, This server, AIOStreams, the add-ons' cards, then the services
OVERVIEW_CARDS = ["flow", "warn", "server", "aiostreams", "aiometadata", "aiomanager", "mediaflow", "vpn", "alerts", "services"]
# The rail's default: everyday pages, upkeep, Add-ons with each add-on's own page under it, then tools
RAIL_PAGES = ["logs", "activity", "net", "backups", "maint", "addons", "vpn", "alerts", "scripts"]
LAYOUTS = {"overview": (OVERVIEW_CARDS, "overview-layout.json"), "rail": (RAIL_PAGES, "rail-layout.json")}
_layout_lock = threading.Lock()


def _layout_path(kind: str = "overview") -> Path:
    return config.STATE_DIR / LAYOUTS[kind][1]


def normal_layout(cards, known=OVERVIEW_CARDS) -> list[dict]:
    """Known items once each, in the order given; any left out (one added in a later
    panel) go back where they sit by default, shown."""
    out, seen = [], set()
    for c in cards if isinstance(cards, list) else []:
        if isinstance(c, dict) and c.get("id") in known and c["id"] not in seen:
            seen.add(c["id"])
            out.append({"id": c["id"], "show": c.get("show") is not False})
    for i, cid in enumerate(known):
        if cid not in seen:
            before = set(known[:i])
            at = max((n + 1 for n, c in enumerate(out) if c["id"] in before), default=0)
            out.insert(at, {"id": cid, "show": True})
    return out


def load_layout(kind: str = "overview") -> list[dict]:
    known = LAYOUTS[kind][0]
    try:
        return normal_layout(json.loads(_layout_path(kind).read_text()).get("cards"), known)
    except Exception:
        return normal_layout([], known)


async def _save_layout(kind: str, request: Request) -> dict:
    try:
        body = await request.json()
    except Exception:
        body = None
    if not isinstance(body, dict) or not isinstance(body.get("cards"), list):
        raise HTTPException(400, "Bad request")
    cards = normal_layout(body["cards"], LAYOUTS[kind][0])
    with _layout_lock:
        tmp = _layout_path(kind).with_suffix(".tmp")
        try:
            tmp.write_text(json.dumps({"cards": cards}))
            tmp.replace(_layout_path(kind))
        except OSError:
            raise HTTPException(500, "Couldn't save the layout.")
    return {"cards": cards}


@app.get("/api/overview-layout")
async def overview_layout(user: str = Depends(current_user)):
    return {"cards": load_layout()}


@app.put("/api/overview-layout")
async def set_overview_layout(request: Request, user: str = Depends(current_user)):
    """{"cards": [{"id": "flow", "show": true}, ...]}; {"cards": []} puts the default back."""
    return await _save_layout("overview", request)


@app.get("/api/rail-layout")
async def rail_layout(user: str = Depends(current_user)):
    return {"cards": load_layout("rail")}


@app.put("/api/rail-layout")
async def set_rail_layout(request: Request, user: str = Depends(current_user)):
    """The rail's pages, as the Overview's cards: {"cards": [{"id": "logs", "show": true}, ...]}."""
    return await _save_layout("rail", request)


@app.get("/api/backup-schedule")
async def backup_schedule(user: str = Depends(current_user)):
    """Scheduled backups: off, daily or weekly, and how the last run went."""
    return await asyncio.to_thread(backend.backup_schedule)


@app.put("/api/backup-schedule")
async def set_backup_schedule(request: Request, user: str = Depends(current_user)):
    """{"every": "off"} or {"every": "daily", "time": "HH:MM"} or {"every": "weekly", "day": 1-7, "time": "HH:MM"}."""
    try:
        body = await request.json()
    except Exception:
        body = None
    if not isinstance(body, dict):
        raise HTTPException(400, "Bad request")
    try:
        return await asyncio.to_thread(backend.set_backup_schedule, body.get("every"), body.get("day"), body.get("time"))
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.get("/api/restart-schedule")
async def restart_schedule(user: str = Depends(current_user)):
    """Maintenance's Scheduled server reboot: when, how the last one went, the clock and time zone."""
    return await asyncio.to_thread(backend.restart_schedule)


@app.put("/api/restart-schedule")
async def set_restart_schedule(request: Request, user: str = Depends(current_user)):
    """{"mode": "off"} or {"mode": "needed"|"always", "every": "daily"|"weekly", "day": 1-7, "time": "HH:MM"}."""
    body = await _json_body(request)
    try:
        return await asyncio.to_thread(backend.set_restart_schedule, body.get("mode"), body.get("every"),
                                       body.get("day"), body.get("time"))
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.get("/api/proxies")
async def proxies(force: bool = False, user: str = Depends(current_user)):
    """Maintenance's Caddy and Cloudflare card: versions, the newest releases (force asks GitHub again)."""
    return await asyncio.to_thread(backend.proxies_info, force)


@app.put("/api/auto-updates")
async def set_auto_updates(request: Request, user: str = Depends(current_user)):
    """{"mode": "off" | "monthly"}: whether Caddy and cloudflared update by themselves."""
    body = await _json_body(request)
    try:
        got = await asyncio.to_thread(backend.set_auto_updates, body.get("mode"))
    except ValueError as e:
        raise HTTPException(400, str(e))
    audit.log(f"automatic updates for Caddy and the tunnel set to {body.get('mode')} by {user} from {client_ip(request)}")
    return got


@app.get("/api/server/timezones")
async def server_timezones(user: str = Depends(current_user)):
    return await asyncio.to_thread(backend.timezones)


@app.put("/api/server/timezone")
async def server_timezone(request: Request, user: str = Depends(current_user)):
    """{"timezone": "Europe/London"}. Scheduled times then follow the new zone."""
    body = await _json_body(request)
    try:
        tz = await asyncio.to_thread(backend.set_timezone, body.get("timezone"))
    except ValueError as e:
        raise HTTPException(400, str(e))
    audit.log(f"time zone set to {tz} by {user} from {client_ip(request)}")
    return {"timezone": tz}


@app.post("/api/server/ntp")
async def server_ntp(request: Request, user: str = Depends(current_user)):
    """Switches on the server's own time sync; installs nothing."""
    try:
        return await asyncio.to_thread(backend.ntp_on)
    except ValueError as e:
        raise HTTPException(400, str(e))


async def _json_body(request: Request) -> dict:
    try:
        body = await request.json()
    except Exception:
        body = None
    if not isinstance(body, dict):
        raise HTTPException(400, "Bad request")
    return body


@app.get("/api/set-asides")
async def set_asides(user: str = Depends(current_user)):
    return await asyncio.to_thread(backend.set_asides)


@app.delete("/api/set-asides/{name}")
async def delete_set_aside(name: str, request: Request, user: str = Depends(current_user)):
    try:
        await asyncio.to_thread(backend.delete_set_aside, name)
    except ValueError:
        raise HTTPException(400, "Not a set-aside folder.")
    except FileNotFoundError:
        raise HTTPException(404, "That folder isn't on the server any more.")
    except Exception:
        raise HTTPException(500, "Couldn't delete it.")
    # The rollback copy can't come back either, so Activity and the panel's own log say so, as for a backup
    ip = client_ip(request)
    audit.log(f"set-aside folder {name} deleted by {user} from {ip}")
    jobs.record("stack.set-aside-delete", "Delete setup from before a restore", [f"==> Deleted {name}", f"From {ip}."])
    return {"ok": True}


async def _backup_item(name: str) -> dict:
    if not BACKUP_NAME.fullmatch(name):
        raise HTTPException(400, "Not a backup file name.")
    item = next((b for b in await asyncio.to_thread(backend.backups) if b["name"] == name), None)
    if not item:
        raise HTTPException(404, "That backup isn't on the server any more.")
    return item


@app.get("/api/backups/{name}/restore-check")
async def restore_check(name: str, user: str = Depends(current_user)):
    """Whether this backup restores here without questions. Changes nothing."""
    item = await _backup_item(name)
    return await asyncio.to_thread(backend.restore_check, item)


@app.put("/api/backups/{name}/meta")
async def backup_meta(name: str, request: Request, user: str = Depends(current_user)):
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Bad request")
    if not isinstance(body, dict):
        raise HTTPException(400, "Bad request")
    items = await asyncio.to_thread(backend.backups)
    if name not in {b["name"] for b in items}:
        raise HTTPException(404, "That backup isn't on the server any more.")
    with _meta_lock:
        meta = load_meta()
        cur = meta.get(name, {})
        if "locked" in body:
            cur["locked"] = bool(body["locked"])
        if "note" in body:
            cur["note"] = str(body["note"]).strip()[:NOTE_MAX]
        if cur.get("locked") or cur.get("note"):
            meta[name] = cur
        else:
            meta.pop(name, None)
        # forget entries for backups that no longer exist
        names = {b["name"] for b in items}
        meta = {k: v for k, v in meta.items() if k in names}
        try:
            save_meta(meta)
        except OSError:
            raise HTTPException(500, "Couldn't save that.")
    return {"locked": bool(cur.get("locked")), "note": cur.get("note", "")}


@app.delete("/api/backups/{name}")
async def delete_backup(name: str, request: Request, user: str = Depends(current_user)):
    if load_meta().get(name, {}).get("locked"):
        raise HTTPException(409, "That backup is locked. Unlock it first.")
    try:
        gone = await asyncio.to_thread(backend.delete_backup, name)
    except ValueError:
        raise HTTPException(400, "Not a backup file name.")
    except FileNotFoundError:
        raise HTTPException(404, "That backup isn't on the server any more.")
    except Exception:
        raise HTTPException(500, "Couldn't delete it.")
    with _meta_lock:
        meta = load_meta()
        if meta.pop(name, None) is not None:
            try:
                save_meta(meta)
            except OSError:
                pass
    # It can't be undone, so Activity and the panel's own log say which one went, when, and from where
    ip = client_ip(request)
    audit.log(f"backup {name} deleted by {user} from {ip}")
    jobs.record("stack.backup-delete", "Delete backup",
                [f"==> Deleted {name}", *(f"Removed from {d}" for d in gone), f"From {ip}."])
    return {"ok": True, "deleted_from": gone}


# ---- streaming helper ----------------------------------------------------

def sse(obj) -> bytes:
    return f"data: {json.dumps(obj)}\n\n".encode()


@app.get("/api/logs/{container}")
async def logs(container: str, request: Request, tail: int = 200, user: str = Depends(current_user)):
    if container not in LOGGABLE:
        raise HTTPException(404, "Unknown container")
    tail = max(0, min(tail, 1000))
    loop = asyncio.get_running_loop()
    q: asyncio.Queue = asyncio.Queue(maxsize=5000)
    holder: dict = {}
    stop = threading.Event()

    def put(item):
        try:
            q.put_nowait(item)
        except asyncio.QueueFull:
            pass

    def worker():
        try:
            stream = backend.log_stream(container, tail)
            holder["s"] = stream
            for line in stream:
                if stop.is_set():
                    break
                loop.call_soon_threadsafe(put, line)
        except Exception as e:  # container missing, docker down...
            loop.call_soon_threadsafe(put, {"error": f"Can't read logs: {type(e).__name__}"})
        finally:
            loop.call_soon_threadsafe(put, None)

    threading.Thread(target=worker, daemon=True).start()

    async def gen():
        try:
            # Send something at once. A proxy in front (Caddy) can hold the response
            # headers back until the first bytes arrive, which on a quiet log means
            # the page sits on "Connecting" until the first keep-alive.
            yield b": connected\n\n"
            idle = 0
            while True:
                try:
                    item = await asyncio.wait_for(q.get(), timeout=1)
                    idle = 0
                except asyncio.TimeoutError:
                    # Notice a closed tab within a second, so Docker's own log
                    # follower is released promptly instead of lingering.
                    if await request.is_disconnected():
                        break
                    idle += 1
                    if idle >= 15:
                        idle = 0
                        yield b": keep-alive\n\n"
                    continue
                if item is None:
                    yield sse({"end": True})
                    break
                yield sse(item if isinstance(item, dict) else {"l": item})
        finally:
            stop.set()
            s = holder.get("s")
            if s:
                s.close()

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})


_warn_cache: dict = {"at": 0.0, "data": None}


# The services the card reads (its cog), one choice per install like the layouts.
# The panel, Caddy, the tunnel and the VPN start on; AIOStreams and the add-ons start off.
# A new add-on's first-run warnings (keys not entered yet) are mostly harmless, and
# AIOStreams' own dashboard has the same Recent log alerts, so each is shown only
# once switched on.
WARN_OFF_BY_DEFAULT = {"aiostreams", "mediaflow-proxy-light", "aiometadata", "aiomanager"}


def _warn_hidden_path() -> Path:
    return config.STATE_DIR / "warn-hidden.json"


def _warn_choices() -> dict[str, bool]:
    """Each service's saved switch; services never saved are left out (their default applies)."""
    try:
        saved = json.loads(_warn_hidden_path().read_text())
    except Exception:
        return {}
    out = {}
    for key, on in (("hidden", False), ("shown", True)):
        if isinstance(saved.get(key), list):
            out.update({c: on for c in saved[key] if c in LOGGABLE})
    return out


def load_warn_hidden() -> list[str]:
    choices = _warn_choices()
    return sorted(c for c in LOGGABLE if not choices.get(c, c not in WARN_OFF_BY_DEFAULT))


# While the panel's own action runs (Restart stack, Update, a VPN switch, a backup...) and for a
# minute after, services complain about each other being away: the tunnel can't reach Caddy, Caddy
# can't reach AIOStreams. Expected then, so the card leaves those lines out. The Logs page keeps them,
# and the same lines at any other time (nothing of the panel's running) still show.
JOB_GRACE = 60


BOOT_GRACE = 180   # after the server boots, while Caddy is up before AIOStreams and the VPN


def _boot_time() -> float | None:
    """When the server booted (the kernel's btime, the host's own even inside the container)."""
    try:
        for line in Path("/proc/stat").read_text().splitlines():
            if line.startswith("btime "):
                return float(line.split()[1])
    except (OSError, ValueError):
        pass
    return None


def _job_windows() -> list[tuple[float, float]]:
    """Times when Caddy's and the tunnel's lines stay off Recent warnings: each panel action and
    a minute after it, and the first minutes after the server boots, when services start in turn."""
    now = time.time()
    with jobs.lock:
        runs = [(j["started"], j["ended"] or now) for j in jobs.items.values() if j.get("started")]
        runs += [(a, b) for a, b in jobs.spans]
    out = [(a - 5, b + JOB_GRACE) for a, b in runs]
    boot = _boot_time()
    if boot:
        out.append((boot, boot + BOOT_GRACE))
    return out


def _line_time(line: str) -> float | None:
    """Docker's timestamp at the start of a line ("2026-11-12T18:10:36.123456789Z ..."), as epoch seconds."""
    try:
        return datetime.strptime(line[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


# Only these complain while what sits behind them restarts, so only their lines are held back
# in those windows. Every other service (AIOStreams' debrid and scraper checks at start-up,
# the VPN failing to connect) always reaches the card.
QUIET_WINDOW_SERVICES = {"caddy", "cloudflared"}


def outside_jobs(services: list[dict], windows: list[tuple[float, float]]) -> list[dict]:
    def keep(line):
        t = _line_time(line)
        return t is None or not any(a <= t <= b for a, b in windows)
    return [{**s, "lines": [ln for ln in s["lines"] if keep(ln)]} if s.get("container") in QUIET_WINDOW_SERVICES else s
            for s in services]


# Lines a service writes only because it was just paused (a backup) or started, and so stay off
# the card for a minute after a backup or that service's own start. Node add-ons (AIOMetadata) see
# the pause as their event loop stalling for as long as it lasted. The Logs page keeps them, and
# the same line at any other time still shows: a real stall is worth a look.
RESUME_QUIET = [re.compile(r"\bEvent loop stalled for \d+ ?ms\b")]
RESUME_GRACE = 60
# The same for a container's own start only, not a backup. Caddy recreated by any script comes
# back without the panel's network, and can't find the panel until the panel connects it again
# (Backend.keep_caddy_connected, a second or so later). Any other time the line still shows.
START_QUIET = {"caddy": [re.compile(r"\blookup aios-ui\b")]}


def after_resumes(services: list[dict], resumes: dict[str, list[float]]) -> list[dict]:
    """resumes (Backend.resumes): a container's own starts under its name, and backups
    (every container) under "*"."""
    def near(t, times):
        return any(a - 5 <= t <= a + RESUME_GRACE for a in times)

    def keep(cname, line):
        own = any(r.search(line) for r in START_QUIET.get(cname, ()))
        if not own and not any(r.search(line) for r in RESUME_QUIET):
            return True
        t = _line_time(line)
        if t is None:
            return True
        if own:
            return not near(t, resumes.get(cname, ()))
        return not near(t, [*resumes.get("*", ()), *resumes.get(cname, ())])
    return [{**s, "lines": [ln for ln in s["lines"] if keep(s.get("container"), ln)]} for s in services]


def _warn_data(loggable) -> tuple[list[dict], dict[str, list[float]]]:
    return backend.log_warnings(loggable), backend.resumes()


@app.get("/api/log-warnings")
async def log_warnings(user: str = Depends(current_user)):
    """The Overview's Recent log alerts: each running service's lines of the last day
    that may be warnings or errors, less those logged during the panel's own actions or
    right after a backup's pause. The browser sorts them with the Logs page's rules."""
    hidden = load_warn_hidden()
    if _warn_cache["data"] is None or time.time() - _warn_cache["at"] > 30:
        _warn_cache["data"] = await asyncio.to_thread(_warn_data, LOGGABLE - set(hidden))
        _warn_cache["at"] = time.time()
    data, resumes = _warn_cache["data"]
    return {"services": after_clear(outside_jobs(after_resumes(data, resumes), _job_windows()), _warn_cleared_at()),
            "hidden": hidden}


# The card's own bin: lines up to then leave the card on every device. Docker's logs and
# the Logs page keep them (its own bin is the one that hides lines there).
def _warn_cleared_path() -> Path:
    return config.STATE_DIR / "warn-cleared.json"


def _warn_cleared_at() -> float:
    try:
        return float(json.loads(_warn_cleared_path().read_text()).get("at") or 0)
    except Exception:
        return 0.0


def after_clear(services: list[dict], at: float) -> list[dict]:
    if not at:
        return services
    def keep(line):
        t = _line_time(line)
        return t is None or t > at
    return [{**s, "lines": [ln for ln in s["lines"] if keep(ln)]} for s in services]


@app.post("/api/log-warnings/clear")
async def clear_warnings(user: str = Depends(current_user)):
    try:
        tmp = _warn_cleared_path().with_suffix(".tmp")
        tmp.write_text(json.dumps({"at": time.time()}))
        tmp.replace(_warn_cleared_path())
    except OSError:
        raise HTTPException(500, "Couldn't save that.")
    return {"ok": True}


@app.put("/api/log-warnings/hidden")
async def set_warn_hidden(request: Request, user: str = Depends(current_user)):
    """{"hidden": ["caddy", ...], "shown": ["aiometadata", ...]}: the switches the cog showed,
    off and on. Services not named (not set up here) keep their saved choice or default."""
    try:
        body = await request.json()
    except Exception:
        body = None
    if (not isinstance(body, dict) or not isinstance(body.get("hidden"), list)
            or not isinstance(body.get("shown", []), list)):
        raise HTTPException(400, "Bad request")
    choices = _warn_choices()
    choices.update({c: True for c in body.get("shown", []) if c in LOGGABLE})
    choices.update({c: False for c in body["hidden"] if c in LOGGABLE})
    try:
        tmp = _warn_hidden_path().with_suffix(".tmp")
        tmp.write_text(json.dumps({"hidden": sorted(c for c, on in choices.items() if not on),
                                   "shown": sorted(c for c, on in choices.items() if on)}))
        tmp.replace(_warn_hidden_path())
    except OSError:
        raise HTTPException(500, "Couldn't save that.")
    _warn_cache["data"] = None
    return {"hidden": load_warn_hidden()}


@app.post("/api/logs/clear-all")
async def clear_all_logs(user: str = Depends(current_user)):
    """The bin's All logs: every service's log, the ones not installed here skipped."""
    done = []
    for c in sorted(LOGGABLE):
        try:
            await asyncio.to_thread(backend.clear_logs, c)
            done.append(c)
        except Exception:
            pass                       # not on this server
    _warn_cache["data"] = None
    return {"ok": True, "cleared": done}


@app.post("/api/logs/{container}/clear")
async def clear_logs(container: str, user: str = Depends(current_user)):
    if container not in LOGGABLE:
        raise HTTPException(404, "Unknown container")
    try:
        how = await asyncio.to_thread(backend.clear_logs, container)
        _warn_cache["data"] = None
    except Exception:
        raise HTTPException(500, "Couldn't clear that log.")
    return {"ok": True, "how": how}


# ---- jobs ----------------------------------------------------------------

def classify(line: str) -> str:
    s = line.lstrip()
    if s.startswith("XX"):
        return "error"
    if s.startswith("!!"):
        return "warn"
    if s.startswith("==>"):
        return "info"
    return "out"


class Jobs:
    MAX_LINES = 3000
    KEEP = 40

    def __init__(self):
        self.lock = threading.Lock()
        self.items: dict[str, dict] = {}
        self.order: list[str] = []
        # When each action ran, [started, ended], kept apart from Activity's list: Recent log
        # alerts hides Caddy's and the tunnel's lines from those times, and clearing Activity
        # (or its 40-entry limit) mustn't bring them back
        self.spans: list[list[float]] = []
        self._load()

    def _path(self) -> Path:
        return config.STATE_DIR / "history.json"

    def _spans_path(self) -> Path:
        return config.STATE_DIR / "job-spans.json"

    SPANS_KEEP = 2 * 86400   # the card shows a day of lines

    def _add_span(self, started: float, ended: float) -> None:
        with self.lock:
            cut = time.time() - self.SPANS_KEEP
            self.spans = [s for s in self.spans if s[1] >= cut] + [[started, ended]]
        self._save_spans()

    def _save_spans(self, path: Path | None = None) -> None:
        try:
            with self.lock:
                data = json.dumps(self.spans)
            target = path or self._spans_path()
            tmp = target.with_name(target.name + ".tmp")
            tmp.write_text(data)
            os.replace(tmp, target)
        except Exception:
            pass

    def _load(self):
        try:
            for j in json.loads(self._path().read_text()):
                j["lines"] = j.get("lines", [])
                self.items[j["id"]] = j
                self.order.append(j["id"])
        except Exception:
            pass
        try:
            self.spans = [[float(a), float(b)] for a, b in json.loads(self._spans_path().read_text())]
        except Exception:
            pass

    def _save(self, path: Path | None = None):
        # Snapshot under the lock, write outside it: a temp file, then a rename, so a crash or a
        # full disk mid-write never leaves a half-written history behind.
        try:
            with self.lock:
                done = [self.items[i] for i in self.order if i in self.items and self.items[i]["ended"]][-self.KEEP:]
                slim = [{**j, "lines": j["lines"][-400:]} for j in done]
            target = path or self._path()
            tmp = target.with_name(target.name + ".tmp")
            tmp.write_text(json.dumps(slim))
            os.replace(tmp, target)
        except Exception:
            pass

    def _current_id(self) -> str | None:
        """The running job's id. The caller holds self.lock."""
        for i in reversed(self.order):
            j = self.items.get(i)
            if j and not j["ended"]:
                return i
        return None

    def current_id(self) -> str | None:
        with self.lock:
            return self._current_id()

    def summaries(self) -> list[dict]:
        with self.lock:
            return [self.summary(self.items[i]) for i in reversed(self.order) if i in self.items]

    def start(self, action, params, after=None) -> dict:
        with self.lock:
            if self._current_id():
                raise HTTPException(409, "Another action is still running. Wait for it to finish.")
            job = {"id": uuid.uuid4().hex[:12], "action": action.id, "label": action.label,
                   "running": action.running, "done": action.done, "started": time.time(),
                   "ended": None, "code": None, "lines": []}
            self.items[job["id"]] = job
            self.order.append(job["id"])
            while len(self.order) > self.KEEP + 5:
                old = self.order.pop(0)
                self.items.pop(old, None)
        note_planned()   # services starting during or just after an action: grey "Starting"
        threading.Thread(target=self._run, args=(job, action, after), daemon=True).start()
        return job

    def record(self, action_id: str, label: str, lines: list[str]) -> None:
        """A finished entry for something done straight away, without a script (deleting a
        backup), so Activity still shows it. Never blocks or waits on a running action."""
        now = time.time()
        job = {"id": uuid.uuid4().hex[:12], "action": action_id, "label": label, "running": label, "done": label,
               "started": now, "ended": now, "code": 0, "lines": [{"k": classify(l), "t": l} for l in lines]}
        with self.lock:
            self.items[job["id"]] = job
            self.order.append(job["id"])
            while len(self.order) > self.KEEP + 5:
                old = self.order.pop(0)
                self.items.pop(old, None)
        self._add_span(now, now)
        self._save()

    def _run(self, job, action, after=None):
        def emit(line: str):
            if len(job["lines"]) < self.MAX_LINES:
                job["lines"].append({"k": classify(line), "t": line})
        try:
            code = backend.run(action, emit)
        except Exception as e:
            emit(f"XX Couldn't run this action: {type(e).__name__}: {e}")
            code = 1
        if after:
            try:
                after()
            except Exception:
                pass
        # A restore moves the install folder aside, and this container's folders go with it
        # (a bind mount follows the folder, not its name). So once one succeeds, the panel
        # restarts itself onto the restored install. Not when the backup has no panel.
        restart = False
        if action.id == "stack.restore" and code == 0:
            restart = config.DEMO or (_restored_state() / "config").is_file()
            emit("==> Restarting the control panel in a few seconds, so it uses the restored install." if restart
                 else "==> The backup has no control panel, so this one keeps running as it is.")
        job["panel_restart"] = restart
        job["code"] = code
        job["ended"] = time.time()
        self._add_span(job["started"], job["ended"])
        note_planned()
        global _status_cache
        _status_cache = None  # next poll reflects what the action changed
        self._save()
        if restart and not config.DEMO:
            threading.Thread(target=self._restart_onto_restored, daemon=True).start()

    def _restart_onto_restored(self):
        # The history so far, this restore included, goes into the restored folder too:
        # the copy above went to the folder that was moved aside.
        self._save(_restored_state() / "history.json")
        self._save_spans(_restored_state() / "job-spans.json")
        # And this boot's markers, or the backup's old boot_id would read as a restart
        serverlog.save(_restored_state() / "server-events.json")
        time.sleep(5)          # let the page get the last lines first
        try:
            backend.client.containers.get("aios-ui").restart(timeout=5)
        except Exception:
            pass

    def clear_finished(self) -> int:
        with self.lock:
            drop = [i for i in self.order if self.items[i]["ended"]]
            for i in drop:
                self.items.pop(i, None)
            self.order = [i for i in self.order if i in self.items]
        self._save()
        return len(drop)

    def remove(self, job_id: str) -> None:
        with self.lock:
            j = self.items.get(job_id)
            if not j:
                raise HTTPException(404, "No such job")
            if not j["ended"]:
                raise HTTPException(409, "That action is still running.")
            self.items.pop(job_id)
            self.order.remove(job_id)
        self._save()

    def summary(self, j) -> dict:
        return {k: j[k] for k in ("id", "action", "label", "running", "done", "started", "ended", "code")}


def _restored_state() -> Path:
    """The live install's ui-state as the host sees it (PID 1's root, this container shares
    the host's processes), even when this container's own /state is the folder a restore moved aside."""
    return Path("/proc/1/root") / str(config.INSTALL_DIR).lstrip("/") / "ui-state"


jobs = Jobs()


def host_busy() -> str | None:
    """Why a change to the server has to wait, or None. Besides this panel's own
    action, a panel update and a Maintenance job run on the host, outside this
    container, and carry on through its restarts."""
    if jobs.current_id():
        return "An action is still running. Wait for it to finish first."
    if config.DEMO:
        return None
    if panelupdate.running():
        return "The panel is updating. Wait for it to finish first."
    if backend._maint_running():
        return "A maintenance job is still running. Wait for it to finish first."
    return None


@app.post("/api/actions/{action_id}")
async def run_action(action_id: str, request: Request, user: str = Depends(current_user)):
    try:
        body = await request.json()
    except Exception:
        body = {}
    params = body.get("params") if isinstance(body, dict) else None
    params = params if isinstance(params, dict) else None
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    if action_id in ("vpn.delete", "vpn.file"):
        # Only a config the list has just found, never the one in use
        # (Delete may take the one in use too while the VPN is off; none is left then.)
        path = str((params or {}).get("path", ""))
        vpn_off = await asyncio.to_thread(backend.vpn_mode) == "off"
        found = next((c for c in await asyncio.to_thread(backend.vpn_configs)
                      if c["path"] == path and (not c["in_use"] or (action_id == "vpn.delete" and vpn_off))), None)
        if not found or (action_id == "vpn.file" and found["in_use"]):
            raise HTTPException(400, "That config isn't on the list any more, or it's in use. Reload the page.")
        try:
            action = build_delete_config(path) if action_id == "vpn.delete" else \
                build_use_file(path, (params or {}).get("ip"), (params or {}).get("on") is True)
        except BadAction as e:
            raise HTTPException(400, str(e))
        return jobs.summary(jobs.start(action, params, None))
    if action_id in ("vpn.uninstall", "aiometadata.uninstall", "aiomanager.uninstall", "mediaflow.uninstall", "webhook.uninstall") \
            and str((params or {}).get("confirm", "")).strip().lower() != "uninstall":
        raise HTTPException(400, "Type uninstall to confirm.")
    if action_id == "stack.restore":
        # Same-server only: the script checks again and refuses rather than asks.
        if str((params or {}).get("confirm", "")).strip().lower() != "restore":
            raise HTTPException(400, "Type restore to confirm.")
        # The check's one question, answered in the dialog: start without the VPN that was off
        action = build_restore(backup_path(await _backup_item(str((params or {}).get("name", "")))),
                               without_vpn=bool((params or {}).get("without_vpn")))
    else:
        try:
            action = resolve(action_id, params)
        except BadAction as e:
            raise HTTPException(400, str(e))
    st = await asyncio.to_thread(backend.available_actions) if hasattr(backend, "available_actions") else None
    if st is not None and action.id != "stack.restore" and not next((a["available"] for a in st if a["id"] == action.id), False):
        raise HTTPException(400, "That action isn't set up on this server.")
    after = None
    if action.id == "stack.update" and (params or {}).get("backup", True):
        status_now = _status_cache[1] if _status_cache else await asyncio.to_thread(backend.status)
        before = {b["name"] for b in await asyncio.to_thread(backend.backups)}
        note = update_note(status_now, params or {})
        after = lambda: label_new_backups(before, note)
    job = jobs.start(action, params, after)
    return jobs.summary(job)


def _build_label(st: dict) -> str | None:
    tag = st.get("build_tag") or (f"v{st['version']}" if st.get("version") else None)
    return f"nightly {tag[:-8]}" if tag and tag.endswith("-nightly") else tag


def update_note(st: dict, params: dict) -> str:
    """What the backup an Update makes first was taken before, for its note."""
    label = _build_label(st)
    was = f" (was {label})" if label else ""
    now_ch = "nightly" if st.get("channel") == "nightly" else "stable"
    target = params.get("channel")
    if target and target != st.get("channel"):
        return f"Before switching {now_ch} → {'nightly' if target == 'nightly' else 'stable'}{was}"
    return f"Before updating from {label}" if label else "Before updating"


def label_new_backups(before: set, note: str) -> None:
    """Notes the backups that appeared since `before`, leaving any note already there."""
    new = [b["name"] for b in backend.backups() if b["name"] not in before]
    if not new:
        return
    with _meta_lock:
        meta = load_meta()
        for name in new:
            cur = meta.setdefault(name, {})
            if not cur.get("note"):
                cur["note"] = note[:NOTE_MAX]
        save_meta(meta)


@app.get("/api/jobs")
async def list_jobs(user: str = Depends(current_user)):
    return jobs.summaries()


@app.delete("/api/jobs")
async def clear_jobs(user: str = Depends(current_user)):
    """Forget finished jobs. A job that is still running stays."""
    return {"cleared": jobs.clear_finished()}


@app.get("/api/jobs/{job_id}")
async def get_job(job_id: str, user: str = Depends(current_user)):
    j = jobs.items.get(job_id)
    if not j:
        raise HTTPException(404, "No such job")
    return {**jobs.summary(j), "lines": j["lines"]}


@app.delete("/api/jobs/{job_id}")
async def remove_job(job_id: str, user: str = Depends(current_user)):
    """Forget one finished job and its saved output."""
    jobs.remove(job_id)
    return {"removed": job_id}


@app.get("/api/jobs/{job_id}/stream")
async def stream_job(job_id: str, request: Request, start: int = 0, user: str = Depends(current_user)):
    j = jobs.items.get(job_id)
    if not j:
        raise HTTPException(404, "No such job")

    async def gen():
        i = max(start, 0)
        idle = 0.0
        while True:
            lines = j["lines"]
            while i < len(lines):
                yield sse({"i": i, **lines[i]})
                i += 1
                idle = 0
            if j["ended"] and i >= len(j["lines"]):
                yield sse({"done": True, "code": j["code"], "ended": j["ended"], "restart": bool(j.get("panel_restart"))})
                return
            if await request.is_disconnected():
                return
            await asyncio.sleep(0.3)
            idle += 0.3
            if idle >= 15:
                idle = 0
                yield b": keep-alive\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})


@app.get("/api/server/reboot-needed")
async def server_reboot_needed(user: str = Depends(current_user)):
    """Whether an update is waiting for a restart, for the Reboot button after Install updates,
    and whether apt is still running (busy), so the drawer knows when its answer is final."""
    needed, busy = await asyncio.gather(asyncio.to_thread(backend.reboot_needed), asyncio.to_thread(backend.updates_running))
    return {"needed": needed, "busy": busy}


@app.post("/api/server/reboot")
async def server_reboot(request: Request, user: str = Depends(current_user)):
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict) or str(body.get("confirm", "")).strip().lower() != "reboot":
        raise HTTPException(400, "Type reboot to confirm.")
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    audit.log(f"server reboot requested by {user} from {client_ip(request)}")

    def go():
        time.sleep(2)           # let this response reach the browser first
        try:
            backend.reboot_host()
        except Exception:
            pass
    threading.Thread(target=go, daemon=True).start()
    return {"ok": True}


@app.post("/api/services/{key}/restart")
async def service_restart(key: str, request: Request, user: str = Depends(current_user)):
    """Restart a single container (AIOStreams, MediaFlow, AIOMetadata, AIOManager)."""
    if key not in RESTARTABLE:
        raise HTTPException(404, "That service can't be restarted on its own.")
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    note_planned(key)   # still starting soon after: grey "Starting", not amber
    try:
        name = await asyncio.to_thread(backend.restart_service, key)
    except RuntimeError as e:
        raise HTTPException(409, str(e))
    except Exception as e:
        if e.__class__.__name__ == "NotFound":
            raise HTTPException(404, "That service isn't installed.")
        raise HTTPException(500, "Docker couldn't restart it.")
    audit.log(f"{name} restarted on its own by {user} from {client_ip(request)}")
    return {"ok": True, "name": name}


@app.post("/api/panel/restart")
async def panel_restart(request: Request, user: str = Depends(current_user)):
    """Restarting this container re-resolves its bind mounts, which a restore
    (it moves the install folder aside) leaves pointing at the old folder.
    Refused while an action runs: the action's script would be killed with it."""
    if busy := await asyncio.to_thread(host_busy):
        raise HTTPException(409, busy)
    if config.DEMO:
        return {"ok": True, "demo": True}
    def go():
        time.sleep(1)
        backend.client.containers.get("aios-ui").restart(timeout=5)
    threading.Thread(target=go, daemon=True).start()
    return {"ok": True}


app.mount("/css", StaticFiles(directory=config.WEB_DIR / "css"), name="css")
app.mount("/js", StaticFiles(directory=config.WEB_DIR / "js"), name="js")
app.mount("/fonts", StaticFiles(directory=config.WEB_DIR / "fonts"), name="fonts")


@app.get("/favicon.svg", include_in_schema=False)
async def favicon():
    return FileResponse(config.WEB_DIR / "favicon.svg", media_type="image/svg+xml")
