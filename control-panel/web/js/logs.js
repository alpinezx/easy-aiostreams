import { $, h, clear, api, toast } from "./util.js";
import { ask } from "./actions.js";

const MAX = 2000;
let current = null, es = null, lines = [], follow = true, filter = "", regex = false, svcs = [];
// Wrap starts off everywhere, until this browser's switch is changed once
let wrap = false;
// Levels picked with the INFO / WARN / ERROR buttons; none picked shows every line.
let levels = new Set();

// Caddy lines that look alarming but are expected. Matched against the raw line.
const NOISE = [
  /aborting with incomplete response.*\/api\/logs\//,        // this page's own live log connection closing
  /aborting with incomplete response.*"error":"[^"]*context canceled"/,   // a browser left a live page (event stream)
  /aborting with incomplete response.*"error":"writing: /,   // the viewer's player or browser hung up mid-transfer (skip, seek, stop)
  /aborting with incomplete response.*"uri":"\/api\/v1\/dashboard\/[^"]*\/stream".*"error":"reading: unexpected EOF"/,   // AIOStreams restarted under an open dashboard page
  /dial tcp [0-9.]+:3000: connect: connection refused.*"uri":"\/api\/v1\/dashboard\/[^"]*\/stream"/,   // an open dashboard page reconnecting while AIOStreams starts
  /exiting; byeee/,                                          // Caddy stopping for a restart
  /shutting down apps, then terminating/,
  /servers shutting down with eternal grace period/,
  /Caddyfile input is not formatted/,                         // whitespace only
  /HTTP\/[23] skipped because it requires TLS/,               // port 80 is plain HTTP by design
  /dial tcp [0-9.]+:8080: connect: connection refused/,      // the panel itself restarting
  /lookup aios-ui on [^ ]+: (server misbehaving|no such host)/,   // the panel container stopped or being rebuilt
];
// AIOStreams cutting a response is only noise next to a stack restart; on its own it means a viewer's stream broke.
const CUT_BY_AIOS = /aborting with incomplete response.*"error":"reading: [^"]*(:3000: read: connection reset by peer|unexpected EOF)"/;
// Tunnel and VPN lines shown in grey, not as errors. cloudflared logs each failure twice: a first half without
// the address, then "Request failed ... dest=<url>".
const QUIET = [
  // gluetun: one DNS query's encrypted connection closed or slow (EOF, a timeout), so it asked again, over
  // another connection or its other provider. Every wording and ending, not one at a time: real DNS trouble
  // shows elsewhere (its health check restarting the VPN, AIOStreams' searches failing), and ERROR lines stay.
  /WARN \[dns\] (exchanging over|renewing|getting) tls connection /,
  /WARN Caught OS signal terminated, shutting down$/,   // gluetun: asked to stop, as a restart or reboot does
  // gluetun: its first health check, a few seconds after it starts (a boot, an update, VPN on), ran before its own
  // DNS was ready, so it restarted the tunnel itself and the next try passed. Only the "startup check" wording:
  // a tunnel that goes unhealthy later says something else ("program has been unhealthy") and stays.
  /WARN \[vpn\] restarting VPN because it failed to pass the healthcheck: startup check: /,
  // gluetun: its start-up release check hit GitHub's hourly limit, common on a shared exit address; the VPN is fine
  /ERROR \[vpn\] cannot get version information: bad response HTTP status code: 403 403 Forbidden$/,
  // cloudflared: told to stop (a restart, update or reboot), it closes its connections to Cloudflare; only said
  // while shutting down. A tunnel that can't reach Cloudflare says something else and stays.
  /Serve tunnel error error="control stream error: Error shutting down control stream: /,
  // cloudflared: back up after a restart or reboot, one connection reached a Cloudflare server that still held
  // its old one, so it moved to another server (both lines of the pair). Other connection failures stay.
  /error="control stream error: already connected to this server, trying another address"/,
  // cloudflared: Cloudflare's side closed one connection with code 0 ("no error"), as its servers restart or
  // rebalance; it's registered again within seconds and the other connections carry on. Other codes stay.
  /error="datagram manager error: Application error 0x0 \(remote\)"/,
  /canceled by remote with error code 0\b/,   // a visitor closed a connection still open (left a live page, stopped a video)
  // The visitor's side gave up before the answer came (a reload, a closed tab, the panel restarting): both halves
  /error="Incoming request ended abruptly: context canceled"/,
  /ERR {2}error="unexpected EOF" .*originService=/,   // a cut connection's first half; its Request failed line says what it was
  // A restart cut a live page: AIOStreams' dashboard, or this panel's own Logs.
  /Request failed error="unexpected EOF" .*dest=https?:\/\/[^/ ]+\/api\/(v1\/dashboard\/[^ ]*\/stream|logs\/[^ ]*) /,
];
const CADDY_STOP = /shutting down apps, then terminating|"msg":"shutdown complete"|exiting; byeee/;
const RESTART_WINDOW = 10;
const CADDY_TS = /"ts":([0-9.]+)/;
let lastStop = -Infinity;
let hideNoise = false;
try {
  hideNoise = localStorage.getItem("aios.hideNoise") === "1";
  const w = localStorage.getItem("aios.logWrap");
  if (w !== null) wrap = w === "1";
  levels = new Set(JSON.parse(localStorage.getItem("aios.logLevels") || "[]"));
} catch (_) {}
const save = (k, v) => { try { localStorage.setItem(k, v); } catch (_) {} };

const ERR = /\b(error|fatal|panic|exception|failed)\b/i;
const WARN = /\bwarn(ing)?\b/i;
// Caddy and AIOStreams write JSON with a "level" field. Trust it over guessing from the words in the line,
// because a warning can carry an "error" field and an info line can mention "failed".
const LEVEL_CLS = { error: "error", fatal: "error", panic: "error", dpanic: "error", critical: "error",
  warn: "warn", warning: "warn", info: "out", debug: "out", trace: "out" };
const LEVEL_NUM = (n) => (n >= 50 ? "error" : n >= 40 ? "warn" : "out");   // pino's numeric levels
const TS = /^(\d{4}-\d\d-\d\dT[\d:.]+)Z?\s(.*)$/s;
// Plain-text lines like "info: [Filter] 73 streams kept"
const PLAIN = /^(trace|debug|info|warn(?:ing)?|error|fatal)\s*:\s*(?:\[([^\]]+)\]\s*)?(.*)$/is;
// The VPN tunnel's (gluetun's) lines: "2026-11-02T18:38:41Z INFO [wireguard] ...", its own time then the level.
// Full-word levels only: cloudflared's INF / ERR keep the word-based guess.
const STAMPED = /^\d{4}-\d\d-\d\dT[\d:.]+Z?\s+(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+(?:\[([^\]]+)\]\s*)?(.*)$/s;
const SKIP = new Set(["level", "time", "ts", "module", "logger", "msg", "message"]);

const fmtVal = (v) => (typeof v === "string" ? v : JSON.stringify(v));

// One log line, split the way AIOStreams' own viewer shows it: time, level, [module] message, then the rest.
function parse(raw) {
  const m = TS.exec(raw);
  let time = "", text = raw;
  if (m) {
    const d = new Date(m[1].slice(0, 23) + "Z");
    if (!isNaN(d)) time = d.toLocaleString([], { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
    text = m[2];
  }
  let cls = null, mod = "", msg = text, extra = "";
  const t = text.trimStart();
  if (t.startsWith("{")) {
    try {
      const j = JSON.parse(t);
      cls = typeof j.level === "number" ? LEVEL_NUM(j.level) : LEVEL_CLS[String(j.level || "").toLowerCase()] || null;
      mod = j.module || j.logger || "";
      msg = j.msg != null ? String(j.msg) : j.message != null ? String(j.message) : "";
      extra = Object.keys(j).filter((k) => !SKIP.has(k)).map((k) => `${k}=${fmtVal(j[k])}`).join(" ");
    } catch (_) {}
  } else {
    const p = PLAIN.exec(t) || STAMPED.exec(t);
    if (p) { cls = LEVEL_CLS[p[1].toLowerCase()] || null; mod = p[2] || ""; msg = p[3]; }
  }
  if (!cls) cls = ERR.test(text) ? "error" : WARN.test(text) ? "warn" : "out";
  const quiet = QUIET.some((r) => r.test(raw));
  if (quiet) cls = "out";
  const ts = Number((CADDY_TS.exec(text) || [])[1]) || NaN;
  const cut = CUT_BY_AIOS.test(raw);
  const noise = quiet || NOISE.some((r) => r.test(raw)) || (cut && ts - lastStop <= RESTART_WINDOW);
  return { raw, noise, time, text, cls, mod, msg, extra, ts, cut, quiet };
}

// A Caddy stop marks AIOStreams cuts just before it as noise. Returns true if any line changed.
function markRestart(stop) {
  lastStop = stop.ts;
  let changed = false;
  for (let i = lines.length - 1; i >= 0 && !(lines[i].ts < stop.ts - RESTART_WINDOW); i--) {
    const l = lines[i];
    if (l.cut && !l.noise) { l.noise = true; changed = true; }
  }
  return changed;
}

// The Overview's Recent log alerts: a log's lines sorted with this page's own rules, so
// the card and Logs always agree on what is a warning, an error or noise. Oldest first, as sent.
// Each comes back with `at` (when Docker got it, in seconds) for the card's "4 min ago".
export function scan(raws) {
  const saved = lastStop;
  lastStop = -Infinity;
  const out = [];
  for (const raw of raws) {
    const l = parse(raw);
    const m = TS.exec(raw);
    l.at = m ? Date.parse(m[1].slice(0, 23) + "Z") / 1000 : NaN;
    if (!isNaN(l.ts) && CADDY_STOP.test(raw)) {
      lastStop = l.ts;
      for (let i = out.length - 1; i >= 0 && !(out[i].ts < l.ts - RESTART_WINDOW); i--) if (out[i].cut) out[i].noise = true;
    }
    out.push(l);
  }
  lastStop = saved;
  return out;
}

const isCaddy = () => current === "caddy";
// Logs with a Hide noise switch: Caddy's, and the Cloudflare Tunnel's and VPN tunnel's grey lines.
const hasNoise = () => isCaddy() || current === "cloudflared" || current === "gluetun";
// The level chips: each line counts as one of INFO, WARN, ERROR or, on those logs, NOISE. With
// none picked every line shows (less the noise, with Hide noise on); NOISE overrides Hide noise.
const noiseChip = () => hasNoise() && levels.has("noise");
const hiddenByToggle = (l) => {
  const noise = hasNoise() && l.noise;
  const picked = noiseChip() || [...levels].some((v) => v !== "noise");
  if (picked) return noise ? !noiseChip() : !levels.has(l.cls);
  return hideNoise && noise;
};

// The filter as a test: plain text (any case), or a regular expression with .* on. A broken pattern matches everything.
let matcher = () => true;
function setMatcher() {
  const box = $("#log-filter");
  box.classList.remove("bad");
  if (!filter) { matcher = () => true; return; }
  if (regex) {
    try { const re = new RegExp(filter, "i"); matcher = (l) => re.test(l.text); }
    catch (_) { box.classList.add("bad"); matcher = () => true; }
  } else {
    const f = filter.toLowerCase();
    matcher = (l) => l.text.toLowerCase().includes(f);
  }
}

const visible = (l) => !hiddenByToggle(l) && matcher(l);

// Phones: the box is sized so that, scrolled down, the filters and the whole box fit on screen
// under the top bar, with no gap below. The filters then stay in reach for scrolling back up.
const PHONE = window.matchMedia("(max-width: 720px)");
function fitBox() {
  const t = $("#log-term");
  if (!PHONE.matches || $("#view-logs").hidden) { t.style.height = ""; snapRows(); return; }
  const screen = window.visualViewport ? window.visualViewport.height : window.innerHeight;
  const bar = $(".topbar").getBoundingClientRect().height;
  const above = t.getBoundingClientRect().top - $(".lg-filters").getBoundingClientRect().top;
  const below = parseFloat(getComputedStyle($("main")).paddingBottom) || 0;
  t.style.height = `${Math.max(240, Math.floor(screen - bar - 12 - above - below))}px`;
  snapRows();
}

// Scrolled to the newest line, the box's height is rarely a whole number of rows, so the top row was cut by
// the edge. Share the left-over height between the rows' padding (about a pixel each) so whole rows fit.
// Not for Wrap, where rows differ in height.
function snapRows() {
  const t = $("#log-term"), keep = follow;
  t.style.removeProperty("--lg-pad");
  const rows = t.querySelectorAll(".lg-ln:not(.open)");   // an opened line is taller: measure a closed one
  if (wrap || rows.length < 3 || !t.clientHeight) return;
  const rowH = rows[1].getBoundingClientRect().height, n = Math.floor(t.clientHeight / rowH);
  if (!(rowH > 0) || n < 1) return;
  t.style.setProperty("--lg-pad", `${7 + (t.clientHeight - n * rowH) / (2 * n)}px`);
  if (keep) t.scrollTop = t.scrollHeight;
}

function syncControls() {
  $("#log-noise-row").hidden = !hasNoise();
  $("#log-help").hidden = !isCaddy();
  $("#log-help-tunnel").hidden = current !== "cloudflared";
  $("#log-help-vpn").hidden = current !== "gluetun";
  $("#log-noise").checked = hideNoise;
  $("#log-noise-chip").hidden = !hasNoise();
  $("#log-noise").disabled = noiseChip();   // set aside while NOISE shows only the noise
  const n = hasNoise() ? lines.filter((l) => l.noise).length : 0;
  $("#log-noise-n").textContent = n ? `(${n})` : "";
  document.querySelectorAll("#view-logs .lg-levels button").forEach((b) => b.setAttribute("aria-pressed", String(levels.has(b.dataset.lv))));
  fitBox();
}

// A JSON line laid out over several lines, for an opened line; null for any other line
function pretty(l) {
  const t = l.text.trimStart();
  if (!t.startsWith("{")) return null;
  try { return JSON.stringify(JSON.parse(t), null, 2); } catch (_) { return null; }
}

// Each row's line, for a tap on it (rows are rebuilt by paint, so a WeakMap lets go of the old ones)
const rowLine = new WeakMap();

function node(l) {
  // Noise (Caddy's expected warnings, the tunnel's closed connections) is grey, whatever its level.
  // An opened line wraps and lays out its JSON, with a copy icon for that one line.
  const json = l.open ? pretty(l) : null;
  const el = h("div", { class: `lg-ln ${l.cls}${l.noise ? " quiet" : ""}${l.open ? " open" : ""}` },
    l.time ? h("time", { class: "lg-time", text: l.time }) : null,
    h("i", { class: "lg-dot", "aria-hidden": "true" }),
    h("span", { class: "lg-msg" },
      l.mod ? h("span", { class: "lg-mod", text: `[${l.mod}] ` }) : null,
      l.msg,
      l.extra && !json ? h("span", { class: "lg-extra", text: ` ${l.extra}` }) : null),
    json ? h("pre", { class: "lg-json", text: json }) : null,
    l.open ? h("button", { class: "lg-cp", type: "button", title: "Copy this line", "aria-label": "Copy this line" },
      $("#log-copy svg").cloneNode(true)) : null);
  rowLine.set(el, l);
  return el;
}

let connected = false;

function paint() {
  const term = $("#log-term"); clear(term);
  term.classList.toggle("wrap", wrap);
  const shown = lines.filter(visible);
  const quiet = isCaddy() ? " Caddy only logs when something happens, like a restart or an error, so quiet is normal." : "";
  const msg = !lines.length ? (connected ? `Connected. Nothing has been logged yet.${quiet}` : "Waiting for log lines…")
    : "No lines match the current filters.";
  if (!shown.length) term.append(h("div", { class: "term-empty", text: msg }));
  else term.append(...shown.map(node));
  snapRows();
  if (follow) term.scrollTop = term.scrollHeight;
  syncJump();   // the button, for the new height
}

// What's on screen (respecting the filters), as the raw lines with full timestamps.
function shownText() {
  const shown = lines.filter(visible);
  return shown.map((l) => l.raw).join("\n") + (shown.length ? "\n" : "");
}

function stamp() {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

const CONN_TEXT = { live: "streaming", retry: "connecting", "": "disconnected" };
function setConn(s, text) { const c = $("#log-conn"); c.dataset.s = s; c.textContent = text || CONN_TEXT[s]; }

function connect() {
  if (es) { es.close(); es = null; }
  lines = []; lastStop = -Infinity; connected = false; paint(); syncControls();
  if (!current) return;
  setConn("retry");
  es = new EventSource(`/api/logs/${encodeURIComponent(current)}?tail=300`);
  es.onopen = () => {
    // The browser reconnects by itself (the panel restarted, say) and the server sends the last 300 lines
    // again: start from those, not after the ones already shown, or each line appears twice.
    if (lines.length) { lines = []; lastStop = -Infinity; syncControls(); }
    setConn("live"); connected = true; paint();
  };
  es.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.end) { setConn("", "container stopped"); es.close(); es = null; return; }
    if (m.error) { setConn("retry", m.error); es.close(); es = null; return; }
    const l = parse(m.l);
    lines.push(l);
    if (lines.length > MAX) lines.splice(0, lines.length - MAX);
    const term = $("#log-term");
    if (!isNaN(l.ts) && CADDY_STOP.test(l.raw) && markRestart(l)) {
      syncControls();
      paint();                         // lines just before the restart turn grey (or hide)
    }
    if (l.noise) syncControls();
    if (visible(l)) {
      if (term.querySelector(".term-empty")) clear(term);
      term.append(node(l));
      while (term.childElementCount > MAX) term.firstChild.remove();
      if (!term.style.getPropertyValue("--lg-pad")) snapRows();   // the first lines arrive after paint: size the rows once
      if (follow) term.scrollTop = term.scrollHeight;
      else if ($("#log-jump").hidden) syncJump();   // paused, and the new lines may now be far enough below
    }
  };
  es.onerror = () => setConn("retry", "reconnecting");
}

function services() {
  const sel = $("#log-svc"); clear(sel);
  svcs.forEach((s) => sel.append(h("option", { value: s.container, text: s.name, selected: s.container === current })));
}

export function show(status, pick) {
  // AIOStreams first (it's the one you read most); the Overview keeps its own order.
  const ORDER = ["aiostreams", "caddy", "gluetun", "mediaflow", "aiometadata", "aiomanager"];
  const rank = (s) => { const i = ORDER.indexOf(s.key); return i < 0 ? ORDER.length : i; };
  svcs = status.services.filter((s) => s.present).sort((a, b) => rank(a) - rank(b));
  const was = current;
  if (pick) current = pick;
  if (!svcs.some((s) => s.container === current)) current = (svcs.find((s) => s.key === "aiostreams") || svcs[0] || {}).container || null;
  services();
  if (!es || current !== was) connect();
  requestAnimationFrame(fitBox);   // the view is shown by now, so it can be measured
}

export function hide() { if (es) { es.close(); es = null; } }

function setFollow(v) { follow = v; $("#log-follow").checked = v; syncJump(); }

// The Jump to latest button: with Auto-scroll off and the newest line more than about 5 lines below. A line or two
// up, or a line opened near the bottom, leaves it hidden, so it isn't in the way of what is being read.
const JUMP_LINES = 5;
// Counts whole lines below the box from the newest up, stopping at the limit, so an opened (tall) line counts as one.
function syncJump() {
  const t = $("#log-term"), jump = $("#log-jump");
  if (follow) { jump.hidden = true; return; }
  const bottom = t.getBoundingClientRect().bottom;
  let below = 0;
  for (let r = t.lastElementChild; r && below < JUMP_LINES && r.getBoundingClientRect().top >= bottom - 1; r = r.previousElementSibling) below++;
  jump.hidden = below < JUMP_LINES;
}

// Tap a line to open it (wrapped, JSON laid out) and again to close it. A drag that selected text leaves it be.
async function onLineClick(e) {
  const row = e.target.closest(".lg-ln"), l = row && rowLine.get(row);
  if (!l) return;
  if (e.target.closest(".lg-cp")) {
    try { await navigator.clipboard.writeText(l.raw); toast("Copied the line."); }
    catch (_) { toast("Couldn't copy the line.", true); }
    return;
  }
  const sel = window.getSelection();
  if (sel && !sel.isCollapsed && row.contains(sel.anchorNode)) return;
  l.open = !l.open;
  holdFollow = l.open ? Date.now() + 400 : 0;   // the browser may scroll to keep what's in view in place as the line grows
  const t = $("#log-term"), fresh = node(l);
  row.replaceWith(fresh);
  if (!l.open) return;
  // Opened, the line holds still while it is read: Auto-scroll pauses (Jump to latest turns it back on),
  // and a line that grew past the box's bottom is scrolled up into view, its top kept in sight
  setFollow(false);
  const box = t.getBoundingClientRect(), r = fresh.getBoundingClientRect();
  const by = Math.min(r.bottom - box.bottom, r.top - box.top);
  if (by > 0) t.scrollTop += by;
}
// Until then, a scroll that lands on the newest line (one the panel made) doesn't switch Auto-scroll back on
let holdFollow = 0;

export function init() {
  $("#log-filter").addEventListener("input", (e) => { filter = e.target.value; setMatcher(); paint(); });
  $("#log-regex").addEventListener("click", (e) => {
    regex = !regex;
    e.currentTarget.setAttribute("aria-pressed", String(regex));
    $("#log-filter").placeholder = regex ? "Regex pattern" : "Filter lines";
    setMatcher(); paint();
  });
  $("#log-svc").addEventListener("change", (e) => { current = e.target.value; connect(); });
  document.querySelectorAll("#view-logs .lg-levels button").forEach((b) => b.addEventListener("click", () => {
    const lv = b.dataset.lv;
    if (levels.has(lv)) levels.delete(lv); else levels.add(lv);
    save("aios.logLevels", JSON.stringify([...levels]));
    syncControls(); paint();
  }));
  $("#log-noise").addEventListener("change", (e) => { hideNoise = e.target.checked; save("aios.hideNoise", hideNoise ? "1" : "0"); paint(); });
  $("#log-wrap").checked = wrap;
  $("#log-wrap").addEventListener("change", (e) => { wrap = e.target.checked; save("aios.logWrap", wrap ? "1" : "0"); paint(); });
  $("#log-follow").addEventListener("change", (e) => { setFollow(e.target.checked); if (follow) { const t = $("#log-term"); t.scrollTop = t.scrollHeight; } });
  $("#log-term").addEventListener("scroll", (e) => {
    const t = e.target, end = t.scrollTop + t.clientHeight >= t.scrollHeight - 24;
    if (end && !follow && Date.now() < holdFollow) { syncJump(); return; }
    setFollow(end);
  });
  $("#log-term").addEventListener("click", onLineClick);
  $("#log-jump").addEventListener("click", () => { const t = $("#log-term"); setFollow(true); t.scrollTop = t.scrollHeight; });
  window.addEventListener("resize", fitBox);
  if (window.visualViewport) window.visualViewport.addEventListener("resize", fitBox);
  // Clear, Copy and .log sit on the level buttons' row of the filter card, which they act on: icons only on a phone,
  // beside the switches (after the rule that tells them apart) on a computer
  const acts = $("#view-logs .lg-acts");
  // On a phone only the bin stays in the row: .log and Copy go into the ⋮ menu (a big text size leaves room for one icon),
  // and the regex switch is dropped (it is switched off if it was on)
  const copyB = $("#log-copy"), dlB = $("#log-download"), dlWord = dlB.querySelector(".lg-word");
  const placeActs = () => {
    if (PHONE.matches) {
      $(".lg-row2").append(acts); $("#log-toggles").append(dlB, copyB); dlWord.textContent = "Save as .log";
      if (regex) $("#log-regex").click();
    } else {
      $("#log-toggles").after(acts); acts.prepend(dlB, copyB); dlWord.textContent = "Save";
    }
    fitBox();
  };
  PHONE.addEventListener("change", placeActs);
  placeActs();
  document.querySelectorAll("#view-logs details.log-help").forEach((d) => d.addEventListener("toggle", fitBox));
  // Phones: Hide noise, Auto-scroll and Wrap sit behind the ⋮ button
  const more = $("#log-more"), tog = $("#log-toggles");
  const openMore = (v) => { tog.classList.toggle("open", v); more.setAttribute("aria-expanded", String(v)); };
  more.addEventListener("click", (e) => { e.stopPropagation(); openMore(!tog.classList.contains("open")); });
  document.addEventListener("click", (e) => { if (!tog.contains(e.target) && !more.contains(e.target)) openMore(false); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") openMore(false); });
  tog.addEventListener("click", (e) => { if (e.target.closest(".btn")) openMore(false); });   // Copy and .log close the menu
  // The bin asks first: this log, or every service's at once
  $("#log-clear").addEventListener("click", async () => {
    if (!current) return;
    const name = (svcs.find((s) => s.container === current) || {}).name || "This log";
    const pick = await ask({ title: "Clear logs?", confirmLabel: name, alt: { label: "All logs", value: "all" },
      body: "Hides everything logged so far, here and on the Overview's Recent warnings. Docker's own log files are kept." });
    if (!pick) return;
    // Close the live stream first, then reconnect once the clear is recorded.
    if (es) { es.close(); es = null; setConn("retry", "clearing"); await new Promise((r) => setTimeout(r, 1500)); }
    const url = pick === "all" ? "/api/logs/clear-all" : `/api/logs/${encodeURIComponent(current)}/clear`;
    try { await api(url, { method: "POST" }); }
    catch (e) { toast(e.message || "Couldn't clear the logs.", true); connect(); return; }
    if (pick === "all") toast("Every log cleared.");
    window.dispatchEvent(new Event("logs-cleared"));   // the Overview's Recent warnings reads again
    connect();       // reconnect so the stream starts from the now-empty log
  });
  $("#log-copy").addEventListener("click", async () => {
    const text = shownText();
    if (!text) { toast("Nothing to copy yet."); return; }
    try { await navigator.clipboard.writeText(text); toast(`Copied ${text.split("\n").length - 1} lines.`); }
    catch (_) { toast("Couldn't copy. Try Download instead.", true); }
  });
  $("#log-download").addEventListener("click", () => {
    const text = shownText();
    if (!text) { toast("Nothing to download yet."); return; }
    const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    const a = h("a", { href: url, download: `${current || "logs"}-${stamp()}.log` });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  });
}
