// Tiny helpers. Everything dynamic goes in through textContent, never innerHTML:
// container names and log lines are untrusted text.

export const $ = (sel, root = document) => root.querySelector(sel);

export function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "dataset") Object.assign(el.dataset, v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

// A box with an arrow out of it, after a link that opens a new tab
export function extIcon() {
  const s = document.createElement("span");
  s.className = "ext";
  s.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>';
  return s;
}

// One icon per action word, shared by every page, so the same action looks the same wherever it is:
// a folded card's corner icon and the open card's button carry the same picture.
const RESTART = '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>';
const COPY = '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1"/>';
const BIN = '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>';
export const ICONS = {
  "Update": '<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>',
  "Check now": '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  "All releases": '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
  "Restart stack": RESTART, "Restart": RESTART, "Restart panel": RESTART,
  "Reboot server": '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>',
  "Stop": '<rect x="6" y="6" width="12" height="12" rx="1.5"/>',
  "Start": '<path d="M7 4v16l13-8z"/>',
  "Turn VPN off": '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m4 4 16 16"/>',
  "Turn VPN on": '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
  "Send test alert": '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
  "Back up now": '<rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',
  "Set schedule": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  "Restore": '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>',
  "Copy restore command": COPY, "Copy scp command": COPY,
  "Lock": '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  "Unlock": '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.9-1"/>',
  "Delete": BIN,
  "Details": '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
  "Logs": '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/>',
};
export function iconSvg(word) {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox", "0 0 24 24"); s.setAttribute("aria-hidden", "true");
  s.innerHTML = ICONS[word];
  return s;
}
// A button whose whole text is a known action word gets its icon in front of the word. Run over a
// page's buttons whenever they're drawn (main.js watches the pages that have them); a button whose
// text changes (Checking…) loses it and gets it back with its word.
export function iconButtons(root) {
  for (const b of root.querySelectorAll(".btn:not(.quiet):not(.fold-act)")) {
    if (b.firstElementChild) continue;
    const w = b.textContent.trim();
    if (ICONS[w]) { b.prepend(iconSvg(w)); b.classList.add("btn-i"); }
  }
}

export function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); }

export function setText(root, sel, text) {
  const el = root.querySelector(sel);
  if (el && el.textContent !== text) el.textContent = text;
}

export function fmtDur(sec) {
  sec = Math.max(0, Math.floor(sec));
  const d = Math.floor(sec / 86400), hr = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  if (d) return `${d}d ${hr}h`;
  if (hr) return `${hr}h ${m}m`;
  if (m) return `${m}m`;
  return `${sec}s`;
}

// Sizes in KB, MB and GB of 1000, as AIOStreams' dashboard writes them, so the two agree
export function fmtBytes(n) {
  if (n == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}

// A 24-hour time ("04:00") typed into a plain box, the same in every browser, like the
// scripts and alerts. Digits only; the colon goes in by itself ("2057" becomes 20:57).
// Its .value is "HH:MM" once it's a real time, or what was typed, which the caller's
// check then turns down.
export function timePicker(value, label = "Time") {
  const pad = (n) => String(n).padStart(2, "0");
  const input = h("input", { class: "input time-box", type: "text", inputmode: "numeric", maxlength: "5",
    autocomplete: "off", spellcheck: "false", placeholder: "HH:MM", "aria-label": `${label}, 24-hour HH:MM` });
  const read = () => {
    const m = input.value.match(/^(\d{1,2}):?(\d{2})$/);
    return m && Number(m[1]) < 24 && Number(m[2]) < 60 ? `${pad(Number(m[1]))}:${m[2]}` : null;
  };
  input.addEventListener("input", () => {
    const d = input.value.replace(/\D/g, "").slice(0, 4);
    input.value = d.length > 2 ? `${d.slice(0, 2)}:${d.slice(2)}` : d;
  });
  input.addEventListener("blur", () => { const t = read(); if (t) input.value = t; });
  const el = h("span", { class: "time-pick" }, input);
  Object.defineProperty(el, "value", {
    get: () => read() || input.value,
    set: (v) => { input.value = String(v || ""); const t = read(); if (t) input.value = t; },
  });
  el.value = value;
  return el;
}

export function ago(ts) {
  const s = Date.now() / 1000 - ts;
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) { const n = Math.round(s / 3600); return `${n} hour${n === 1 ? "" : "s"} ago`; }
  { const n = Math.round(s / 86400); return `${n} day${n === 1 ? "" : "s"} ago`; }
}

export const OUT_OF_REACH = "The panel is briefly out of reach while things restart. It comes back by itself.";

export async function api(path, opts = {}) {
  const res = await fetch(path, {
    credentials: "same-origin",
    ...opts,
    headers: { "X-UI-Request": "1", ...(opts.body ? { "Content-Type": "application/json" } : {}), ...(opts.headers || {}) },
  });
  if (res.status === 401) { location.href = "/login"; throw new Error("signed out"); }
  if (!res.ok) {
    // A gateway error with no reason from the panel: Caddy (or the tunnel) couldn't reach it for a
    // moment, as when the VPN is switched or the stack restarts. Not a fault, so not worded like one.
    let msg = [502, 503, 504].includes(res.status) ? OUT_OF_REACH : `Request failed (${res.status})`;
    try { const body = await res.json(); msg = body.detail || body.error || msg; } catch (_) {}
    const err = new Error(msg); err.status = res.status; throw err;
  }
  return res.json();
}

export function toast(text, bad = false) {
  if (text === OUT_OF_REACH) bad = false;   // expected during a restart, so never shown as an error
  const t = h("div", { class: "toast" + (bad ? " bad" : ""), text });
  $("#toasts").append(t);
  setTimeout(() => t.remove(), bad ? 7000 : 4000);
}
