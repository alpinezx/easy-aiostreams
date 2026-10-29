import { $, h, clear, api, ago, toast, fmtBytes, timePicker } from "./util.js";
import { runAction, rebootServer } from "./actions.js";

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

function card(title, grid, note, ...btns) {
  return h("section", { class: "panel maint-card" },
    h("div", { class: "card-head" }, h("h3", { text: title })),
    h("div", { class: "stat-grid" }, ...grid),
    h("div", { class: "card-foot" }, h("div", { class: "maint-foot" }, h("span", { class: "dim", text: note || "" }), ...btns)));
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
    stat("Restart", u.reboot ? "Needed" : "Not needed", u.reboot ? "To finish installing updates" : "", u.reboot ? "warn" : ""),
    stat("Checked", u.checked_at ? ago(u.checked_at) : "Unknown", "The package lists"),
  ], "AIOStreams' own updates are on the Overview.", button("maint.updates", u.count > 0),
  u.reboot ? h("button", { class: "btn small danger", type: "button", text: "Reboot server", onclick: rebootServer,
    disabled: !!(status && status.busy) || !!(last && last.last && last.last.running) }) : null);
}

function logs(m) {
  const l = m.logs;
  const sub = !l.limited ? "They can grow without limit" : l.pending ? "Some containers take it when next recreated" : "10 MB per container";
  return card("Container logs", [
    stat("Size limit", l.limited ? "Set" : "Not set", sub, l.limited ? "ok" : "warn"),
    stat("Using now", fmtBytes(l.size), "All containers together"),
  ], l.limited ? "" : "Setting it restarts every container once: a few seconds of downtime.", l.limited ? null : button("maint.logs", true));
}

// Scheduled restart: setup-maintenance.sh's timer restarts the server at a set time, only when an
// update needs it or every time. With it, the clock that time goes by, and its time zone.
const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
let rs = null;

function restart(r) {
  const on = r.mode !== "off";
  const when = r.every === "daily" ? `Daily ${r.time}` : `${DAYS[r.day - 1]} ${r.time}`;
  const next = !on ? stat("Next restart", "Off", "Restarts are up to you")
    : !r.timer ? stat("Next restart", "Not running", "Press Set to start it again", "warn")
    : stat("Next restart", when, r.mode === "always" ? "Every time" : r.needed ? "An update needs one" : "Only if an update needs one");
  const l = r.last;
  const last = stat("Last", l ? ago(l.at) : "Not yet",
    !l ? "" : l.status === "restarted" ? "Restarted" : /^Not needed/.test(l.text) ? "Skipped: not needed" : "Skipped", "", l ? l.text : null);
  const cards = [next, last, clockStat(r)];

  const mode = h("select", { class: "input", "aria-label": "When" },
    ...[["off", "Off"], ["needed", "When needed"], ["always", "Always"]].map(([v, t]) => h("option", { value: v, text: t })));
  const every = h("select", { class: "input", "aria-label": "How often" },
    ...[["daily", "Daily"], ["weekly", "Weekly"]].map(([v, t]) => h("option", { value: v, text: t })));
  const day = h("select", { class: "input", "aria-label": "Day" }, ...DAYS.map((d, i) => h("option", { value: String(i + 1), text: d })));
  const time = timePicker(r.time);
  const onLbl = h("span", { class: "dim", text: "on" }), atLbl = h("span", { class: "dim", text: "at" });
  mode.value = r.mode; every.value = r.every; day.value = String(r.day);
  const setBtn = h("button", { class: "btn small", type: "button", text: "Set" });
  const show = () => {
    const o = mode.value !== "off";
    for (const el of [every, atLbl, time, setBtn]) el.hidden = !o;
    onLbl.hidden = day.hidden = !o || every.value !== "weekly";
  };
  const save = async (body) => {
    setBtn.disabled = mode.disabled = true;
    try {
      const n = await api("/api/restart-schedule", { method: "PUT", body: JSON.stringify(body) });
      toast(n.mode === "off" ? "Scheduled restart: off."
        : `Scheduled restart: ${n.mode === "always" ? "always" : "when needed"}, ${n.every === "daily" ? `daily at ${n.time}` : `${DAYS[n.day - 1]}s at ${n.time}`}.`);
      rs = n;
    } catch (e) { toast(e.message || "Couldn't save it.", true); }
    render(true);
  };
  mode.addEventListener("change", () => { show(); if (mode.value === "off" && r.mode !== "off") save({ mode: "off" }); });
  every.addEventListener("change", show);
  setBtn.addEventListener("click", () => {
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time.value)) { toast("Type a 24-hour time, for example 04:30.", true); return; }
    save({ mode: mode.value, every: every.value, day: Number(day.value), time: time.value });
  });
  show();

  const note = r.toolkit
    ? h("span", { class: "warn", text: `linux-aio-toolkit also restarts this server, ${r.toolkit}. Remove one so they don't both run.` })
    : h("span", { class: "dim", text: on ? "Never during a backup or an update. Phone alerts says it was planned." : "" });
  const ntp = r.clock.known && !r.clock.ntp && r.clock.can_ntp
    ? h("button", { class: "btn small", type: "button", text: "Turn on time sync", onclick: async (e) => {
      e.target.disabled = true;
      try { await api("/api/server/ntp", { method: "POST", body: "{}" }); toast("Time sync: on."); rs = await api("/api/restart-schedule"); }
      catch (err) { toast(err.message || "Couldn't switch it on.", true); }
      render(true);
    } }) : null;
  return h("section", { class: "panel maint-card" },
    h("div", { class: "card-head" }, h("h3", { text: "Scheduled restart" })),
    h("div", { class: "stat-grid" }, ...cards),
    h("div", { class: "wd-when-row restart-row" }, mode, every, onLbl, day, atLbl, time),
    h("div", { class: "card-foot" }, h("div", { class: "maint-foot" }, note, ntp, setBtn)));
}

// The clock: synced or not, and the time zone under it, which Change sets
function clockStat(r) {
  const c = r.clock;
  const s = stat("Clock", !c.known ? "Can't tell" : c.synced ? "Synced" : "Not synced", "",
    !c.known ? "" : c.synced ? "ok" : "warn",
    c.known && !c.synced ? (c.ntp ? "Time sync is on but hasn't reached a time server yet." : "Time sync is off, so the clock can drift.") : null);
  const sub = s.querySelector(".ver-sub");
  const change = h("button", { class: "linkish", type: "button", text: "Change" });
  sub.append(`${r.timezone || "Time zone unknown"} · `, change);
  change.addEventListener("click", () => {
    // The box opens at once; its suggestions follow as the server's list arrives
    const list = h("datalist", { id: "tz-list" });
    api("/api/server/timezones").then((zones) => list.append(...zones.map((z) => h("option", { value: z })))).catch(() => {});
    const box = h("input", { class: "input tz-box", type: "text", list: "tz-list", autocomplete: "off", spellcheck: "false",
      placeholder: "Europe/London", "aria-label": "Time zone, for example Europe/London" });
    const go = h("button", { class: "btn small", type: "button", text: "Set" });
    const done = async () => {
      const tz = box.value.trim();
      if (!tz) return;
      go.disabled = true;
      try {
        const n = await api("/api/server/timezone", { method: "PUT", body: JSON.stringify({ timezone: tz }) });
        toast(`Time zone: ${n.timezone}. Scheduled backups and restarts now go by it.`);
        rs = await api("/api/restart-schedule");
      } catch (e) { toast(e.message || "Couldn't set it.", true); go.disabled = false; return; }
      render(true);
    };
    box.addEventListener("keydown", (e) => { if (e.key === "Enter") done(); if (e.key === "Escape") render(true); });
    go.addEventListener("click", done);
    clear(sub); sub.classList.add("tz-edit"); sub.append(box, list, go);
    box.focus();
  });
  return s;
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
  try {
    [last, rs] = await Promise.all([api(`/api/maintenance${force ? "?force=1" : ""}`),
      api("/api/restart-schedule").catch(() => null)]);
  }
  catch (e) { if (!last) { clear(root); root.append(h("p", { class: "empty", text: e.message || "Couldn't load it." })); } return; }
  finally { loading = false; }
  render();
}

function render(force) {
  if (!last) return;
  const root = $("#maint-root");
  // A time zone being typed survives the page's own refreshes
  if (root.querySelector(".tz-edit") && !force) return;
  const open = !!(root.querySelector(".maint-last") || {}).open;   // keep the output open across refreshes
  clear(root);
  root.append(h("div", { class: "maint-grid" }, space(last), updates(last), logs(last), rs && rs.available ? restart(rs) : null));
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
