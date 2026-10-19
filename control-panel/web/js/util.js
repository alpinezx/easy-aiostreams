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

// A 24-hour time as two dropdowns, hour and minute. <input type="time"> shows AM/PM in
// some browsers, by the system's language; these read the same everywhere, like the
// scripts and alerts ("04:00"). Has a .value of "HH:MM", like an input.
export function timePicker(value, label = "Time") {
  const pad = (n) => String(n).padStart(2, "0");
  const opts = (n) => Array.from({ length: n }, (_, i) => h("option", { value: pad(i), text: pad(i) }));
  const hh = h("select", { class: "input", "aria-label": `${label}, hour` }, ...opts(24));
  const mm = h("select", { class: "input", "aria-label": `${label}, minute` }, ...opts(60));
  const el = h("span", { class: "time-pick" }, hh, h("span", { class: "dim", text: ":" }), mm);
  Object.defineProperty(el, "value", {
    get: () => `${hh.value}:${mm.value}`,
    set: (v) => { const [a, b] = String(v || "").split(":"); hh.value = pad(Math.min(23, Number(a) || 0)); mm.value = pad(Math.min(59, Number(b) || 0)); },
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
