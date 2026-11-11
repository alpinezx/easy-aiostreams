import { $, h, clear, api, ago, toast, fmtBytes, timePicker } from "./util.js";
import { runAction, rebootServer } from "./actions.js";
import { openUpdates } from "./releases.js";

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
  // A title can carry a quiet word on its right: System updates' system
  const [name, corner] = Array.isArray(title) ? title : [title, ""];
  return h("section", { class: "panel maint-card" },
    h("div", { class: "card-head" }, h("h3", { text: name }), corner ? h("span", { class: "dim card-corner", text: corner }) : null),
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
  if (!u.available) return card(["System updates", u.os], [stat("Waiting", "Can't tell", "This server doesn't use apt")], "", null);
  const pk = u.packages || [];
  const c = card(["System updates", u.os], [
    stat("Waiting", u.count ? `${u.count} update${u.count === 1 ? "" : "s"}` : "Up to date",
      (u.count ? (u.security ? `${u.security} for security` : "None for security") + (u.phased ? `, ${u.phased} more phasing in` : "")
        : u.phased ? `${u.phased} more phasing in` : ""), u.security ? "warn" : u.count ? "" : "ok",
      u.phased ? `Ubuntu rolls some updates out gradually, a few servers at a time. ${u.phased} ${u.phased === 1 ? "isn't" : "aren't"} offered to this server yet, `
        + "so Install updates leaves them until its turn, usually within days." : null),
    stat("Restart", u.reboot ? "Needed" : "Not needed", u.reboot ? "To finish installing updates" : "", u.reboot ? "warn" : ""),
    stat("Checked", u.checked_at ? ago(u.checked_at) : "Unknown", "The package lists"),
  ], "", button("maint.updates", u.count > 0),
  // What's waiting, by name, in a drawer: nothing is installed from it
  h("button", { class: "btn small", type: "button", text: "List updates", disabled: !pk.length,
    title: pk.length ? "Which packages are waiting, and their versions" : "Nothing is waiting", onclick: () => openUpdates(u) }),
  u.reboot ? h("button", { class: "btn small danger", type: "button", text: "Reboot server", onclick: rebootServer,
    disabled: !!(status && status.busy) || !!(last && last.last && last.last.running) }) : null);
  c.insertBefore(updPeek(u, pk), c.querySelector(".card-foot"));
  return c;
}

// The card's spare room on a desktop (a phone's card is long enough already): the first few waiting
// updates, as List updates shows them, or with nothing waiting, what the last install brought.
const PEEK = 4;
function peekRows(list) {
  return h("div", { class: "upd-peek-grid" }, ...list.slice(0, PEEK).flatMap((p) => [
    h("span", { class: "upd-name mono", text: p.name }),
    h("span", {}, p.security ? h("span", { class: "chip warn small-chip", text: "Security" }) : null),
    h("span", { class: "upd-ver mono dim", title: `${p.from} → ${p.to}`, text: `${p.from} → ${p.to}` })]));
}
function updPeek(u, pk) {
  const now = pk.filter((p) => !p.phased);
  if (now.length) {
    const more = now.length - PEEK + (u.phased || 0);
    return h("div", { class: "upd-peek" }, peekRows(now),
      more > 0 ? h("button", { class: "linkish upd-more", type: "button", text: `and ${more} more`, onclick: () => openUpdates(u) }) : null);
  }
  const done = u.installed;
  const phasing = u.phased ? ` ${u.phased} more ${u.phased === 1 ? "is" : "are"} phasing in.` : "";
  if (!done || !done.packages.length) return h("div", { class: "upd-peek empty" }, h("p", { class: "dim", text: `Nothing waiting.${phasing}` }));
  const more = done.count - PEEK;
  return h("div", { class: "upd-peek" },
    h("p", { class: "dim upd-peek-head", text: `Up to date.${phasing} Last installed${done.at ? ` ${ago(done.at)}` : ""}${done.auto ? ", by Ubuntu's automatic updates" : ""}:` }),
    peekRows(done.packages),
    more > 0 ? h("button", { class: "linkish upd-more", type: "button", text: `and ${more} more`, onclick: () => openUpdates(u, true) }) : null);
}

function logs(m) {
  const l = m.logs;
  const sub = !l.limited ? "They can grow without limit" : l.pending ? "Some containers take it when next recreated" : "10 MB per container";
  return card("Container logs", [
    stat("Size limit", l.limited ? "Set" : "Not set", sub, l.limited ? "ok" : "warn"),
    stat("Using now", fmtBytes(l.size), "All containers together"),
  ], l.limited ? "" : "Setting it restarts every container once: a few seconds of downtime.", l.limited ? null : button("maint.logs", true));
}

// Scheduled server reboot: setup-maintenance.sh's timer restarts the server at a set time, only when an
// update needs it or every time. With it, the clock that time goes by, and its time zone.
const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
let rs = null, editing = false;
// The card is a list: Next reboot and Last, then Schedule and Clock, each with its state on the
// right and its controls under it. On a phone the buttons are full width under the controls;
// on a desktop they sit at the end of the controls' row.
const PHONE = window.matchMedia("(max-width: 720px)");
PHONE.addEventListener("change", () => { if (last) render(true); });

function restart(r) {
  const on = r.mode !== "off";
  const when = r.every === "daily" ? `Daily ${r.time}` : `${DAYS[r.day - 1]} ${r.time}`;
  const next = !on ? stat("Next reboot", "Off", "Reboots are up to you")
    : !r.timer ? stat("Next reboot", "Not running", "Press Set to start it again", "warn")
    : stat("Next reboot", when, r.mode === "always" ? "Every time" : r.needed ? "An update needs one" : "Only if an update needs one");
  const l = r.last;
  const last = stat("Last", l ? ago(l.at) : "Not yet",
    !l ? "" : l.status === "restarted" ? "Restarted" : /^Not needed/.test(l.text) ? "Skipped: not needed" : "Skipped", "", l ? l.text : null);
  const phone = PHONE.matches;
  const cards = [next, last];

  const mode = h("select", { class: "input", "aria-label": "When" },
    ...[["off", "Off"], ["needed", "When needed"], ["always", "Always"]].map(([v, t]) => h("option", { value: v, text: t })));
  const every = h("select", { class: "input", "aria-label": "How often" },
    ...[["daily", "Daily"], ["weekly", "Weekly"]].map(([v, t]) => h("option", { value: v, text: t })));
  const day = h("select", { class: "input", "aria-label": "Day" }, ...DAYS.map((d, i) => h("option", { value: String(i + 1), text: d })));
  const time = timePicker(r.time);
  const onLbl = h("span", { class: "dim", text: "on" }), atLbl = h("span", { class: "dim", text: "at" });
  mode.value = r.mode; every.value = r.every; day.value = String(r.day);
  const setBtn = h("button", { class: "btn small" + (phone ? " rs-wide" : ""), type: "button", text: "Set schedule" });
  const show = () => {
    const o = mode.value !== "off";
    for (const el of [every, atLbl, time, setBtn]) el.hidden = !o;
    onLbl.hidden = day.hidden = !o || every.value !== "weekly";
    // Each box says what it is, so the little words go
    onLbl.hidden = atLbl.hidden = true;
  };
  const save = async (body) => {
    setBtn.disabled = mode.disabled = true;
    try {
      const n = await api("/api/restart-schedule", { method: "PUT", body: JSON.stringify(body) });
      toast(n.mode === "off" ? "Scheduled server reboot: off."
        : `Scheduled server reboot: ${n.mode === "always" ? "always" : "when needed"}, ${n.every === "daily" ? `daily at ${n.time}` : `${DAYS[n.day - 1]}s at ${n.time}`}.`);
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

  // With no time sync service at all (some Debian images) there's nothing to switch on, so say how to add one
  const noSync = r.clock.known && !r.clock.synced && !r.clock.can_ntp;
  const note = r.toolkit
    ? h("span", { class: "warn", text: `linux-aio-toolkit also restarts this server, ${r.toolkit}. Remove one so they don't both run.` })
    : noSync ? h("span", { class: "warn", text: "The clock isn't kept in sync: this server has no time sync service. Over SSH: sudo apt install systemd-timesyncd" })
    : h("span", { class: "dim", text: on ? "Never during a backup or an update. Phone alerts says it was planned." : "" });
  const ntp = r.clock.known && !r.clock.ntp && r.clock.can_ntp
    ? h("button", { class: "btn small", type: "button", text: "Turn on time sync", onclick: async (e) => {
      e.target.disabled = true;
      try { await api("/api/server/ntp", { method: "POST", body: "{}" }); toast("Time sync: on."); rs = await api("/api/restart-schedule"); }
      catch (err) { toast(err.message || "Couldn't switch it on.", true); }
      render(true);
    } }) : null;
  {
    // Schedule: Active, Off or Not running, then its choices and Set; Clock: Synced or not, then the time zone
    // (why it isn't synced in its tooltip)
    const word = !on ? ["Off", "dim"] : !r.timer ? ["Not running", "warn"] : ["Active", "ok"];
    const c = r.clock;
    const clock = !c.known ? ["Can't tell", "dim"] : c.synced ? ["Synced", "ok"] : ["Not synced", "warn"];
    const [tzWrap, tzGo] = tzEditor(r, true);
    if (!phone) tzGo.classList.remove("rs-wide");
    if (ntp && phone) ntp.classList.add("rs-wide");
    // Once a choice is changed or a zone typed, the page's own refreshes leave the card alone until Set
    const cardEl = h("section", { class: "panel maint-card rs-list " + (phone ? "rs-phone" : "rs-desk"),
      oninput: () => { editing = true; }, onchange: () => { editing = true; } },
      h("div", { class: "card-head" }, h("h3", { text: "Scheduled server reboot" })),
      h("div", { class: "stat-grid" }, ...cards),
      h("div", { class: "rs-block" },
        h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: "Schedule" }), h("span", { class: "rs-word " + word[1], text: word[0] })),
        h("div", { class: "rs-ctl" }, h("div", { class: "wd-when-row restart-row" }, mode, every, onLbl, day, atLbl, time), setBtn)),
      h("div", { class: "rs-block" },
        h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: "Clock" }), h("span", { class: "rs-word " + clock[1], text: clock[0],
          title: c.known && !c.synced ? (c.ntp ? "Time sync is on but hasn't reached a time server yet." : "Time sync is off, so the clock can drift.") : null })),
        h("div", { class: "rs-ctl" }, tzWrap, tzGo, ntp)),
      note.textContent ? h("div", { class: "card-foot" }, h("div", { class: "maint-foot" }, note)) : null);
    return cardEl;
  }
}

// The time zone box and its Set button. Our own list of suggestions rather than the browser's, so it
// looks like the panel: up to 8 zones matching what's typed, a city's start first ("paris", "new
// york"). The zone in use is its placeholder.
function tzEditor(r, phone) {
  {
    let zones = [], shown = [], pick = -1;
    const box = h("input", { class: "input tz-box", type: "text", autocomplete: "off", spellcheck: "false", role: "combobox",
      "aria-autocomplete": "list", "aria-expanded": "false", placeholder: (phone && r.timezone) || "Europe/London",
      "aria-label": phone && r.timezone ? `Time zone, now ${r.timezone}` : "Time zone, for example Europe/London" });
    // Its zones load the first time it's used
    let asked = false;
    box.addEventListener("focus", () => { if (!asked) { asked = true; api("/api/server/timezones").then((z) => { zones = z; }).catch(() => {}); } });
    const list = h("ul", { class: "tz-sugg", role: "listbox", hidden: true });
    const draw = () => {
      clear(list);
      shown.forEach((z, i) => list.append(h("li", { role: "option", class: i === pick ? "on" : "", "aria-selected": String(i === pick), text: z.replace(/_/g, " "),
        onmousedown: (e) => { e.preventDefault(); box.value = z; close(); done(); } })));
      list.hidden = !shown.length;
      box.setAttribute("aria-expanded", String(!list.hidden));
    };
    const close = () => { shown = []; pick = -1; draw(); };
    box.addEventListener("input", () => {
      const q = box.value.trim().toLowerCase().replace(/ /g, "_");
      const rank = (z) => { const l = z.toLowerCase(), city = l.slice(l.lastIndexOf("/") + 1);
        return city.startsWith(q) ? 0 : l.startsWith(q) ? 1 : l.includes(q) ? 2 : 3; };
      shown = q ? zones.map((z) => [rank(z), z]).filter(([r]) => r < 3).sort((a, b) => a[0] - b[0] || a[1].localeCompare(b[1]))
        .slice(0, 8).map(([, z]) => z) : [];
      pick = -1; draw();
    });
    box.addEventListener("blur", close);
    const go = h("button", { class: "btn small" + (phone ? " rs-wide" : ""), type: "button", text: phone ? "Set time zone" : "Set" });
    const done = async () => {
      const tz = box.value.trim();
      if (!tz) return;
      go.disabled = true;
      try {
        const n = await api("/api/server/timezone", { method: "PUT", body: JSON.stringify({ timezone: tz }) });
        toast(`Time zone: ${n.timezone}. Scheduled backups and reboots now go by it.`);
        rs = await api("/api/restart-schedule");
      } catch (e) { toast(e.message || "Couldn't set it.", true); go.disabled = false; return; }
      render(true);
    };
    box.addEventListener("keydown", (e) => {
      if ((e.key === "ArrowDown" || e.key === "ArrowUp") && shown.length) {
        e.preventDefault();
        pick = (pick + (e.key === "ArrowDown" ? 1 : shown.length - 1)) % shown.length;
        draw();
      } else if (e.key === "Enter") {
        if (pick >= 0) box.value = shown[pick];
        close(); done();
      } else if (e.key === "Escape") {
        if (shown.length) close(); else { box.value = ""; render(true); }
      }
    });
    go.addEventListener("click", done);
    return [h("span", { class: "tz-wrap" }, box, list), go, box];
  }
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
  // A schedule being chosen or a time zone being typed survives the page's own refreshes
  if (editing && !force) return;
  editing = false;
  const open = !!(root.querySelector(".maint-last") || {}).open;   // keep the output open across refreshes
  clear(root);
  root.append(h("div", { class: "maint-grid" }, updates(last), rs && rs.available ? restart(rs) : null, space(last), logs(last)));
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
