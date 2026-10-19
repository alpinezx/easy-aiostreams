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

export function fmtBytes(n) {
  if (n == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}

// A 24-hour time ("04:00"), the same in every browser, like the scripts and alerts.
// A small box you can type in ("2057" becomes 20:57); clicking it opens a compact grid
// of hours, then minutes in 5-minute steps, rather than a 24-row list. Has a .value
// of "HH:MM", like an input.
export function timePicker(value, label = "Time") {
  const pad = (n) => String(n).padStart(2, "0");
  const input = h("input", { class: "input time-box", type: "text", inputmode: "numeric", maxlength: "5",
    autocomplete: "off", spellcheck: "false", "aria-label": `${label}, 24-hour HH:MM`, placeholder: "HH:MM" });
  let hour = 0, minute = 0;
  const show = () => { input.value = `${pad(hour)}:${pad(minute)}`; mark(); };
  const cell = (n, kind) => h("button", { type: "button", class: "tp-cell", text: pad(n), dataset: { kind, n: String(n) },
    onclick: () => {
      if (kind === "h") { hour = n; show(); }
      else { minute = n; show(); close(); input.focus(); }
    } });
  const pop = h("div", { class: "tp-pop", hidden: true, role: "dialog", "aria-label": label },
    h("div", { class: "tp-head", text: "Hour" }),
    h("div", { class: "tp-grid" }, ...Array.from({ length: 24 }, (_, i) => cell(i, "h"))),
    h("div", { class: "tp-head", text: "Minute" }),
    h("div", { class: "tp-grid" }, ...Array.from({ length: 12 }, (_, i) => cell(i * 5, "m"))));
  const el = h("span", { class: "time-pick" }, input, pop);
  function mark() {
    for (const b of pop.querySelectorAll(".tp-cell")) {
      const n = Number(b.dataset.n);
      b.classList.toggle("on", b.dataset.kind === "h" ? n === hour : n === minute);
    }
  }
  const outside = (e) => { if (!el.contains(e.target)) close(); };
  function open() {
    if (!pop.hidden) return;
    pop.hidden = false;
    // kept on screen: on a phone the box can sit near the right edge
    pop.style.left = "0px";
    const r = pop.getBoundingClientRect();
    const vw = document.documentElement.clientWidth;
    if (r.right > vw - 8) pop.style.left = `${Math.round(vw - 8 - r.right)}px`;
    document.addEventListener("pointerdown", outside, true);
  }
  function close() {
    pop.hidden = true;
    document.removeEventListener("pointerdown", outside, true);
  }
  // Typed: digits only, the colon added after two; read back when it's a whole time
  const parse = () => {
    const m = input.value.match(/^(\d{1,2}):?(\d{2})$/);
    if (m && Number(m[1]) < 24 && Number(m[2]) < 60) { hour = Number(m[1]); minute = Number(m[2]); mark(); return true; }
    return false;
  };
  input.addEventListener("input", () => {
    const d = input.value.replace(/\D/g, "").slice(0, 4);
    input.value = d.length > 2 ? `${d.slice(0, 2)}:${d.slice(2)}` : d;
    parse();
  });
  input.addEventListener("click", open);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
    if (e.key === "Enter") { close(); if (!parse()) show(); }
  });
  input.addEventListener("blur", () => { if (!parse()) setTimeout(() => { if (!el.contains(document.activeElement)) show(); }, 0); });
  Object.defineProperty(el, "value", {
    get: () => (parse(), `${pad(hour)}:${pad(minute)}`),
    set: (v) => { const [a, b] = String(v || "").split(":"); hour = Math.min(23, Number(a) || 0); minute = Math.min(59, Number(b) || 0); show(); },
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

export async function api(path, opts = {}) {
  const res = await fetch(path, {
    credentials: "same-origin",
    ...opts,
    headers: { "X-UI-Request": "1", ...(opts.body ? { "Content-Type": "application/json" } : {}), ...(opts.headers || {}) },
  });
  if (res.status === 401) { location.href = "/login"; throw new Error("signed out"); }
  if (!res.ok) {
    let msg = `Request failed (${res.status})`;
    try { const body = await res.json(); msg = body.detail || body.error || msg; } catch (_) {}
    const err = new Error(msg); err.status = res.status; throw err;
  }
  return res.json();
}

export function toast(text, bad = false) {
  const t = h("div", { class: "toast" + (bad ? " bad" : ""), text });
  $("#toasts").append(t);
  setTimeout(() => t.remove(), bad ? 7000 : 4000);
}
