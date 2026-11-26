import { $, h, clear, api, ago, toast, fmtBytes, timePicker } from "./util.js";
import { runAction, rebootServer } from "./actions.js";
import { openUpdates, openOutput, openReleases } from "./releases.js";
import { setMaint } from "./scripts.js";

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
    // A note given as two sentences: one line on a computer, a line each on a phone
    h("div", { class: "card-foot" }, h("div", { class: "maint-foot" }, Array.isArray(note)
      ? h("span", { class: "dim note-2" }, h("span", { text: note[0] }), " ", h("span", { text: note[1] }))
      : h("span", { class: "dim", text: note || "" }), ...btns)));
}

// Phones: Free up space and Container logs fold to their title and one word on the right, like
// Scheduled server reboot: folded until opened, remembered per browser (key "aios.<id>Open")
const PHONE_Q = window.matchMedia("(max-width: 720px)");
function phoneFold(el, id, title, word) {
  if (!PHONE_Q.matches) return el;
  let open = false;
  try { open = localStorage.getItem(`aios.${id}Open`) === "1"; } catch (_) {}
  el.classList.add("mfold");
  el.classList.toggle("folded", !open);
  const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
  chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(open), onclick: () => {
    open = !open;
    try { localStorage.setItem(`aios.${id}Open`, open ? "1" : "0"); } catch (_) {}
    el.classList.toggle("folded", !open);
    tog.setAttribute("aria-expanded", String(open));
  } }, title, chev);
  el.querySelector(".card-head").replaceWith(h("div", { class: "card-head sched-head" }, h("h3", {}, tog),
    h("span", { class: "rs-word sched-fold-word fold-word " + word[1], text: word[0] })));
  return el;
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
  const worth = total > 20 * 1024 * 1024;
  const el = card("Free up space", [
    stat("Old images", fmtBytes(s.images), s.image_count ? `${s.image_count} nothing uses any more` : "None left over"),
    stat("Build leftovers", fmtBytes(s.build), "Panel rebuilds"),
    stat("System logs", fmtBytes(s.journal), "Over the 100 MB kept"),
  ], worth ? [`About ${fmtBytes(total)} can go.`, "Settings, backups and what's in use stay."] : "Nothing worth freeing right now.",
  button("maint.space", worth));
  el.classList.add("fs-spread");   // desktop: three figures spread across the card, the last at its right edge
  // Phones: Container logs under the card's foot; a computer: above it, so Free up space ends the card
  // like Scheduled server reboot's note beside it
  if (PHONE_Q.matches) el.append(logsBlock(m)); else el.insertBefore(logsBlock(m), el.querySelector(".card-foot"));
  return phoneFold(el, "space", "Free up space", worth ? [fmtBytes(total), ""] : ["Nothing to clear", "dim"]);
}

function updates(m) {
  const u = m.updates;
  if (!u.available) return card(["System updates", u.os], [stat("Waiting", "Can't tell", "This server doesn't use apt")], "", null);
  const pk = u.packages || [];
  const j = m.last && m.last.what === "Install updates" ? m.last : null;   // another job's output keeps its card at the page's foot
  // With nothing waiting and something installed, the line saying when and how the last install ended heads the preview, with
  // "Show last update" under it on a phone, and on a computer beside Show output and List updates in the card's foot
  const hasLast = !pk.some((p) => !p.phased) && u.installed && u.installed.packages.length;
  const lastDone = !PHONE_Q.matches && hasLast ? u.installed : null;
  // The lines under Waiting ("2 for security, 3 phasing in") and Checked ("The package lists") are hidden by CSS:
  // the list under the figures shows the same
  const checked = stat("Checked", u.checked_at ? ago(u.checked_at) : "Unknown", "The package lists");
  checked.classList.add("upd-checked");
  const waiting = stat("Waiting", u.count ? `${u.count} update${u.count === 1 ? "" : "s"}` : "Up to date",
      (u.count ? (u.security ? `${u.security} for security` : "None for security") + (u.phased ? `, ${u.phased} phasing in` : "")
        : u.phased ? `${u.phased} more phasing in` : ""), u.security ? "warn" : u.count ? "" : "ok",
      u.phased ? `Ubuntu rolls some updates out gradually, a few servers at a time. ${u.phased} ${u.phased === 1 ? "isn't" : "aren't"} offered to this server yet, `
        + "so Install updates leaves them until its turn, usually within days." : null);
  waiting.classList.add("upd-waiting");
  // Its explanation sits on the figure too, for a desktop card without the line under it
  if (u.phased) waiting.querySelector(".stat-value").title = waiting.querySelector(".ver-sub").title;
  const c = card(["System updates", u.os], [
    waiting,
    stat("Restart", u.reboot ? "Needed" : "Not needed", "", u.reboot ? "warn" : ""),
    checked,
  ], hasLast ? "" : lastLine(j), button("maint.updates", u.count > 0),
  // The last install's output, in the same drawer
  j ? h("button", { class: "btn small maint-list maint-out", type: "button", text: "Show output",
    title: "What the last install printed", onclick: () => openOutput(j) }) : null,
  lastDone ? lastOpen(u) : null,   // before List updates: what was installed sits beside its output
  // What's waiting, by name, in a drawer: nothing is installed from it
  h("button", { class: "btn small maint-list", type: "button", text: "List updates", disabled: !pk.length,
    title: pk.length ? "Which packages are waiting, and their versions" : "Nothing is waiting", onclick: () => openUpdates(u) }),
  u.reboot ? h("button", { class: "btn small danger", type: "button", text: "Reboot server", onclick: rebootServer,
    disabled: !!(status && status.busy) || !!(last && last.last && last.last.running) }) : null);
  c.classList.add("fs-spread");   // desktop: the three figures spread across the card, Checked at its right edge
  if (lastDone) {
    c.classList.add("upd-last-done");
    c.querySelector(".maint-foot > .maint-list").classList.add("maint-first");   // its icon starts on the card's text line
  }
  c.insertBefore(updPeek(u, pk, j), c.querySelector(".card-foot"));
  // a failed install is seen without opening anything
  if (j && !j.running && j.code !== 0) (c.querySelector(".maint-foot > .dim:not(:empty)") || c.querySelector(".upd-peek-head")).classList.add("warn");
  return c;
}

// The card's spare room on a desktop (a phone's card is long enough already, so it only gets the drawer's line): the first few waiting
// updates, as List updates shows them, or with nothing waiting, what the last install brought.
const PEEK = 4;
function peekRows(list) {
  const shown = list.slice(0, PEEK);
  const sec = shown.filter((p) => p.security), rest = shown.filter((p) => !p.security);
  const row = (p) => [
    h("span", { class: "upd-name mono", text: p.name }),
    h("span", { class: "upd-ver mono dim", title: `${p.from} → ${p.to}`, text: `${p.from} → ${p.to}` })];
  // Security updates under a label of their own (and the others under "Other" when both are shown), as in the drawer,
  // so a row needs no tag
  const label = (text, kind) => h("div", { class: "ver-label upd-peek-label" + (kind ? ` ${kind}` : ""), text });
  return h("div", { class: "upd-peek-grid" },
    ...(sec.length ? [label("Security", "sec")] : []), ...sec.flatMap(row),
    ...(sec.length && rest.length ? [label("Other")] : []), ...rest.flatMap(row));
}
// The line that opens the full list in a drawer: the list icon and a bold word, like Show output and List updates, so it
// reads as something to press. On a phone it is all there is (the rows would take half the screen); on a desktop it heads the preview.
function peekOpen(label, open) {
  const ic = h("span", { class: "upd-tog-ic", "aria-hidden": "true" });
  ic.innerHTML = '<svg viewBox="0 0 24 24"><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/></svg>';
  return h("button", { class: "upd-tog", type: "button", onclick: open }, ic, label);
}
// A computer's button for what the last update installed: beside Show output and List updates, the list icon and the words
function lastOpen(u) {
  const ic = h("span", {});
  ic.innerHTML = '<svg class="bi" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/></svg>';
  return h("button", { class: "btn small maint-list btn-i", type: "button", title: "What the last update installed", onclick: () => openUpdates(u, true) },
    ic.firstChild, h("span", { text: "Show last update" }));   // no time: the heading above already says when
}
function updPeek(u, pk, j) {
  const now = pk.filter((p) => !p.phased);
  if (now.length) {
    const hidden = Math.max(0, now.length - PEEK);
    const bits = [hidden ? `${hidden} more waiting` : "", u.phased ? `${u.phased} phasing in` : ""].filter(Boolean).join(", ");
    const open = () => openUpdates(u);
    if (PHONE_Q.matches) return h("div", { class: "upd-peek upd-peek-row" }, peekOpen("What's waiting", open));
    return h("div", { class: "upd-peek" },
      h("p", { class: "upd-peek-head" }, peekOpen("What's waiting", open)), peekRows(now),
      bits ? h("button", { class: "linkish upd-more", type: "button", text: bits, onclick: open }) : null);
  }
  const done = u.installed;
  const phasing = u.phased ? ` ${u.phased} more ${u.phased === 1 ? "is" : "are"} phasing in.` : "";
  if (!done || !done.packages.length) return h("div", { class: "upd-peek empty" }, h("p", { class: "dim", text: `Nothing waiting.${phasing}` }));
  const more = done.count - PEEK;
  const when = `${done.at ? ` ${ago(done.at)}` : ""}${done.auto ? ", by Ubuntu's automatic updates" : ""}`;
  const open = () => openUpdates(u, true);
  // The heading says how the last install ended; the button that opens it is under it on a phone, in the card's foot on a computer
  const head = j ? lastLine(j) : `Last update${when}`;
  if (PHONE_Q.matches) return h("div", { class: "upd-peek upd-peek-row" }, h("p", { class: "upd-peek-head" }, head), peekOpen("Show last update", open));
  return h("div", { class: "upd-peek" },
    h("p", { class: "upd-peek-head" }, head, phasing ? h("span", { class: "dim", text: phasing }) : null),
    peekRows(done.packages),
    more > 0 ? h("button", { class: "linkish upd-more", type: "button", text: `${more} more installed`, onclick: open }) : null);
}

// Container logs as the foot of Free up space, a line above it: its state on the right, what it
// uses and Set limits under it. Not set stays in view on a folded phone card (amber).
function logsBlock(m) {
  const l = m.logs;
  const word = l.limited ? ["Limit set", "ok"] : ["Not set", "warn"];
  const what = !l.limited ? `Using ${fmtBytes(l.size)}, with no size limit.`
    : l.pending ? `Using ${fmtBytes(l.size)}. 10 MB per container; some take it when next recreated.` : `Using ${fmtBytes(l.size)}, at most 10 MB per container.`;
  const blk = h("div", { class: "cl-block" + (l.limited ? "" : " cl-keep") },
    h("div", { class: "cl-line" }, h("span", { class: "ver-label", text: "Container logs" }), h("span", { class: "cl-word " + word[1], text: word[0] })),
    h("div", { class: "maint-foot" }, h("span", { class: "dim", text: what }), l.limited ? null : button("maint.logs", true)));
  return blk;
}

// Scheduled server reboot: setup-maintenance.sh's timer restarts the server at a set time, only when an
// update needs it or every time. With it, the clock that time goes by, and its time zone.
const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
let rs = null, editing = false;
// Phones: whether Scheduled server reboot is open (folded until opened, remembered per browser)
let rebootOpen = false;
try { rebootOpen = localStorage.getItem("aios.rebootOpen") === "1"; } catch (_) {}
// The card is a list: Schedule, Clock, then Next reboot and Last, each with its state on the
// right and its controls under it. On a phone the buttons are full width under the controls;
// on a desktop they sit at the end of the controls' row.
const PHONE = window.matchMedia("(max-width: 720px)");
PHONE.addEventListener("change", () => { if (last) render(true); });

function restart(r) {
  const on = r.mode !== "off";
  const when = r.every === "daily" ? `Daily ${r.time}` : `${DAYS[r.day - 1]} ${r.time}`;
  const next = !on ? stat("Next reboot", "Off", "Reboots are up to you")
    : !r.timer ? stat("Next reboot", "Not running", "Press Set to start it again", "warn")
    : stat("Next reboot", when, r.mode === "always" ? "Every time" : r.needed ? "An update needs one" : "Only if needed");
  const l = r.last;
  const last = stat("Last", l ? ago(l.at) : "Not yet",
    !l ? "" : l.status === "restarted" ? "Restarted" : /^Not needed/.test(l.text) ? "Skipped: not needed" : "Skipped", "", l ? l.text : null);
  const phone = PHONE.matches;
  const cards = [next, last];

  const mode = h("select", { class: "input", "aria-label": "When" },
    ...[["off", "Off"], ["needed", "When needed"], ["always", "Always"]].map(([v, t]) => h("option", { value: v, text: t })));
  const every = h("select", { class: "input", "aria-label": "How often" },
    ...[["daily", "Daily"], ["weekly", "Weekly"]].map(([v, t]) => h("option", { value: v, text: t })));
  const day = h("select", { class: "input", "aria-label": "Day" }, ...DAYS.map((d, i) => h("option", { value: String(i + 1), text: d.slice(0, 3) })));
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
    // Schedule: On, Off or Not running, then its choices and Set; Clock: Synced or not, then the time zone
    // (why it isn't synced in its tooltip)
    const word = !on ? ["Off", "dim"] : !r.timer ? ["Not running", "warn"] : ["On", "ok"];
    const c = r.clock;
    const clock = !c.known ? ["Can't tell", "dim"] : c.synced ? ["Synced", "ok"] : ["Not synced", "warn"];
    const [tzWrap, tzGo] = tzEditor(r, true);
    if (!phone) tzGo.classList.remove("rs-wide");
    if (ntp && phone) ntp.classList.add("rs-wide");
    const sched = h("div", { class: "rs-block" },
      h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: "Schedule" }), h("span", { class: "rs-word " + word[1], text: word[0] })),
      h("div", { class: "rs-ctl" }, h("div", { class: "wd-when-row restart-row" }, mode, every, onLbl, day, atLbl, time), setBtn));
    // Once a choice is changed or a zone typed, the page's own refreshes leave the card alone until Set
    // On a phone the title folds the card to one line with Schedule's state beside it, as on Scheduled
    // backups: folded until opened, remembered per browser. A clock out of sync or a warning still shows.
    const cardEl = h("section", { class: "panel maint-card rs-list " + (phone ? "rs-phone" : "rs-desk") + (phone && !rebootOpen ? " folded" : ""),
      oninput: () => { editing = true; }, onchange: () => { editing = true; } });
    let head = h("div", { class: "card-head" }, h("h3", { text: "Scheduled server reboot" }));
    if (phone) {
      const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
      chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
      const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(rebootOpen), onclick: () => {
        rebootOpen = !rebootOpen;
        try { localStorage.setItem("aios.rebootOpen", rebootOpen ? "1" : "0"); } catch (_) {}
        cardEl.classList.toggle("folded", !rebootOpen);
        tog.setAttribute("aria-expanded", String(rebootOpen));
      } }, "Scheduled server reboot", chev);
      head = h("div", { class: "card-head sched-head" }, h("h3", {}, tog), h("span", { class: "rs-word sched-fold-word " + word[1], text: word[0] }));
    }
    const clockBlk = h("div", { class: "rs-block" },
      h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: "Clock" }), h("span", { class: "rs-word " + clock[1], text: clock[0],
        title: c.known && !c.synced ? (c.ntp ? "Time sync is on but hasn't reached a time server yet." : "Time sync is off, so the clock can drift.") : null })),
      h("div", { class: "rs-ctl" }, tzWrap, tzGo, ntp));
    const stats = h("div", { class: "stat-grid" }, ...cards);
    // Schedule first, as on Backup & Restore's Scheduled backups, then Clock; Next reboot and Last close the card
    cardEl.append(head, sched, clockBlk, stats,
      ...(note.textContent ? [h("div", { class: "card-foot" }, h("div", { class: "maint-foot" }, note))] : []));
    // Clock kept in view on a folded card when it's out of sync
    if (clock[1] === "warn") clockBlk.classList.add("rs-keep");
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
        onmousedown: (e) => { e.preventDefault(); fill(z); } })));
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
      pick = -1; draw(); ready();
    });
    box.addEventListener("blur", close);
    // Set changes the zone; picking a suggestion only fills the box, and Set stays greyed until it has something
    const go = h("button", { class: "btn small" + (phone ? " rs-wide" : ""), type: "button", text: phone ? "Set time zone" : "Set", disabled: true });
    const ready = () => { go.disabled = !box.value.trim(); };
    const fill = (z) => { box.value = z; close(); ready(); };
    const done = async () => {
      const tz = box.value.trim();
      if (!tz) return;
      go.disabled = true;
      try {
        const n = await api("/api/server/timezone", { method: "PUT", body: JSON.stringify({ timezone: tz }) });
        toast(`Time zone: ${n.timezone}.`);
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
        // Enter on a highlighted suggestion picks it; Enter on a filled box sets it, as a form would
        if (pick >= 0) fill(shown[pick]); else { close(); done(); }
      } else if (e.key === "Escape") {
        if (shown.length) close(); else { box.value = ""; render(true); }
      }
    });
    go.addEventListener("click", done);
    return [h("span", { class: "tz-wrap" }, box, list), go, box];
  }
}

// Caddy and the Cloudflare Tunnel's cloudflared, each with its version, whether a newer release is out
// (with its notes), and its own Update; then whether they update by themselves each month (off unless
// chosen). Without a tunnel the card is Caddy's alone.
let proxOpen = false;
try { proxOpen = localStorage.getItem("aios.proxOpen") === "1"; } catch (_) {}
function upIcon() {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox", "0 0 24 24"); s.setAttribute("aria-hidden", "true"); s.setAttribute("class", "st-i");
  s.innerHTML = '<path d="M12 19V5"/><path d="m5 12 7-7 7 7"/>';
  return s;
}
function proxies(m) {
  const p = m.proxies;
  if (!p) return null;
  const phone = PHONE.matches;
  const newer = p.items.filter((i) => i.newer);
  const cardEl = h("section", { class: "panel maint-card rs-list prox-card " + (phone ? "rs-phone" : "rs-desk") + (phone && !proxOpen ? " folded" : "") });
  const word = newer.length ? [`${newer.length} update${newer.length === 1 ? "" : "s"}`, "warn"] : ["Up to date", "ok"];
  const tunnel = p.items.length > 1;
  const title = tunnel ? "Caddy and Cloudflare" : "Caddy";
  let head = h("div", { class: "card-head" }, h("h3", { text: title }));
  if (phone) {
    const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
    chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
    const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(proxOpen), onclick: () => {
      proxOpen = !proxOpen;
      try { localStorage.setItem("aios.proxOpen", proxOpen ? "1" : "0"); } catch (_) {}
      cardEl.classList.toggle("folded", !proxOpen);
      tog.setAttribute("aria-expanded", String(proxOpen));
    } }, title, chev);
    head = h("div", { class: "card-head sched-head" }, h("h3", {}, tog), h("span", { class: "rs-word sched-fold-word " + word[1], text: word[0] }));
  }
  cardEl.append(head);
  const busy = !!(status && status.busy) || !!(last && last.last && last.last.running);
  for (const i of p.items) {
    const fresh = i.newer;
    const state = fresh ? h("span", { class: "rs-word warn" }, upIcon(), `${i.latest} available`)
      : i.running ? h("span", { class: "rs-word ok", text: "Up to date" }) : h("span", { class: "rs-word dim", text: "Not running" });
    const a = ((status && status.actions) || []).find((x) => x.id === `maint.${i.id}`);
    const btn = h("button", { class: "btn small" + (fresh ? " primary" : "") + (phone ? " rs-wide" : ""), type: "button", text: "Update",
      disabled: busy || !a || !a.available,
      title: !a || !a.available ? "This server's scripts are from before this button. Update them on the Scripts tab."
        : fresh ? `Update ${i.name} to ${i.latest}. The one it replaces comes back if the new one doesn't work.` : null,
      // Like the Overview and VPN: up to date (and the check worked) just says so, as elsewhere in the panel
      onclick: () => (!fresh && i.running && i.latest ? toast(`${i.name} is up to date (${i.running}). Nothing to do.`) : runAction(a)) });
    const notes = h("button", { class: "btn small quiet prox-notes", type: "button", text: "All releases",
      onclick: () => releaseNotes(i) });
    const blk = h("div", { class: "rs-block" },
      h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: i.name }), state),
      h("div", { class: "rs-ctl" }, h("span", { class: "prox-ver" }, h("span", { class: "mono", text: i.running || "Unknown" }),
        h("span", { class: "dim", text: " · " }), notes), btn));
    if (fresh) blk.classList.add("rs-keep");   // a folded phone card still shows what's waiting
    // A computer, Caddy alone: the state word on the title's line (its own spot kept empty, so nothing moves)
    if (!phone && !tunnel) head.append(state.cloneNode(true));
    cardEl.append(blk);
  }
  const auto = h("select", { class: "input", "aria-label": "Automatic updates", disabled: !p.can_auto,
    title: p.can_auto ? null : "This server's scripts are from before automatic updates. Update them on the Scripts tab." },
    h("option", { value: "off", text: "Only when I press Update" }), h("option", { value: "monthly", text: "Automatically, once a month" }));
  auto.value = p.auto;
  const both = tunnel ? "Caddy and the tunnel" : "Caddy";
  auto.addEventListener("change", async () => {
    auto.disabled = true;
    try {
      last.proxies = await api("/api/auto-updates", { method: "PUT", body: JSON.stringify({ mode: auto.value }) });
      setMaint(last);
      toast(auto.value === "off" ? `${both} update only when you press Update.`
        : `${both} update by themselves once a month, on the first Wednesday at 03:15 server time. Activity says when.`);
    } catch (e) { toast(e.message || "Couldn't change it."); }
    render(true);
  });
  const autoWord = p.auto !== "monthly" ? ["Off", "dim"] : p.timer ? ["Monthly", "ok"] : ["Not running", "warn"];
  // Beside the select, so switching it never changes the card's height (the foot stays one line)
  const autoNote = p.auto !== "monthly" ? "Nothing updates until you press Update."
    : "First Wednesday of the month at 03:15." + (p.last ? ` Last run ${ago(p.last.at)}: ${p.last.text}` : "");
  cardEl.append(h("div", { class: "rs-block prox-auto-block" + (autoWord[1] === "warn" ? " rs-keep" : "") },
    h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: "Automatic updates" }), h("span", { class: "rs-word " + autoWord[1], text: autoWord[0] })),
    h("div", { class: "rs-ctl" }, auto, h("span", { class: "dim prox-auto", text: autoNote }))));
  const check = h("button", { class: "btn small", type: "button", text: "Check now", onclick: async () => {
    check.disabled = true;
    try { last.proxies = await api("/api/proxies?force=1"); setMaint(last); } catch (e) { toast(e.message || "Couldn't check."); }
    render(true);
  } });
  cardEl.append(h("div", { class: "card-foot" }, h("div", { class: "maint-foot" },
    h("span", { class: "dim", text: p.error ? `Couldn't check for new releases: ${p.error}`
      : `Checked ${ago(p.checked_at)}. If an update fails, the earlier version comes back.` }),
    check)));
  return cardEl;
}

// Its releases from GitHub in the release drawer, with the running one marked
async function releaseNotes(i) {
  try {
    const rel = await api(`/api/${i.id}-releases`);
    openReleases({ ...rel, name: i.id === "caddy" ? "Caddy" : "cloudflared",
      page: i.id === "caddy" ? "https://github.com/caddyserver/caddy/releases" : "https://github.com/cloudflare/cloudflared/releases" }, i.running || "");
  } catch (e) { toast(e.message || "Couldn't load the release notes."); }
}

// How the last job ended: it may have outlived a panel restart (Docker restarts it)
// The updates card's quiet line: what the last install did, amber when it failed
function lastLine(j) {
  if (!j) return "";
  const when = `${j.running ? "started " : ""}${ago(j.at)}`;
  return j.running ? `Installing, ${when}` : j.code === 0 ? `Last install ${when}, finished` : `Last install ${when} failed`;
}

function lastRun(m) {
  const j = m.last;
  if (!j || j.what === "Install updates") return null;   // shown by the System updates card
  const state = j.running ? ["Running", ""] : j.code === 0 ? ["Finished", "ok"] : ["Failed", "bad"];
  // What ran and when, its state at the right like a card's, then a plain Show output toggle
  const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
  chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  return h("details", { class: "panel maint-last" },
    h("summary", {},
      h("span", { class: "ml-head" }, h("span", { class: "ml-what", text: `${j.what}, ${j.running ? "started " : ""}${ago(j.at)}` }),
        h("span", { class: "chip small-chip " + state[1], text: state[0] })),
      h("span", { class: "ml-toggle" }, h("span", { class: "ml-show", text: "Show output" }),
        h("span", { class: "ml-hide", text: "Hide output" }), chev)),
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
  setMaint(last);
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
  root.append(h("div", { class: "maint-grid" }, updates(last), proxies(last), rs && rs.available ? restart(rs) : null, space(last)));
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
