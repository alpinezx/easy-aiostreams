import { $, h, clear, api, toast } from "./util.js";

const MAX = 2000;
let current = null, es = null, lines = [], follow = true, filter = "", svcs = [];

// Caddy lines that look alarming but are expected. Matched against the raw line.
const NOISE = [
  /aborting with incomplete response.*\/api\/logs\//,        // this page's own live log connection closing
  /aborting with incomplete response.*"error":"[^"]*context canceled"/,   // a browser left a live page (event stream)
  /aborting with incomplete response.*"error":"writing: /,   // the viewer's player or browser hung up mid-transfer (skip, seek, stop)
  /aborting with incomplete response.*"uri":"\/api\/v1\/dashboard\/[^"]*\/stream".*"error":"reading: unexpected EOF"/,   // AIOStreams restarted under an open dashboard page
  /exiting; byeee/,                                          // Caddy stopping for a restart
  /shutting down apps, then terminating/,
  /servers shutting down with eternal grace period/,
  /Caddyfile input is not formatted/,                         // whitespace only
  /HTTP\/[23] skipped because it requires TLS/,               // port 80 is plain HTTP by design
  /dial tcp [0-9.]+:8080: connect: connection refused/,      // the panel itself restarting
  /lookup aios-ui on [^ ]+: (server misbehaving|no such host)/,   // the panel container stopped or being rebuilt
];
let hideNoise = false, hideWarn = false;
try {
  hideNoise = localStorage.getItem("aios.hideNoise") === "1";
  hideWarn = localStorage.getItem("aios.hideWarn") === "1";
} catch (_) {}

const ERR = /\b(error|fatal|panic|exception|failed)\b/i;
const WARN = /\bwarn(ing)?\b/i;
// Caddy and AIOStreams both write JSON with a "level" field first. Trust it over guessing from the words in the line,
// because a warning can carry an "error" field and an info line can mention "failed".
const LEVEL = /"level":"([A-Za-z]+)"/;
const LEVEL_CLS = { error: "error", fatal: "error", panic: "error", dpanic: "error", critical: "error",
  warn: "warn", warning: "warn", info: "out", debug: "out", trace: "out" };
const TS = /^(\d{4}-\d\d-\d\dT[\d:.]+)Z?\s(.*)$/s;

function parse(raw) {
  const m = TS.exec(raw);
  let time = "", text = raw;
  if (m) {
    const d = new Date(m[1].slice(0, 23) + "Z");
    if (!isNaN(d)) time = d.toLocaleTimeString([], { hour12: false });
    text = m[2];
  }
  const lv = LEVEL.exec(text);
  const cls = (lv && LEVEL_CLS[lv[1].toLowerCase()]) || (ERR.test(text) ? "error" : WARN.test(text) ? "warn" : "out");
  return { raw, noise: NOISE.some((r) => r.test(raw)), time, text, cls };
}

const hiddenByToggle = (l) => (hideNoise && current === "caddy" && l.noise) || (hideWarn && l.cls === "warn");

function visible(l) {
  if (hiddenByToggle(l)) return false;
  const f = filter.toLowerCase();
  return !f || l.text.toLowerCase().includes(f);
}

function noiseCount() { return current === "caddy" ? lines.filter((l) => l.noise).length : 0; }

function syncNoiseButton() {
  const b = $("#log-noise");
  if (!b) return;
  b.hidden = current !== "caddy";
  b.setAttribute("aria-pressed", String(hideNoise));
  const n = noiseCount();
  b.textContent = n ? `Hide noise (${n})` : "Hide noise";
}

function warnCount() { return lines.filter((l) => l.cls === "warn").length; }

function syncWarnButton() {
  const b = $("#log-warn");
  if (!b) return;
  b.setAttribute("aria-pressed", String(hideWarn));
  const n = warnCount();
  b.textContent = n ? `Hide warnings (${n})` : "Hide warnings";
}

function syncButtons() { syncNoiseButton(); syncWarnButton(); }

function node(l) {
  return h("div", { class: `ln ${l.cls}` }, h("time", { text: l.time }), h("span", { text: l.text }));
}

let connected = false;

function paint() {
  const term = $("#log-term"); clear(term);
  const shown = lines.filter(visible);
  const quiet = current === "caddy" ? " Caddy only logs when something happens, like a restart or an error, so quiet is normal." : "";
  const msg = !lines.length ? (connected ? `Connected. Nothing has been logged yet.${quiet}` : "Waiting for log lines…")
    : lines.every(hiddenByToggle) ? "Everything so far is hidden by Hide noise or Hide warnings. Turn one off to see it."
    : "No lines match that filter.";
  if (!shown.length) term.append(h("div", { class: "term-empty", text: msg }));
  else term.append(...shown.map(node));
  if (follow) term.scrollTop = term.scrollHeight;
}

// What's on screen (respecting the filter), as plain text with full timestamps.
function shownText() {
  const shown = lines.filter(visible);
  return shown.map((l) => l.raw).join("\n") + (shown.length ? "\n" : "");
}

function stamp() {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function setConn(s, text) { const c = $("#log-conn"); c.dataset.s = s; c.textContent = text; }

function connect() {
  if (es) { es.close(); es = null; }
  lines = []; connected = false; paint(); syncButtons();
  if (!current) return;
  setConn("retry", "Connecting");
  es = new EventSource(`/api/logs/${encodeURIComponent(current)}?tail=300`);
  es.onopen = () => { setConn("live", "Live"); connected = true; if (!lines.length) paint(); };
  es.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.end) { setConn("", "Container stopped"); es.close(); es = null; return; }
    if (m.error) { setConn("retry", m.error); es.close(); es = null; return; }
    const l = parse(m.l);
    lines.push(l);
    if (lines.length > MAX) lines.splice(0, lines.length - MAX);
    const term = $("#log-term");
    if (l.noise || l.cls === "warn") syncButtons();
    if (visible(l)) {
      if (term.querySelector(".term-empty")) clear(term);
      term.append(node(l));
      while (term.childElementCount > MAX) term.firstChild.remove();
      if (follow) term.scrollTop = term.scrollHeight;
    }
  };
  es.onerror = () => setConn("retry", "Reconnecting");
}

function tabs() {
  const box = $("#log-tabs"); clear(box);
  svcs.forEach((s) => box.append(h("button", { type: "button", "aria-pressed": String(s.container === current), text: s.name,
    onclick: () => { current = s.container; tabs(); connect(); } })));
}

export function show(status, pick) {
  // AIOStreams first (it's the one you read most); the Overview keeps its own order.
  const ORDER = ["aiostreams", "caddy", "gluetun", "mediaflow", "webhook"];
  const rank = (s) => { const i = ORDER.indexOf(s.key); return i < 0 ? ORDER.length : i; };
  svcs = status.services.filter((s) => s.present).sort((a, b) => rank(a) - rank(b));
  if (pick) current = pick;
  if (!svcs.some((s) => s.container === current)) current = (svcs.find((s) => s.key === "aiostreams") || svcs[0] || {}).container || null;
  tabs();
  if (!es) connect();
}

export function hide() { if (es) { es.close(); es = null; } }

export function init() {
  $("#log-filter").addEventListener("input", (e) => { filter = e.target.value; paint(); });
  $("#log-clear").addEventListener("click", async () => {
    if (!current) return;
    // Close the live stream first, then reconnect once the clear is recorded.
    if (es) { es.close(); es = null; setConn("retry", "Clearing"); await new Promise((r) => setTimeout(r, 1500)); }
    try { await api(`/api/logs/${encodeURIComponent(current)}/clear`, { method: "POST" }); }
    catch (e) { toast(e.message || "Couldn't clear that log.", true); connect(); return; }
    connect();       // reconnect so the stream starts from the now-empty log
  });
  $("#log-warn").addEventListener("click", () => {
    hideWarn = !hideWarn;
    try { localStorage.setItem("aios.hideWarn", hideWarn ? "1" : "0"); } catch (_) {}
    syncButtons(); paint();
  });
  $("#log-noise").addEventListener("click", () => {
    hideNoise = !hideNoise;
    try { localStorage.setItem("aios.hideNoise", hideNoise ? "1" : "0"); } catch (_) {}
    syncButtons(); paint();
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
    const a = h("a", { href: url, download: `${current || "logs"}-${stamp()}.txt` });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  });
  const btn = $("#log-follow");
  const setFollow = (v) => { follow = v; btn.setAttribute("aria-pressed", String(v)); };
  btn.addEventListener("click", () => { setFollow(!follow); if (follow) { const t = $("#log-term"); t.scrollTop = t.scrollHeight; } });
  $("#log-term").addEventListener("scroll", (e) => {
    const t = e.target;
    setFollow(t.scrollTop + t.clientHeight >= t.scrollHeight - 24);
  });
}
