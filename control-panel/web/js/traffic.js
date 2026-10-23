// The VPN's traffic: everything through the tunnel, every viewer and search together.
// The panel reads gluetun's counters once a minute (app/traffic.py); this draws them.
// The Network page gets the graph, its figures and the last 7 days; the Overview one line each.
import { h, clear, api, fmtBytes, toast } from "./util.js";
import { ask } from "./actions.js";

let range = "24h";
try { range = localStorage.getItem("aios.vpnRange") || "24h"; } catch (_) {}
const RANGES = { "1h": ["1 hour", 3600, 60], "24h": ["24 hours", 86400, 300], "7d": ["7 days", 7 * 86400, 3600] };

// Two histories: "vpn" (the tunnel) and "host" (the server's own network card), each asked
// for again at most once a minute (they only change once a minute)
const hist = { vpn: { data: null, at: 0, loading: null }, host: { data: null, at: 0, loading: null } };
export function loadTraffic(force, kind = "vpn") {
  const c = hist[kind];
  if (!force && c.data && Date.now() - c.at < 55000) return Promise.resolve(c.data);
  if (!c.loading) {
    c.loading = api(`/api/${kind}/traffic`).then((d) => { c.data = d; return d; })
      .finally(() => { c.at = Date.now(); c.loading = null; });    // a failed ask waits a minute too
  }
  return c.loading;
}
export const trafficData = (kind = "vpn") => hist[kind].data;
export const trafficStale = (kind = "vpn") => !hist[kind].loading && (!hist[kind].data || Date.now() - hist[kind].at >= 55000);

// Clear history, on the Network page: asks, then the record starts again from now.
// True once it's cleared.
const WHAT = { vpn: ["the VPN's", "VPN"], host: ["the server's network", "network"] };
async function clearHistory(kind) {
  const ok = await ask({ title: `Clear ${WHAT[kind][0]} traffic history?`, confirmLabel: "Clear history", danger: true,
    body: `${kind === "vpn" ? "The graph and totals start" : "Today's totals start"} again from the next minute. Only the panel's record goes: nothing on the server changes, and streaming isn't touched. This can't be undone.` });
  if (!ok) return false;
  try {
    await api(`/api/${kind}/traffic/clear`, { method: "POST" });
    hist[kind].at = 0;
    await loadTraffic(true, kind).catch(() => {});
    toast(`The ${WHAT[kind][1]} traffic history is cleared.`);
    return true;
  } catch (e) { toast(e.message || "Couldn't clear it.", true); return false; }
}

// Speeds right now, from the counters in each status check (every few seconds): what went
// through between the last two checks. Null until there are two, or after a counter restarted.
let prevNet = null, curNet = null, live = { host: null, vpn: null };
export function feedNet(net) {
  if (!net || (curNet && net.t === curNet.t)) return;
  prevNet = curNet; curNet = net;
  const rate = (k) => {
    const a = prevNet && prevNet[k], b = curNet[k], dt = prevNet ? curNet.t - prevNet.t : 0;
    if (!a || !b || dt <= 0 || dt > 30 || b[0] < a[0] || b[1] < a[1]) return null;
    return [(b[0] - a[0]) / dt, (b[1] - a[1]) / dt];
  };
  live = { host: rate("host"), vpn: rate("vpn") };
}
export const liveRate = (kind) => live[kind];

// Bytes a second as a network speed, in bits like a speed test
export function fmtRate(bps) {
  const b = (bps || 0) * 8;
  if (b >= 1e6) return `${b >= 1e7 ? Math.round(b / 1e6) : (b / 1e6).toFixed(1)} Mbit/s`;
  if (b >= 1e3) return `${Math.round(b / 1e3)} kbit/s`;
  return `${Math.round(b)} bit/s`;
}

const hhmm = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const dayKey = (t) => new Date(t * 1000).toDateString();
function dayName(t) {
  const d = new Date(t * 1000), today = new Date();
  const yest = new Date(today); yest.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return "Today";
  if (d.toDateString() === yest.toDateString()) return "Yesterday";
  return d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
}
const when = (t) => (dayName(t) === "Today" ? hhmm(t) : `${dayName(t)} ${hhmm(t)}`);

// What's going through now: the live speed, else the latest full minute if it's recent
export function nowRate(d, kind = "vpn") {
  if (live[kind]) return live[kind];
  const m = d && d.minutes[d.minutes.length - 1];
  return m && m[0] >= d.now - 180 ? [m[1] / 60, m[2] / 60] : null;
}

// Today since midnight, from the minutes (they cover the whole day)
export function today(d) {
  if (!d) return null;
  const mid = new Date(); mid.setHours(0, 0, 0, 0);
  const from = mid.getTime() / 1000;
  return d.minutes.reduce((s, m) => (m[0] >= from ? [s[0] + m[1], s[1] + m[2]] : s), [0, 0]);
}

// Down and up speeds, each with its own unit: "↓ 387 kbit/s ↑ 1.4 kbit/s"
export const fmtPair = ([d, u]) => `↓ ${fmtRate(d)} ↑ ${fmtRate(u)}`;

// The Overview's VPN line, in two halves that each stay whole: "Now ↓ 32 ↑ 1.2 Mbit/s", "Today ↓ 3.2 GB ↑ 48 MB"
export function summaryLine(d) {
  const n = nowRate(d), t = today(d);
  return [n ? `Now ${fmtPair(n)}` : "", t && (t[0] || t[1]) ? `Today ↓ ${fmtBytes(t[0])} ↑ ${fmtBytes(t[1])}` : ""].filter(Boolean);
}

// One range's points: [slot start, down bytes/s, up bytes/s] or null for a gap, plus its figures
function series(d, key) {
  const [, span, step] = RANGES[key];
  const end = Math.floor(d.now / step) * step, start = end - span + step;
  const sums = new Map();
  const src = key === "7d" ? d.hours : d.minutes;
  for (const r of src) {
    if (r[0] < start) continue;
    const k = Math.floor(r[0] / step) * step;
    const s = sums.get(k) || [0, 0, 0];
    s[0] += r[1]; s[1] += r[2]; s[2] += key === "7d" ? 0 : 60;
    sums.set(k, s);
  }
  const pts = [];
  for (let t = start; t <= end; t += step) {
    const s = sums.get(t);
    // An hour is averaged over the hour (or the part of it gone so far); minutes over the minutes with data
    const secs = key === "7d" ? Math.max(60, Math.min(3600, d.now - t)) : s && s[2];
    pts.push(s ? [t, s[0] / secs, s[1] / secs] : [t, null, null]);
  }
  let peak = null, tot = [0, 0];
  if (key === "7d") {
    for (const r of d.hours) {
      if (r[0] < start) continue;
      tot[0] += r[1]; tot[1] += r[2];
      if (!peak || r[3] / 60 > peak[1]) peak = [r[0], r[3] / 60, true];
    }
  } else {
    for (const r of d.minutes) {
      if (r[0] < start) continue;
      tot[0] += r[1]; tot[1] += r[2];
      if (!peak || r[1] / 60 > peak[1]) peak = [r[0], r[1] / 60, false];
    }
  }
  return { pts, peak, tot, step };
}

// A round top for the scale, in bits: 1, 2 or 5 times a power of ten
function niceTop(bps) {
  const b = Math.max(bps * 8, 1e5);
  const p = 10 ** Math.floor(Math.log10(b));
  return ([1, 2, 5, 10].find((m) => m * p >= b) * p) / 8;
}

const SVG = "http://www.w3.org/2000/svg";
function svgEl(tag, attrs) {
  const e = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  return e;
}

// Down as a filled area, up as a line, broken where there's no data
function chart(s, key) {
  const W = 1000, H = 200, n = s.pts.length;
  const top = niceTop(Math.max(0, ...s.pts.map((p) => Math.max(p[1] || 0, p[2] || 0))));
  const x = (i) => (n > 1 ? (i / (n - 1)) * W : 0);
  const y = (v) => H - (v / top) * (H - 6);
  const runs = [];
  let run = null;
  s.pts.forEach((p, i) => {
    if (p[1] == null) { run = null; return; }
    if (!run) runs.push(run = []);
    run.push(i);
  });
  let area = "", down = "", up = "";
  for (const r of runs) {
    const line = (k) => r.map((i, j) => `${j ? "L" : "M"}${x(i).toFixed(1)} ${y(s.pts[i][k]).toFixed(1)}`).join(" ");
    const dl = r.length > 1 ? line(1) : `M${x(r[0]) - 2} ${y(s.pts[r[0]][1])} L${x(r[0]) + 2} ${y(s.pts[r[0]][1])}`;
    down += dl + " ";
    up += (r.length > 1 ? line(2) : "") + " ";
    area += `${dl} L${x(r[r.length - 1]).toFixed(1)} ${H} L${x(r[0]).toFixed(1)} ${H} Z `;
  }
  const svg = svgEl("svg", { class: "tr-svg", viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none", "aria-hidden": "true" });
  svg.append(svgEl("line", { class: "tr-grid", x1: 0, x2: W, y1: y(top / 2), y2: y(top / 2), "vector-effect": "non-scaling-stroke" }),
    svgEl("path", { class: "tr-area", d: area || "M0 0" }),
    svgEl("path", { class: "tr-down", d: down || "M0 0", "vector-effect": "non-scaling-stroke" }),
    svgEl("path", { class: "tr-up", d: up || "M0 0", "vector-effect": "non-scaling-stroke" }));

  // Times along the bottom: five, evenly spaced
  const ticks = h("div", { class: "tr-ticks", "aria-hidden": "true" });
  for (let k = 0; k <= 4; k++) {
    const p = s.pts[Math.round((k / 4) * (n - 1))];
    ticks.append(h("span", { text: key === "7d" ? dayName(p[0]).replace(/ \d+ \w+$/, "") : hhmm(p[0]) }));
  }
  const cursor = h("div", { class: "tr-cursor", hidden: true });
  const tip = h("div", { class: "tr-tip", hidden: true });
  const plot = h("div", { class: "tr-plot" },
    h("span", { class: "tr-ymax", text: fmtRate(top) }), h("span", { class: "tr-ymid", text: fmtRate(top / 2) }),
    svg, cursor, tip);
  // Point at the graph (or touch it) for that moment's speeds
  const show = (e) => {
    const r = plot.getBoundingClientRect();
    const i = Math.max(0, Math.min(n - 1, Math.round(((e.clientX - r.left) / r.width) * (n - 1))));
    const p = s.pts[i];
    cursor.hidden = tip.hidden = false;
    const left = (x(i) / W) * 100;
    cursor.style.left = `${left}%`;
    tip.style.left = `${Math.min(Math.max(left, 12), 88)}%`;
    clear(tip);
    const label = key === "7d" ? `${dayName(p[0])}, ${hhmm(p[0])} to ${hhmm(p[0] + 3600)}`
      : key === "24h" ? `${dayName(p[0]) === "Today" ? "" : dayName(p[0]) + ", "}${hhmm(p[0])} to ${hhmm(p[0] + 300)}` : when(p[0]);
    tip.append(h("div", { class: "tr-tip-t", text: label }));
    if (p[1] == null) tip.append(h("div", { class: "dim", text: "No data: VPN off or the panel not running" }));
    else tip.append(h("div", { text: `↓ ${fmtRate(p[1])}` }), h("div", { class: "dim", text: `↑ ${fmtRate(p[2])}` }));
  };
  plot.addEventListener("pointermove", show);
  plot.addEventListener("pointerdown", show);
  plot.addEventListener("pointerleave", () => { cursor.hidden = tip.hidden = true; });
  return h("div", { class: "tr-chart" }, plot, ticks);
}

const fig = (label, value, sub) => h("div", { class: "vpn-cell" }, h("div", { class: "vpn-label", text: label }),
  h("div", { class: "vpn-value", text: value }), h("div", { class: "tr-sub dim", text: sub || "" }));

// The last 7 days, newest first, each a bar of how much came down
function days(d) {
  const by = new Map();
  for (const r of d.hours) {
    const k = dayKey(r[0]);
    const s = by.get(k) || [r[0], 0, 0];
    s[1] += r[1]; s[2] += r[2];
    by.set(k, s);
  }
  const rows = [];
  for (let i = 0; i < 7; i++) {
    const day = new Date(); day.setHours(12, 0, 0, 0); day.setDate(day.getDate() - i);
    rows.push(by.get(day.toDateString()) || [day.getTime() / 1000, null, null]);
  }
  const most = Math.max(1, ...rows.map((r) => r[1] || 0));
  return h("div", { class: "tr-days" }, h("div", { class: "vpn-label", text: "Last 7 days" }),
    ...rows.map((r) => {
      const bar = h("i");
      bar.style.width = `${r[1] ? Math.max(1, (r[1] / most) * 100) : 0}%`;   // set here: the page's CSP blocks style attributes
      return h("div", { class: "tr-day" },
        h("span", { class: "tr-day-name", text: dayName(r[0]) }),
        h("span", { class: "tr-bar" }, bar),
        h("span", { class: "tr-day-tot" + (r[1] == null ? " dim" : ""),
          text: r[1] == null ? "No data" : `↓ ${fmtBytes(r[1])}   ↑ ${fmtBytes(r[2])}` }));
    }));
}

// The Traffic card's Now, kept up to date with each status check between the minute's redraws
const nowFigs = {};
export function updateNow() {
  for (const [kind, f] of Object.entries(nowFigs)) {
    const n = f.isConnected && nowRate(trafficData(kind), kind);
    if (!n) continue;
    f.querySelector(".vpn-value").textContent = `↓ ${fmtRate(n[0])}`;
    f.querySelector(".tr-sub").textContent = `↑ ${fmtRate(n[1])}`;
  }
}

// A Traffic card, drawn into box (and again once a minute while its page is open): the VPN's
// tunnel ("vpn") or the server's own network card ("host")
export async function trafficCard(box, force, kind = "vpn") {
  let d;
  try { d = await loadTraffic(force, kind); } catch (_) { return; }
  if (!box.isConnected) return;
  clear(box);
  const s = series(d, range);
  const n = nowRate(d, kind);
  const btns = h("div", { class: "tr-ranges", role: "group", "aria-label": "Time range" },
    ...Object.entries(RANGES).map(([k, [label]]) => h("button", { class: "btn small", type: "button", text: label,
      "aria-pressed": String(k === range), onclick: () => {
        range = k;
        try { localStorage.setItem("aios.vpnRange", k); } catch (_) {}
        trafficCard(box, false, kind);
      } })));
  const label = RANGES[range][0];
  const what = kind === "vpn" ? "Everything through the VPN" : "Everything in and out of this server";
  box.append(h("div", { class: "panel vpn-card tr-card" },
    h("div", { class: "vpn-head" }, h("h3", { class: "tr-title", text: "Traffic" }), btns),
    h("div", { class: "vpn-grid tr-figs" },
      nowFigs[kind] = fig("Now", n ? `↓ ${fmtRate(n[0])}` : "Measuring…", n ? `↑ ${fmtRate(n[1])}` : ""),
      fig("Peak", s.peak && s.peak[1] ? `↓ ${fmtRate(s.peak[1])}` : "None", s.peak && s.peak[1] ? `${s.peak[2] ? "Busiest minute, " : ""}${when(s.peak[0])}` : ""),
      fig("Down", fmtBytes(s.tot[0]), `in the last ${label}`),
      fig("Up", fmtBytes(s.tot[1]), `in the last ${label}`)),
    chart(s, range),
    h("div", { class: "tr-legend dim" }, h("span", { class: "tr-key down", text: "Down" }), h("span", { class: "tr-key up", text: "Up" }),
      h("span", { class: "tr-step", text: `${what}, ${range === "7d" ? "hourly averages" : range === "24h" ? "5-minute averages" : "minute by minute"}` })),
    days(d),
    d.since ? h("div", { class: "card-foot" }, h("span", { class: "dim tr-since", text: `Recorded since ${dayName(d.since)}, ${hhmm(d.since)}` }),
      h("button", { class: "btn small quiet", type: "button", text: "Clear history",
        onclick: async () => { if (await clearHistory(kind)) trafficCard(box, false, kind); } })) : null));
}
