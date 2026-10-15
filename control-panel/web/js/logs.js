import { $, h, clear, api, toast } from "./util.js";

const MAX = 2000;
let current = null, es = null, lines = [], follow = true, filter = "", regex = false, wrap = false, svcs = [];
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
const CADDY_STOP = /shutting down apps, then terminating|"msg":"shutdown complete"|exiting; byeee/;
const RESTART_WINDOW = 10;
const CADDY_TS = /"ts":([0-9.]+)/;
let lastStop = -Infinity;
let hideNoise = false;
try {
  hideNoise = localStorage.getItem("aios.hideNoise") === "1";
  wrap = localStorage.getItem("aios.logWrap") === "1";
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
    const p = PLAIN.exec(t);
    if (p) { cls = LEVEL_CLS[p[1].toLowerCase()] || null; mod = p[2] || ""; msg = p[3]; }
  }
  if (!cls) cls = ERR.test(text) ? "error" : WARN.test(text) ? "warn" : "out";
  const ts = Number((CADDY_TS.exec(text) || [])[1]) || NaN;
  const cut = CUT_BY_AIOS.test(raw);
  const noise = NOISE.some((r) => r.test(raw)) || (cut && ts - lastStop <= RESTART_WINDOW);
  return { raw, noise, time, text, cls, mod, msg, extra, ts, cut };
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

const isCaddy = () => current === "caddy";
const hiddenByToggle = (l) => (hideNoise && isCaddy() && l.noise) || (levels.size > 0 && !levels.has(l.cls));

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

function syncControls() {
  $("#log-noise-row").hidden = !isCaddy();
  $("#log-help").hidden = !isCaddy();
  $("#log-noise").checked = hideNoise;
  const n = isCaddy() ? lines.filter((l) => l.noise).length : 0;
  $("#log-noise-n").textContent = n ? `(${n})` : "";
  document.querySelectorAll(".lg-levels button").forEach((b) => b.setAttribute("aria-pressed", String(levels.has(b.dataset.lv))));
}

function setCount() { $("#log-count").textContent = `${lines.filter(visible).length} shown`; }

function node(l) {
  return h("div", { class: `lg-ln ${l.cls}` },
    l.time ? h("time", { class: "lg-time", text: l.time }) : null,
    h("i", { class: "lg-dot", "aria-hidden": "true" }),
    h("span", { class: "lg-msg" },
      l.mod ? h("span", { class: "lg-mod", text: `[${l.mod}] ` }) : null,
      l.msg,
      l.extra ? h("span", { class: "lg-extra", text: ` ${l.extra}` }) : null));
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
  setCount();
  if (follow) term.scrollTop = term.scrollHeight;
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
  es.onopen = () => { setConn("live"); connected = true; if (!lines.length) paint(); };
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
      if (hideNoise && isCaddy()) paint();
    }
    if (l.noise) syncControls();
    if (visible(l)) {
      if (term.querySelector(".term-empty")) clear(term);
      term.append(node(l));
      while (term.childElementCount > MAX) term.firstChild.remove();
      if (follow) term.scrollTop = term.scrollHeight;
    }
    setCount();
  };
  es.onerror = () => setConn("retry", "reconnecting");
}

function services() {
  const sel = $("#log-svc"); clear(sel);
  svcs.forEach((s) => sel.append(h("option", { value: s.container, text: s.name, selected: s.container === current })));
}

export function show(status, pick) {
  // AIOStreams first (it's the one you read most); the Overview keeps its own order.
  const ORDER = ["aiostreams", "caddy", "gluetun", "mediaflow", "webhook"];
  const rank = (s) => { const i = ORDER.indexOf(s.key); return i < 0 ? ORDER.length : i; };
  svcs = status.services.filter((s) => s.present).sort((a, b) => rank(a) - rank(b));
  const was = current;
  if (pick) current = pick;
  if (!svcs.some((s) => s.container === current)) current = (svcs.find((s) => s.key === "aiostreams") || svcs[0] || {}).container || null;
  services();
  if (!es || current !== was) connect();
}

export function hide() { if (es) { es.close(); es = null; } }

function setFollow(v) { follow = v; $("#log-follow").checked = v; }

export function init() {
  $("#log-filter").addEventListener("input", (e) => { filter = e.target.value; setMatcher(); paint(); });
  $("#log-regex").addEventListener("click", (e) => {
    regex = !regex;
    e.currentTarget.setAttribute("aria-pressed", String(regex));
    $("#log-filter").placeholder = regex ? "Regex pattern" : "Filter lines";
    setMatcher(); paint();
  });
  $("#log-svc").addEventListener("change", (e) => { current = e.target.value; connect(); });
  document.querySelectorAll(".lg-levels button").forEach((b) => b.addEventListener("click", () => {
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
    const t = e.target;
    setFollow(t.scrollTop + t.clientHeight >= t.scrollHeight - 24);
  });
  // Phones: Hide noise, Auto-scroll and Wrap sit behind the ⋮ button
  const more = $("#log-more"), tog = $("#log-toggles");
  const openMore = (v) => { tog.classList.toggle("open", v); more.setAttribute("aria-expanded", String(v)); };
  more.addEventListener("click", (e) => { e.stopPropagation(); openMore(!tog.classList.contains("open")); });
  document.addEventListener("click", (e) => { if (!tog.contains(e.target) && !more.contains(e.target)) openMore(false); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") openMore(false); });
  $("#log-clear").addEventListener("click", async () => {
    if (!current) return;
    // Close the live stream first, then reconnect once the clear is recorded.
    if (es) { es.close(); es = null; setConn("retry", "clearing"); await new Promise((r) => setTimeout(r, 1500)); }
    try { await api(`/api/logs/${encodeURIComponent(current)}/clear`, { method: "POST" }); }
    catch (e) { toast(e.message || "Couldn't clear that log.", true); connect(); return; }
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
