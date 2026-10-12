"""Web server: login, JSON API, server-sent events. No shell access from the
browser, only the allowlisted actions in actions.py."""
from __future__ import annotations

import asyncio
import json
import secrets
import threading
import time
import uuid
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import auth, config, releases, scriptsync, terminal
from .actions import SCRIPTS, BadAction, build_restore, resolve
from .stack import BACKUP_NAME, RESTARTABLE, backup_path

if config.DEMO:
    from .demo import DemoBackend
    import os
    backend = DemoBackend(os.environ.get("UI_DEMO_SCENARIO", "ok"))
else:
    from .stack import Backend
    backend = Backend()

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
lockout = auth.Lockout()
COOKIE = "ui_session"
LOGGABLE = {"caddy", "gluetun", "aiostreams", "mediaflow-proxy-light", "aios-webhook-relay"}


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
    wait = lockout.locked_for(ip)
    if wait:
        raise HTTPException(429, f"Too many wrong passwords. Try again in {wait // 60 + 1} minutes.")
    try:
        body = await request.json()
        username, password = str(body.get("username", "")), str(body.get("password", ""))
    except Exception:
        raise HTTPException(400, "Bad request")
    # Always run the hash so a wrong username takes as long as a wrong password.
    pw_ok = await asyncio.to_thread(auth.verify_password, password, cfg.pw_hash)
    user_ok = secrets.compare_digest(username.encode(), cfg.user.encode())
    if not (pw_ok and user_ok):
        lockout.record_fail(ip)
        await asyncio.sleep(0.5)
        raise HTTPException(401, "Wrong username or password.")
    lockout.clear(ip)
    token = auth.make_session(cfg.secret, cfg.user)
    secure = request.url.scheme == "https"
    response.set_cookie(COOKIE, token, max_age=config.SESSION_DAYS * 86400, httponly=True,
                        secure=secure, samesite="strict", path="/")
    return {"ok": True}


@app.post("/api/logout")
async def logout(response: Response):
    response.delete_cookie(COOKIE, path="/")
    response.delete_cookie(terminal.UNLOCK_COOKIE, path="/api/terminal")
    return {"ok": True}


@app.get("/api/me")
async def me(user: str = Depends(current_user)):
    return {"user": user, "demo": config.DEMO, "terminal": terminal.enabled()}


# ---- status --------------------------------------------------------------

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
    return data


@app.get("/api/scripts/compare")
async def scripts_compare(force: bool = False, user: str = Depends(current_user)):
    """Which of the stack's scripts on this server differ from GitHub's main.
    setup-backup.sh is included: the AIOStreams menu row updates it too."""
    files = [f for _, _, f in SCRIPTS] + ["setup-backup.sh"]
    if config.DEMO:
        return scriptsync.demo(files)
    return await asyncio.to_thread(scriptsync.compare, config.INSTALL_DIR, files, force)


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


@app.get("/api/backups")
async def backups(user: str = Depends(current_user)):
    items = await asyncio.to_thread(backend.backups)
    meta = load_meta()
    known, pending = builds_for(items)
    return [{**b, "locked": bool(meta.get(b["name"], {}).get("locked")),
             "note": str(meta.get(b["name"], {}).get("note", "")),
             "build": known.get(b["name"]), "build_pending": b["name"] in pending} for b in items]


@app.get("/api/set-asides")
async def set_asides(user: str = Depends(current_user)):
    return await asyncio.to_thread(backend.set_asides)


@app.delete("/api/set-asides/{name}")
async def delete_set_aside(name: str, user: str = Depends(current_user)):
    try:
        await asyncio.to_thread(backend.delete_set_aside, name)
    except ValueError:
        raise HTTPException(400, "Not a set-aside folder.")
    except FileNotFoundError:
        raise HTTPException(404, "That folder isn't on the server any more.")
    except Exception:
        raise HTTPException(500, "Couldn't delete it.")
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
async def delete_backup(name: str, user: str = Depends(current_user)):
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


@app.post("/api/logs/{container}/clear")
async def clear_logs(container: str, user: str = Depends(current_user)):
    if container not in LOGGABLE:
        raise HTTPException(404, "Unknown container")
    try:
        how = await asyncio.to_thread(backend.clear_logs, container)
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
        self._load()

    def _path(self) -> Path:
        return config.STATE_DIR / "history.json"

    def _load(self):
        try:
            for j in json.loads(self._path().read_text()):
                j["lines"] = j.get("lines", [])
                self.items[j["id"]] = j
                self.order.append(j["id"])
        except Exception:
            pass

    def _save(self):
        try:
            done = [self.items[i] for i in self.order if self.items[i]["ended"]][-self.KEEP:]
            slim = [{**j, "lines": j["lines"][-400:]} for j in done]
            self._path().write_text(json.dumps(slim))
        except Exception:
            pass

    def current_id(self) -> str | None:
        for i in reversed(self.order):
            if not self.items[i]["ended"]:
                return i
        return None

    def start(self, action, params, after=None) -> dict:
        with self.lock:
            if self.current_id():
                raise HTTPException(409, "Another action is still running. Wait for it to finish.")
            job = {"id": uuid.uuid4().hex[:12], "action": action.id, "label": action.label,
                   "running": action.running, "done": action.done, "started": time.time(),
                   "ended": None, "code": None, "lines": []}
            self.items[job["id"]] = job
            self.order.append(job["id"])
            while len(self.order) > self.KEEP + 5:
                old = self.order.pop(0)
                self.items.pop(old, None)
        threading.Thread(target=self._run, args=(job, action, after), daemon=True).start()
        return job

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
        job["code"] = code
        job["ended"] = time.time()
        global _status_cache
        _status_cache = None  # next poll reflects what the action changed
        self._save()

    def clear_finished(self) -> int:
        with self.lock:
            drop = [i for i in self.order if self.items[i]["ended"]]
            for i in drop:
                self.items.pop(i, None)
            self.order = [i for i in self.order if i in self.items]
        self._save()
        return len(drop)

    def summary(self, j) -> dict:
        return {k: j[k] for k in ("id", "action", "label", "running", "done", "started", "ended", "code")}


jobs = Jobs()


@app.post("/api/actions/{action_id}")
async def run_action(action_id: str, request: Request, user: str = Depends(current_user)):
    try:
        body = await request.json()
    except Exception:
        body = {}
    params = body.get("params") if isinstance(body, dict) else None
    params = params if isinstance(params, dict) else None
    if action_id == "stack.restore":
        # Same-server only: the script checks again and refuses rather than asks.
        if str((params or {}).get("confirm", "")).strip().lower() != "restore":
            raise HTTPException(400, "Type restore to confirm.")
        action = build_restore(backup_path(await _backup_item(str((params or {}).get("name", "")))))
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
    return [jobs.summary(jobs.items[i]) for i in reversed(jobs.order)]


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
                yield sse({"done": True, "code": j["code"], "ended": j["ended"]})
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


# ---- web terminal (only when setup-ui.sh switched it on) -----------------

def _need_terminal():
    if not terminal.enabled():
        raise HTTPException(404, "Not found")


@app.post("/api/terminal/unlock")
async def terminal_unlock(request: Request, user: str = Depends(current_user)):
    _need_terminal()
    ip = client_ip(request)
    wait = terminal.unlock_lockout.locked_for(ip)
    if wait:
        raise HTTPException(429, f"Too many wrong terminal keys. Try again in {wait // 60 + 1} minutes.")
    try:
        payload = await request.json()
        key = str(payload.get("key", ""))
        remember = payload.get("remember") is True
    except Exception:
        raise HTTPException(400, "Bad request")
    ok = await asyncio.to_thread(terminal.check_key, key)
    if not ok:
        terminal.unlock_lockout.record_fail(ip)
        terminal.log(f"bad terminal key from {ip}")
        await asyncio.sleep(1)
        raise HTTPException(403, "Wrong terminal key.")
    terminal.unlock_lockout.clear(ip)
    body = {"ticket": terminal.tickets.issue(user), "idle_minutes": terminal.idle_seconds() // 60}
    resp = JSONResponse(body)
    if remember:
        cfg = auth.load_auth()
        login_token = request.cookies.get(COOKIE, "")
        resp.set_cookie(terminal.UNLOCK_COOKIE, terminal.make_unlock(cfg.secret, user, login_token, config.SESSION_DAYS * 86400),
                        max_age=config.SESSION_DAYS * 86400, httponly=True, secure=request.url.scheme == "https",
                        samesite="strict", path="/api/terminal")
        terminal.log(f"terminal unlocked and remembered for {user} from {ip}")
    return resp


@app.post("/api/terminal/ticket")
async def terminal_ticket(request: Request, user: str = Depends(current_user)):
    """A new ticket without the key, if this browser was left unlocked."""
    _need_terminal()
    cfg = auth.load_auth()
    if not terminal.read_unlock(cfg.secret, request.cookies.get(terminal.UNLOCK_COOKIE), user, request.cookies.get(COOKIE, "")):
        raise HTTPException(403, "Locked")
    return {"ticket": terminal.tickets.issue(user), "idle_minutes": terminal.idle_seconds() // 60}


@app.post("/api/terminal/lock")
async def terminal_lock(response: Response, user: str = Depends(current_user)):
    response.delete_cookie(terminal.UNLOCK_COOKIE, path="/api/terminal")
    return {"ok": True}


@app.websocket("/api/terminal/ws")
async def terminal_ws(ws: WebSocket, ticket: str = "", as_: str = Query("root", alias="as")):
    origin, host = ws.headers.get("origin"), ws.headers.get("host", "")
    # Only root or the detected login user (the one with a ~/aiostreams shortcut). Never an arbitrary name.
    if as_ != "root":
        uc = await asyncio.to_thread(backend.user_copy)
        if not uc or as_ != uc.get("user"):
            as_ = "root"
    cfg = auth.load_auth()
    user = auth.read_session(cfg.secret, ws.cookies.get(COOKIE)) if cfg else None
    if (not terminal.enabled() or not user or not origin
            or origin.split("://", 1)[-1] != host or not terminal.tickets.redeem(ticket, user)):
        await ws.close(code=4403)
        return
    ip = ws.client.host if ws.client else "unknown"
    await ws.accept()
    q: asyncio.Queue = asyncio.Queue()
    # If the browser goes away while the session is still being attached, the
    # attach finishes in its thread anyway; make sure it doesn't stay claimed.
    guard = {"lock": threading.Lock(), "cancelled": False, "got": None}
    loop = asyncio.get_running_loop()

    def do_attach():
        got = terminal.attach(loop, q, user, ip, as_)
        with guard["lock"]:
            guard["got"] = got
            if guard["cancelled"] and got:
                terminal.detach(got[0], q)
        return got

    try:
        got = await asyncio.to_thread(do_attach)
    except asyncio.CancelledError:
        with guard["lock"]:
            guard["cancelled"] = True
            if guard["got"]:
                terminal.detach(guard["got"][0], q)
        raise
    if got is None:
        await ws.send_text(json.dumps({"end": "Another terminal window already has this session open."}))
        await ws.close(code=1000)
        return
    sess, replay, resumed = got
    ended = False

    async def pump():
        nonlocal ended
        if resumed:
            await ws.send_text(json.dumps({"resumed": True}))
            if replay:
                await ws.send_bytes(replay)
        while True:
            item = await q.get()
            if isinstance(item, tuple):
                ended = True
                await ws.send_text(json.dumps({"end": f"Session ended: {item[1]}."}))
                return
            await ws.send_bytes(item)

    async def listen():
        while True:
            msg = json.loads(await ws.receive_text())
            if "i" in msg:
                await asyncio.to_thread(sess.write, str(msg["i"]).encode())
            elif "r" in msg:
                sess.shell.resize(*msg["r"][:2])
            elif msg.get("x"):
                sess.end("ended by you")

    tasks = [asyncio.create_task(pump()), asyncio.create_task(listen())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        if not ended:
            terminal.detach(sess, q)      # shell keeps running; unlock again to come back
        try:
            await asyncio.gather(*tasks, return_exceptions=True)
            await ws.close(code=1000)
        except BaseException:
            pass


@app.post("/api/server/reboot")
async def server_reboot(request: Request, user: str = Depends(current_user)):
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict) or str(body.get("confirm", "")).strip().lower() != "reboot":
        raise HTTPException(400, "Type reboot to confirm.")
    if jobs.current_id():
        raise HTTPException(409, "An action is still running. Wait for it to finish before rebooting.")
    terminal.log(f"server reboot requested by {user} from {client_ip(request)}")

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
    """Restart a single container (AIOStreams, MediaFlow, webhook relay)."""
    if key not in RESTARTABLE:
        raise HTTPException(404, "That service can't be restarted on its own.")
    if jobs.current_id():
        raise HTTPException(409, "An action is still running. Wait for it to finish first.")
    try:
        name = await asyncio.to_thread(backend.restart_service, key)
    except RuntimeError as e:
        raise HTTPException(409, str(e))
    except Exception as e:
        if e.__class__.__name__ == "NotFound":
            raise HTTPException(404, "That service isn't installed.")
        raise HTTPException(500, "Docker couldn't restart it.")
    terminal.log(f"{name} restarted on its own by {user} from {client_ip(request)}")
    return {"ok": True, "name": name}


@app.post("/api/panel/restart")
async def panel_restart(request: Request, user: str = Depends(current_user)):
    """Restarting this container re-resolves its bind mounts, which a restore
    (it moves the install folder aside) leaves pointing at the old folder."""
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
app.mount("/vendor", StaticFiles(directory=config.WEB_DIR / "vendor"), name="vendor")


@app.get("/favicon.svg", include_in_schema=False)
async def favicon():
    return FileResponse(config.WEB_DIR / "favicon.svg", media_type="image/svg+xml")
