import { $, h, clear, api, ago, toast, fmtBytes } from "./util.js";
import { runAction } from "./actions.js";
import { loadTraffic, trafficData, clearHistory } from "./traffic.js";

// Maintenance: upkeep that's easy to forget. Each card says what it found, coloured
// only when something needs a look, with its one button at the bottom right. The
// buttons run setup-aiostreams.sh's free-space, system-updates and log-limits.
let last = null, loading = false, status = null;

// The line under a value can carry an explanation on hover
function stat(label, value, sub, tone, why) {
  return h("div", { class: "stat" }, h("div", { class: "ver-label", text: label }),
    h("div", { class: "stat-value" + (tone ? " " + tone : ""), text: value }),
    h("div", { class: "ver-sub", text: sub || "", title: why || null }));
}

function card(title, grid, note, btn) {
  return h("section", { class: "panel maint-card" },
    h("div", { class: "card-head" }, h("h3", { text: title })),
    h("div", { class: "stat-grid" }, ...grid),
    h("div", { class: "card-foot" }, h("div", { class: "maint-foot" }, h("span", { class: "dim", text: note || "" }), btn)));
}

function button(id, enabled) {
  const a = ((status && status.actions) || []).find((x) => x.id === id);
  if (!a || !a.available) return null;
  return h("button", { class: "btn small", type: "button", text: a.label,
    disabled: !enabled || !!(status && status.busy) || !!(last && last.last && last.last.running), onclick: () => runAction(a) });
}

function space(m) {
  const s = m.space;
  const total = s.images + s.build + s.journal;
  return card("Free up space", [
    stat("Old images", fmtBytes(s.images), s.image_count ? `${s.image_count} nothing uses any more` : "None left over"),
    stat("Build leftovers", fmtBytes(s.build), "From rebuilding the panel"),
    stat("System logs", fmtBytes(s.journal), "Beyond the newest 100 MB"),
  ], total > 20 * 1024 * 1024 ? `About ${fmtBytes(total)} can go. Nothing in use, your settings or backups.` : "Nothing worth freeing right now.",
  button("maint.space", total > 20 * 1024 * 1024));
}

function updates(m) {
  const u = m.updates;
  if (!u.available) return card("System updates", [stat("Waiting", "Can't tell", "This server doesn't use apt")], "", null);
  return card("System updates", [
    stat("Waiting", u.count ? `${u.count} update${u.count === 1 ? "" : "s"}` : "Up to date",
      (u.count ? (u.security ? `${u.security} for security` : "None for security") + (u.phased ? `, ${u.phased} more phasing in` : "")
        : u.phased ? `${u.phased} more phasing in` : ""), u.security ? "warn" : u.count ? "" : "ok",
      u.phased ? `Ubuntu rolls some updates out gradually, a few servers at a time. ${u.phased} ${u.phased === 1 ? "isn't" : "aren't"} offered to this server yet, `
        + "so Install updates leaves them until its turn, usually within days." : null),
    stat("Restart", u.reboot ? "Needed" : "Not needed", u.reboot ? "Reboot server, on the Overview" : "", u.reboot ? "warn" : ""),
    stat("Checked", u.checked_at ? ago(u.checked_at) : "Unknown", "Ubuntu's package lists"),
  ], "AIOStreams' own updates are on the Overview.", button("maint.updates", u.count > 0));
}

function logs(m) {
  const l = m.logs;
  const sub = !l.limited ? "They can grow without limit" : l.pending ? "Some containers take it when next recreated" : "10 MB per container";
  return card("Container logs", [
    stat("Size limit", l.limited ? "Set" : "Not set", sub, l.limited ? "ok" : "warn"),
    stat("Using now", fmtBytes(l.size), "All containers together"),
  ], l.limited ? "" : "Setting it restarts every container once: a few seconds of downtime.", l.limited ? null : button("maint.logs", true));
}

// The traffic histories the panel keeps (the VPN's, the server's network), each with its own Clear
function traffic() {
  const kinds = [["vpn", "VPN"], ["host", "Network"]].filter(([k]) =>
    k === "host" || (status && (status.vpn === "on" || status.vpn === "off")) || (trafficData(k) && trafficData(k).since));
  const grid = [], btns = [];
  for (const [k, label] of kinds) {
    const d = trafficData(k);
    if (!d) continue;
    const since = d.since && new Date(d.since * 1000);
    const short = !since ? "" : since.toDateString() === new Date().toDateString()
      ? since.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : since.toLocaleDateString([], { day: "numeric", month: "short" });
    grid.push(stat(label, d.since ? `Since ${short}` : "Nothing yet",
      d.since ? `↓ ${fmtBytes(d.total[0])} ↑ ${fmtBytes(d.total[1])} in all` : "Starts from the next minute"));
    if (d.since) btns.push(h("button", { class: "btn small quiet", type: "button", text: `Clear ${label === "VPN" ? "VPN" : "network"} history`,
      onclick: async () => { if (await clearHistory(k)) render(); } }));
  }
  if (!grid.length) return null;
  return card("Traffic history", grid, "The graphs and today's totals. Kept for 30 days.",
    btns.length ? h("span", { class: "maint-btns" }, ...btns) : null);
}

// How the last job ended: it may have outlived a panel restart (Docker restarts it)
function lastRun(m) {
  const j = m.last;
  if (!j) return null;
  const state = j.running ? ["Running", ""] : j.code === 0 ? ["Finished", "ok"] : ["Failed", "bad"];
  return h("details", { class: "panel maint-last" },
    h("summary", {}, h("span", { class: "chip " + state[1], text: state[0] }),
      h("span", { text: ` ${j.what}, ${j.running ? "started " : ""}${ago(j.at)}` }), h("span", { class: "dim", text: " · Output" })),
    h("pre", { text: j.tail.join("\n") }));
}

async function load(force) {
  if (loading) return;
  loading = true;
  const root = $("#maint-root");
  if (!last) { clear(root); root.append(h("p", { class: "dim", text: "Looking around the server…" })); }
  // The traffic histories come with it, so the page draws once
  for (const k of ["vpn", "host"]) loadTraffic(force, k).then(() => { if (last && !loading) render(); }).catch(() => {});
  try { last = await api(`/api/maintenance${force ? "?force=1" : ""}`); }
  catch (e) { if (!last) { clear(root); root.append(h("p", { class: "empty", text: e.message || "Couldn't load it." })); } return; }
  finally { loading = false; }
  render();
}

function render() {
  if (!last) return;
  const root = $("#maint-root");
  const open = !!(root.querySelector(".maint-last") || {}).open;   // keep the output open across refreshes
  clear(root);
  root.append(h("div", { class: "maint-grid" }, space(last), updates(last), logs(last), traffic()));
  const run = lastRun(last);
  if (run) root.append(run);
  if (open && root.querySelector(".maint-last")) root.querySelector(".maint-last").open = true;
}

export function show(st, force) {
  status = st;
  render();
  return load(force);
}

// A job just ended, or one is running: look again
let wasBusy = false;
export function setStatus(st) {
  status = st;
  const busy = !!st.busy || !!(last && last.last && last.last.running);
  if (wasBusy && !busy) load(true);
  else if (busy && last && last.last && last.last.running) load(false);
  if (busy !== wasBusy) render();   // buttons follow; otherwise leave the page be
  wasBusy = busy;
}
