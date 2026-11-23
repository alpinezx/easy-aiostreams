import { $, h, clear, api, ago, fmtBytes, toast, timePicker } from "./util.js";
import { openJob, runAction, ask } from "./actions.js";

// A backup's file name with a break allowed after each hyphen. The browser won't break a hyphen that's followed
// by a digit (scheduled-20261119), so a long name would otherwise split mid-word (".tar.g" and "z").
const nameParts = (s) => s.split(/(?<=-)/).flatMap((p, i) => (i ? [h("wbr"), p] : [p]));

// The panel reads each backup's build in the background; look again a few times while it does.
let buildTimer = null, buildTries = 0;
// This server's public IP for the scp command, looked up once per page load. null: not found.
let serverIp;

// What the phone-alerts watchdog noticed on its own, shown in the same list when it's set up.
// Pill words and colours for each kind of event.
const ALERT_KIND = {
  fail: ["Failed", "warn"], alert: ["Alert sent", "bad"], recovered: ["Recovered", "ok"],
  start: ["Started", ""], stop: ["Stopped", ""], test: ["Test alert", ""], topic: ["Topic", ""], reboot: ["Restarted", ""], disk: ["Disk space", ""], cert: ["Certificate", ""],
  update: ["Update", ""], scripts: ["Scripts", ""], backup: ["Backup", ""], security: ["Security", ""], weekly: ["Weekly", ""],
};
const BIN = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/></svg>';

// All, Actions (what you started) or Alerts (what the watchdog noticed). Only shown with phone alerts set up.
let filter = "all";
try { filter = localStorage.getItem("aios.activityFilter") || "all"; } catch (_) {}
// The filter card above the list: free text, and the OK / WARN / ERROR chips (none pressed shows everything)
let query = "";
const states = new Set();
let wired = false;

const binButton = (title, label, disabled, onclick) => {
  const x = h("button", { class: "btn small quiet job-x", type: "button", title, "aria-label": label, disabled, onclick });
  x.innerHTML = BIN;
  return x;
};

let lastStatus = null;
export async function showActivity(status) {
  lastStatus = status;
  const box = $("#jobs"); clear(box);
  const alertsOn = !!(status && status.watchdog && status.watchdog.configured);
  if (!alertsOn) filter = "all";
  const [jobs, events] = await Promise.all([
    api("/api/jobs"),
    alertsOn ? api("/api/watchdog").then((w) => w.events || [], () => []) : [],
  ]);
  clear(box);   // only now, so typing in the filter doesn't blink the list
  const showJobs = filter !== "alerts", showEvents = alertsOn && filter !== "actions";

  const show = $("#act-show");
  show.hidden = !alertsOn;
  show.value = filter;
  if (!wired) {
    wired = true;
    const again = () => showActivity(lastStatus).catch(() => {});
    show.addEventListener("change", () => {
      filter = show.value;
      try { localStorage.setItem("aios.activityFilter", filter); } catch (_) {}
      again();
    });
    // Each look asks the server again (the watchdog's part runs commands on the host), so typing waits for a pause
    let typing = null;
    $("#act-filter").addEventListener("input", (e) => {
      query = e.target.value.trim().toLowerCase();
      clearTimeout(typing);
      typing = setTimeout(again, 250);
    });
    // a row whose text wraps puts its group on a line of its own (see markWraps): re-measure when the list changes size or is shown
    if (window.ResizeObserver) new ResizeObserver(markWraps).observe(box);
    for (const b of $("#act-states").querySelectorAll("button")) {
      b.addEventListener("click", () => {
        const on = b.getAttribute("aria-pressed") !== "true";
        b.setAttribute("aria-pressed", String(on));
        if (on) states.add(b.dataset.st); else states.delete(b.dataset.st);
        again();
      });
    }
  }

  const cb = $("#clear-activity");
  cb.disabled = !((showJobs && jobs.some((j) => j.ended)) || (showEvents && events.length));
  cb.onclick = async () => {
    const what = showJobs && showEvents ? "the list of finished actions, their saved output and the phone alerts history"
      : showEvents ? "the phone alerts history" : "the list of finished actions and their saved output";
    const ok = await ask({ title: "Clear activity?", confirmLabel: "Clear", danger: true,
      body: `This removes ${what}. Anything still running stays. The watchdog keeps checking, and the 14-day strip on Phone alerts stays.` });
    if (!ok) return;
    try {
      if (showJobs) await api("/api/jobs", { method: "DELETE" });
      if (showEvents) await api("/api/watchdog/events/clear", { method: "POST" });
      toast("Activity cleared.");
    } catch (e) { toast(e.message || "Couldn't clear it.", true); }
    showActivity(status).catch(() => {});
  };

  // One list, newest first. Jobs carry their start time, events theirs, both in epoch seconds.
  const rows = [];
  if (showJobs) for (const j of jobs) rows.push({ at: j.started, job: j });
  if (showEvents) for (const e of events) rows.push({ at: e.at, event: e });
  rows.sort((a, b) => b.at - a.at);
  const tone = (r) => r.event ? (ALERT_KIND[r.event.kind] || ["", ""])[1] : !r.job.ended ? "run" : r.job.code === 0 ? "ok" : "bad";
  // OK holds everything that went fine or is just a note (Started, Test alert, Running), like INFO in Logs
  const group = (r) => { const t = tone(r); return t === "warn" || t === "bad" ? t : "ok"; };
  const words = (r) => r.event ? `${r.event.text} phone alerts ${(ALERT_KIND[r.event.kind] || [r.event.kind])[0]}`
    : `${r.job.label} ${actionGroup(r.job.action)} ${tone(r) === "ok" ? "done" : tone(r) === "bad" ? "failed" : "running"}`;
  const total = rows.length;
  for (let k = rows.length - 1; k >= 0; k--) {
    if ((states.size && !states.has(group(rows[k]))) || (query && !words(rows[k]).toLowerCase().includes(query))) rows.splice(k, 1);
  }

  if (!rows.length) {
    const text = total ? "Nothing matches that filter." : filter === "alerts" ? "No phone alerts events yet. Failed checks, alerts and recoveries show here."
      : filter === "actions" || !alertsOn ? "Nothing has run from here yet. Actions you start on the Overview page show up in this list."
        : "Nothing yet. Actions you start and phone alerts events show up in this list.";
    box.append(h("p", { class: "empty", style: null, text }));
    box.lastChild.style.padding = "18px 16px";
    return;
  }
  // A log line: when (a pill, like Logs), a dot for how it went, then what happened. Done and Recovered are a
  // plain green dot; anything else also says its word, so the colour never carries it alone.
  const line = (at, tone, word, open, group, extra) => {
    const dot = h("span", { class: "lg-dot " + (tone || "neutral"), role: "img", "aria-label": word, title: word });
    return h("div", { class: "item job act-ln t-" + (tone || "neutral") + (tone === "warn" || tone === "bad" ? " " + tone : "") + extra },
      dot, open,
      // desktop: time, then name, then group (display: contents + order); a phone: line two, time then group
      h("span", { class: "act-sub" },
        h("span", { class: "lg-time", title: new Date(at * 1000).toLocaleString(), text: ago(at) }),
        h("span", { class: "act-grp dim", text: group })));
  };
  for (const { job: j, event: e } of rows) {
    if (e) {
      // An alert: nothing to open, so the row isn't a button
      const [name, cls] = ALERT_KIND[e.kind] || [e.kind, ""];
      const row = line(e.at, cls, name,
        h("span", { class: "job-open" }, h("span", { class: "what" }, longWords(e.text))),
        "Phone alerts" + (cls === "ok" ? "" : ` · ${name}`), " evt");
      row.append(binButton("Remove from Activity", `Remove "${e.text}" from Activity`, false, async () => {
        try { await api("/api/watchdog/events/remove", { method: "POST", body: JSON.stringify({ at: e.at, kind: e.kind, text: e.text }) }); }
        catch (err) { toast(err.message || "Couldn't remove it.", true); }
        showActivity(status).catch(() => {});
      }));
      box.append(row);
      continue;
    }
    const state = !j.ended ? ["Running", "run"] : j.code === 0 ? ["Done", "ok"] : ["Failed", "bad"];
    // The whole row opens the output; the label is the button, so the keyboard reaches it too.
    const grp = actionGroup(j.action);
    const row = line(j.started, state[1], state[0],
      h("button", { class: "job-open", type: "button" }, h("span", { class: "what", text: j.label })),
      [grp, state[1] === "ok" ? "" : state[0]].filter(Boolean).join(" · "), "");
    row.addEventListener("click", (ev) => { if (!ev.target.closest(".job-x")) openJob(j.id); });
    row.append(binButton("Remove from Activity", `Remove ${j.label} from Activity`, !j.ended, async () => {
      try { await api(`/api/jobs/${j.id}`, { method: "DELETE" }); }
      catch (err) { toast(err.message || "Couldn't remove it.", true); }
      showActivity(status).catch(() => {});
    }));
    box.append(row);
  }
  markWraps();
}

// On a computer, a row whose text wraps onto more than one line gets its group (Phone alerts · Failed) on a clean line
// underneath, instead of floating beside the middle of the wrapped text. Measured with every row in its one-line layout.
function markWraps() {
  const rows = [...document.querySelectorAll("#jobs .act-ln")];
  for (const r of rows) r.classList.remove("wraps");
  if (!rows.length || window.matchMedia("(max-width: 720px)").matches) return;
  const flags = rows.map((r) => {
    const o = r.querySelector(".job-open");
    return o.getBoundingClientRect().height > parseFloat(getComputedStyle(o).fontSize) * 2.2;
  });
  rows.forEach((r, i) => { if (flags[i]) r.classList.add("wraps"); });
}

// A long unbroken word (a backup's file name) is kept together: it moves to the next line whole, and only then
// breaks, at its own hyphens, instead of splitting wherever the line happens to run out
function longWords(text) {
  return String(text).split(/(\S{20,})/).map((part, i) => (i % 2 ? h("span", { class: "lg-long", text: part }) : part));
}

function actionGroup(id) {
  return { stack: "AIOStreams", mediaflow: "MediaFlow", webhook: "Webhook relay", watchdog: "Phone alerts" }[id.split(".")[0]] || "";
}

export async function showBackups(status) {
  const box = $("#backups"); clear(box);
  const act = (status.actions || []).find((a) => a.id === "stack.backup");
  const b = $("#backup-now");
  b.disabled = !act || !act.available || !!status.busy;
  b.onclick = () => runAction(act);
  showSetAsides().catch(() => {});
  showSchedule().catch(() => {});
  const items = await api("/api/backups");
  if (serverIp === undefined) serverIp = await api("/api/server-address").then((r) => r.ip || null, () => null);
  // An IPv6 address needs brackets in scp's user@host:path.
  const host = !serverIp ? "YOUR_SERVER" : serverIp.includes(":") ? `[${serverIp}]` : serverIp;
  clearTimeout(buildTimer);
  backupsHead(items.length);
  if (items.some((it) => it.build_pending) && buildTries < 10) {
    buildTries++;
    buildTimer = setTimeout(() => { if (!$("#view-backups").hidden) showBackups(status).catch(() => {}); }, 3000);
  } else {
    buildTries = 0;
  }
  if (!items.length) {
    box.append(h("p", { class: "empty", text: "No backups on this server yet. Use Back up now to make one." }));
    box.lastChild.style.padding = "18px 16px";
    return;
  }
  for (const it of items) {
    // Restore runs as root, so use the root-owned copy. For scp, prefer the copy in a normal user's
    // home (readable without root); fall back to root's copy.
    const userDir = it.dirs.find((d) => d.startsWith("/home/"));
    const cmd = userDir ? `scp ${userDir.split("/")[2]}@${host}:${userDir}/${it.name} .` : `scp root@${host}:${it.dirs[0]}/${it.name} .`;
    const mainDir = it.dirs.find((d) => !d.startsWith("/home/")) || it.dirs[0];
    const restore = `sudo bash ${status.install_dir || "/opt/aiostreams"}/setup-aiostreams.sh restore ${mainDir}/${it.name}`;
    box.append(backupRow(it, cmd, restore, status));
  }
}

async function copy(text, okMsg) {
  try { await navigator.clipboard.writeText(text); toast(okMsg); } catch (_) { toast(text); }
}

// A same-server rollback. The check runs first (it changes nothing); anything it finds means the
// restore needs answers only SSH can give, so the panel refuses and offers the SSH command instead.
// Its one question (start without the VPN, switched off in the backup) is asked here instead.
async function startRestore(it, restoreCmd, btn) {
  const label = btn.textContent;
  btn.disabled = true; btn.textContent = "Checking…";
  let res;
  try { res = await api(`/api/backups/${encodeURIComponent(it.name)}/restore-check`); }
  catch (e) { toast(e.message || "Couldn't check that backup.", true); return; }
  finally { btn.disabled = false; btn.textContent = label; }
  if (!res.ok) {
    const copyIt = await ask({ title: "Restore this one over SSH",
      body: "The panel only restores a backup of this same server, with the same domains, pointing here. This one needs answers only you can give over SSH:",
      options: { el: h("ul", { class: "check-list" }, ...res.reasons.map((r) => h("li", { text: r }))), read: () => true },
      confirmLabel: "Copy SSH restore command" });
    if (copyIt) copy(restoreCmd, "Copied. Paste it into an SSH session.");
    return;
  }
  // The check's own notes say which AIOStreams it holds, so the text above them doesn't
  const input = h("input", { class: "input", type: "text", autocomplete: "off", spellcheck: "false", placeholder: "Type restore to confirm", "aria-label": "Type restore to confirm" });
  const asks = res.questions || [];
  const el = h("div", { class: "opts" },
    h("ul", { class: "check-list ok" }, ...res.notes.map((n) => h("li", { text: n }))),
    asks.length ? h("ul", { class: "check-list" }, ...asks.map((q) => h("li", { text: q }))) : null,
    asks.length ? h("p", { class: "small", text: "Restoring says yes to that. Turn the VPN back on afterwards if you want it." }) : null,
    input);
  const ok = await ask({ title: "Restore this backup?", danger: true, confirmLabel: "Restore",
    body: `Made ${ago(it.mtime)}. Streams stop for a minute or two, then the panel restarts. Your current setup is kept aside, not deleted.`,
    options: { el, gate: input, word: "restore", read: () => true } });
  if (!ok) return;
  try {
    const job = await api("/api/actions/stack.restore", { method: "POST", body: JSON.stringify({ params: { name: it.name, confirm: "restore", without_vpn: asks.length > 0 } }) });
    openJob(job.id);
    window.dispatchEvent(new CustomEvent("job-started"));
  } catch (e) { toast(e.message || "Couldn't start the restore.", true); }
}

async function saveMeta(it, patch) {
  try { await api(`/api/backups/${encodeURIComponent(it.name)}/meta`, { method: "PUT", body: JSON.stringify(patch) }); return true; }
  catch (e) { toast(e.message || "Couldn't save that.", true); return false; }
}

function backupRow(it, cmd, restore, status) {
  const refresh = () => showBackups(status).catch(() => {});
  const noteLine = h("div", { class: "bk-note" });
  const showNote = () => {
    clear(noteLine);
    noteLine.append(h("button", { class: "bk-note-btn" + (it.note ? "" : " empty"), type: "button",
      text: it.note || "Add a note", title: "Edit note", onclick: editNote }));
  };
  const editNote = () => {
    clear(noteLine);
    const input = h("input", { class: "input", type: "text", maxlength: "200", value: it.note,
      placeholder: "e.g. Known good, before the big update", "aria-label": "Note" });
    const save = async () => { if (await saveMeta(it, { note: input.value })) { it.note = input.value.trim(); } showNote(); };
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") save(); if (e.key === "Escape") showNote(); });
    noteLine.append(input, h("button", { class: "btn small", type: "button", text: "Save", onclick: save }),
      h("button", { class: "btn small quiet", type: "button", text: "Cancel", onclick: showNote }));
    input.focus();
  };
  showNote();

  const del = h("button", { class: "btn small danger", type: "button", text: "Delete", disabled: it.locked,
    title: it.locked ? "Locked. Unlock it to delete." : "", onclick: async () => {
      const ok = await ask({ title: "Delete this backup?", confirmLabel: "Delete", danger: true,
        body: `${it.name} will be removed from ${it.dirs.join(" and ")}. This can't be undone.` });
      if (!ok) return;
      try { await api(`/api/backups/${encodeURIComponent(it.name)}`, { method: "DELETE" }); toast("Backup deleted."); }
      catch (e) { toast(e.message || "Couldn't delete it.", true); }
      refresh();
    } });

  // On a phone each backup folds to its name, tags, size, age and note; the chevron (or the name)
  // opens it for where it's saved and its buttons. A computer always shows it all.
  const row = h("div", { class: "item bk" + (it.locked ? " locked" : "") + (openBk.has(it.name) ? "" : " folded") });
  const tog = h("button", { class: "path-toggle fold-toggle bk-tog", type: "button", "aria-expanded": String(openBk.has(it.name)),
    "aria-label": `Show all of ${it.name}`, onclick: () => {
      const open = !openBk.has(it.name);
      if (open) openBk.add(it.name); else openBk.delete(it.name);
      row.classList.toggle("folded", !open);
      tog.setAttribute("aria-expanded", String(open));
    } }, chev());
  // On a phone's size line Locked is a padlock, so Scheduled and Locked fit side by side
  const tags = (icon) => {
    let lock = null;
    if (it.locked && icon) {
      lock = h("span", { class: "lock-tag lock-ic", role: "img", "aria-label": "Locked", title: "Locked" });
      lock.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>';
    } else if (it.locked) lock = h("span", { class: "lock-tag", text: "Locked" });
    return [it.name.includes("-scheduled-") ? h("span", { class: "lock-tag sched-tag", text: "Scheduled",
      title: "Made by the schedule. The newest 7 are kept and older ones removed; lock one to keep it for good." }) : null, lock];
  };
  row.append(
    h("span", { class: "bk-head", onclick: (e) => { if (!e.target.closest("button") && window.matchMedia("(max-width: 720px)").matches) tog.click(); } },
      h("div", { class: "what mono" }, tog, ...nameParts(it.name), tags()),
      // Folded on a phone, only "Made 3 min ago", so the tags beside it never push it onto two lines;
      // the size comes back when it's opened
      h("div", { class: "when" }, h("span", { class: "bk-size", text: `${fmtBytes(it.size)}, ` }),
        h("span", { class: "bk-made", text: "made" }), h("span", { class: "bk-made-cap", text: "Made" }), ` ${ago(it.mtime)}`,
        h("span", { class: "bk-where", text: `, saved in ${it.dirs.join(" and ")}` })),
      // A phone puts the tags at the end of the size line instead, so every backup is two lines folded
      h("span", { class: "bk-tags" }, tags(true))),
    h("div", { class: "btns" },
      h("button", { class: "btn small", type: "button", text: "Restore", disabled: !!status.busy,
        title: "Roll your AIOStreams setup back to this backup, after checking it's safe to do from here",
        onclick: (e) => startRestore(it, restore, e.currentTarget) }),
      h("button", { class: "btn small", type: "button", text: "Copy restore command", onclick: () => copy(restore, "Copied. Paste it into an SSH session to restore from this backup.") }),
      h("button", { class: "btn small", type: "button", text: "Copy scp command", onclick: () => copy(cmd, cmd.includes("@YOUR_SERVER:")
        ? "Copied. Replace YOUR_SERVER with your server's address."
        : "Copied. Run it in a terminal on your own computer to download this backup.") }),
      h("button", { class: "btn small", type: "button", text: it.locked ? "Unlock" : "Lock", "aria-pressed": String(!!it.locked), onclick: async () => {
        if (await saveMeta(it, { locked: !it.locked })) toast(it.locked ? "Unlocked." : "Locked. It can't be deleted from here until you unlock it.");
        refresh();
      } }),
      del),
    noteLine);
  return row;
}

// Scheduled backups: off, daily or weekly at a time of day, server time. setup-backup.sh's
// timer makes them; the newest 7 are kept, and the watchdog alerts if one fails.
const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
export function scheduleText(s) {
  if (!s || s.every === "off") return "Not scheduled";
  return s.every === "daily" ? `Daily at ${s.time}` : `${DAYS[(s.day || 7) - 1]}s at ${s.time}`;
}

// On a phone the card is laid out like Maintenance's Scheduled server reboot: Schedule with its
// state on the right, the choices under it in a row and a full-width Set button
const PHONE = window.matchMedia("(max-width: 720px)");
PHONE.addEventListener("change", () => { if ($("#backup-schedule").childElementCount) showSchedule().catch(() => {}); });

// Phones: whether Scheduled backups is open (folded until opened, remembered), and which backups are
// open (folded until tapped; kept while the panel is open)
let schedOpen = false;
try { schedOpen = localStorage.getItem("aios.schedOpen") === "1"; } catch (_) {}
const openBk = new Set();
function chev() {
  const c = h("span", { class: "path-chev", "aria-hidden": "true" });
  c.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  return c;
}

// The "Backups" title. A computer shows it as a plain heading over the open list; on a phone the whole
// list is one card that folds to this title and a count, folded until opened and remembered per browser.
let backupsOpen = false;
try { backupsOpen = localStorage.getItem("aios.backupsOpen") === "1"; } catch (_) {}
let backupsCount = 0;
function backupsHead(n) {
  backupsCount = n;
  const head = $("#backups-head"), card = $("#backups-card");
  head.hidden = !n;
  card.classList.toggle("has-items", n > 0);
  card.classList.toggle("folded", !backupsOpen);
  clear(head);
  const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(backupsOpen), onclick: () => {
    backupsOpen = !backupsOpen;
    try { localStorage.setItem("aios.backupsOpen", backupsOpen ? "1" : "0"); } catch (_) {}
    card.classList.toggle("folded", !backupsOpen);
    tog.setAttribute("aria-expanded", String(backupsOpen));
  } }, "Backups", chev());
  head.append(tog, h("span", { class: "bk-count", text: String(n) }));
}
PHONE.addEventListener("change", () => { backupsHead(backupsCount); asideHead(asideCount); });

// Set aside by restores: the same fold on a phone, with the count in amber while it's folded, since
// leftovers are clean-up waiting (this is what replaced the pill in the page heading)
let asideOpen = false;
try { asideOpen = localStorage.getItem("aios.asideOpen") === "1"; } catch (_) {}
let asideCount = 0;
function asideHead(n) {
  asideCount = n;
  const head = $("#aside-head"), card = $("#set-asides");
  card.classList.toggle("folded", !asideOpen);
  clear(head);
  const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(asideOpen), onclick: () => {
    asideOpen = !asideOpen;
    try { localStorage.setItem("aios.asideOpen", asideOpen ? "1" : "0"); } catch (_) {}
    card.classList.toggle("folded", !asideOpen);
    tog.setAttribute("aria-expanded", String(asideOpen));
  } }, "Set aside by restores", chev());
  head.append(tog, h("span", { class: "bk-count aside-count", text: String(n) }));
}

async function showSchedule() {
  const box = $("#backup-schedule");
  let s;
  try { s = await api("/api/backup-schedule"); } catch (_) { clear(box); return; }
  clear(box);
  if (!s.available) return;
  const every = h("select", { class: "input", "aria-label": "How often" },
    ...[["off", "Off"], ["daily", "Daily"], ["weekly", "Weekly"]].map(([v, t]) => h("option", { value: v, text: t })));
  const day = h("select", { class: "input", "aria-label": "Day" }, ...DAYS.map((d, i) => h("option", { value: String(i + 1), text: d.slice(0, 3) })));
  const time = timePicker(s.time || "04:00");
  const phone = PHONE.matches;
  const setBtn = h("button", { class: "btn small" + (phone ? " rs-wide" : ""), type: "button", text: "Set schedule" });
  every.value = s.every; day.value = String(s.day || 7);
  const onDay = h("span", { class: "dim", text: "on" });
  const tz = h("span", { class: "dim" }, "24-hour, server time", s.timezone ? [" ", h("span", { class: "nowrap", text: `(${s.timezone})` })] : null);
  const atLbl = h("span", { class: "dim", text: "at" });
  const show = () => {
    const on = every.value !== "off";
    for (const el of [atLbl, time, setBtn, tz]) el.hidden = !on;
    onDay.hidden = day.hidden = every.value !== "weekly";
    onDay.hidden = atLbl.hidden = true;   // each box says what it is
  };
  const save = async (body) => {
    setBtn.disabled = every.disabled = true;
    try {
      const r = await api("/api/backup-schedule", { method: "PUT", body: JSON.stringify(body) });
      toast(r.every === "off" ? "Scheduled backups: off." : `Scheduled backups: ${r.every === "daily" ? `daily at ${r.time}` : `weekly, ${scheduleText(r)}`}.`);
    } catch (e) { toast(e.message || "Couldn't save it.", true); }
    showSchedule().catch(() => {});
  };
  every.addEventListener("change", () => { show(); if (every.value === "off" && s.every !== "off") save({ every: "off" }); });
  setBtn.addEventListener("click", () => {
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time.value)) { toast("Type a 24-hour time, for example 04:00 or 20:57.", true); return; }
    save({ every: every.value, day: Number(day.value), time: time.value });
  });
  show();

  // How the last run went: quiet when fine, amber when it failed or was skipped
  const l = s.last;
  let last = null;
  if (s.every !== "off" && l) {
    if (l.status === "running") last = h("p", { class: "dim sched-last", text: "Making one now…" });
    else if (l.status === "ok") last = h("p", { class: "dim sched-last", text: `Last ran ${ago(l.at)}.` });
    else last = h("p", { class: "sched-last warn", text: `The last one ${l.status === "skipped" ? "was skipped" : "failed"} ${ago(l.at)}: ${l.text}` });
  } else if (s.every !== "off" && !s.timer) {
    last = h("p", { class: "sched-last warn", text: "The timer isn't running. Press Set to start it again." });
  }
  const keep = h("p", { class: "dim small bal", text: "Keeps the newest 7 scheduled backups. Only unlocked scheduled ones are ever removed." });
  // Laid out like Maintenance's Scheduled server reboot: Schedule with its state on the right, then the
  // choices; Set is full width under them on a phone, at the end of their row on a desktop
  const word = s.every === "off" ? ["Off", "dim"] : !s.timer ? ["Not running", "warn"] : ["On", "ok"];
  tz.className = "dim small rs-tz";
  const row = h("div", { class: "wd-when-row restart-row bk-row" }, every, onDay, day, atLbl, time);
  // On a phone the title folds the card to one line with the state beside it, like the Network page's
  // cards: folded until opened, remembered per browser. A failed or skipped run still shows folded.
  const card = h("section", { class: `panel sched-card rs-list ${phone ? "rs-phone bk-phone" : "rs-desk bk-desk"}` + (!schedOpen ? " folded" : "") });
  let title = h("h3", { text: "Scheduled backups" });
  {
    const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(schedOpen), onclick: () => {
      schedOpen = !schedOpen;
      try { localStorage.setItem("aios.schedOpen", schedOpen ? "1" : "0"); } catch (_) {}
      card.classList.toggle("folded", !schedOpen);
      tog.setAttribute("aria-expanded", String(schedOpen));
    } }, "Scheduled backups", chev());
    title = h("div", { class: "sched-head" }, h("h3", {}, tog), h("span", { class: "rs-word sched-fold-word " + word[1], text: word[0] }));
  }
  box.append(card);
  card.append(
    title,
    h("div", { class: "rs-block" },
      h("div", { class: "rs-line" }, h("span", { class: "ver-label", text: "Schedule" }), h("span", { class: "rs-word " + word[1], text: word[0] })),
      ...(phone ? [row, tz, setBtn] : [h("div", { class: "rs-ctl" }, row), tz])),
    // native append writes a null out as the word "null", so the last-run line only when there is one
    ...(last ? [last] : []),
    // Desktop: Set schedule in the card's bottom right corner, beside the note
    ...(phone ? [keep] : [h("div", { class: "bk-foot" }, keep, setBtn)]));
}

// Old installs a restore moved aside. Only shown when there are some.
async function showSetAsides() {
  const wrap = $("#set-asides"), box = $("#set-aside-list");
  const items = await api("/api/set-asides");
  clear(box);
  wrap.hidden = !items.length;
  asideHead(items.length);
  for (const it of items) {
    const size = it.size != null ? fmtBytes(it.size) : "size unknown";
    const when = it.when ? `set aside ${ago(it.when)}` : "";
    box.append(h("div", { class: "item bk" },
      h("span", {},
        h("div", { class: "what mono" }, ...nameParts(it.name)),
        h("div", { class: "when", text: [size, when, `in ${it.dir}`].filter(Boolean).join(", ") })),
      h("div", { class: "btns" },
        h("button", { class: "btn small danger", type: "button", text: "Delete", onclick: async () => {
          const ok = await ask({ title: "Delete this folder?", confirmLabel: "Delete", danger: true,
            body: `${it.dir}/${it.name} will be removed. That's your old setup from before the restore, so only do this once the restored one works. This can't be undone.` });
          if (!ok) return;
          try { await api(`/api/set-asides/${encodeURIComponent(it.name)}`, { method: "DELETE" }); toast("Folder deleted."); }
          catch (e) { toast(e.message || "Couldn't delete it.", true); }
          showSetAsides().catch(() => {});
        } }))));
  }
}
