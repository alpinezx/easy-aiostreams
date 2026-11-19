import { $, h, clear, api, ago, toast, timePicker } from "./util.js";
import { runAction, ask } from "./actions.js";

// The Phone alerts page: what the watchdog (setup-watchdog.sh) is doing, what it
// has seen lately ("did anything happen overnight?"), and changing its ntfy
// topic with a test alert straight after. The topic acts like a password, so the
// server only ever sends it masked.

let st = null, last = null, loading = false, showAll = false;

const actFor = (id) => { const a = st && st.actions.find((x) => x.id === id); return a && a.available ? a : null; };

// "18 Oct 2026, 16:02:11 UTC OK" -> when, and what it said
export function parseCheck(line) {
  const m = (line || "").match(/^(\d{1,2} \w{3} \d{4}), (\d{2}:\d{2}:\d{2}) (\S+) (.*)$/);
  if (!m) return { at: null, result: line || "" };
  const t = Date.parse(`${m[1]} ${m[2]} ${m[3] === "UTC" ? "UTC" : ""}`.trim());
  return { at: Number.isNaN(t) ? null : t / 1000, result: m[4] };
}

const KIND = {
  fail: ["Failed", "warn"], alert: ["Alert sent", "bad"], recovered: ["Recovered", "ok"],
  start: ["Started", ""], stop: ["Stopped", ""], test: ["Test alert", ""], topic: ["Topic", ""], reboot: ["Restarted", ""], disk: ["Disk space", ""], cert: ["Certificate", ""],
  update: ["Update", ""], scripts: ["Scripts", ""], backup: ["Backup", ""], security: ["Security", ""], weekly: ["Weekly", ""],
};

function when(at) {
  const d = new Date(at * 1000), now = new Date();
  const time = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const days = Math.round((new Date(now.toDateString()) - new Date(d.toDateString())) / 86400000);
  if (days === 0) return `Today ${time}`;
  if (days === 1) return `Yesterday ${time}`;
  return `${d.toLocaleDateString([], { day: "numeric", month: "short" })} ${time}`;
}

export function setStatus(status) {
  st = status;
  buttons();
}

// Start/Stop and Send test alert sit in the page heading, like the VPN page's switch
function buttons() {
  const box = $("#alerts-acts");
  if (!box || !st) return;
  clear(box);
  const w = st.watchdog || {};
  for (const id of [w.running ? "watchdog.stop" : "watchdog.start", "watchdog.test"]) {
    const a = actFor(id);
    if (a) box.append(h("button", { class: "btn small", type: "button", text: id === "watchdog.stop" ? "Stop watchdog" : id === "watchdog.start" ? "Start watchdog" : a.label,
      disabled: !!st.busy, onclick: () => runAction(a) }));
  }
  for (const b of document.querySelectorAll("#alerts-root .btn")) b.disabled = !!st.busy;
}

export async function show(status) {
  if (status) st = status;
  buttons();
  const box = $("#alerts-root");
  if (loading) return;
  loading = true;
  if (!box.firstChild) box.append(h("p", { class: "empty", text: "Loading…" }));
  try {
    render(await api("/api/watchdog"));
  } catch (e) {
    clear(box);
    box.append(h("p", { class: "empty", text: e.message || "Couldn't read the watchdog's state." }));
  } finally {
    loading = false;
  }
}

function cell(label, ...value) {
  return h("div", {}, h("div", { class: "vpn-label", text: label }), h("div", { class: "vpn-value" }, ...value));
}

// What it watches: folded until opened (a long list of every check), remembered per browser
// like the Overview's cards (key "aios.wdWatchOpen"). Folded, the value line says how many.
let watchOpen = false;
try { watchOpen = localStorage.getItem("aios.wdWatchOpen") === "1"; } catch (_) {}
// With several sites, "HTTPS certificates (5 sites)" has a chevron of its own that lists which
// sites' certificates are checked; folded until opened, remembered (key "aios.wdCertsOpen").
let certsOpen = false;
try { certsOpen = localStorage.getItem("aios.wdCertsOpen") === "1"; } catch (_) {}
function certsItem(text, sites, note = "") {
  // "HTTPS certificates (5 sites)": the count reads as a quiet note after the name, without its brackets
  const m = text.match(/^(.*?) \((\d+ sites?)\)$/);
  const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
  chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  const more = h("div", { class: "wd-certs", hidden: !certsOpen },
    ...(note ? [h("div", { class: "dim", text: note })] : sites.map((s) => h("div", { text: s.host, title: s.label }))));
  const tog = h("button", { class: "path-toggle fold-toggle wd-certs-tog", type: "button", "aria-expanded": String(certsOpen),
    title: "Show or hide which sites' certificates are checked", onclick: () => {
      certsOpen = !certsOpen;
      try { localStorage.setItem("aios.wdCertsOpen", certsOpen ? "1" : "0"); } catch (_) {}
      tog.setAttribute("aria-expanded", String(certsOpen));
      more.hidden = !certsOpen;
    } }, ...(m ? [m[1], " ", h("span", { class: "dim", text: m[2] })] : [text]), chev);
  return h("div", { class: "wd-watch-item" }, tog, more);
}

// Two short lists: the sites (name, its address under it), then the other checks (tunnel, VPN, disk)
function watchRows(rows, certNote) {
  const sites = rows.filter((r) => r.host), other = rows.filter((r) => !r.host);
  const note = certNote || "The main site is loaded, add-ons get a health check, and every certificate is checked.";
  const head = (t) => h("div", { class: "wd-watch-head", text: t });
  return [
    ...(sites.length ? [head("Sites"),
      ...sites.map((r) => h("div", { class: "wd-watch-item wd-site" }, h("div", { text: r.name }), h("div", { class: "dim wd-site-host", text: r.host }))),
      h("div", { class: "dim wd-watch-note", text: note })] : []),
    ...(other.length ? [head("Services"), ...other.map((r) => h("div", { class: "wd-watch-item", text: r.name }))] : []),
  ];
}

function watchCell(watches, certSites = [], certNote = "", rows = null) {
  // Short and unfolded: how many sites (certificates included unless a Tunnel handles them) and how many other checks
  if (rows && rows.length) {
    const sites = rows.filter((r) => r.host).length, other = rows.length - sites;
    return h("div", { class: "wd-watch" }, h("div", { class: "vpn-label", text: "Watches" }),
      ...(sites ? [h("div", { class: "vpn-value", text: `${sites} site${sites === 1 ? "" : "s"}${certNote ? "" : ", certificates included"}` })] : []),
      ...(other ? [h("div", { class: "vpn-value wd-watch-more", text: `${other} service & system check${other === 1 ? "" : "s"}` })] : []),
      certNote ? h("div", { class: "dim wd-watch-note", text: certNote }) : null);
  }
  const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
  chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  const n = rows && rows.length ? rows.length : watches.length;
  const count = h("div", { class: "vpn-value wd-watch-count", text: `Running ${n} check${n === 1 ? "" : "s"}` });
  const list = h("div", { class: "vpn-value wd-watch-list" }, ...(rows && rows.length ? watchRows(rows, certNote) : watches.map((x) =>
    certSites.length > 1 && x.startsWith("HTTPS certificates") ? certsItem(x, certSites)
      : h("div", { class: "wd-watch-item", text: x }))));
  // Through a Cloudflare Tunnel the watchdog checks the tunnel, not the certificates (Cloudflare renews them): the
  // sites' note says so (and the older list, with no rows, keeps its own line)
  if (certNote && !(rows && rows.length)) list.append(certsItem("HTTPS certificates", [], certNote));
  const show = () => { count.hidden = watchOpen; list.hidden = !watchOpen; };
  const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(watchOpen),
    title: "Show or hide everything it watches", onclick: () => {
      watchOpen = !watchOpen;
      try { localStorage.setItem("aios.wdWatchOpen", watchOpen ? "1" : "0"); } catch (_) {}
      tog.setAttribute("aria-expanded", String(watchOpen));
      show();
    } }, "Watches", chev);
  show();
  return h("div", { class: "wd-watch" }, h("div", { class: "vpn-label" }, tog), count, list);
}

// One square per day for the last 14: green all passed, amber some failed, faint no checks
// nowOk: the latest check passed, so today's failures are behind it. Today's square then
// shows both (green, with an amber band at its foot) and its wording says they were earlier.
export function days(tally, nowOk = false) {
  const by = Object.fromEntries((tally || []).map((t) => [t.day, t]));
  const strip = h("div", { class: "wd-days", role: "list", "aria-label": "Checks per day, last 14 days" });
  for (let back = 13; back >= 0; back--) {
    const d = new Date(Date.now() - back * 86400000);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const t = by[key];
    const label = d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
    const s = !t || t.passed + t.failed === 0 ? "none" : t.failed ? (back === 0 && nowOk ? "recovered" : "warn") : "ok";
    const n = t ? t.passed + t.failed : 0;
    const earlier = back === 0 && nowOk ? " earlier, all passing now" : "";
    const tip = !t ? `${label}: no checks` : `${label}: ${n} check${n === 1 ? "" : "s"}${t.failed ? `, ${t.failed} failed${earlier}` : n === 1 ? ", passed" : ", all passed"}`;
    strip.append(h("span", { class: "wd-day", dataset: { s }, role: "listitem", title: tip, "aria-label": tip }));
  }
  return strip;
}

export function todayLine(tally, nowOk = false) {
  const t = (tally || [])[(tally || []).length - 1];
  const d = new Date();
  const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  if (!t || t.day !== key) return "No checks yet today.";
  const n = t.passed + t.failed;
  const checks = `${n} check${n === 1 ? "" : "s"}`;
  if (t.failed && nowOk) return `Today: ${checks}, ${t.failed} failed earlier. All passing now.`;
  return t.failed ? `Today: ${checks}, ${t.failed} failed.` : n === 1 ? "Today: 1 check, passed." : `Today: ${checks}, all passed.`;
}

function render(w) {
  last = w;
  const box = $("#alerts-root");
  clear(box);
  if (!w.configured) {
    box.append(h("p", { class: "empty", text: "The watchdog isn't set up on this server." }));
    return;
  }
  const chk = parseCheck(w.last_check);
  const down = w.alert_state === "down";
  const warns = (w.warnings || []).map((x) => ({ disk: "disk nearly full", cert: "certificate not renewing" })[x] || x);
  const [lamp, word] = !w.running ? ["", "Stopped, no checks running"]
    : down ? ["down", "Something's down, alert sent"]
      : w.fails ? ["degraded", "A check just failed"]
        : warns.length ? ["degraded", `Watching: ${warns.join(", ")}`] : ["ok", "Watching"];
  const passed = chk.result === "OK";
  const result = !w.running ? "No checks while stopped"
    : passed ? "All checks passed" : chk.result.replace(/^FAIL:\s*/, "") || "No check yet";

  const card = h("div", { class: "panel vpn-card" },
    h("div", { class: "vpn-head" },
      h("div", { class: "vpn-state" }, h("span", { class: "lamp", dataset: { s: lamp }, "aria-hidden": "true" }), h("span", { text: word })),
      chk.at && w.running ? h("span", { class: "vpn-checked", text: `Checked ${ago(chk.at)}` }) : null),
    h("div", { class: "vpn-grid wd-grid" },
      cell("Last check", h("span", { class: passed || !w.running ? "" : "wd-fail", text: result })),
      watchCell(w.watches, w.cert_sites, w.cert_note || "", w.watch_rows),
      cell("How often", `Every ${w.every_min} min, alert after ${w.threshold} ${w.threshold === 1 ? "fail" : "fails"}`)),
    h("div", { class: "wd-days-row" },
      h("div", {}, h("div", { class: "vpn-label", text: "Last 14 days" }), days(w.tally, w.running && passed)),
      h("div", { class: "wd-today-wrap" }, h("span", { class: "dim wd-today", text: todayLine(w.tally, w.running && passed) }),
        (w.tally || []).length ? h("button", { class: "btn small quiet", type: "button", text: "Reset", title: "Start the 14 days again", onclick: resetTally }) : null)),
    h("div", { class: "vpn-card-acts wd-topic" },
      h("div", { class: "wd-topic-what" }, h("span", { class: "vpn-label", text: "Alert topic" }),
        h("span", { class: "mono", text: w.topic || "none" })),
      actFor("watchdog.topic") ? h("button", { class: "btn small", type: "button", text: "Change topic", disabled: !!(st && st.busy), onclick: changeTopic }) : null));
  box.append(card, extras(w));

  // What happened lately, newest first
  const list = h("ul", { class: "wd-events" });
  const evs = showAll ? w.events : w.events.slice(0, 12);
  for (const e of evs) {
    const [name, cls] = KIND[e.kind] || [e.kind, ""];
    // Laid out like the Activity page's rows: what happened, then when, then its pill
    // Each has a bin, as on Activity: removes just that one
    const x = h("button", { class: "btn small quiet job-x", type: "button", title: "Remove from Recent events", "aria-label": `Remove "${e.text}" from Recent events`,
      onclick: () => removeEvent(e) });
    x.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/></svg>';
    list.append(h("li", {},
      h("span", { class: "wd-text", text: e.text }),
      h("span", { class: "wd-when", title: new Date(e.at * 1000).toLocaleString(), text: when(e.at) }),
      h("span", { class: "chip" + (cls ? " " + cls : ""), text: name }),
      x));
  }
  box.append(h("div", { class: "wd-sub" }, h("h3", { text: "Recent events" }),
    w.events.length ? h("button", { class: "btn small quiet", type: "button", text: "Clear history", onclick: clearEvents }) : null),
    w.events.length ? list : h("p", { class: "dim", text: "Nothing yet. Failed checks, alerts and recoveries show here." }));
  if (w.events.length > 12 && !showAll) box.append(h("button", { class: "btn small quiet", type: "button", text: `Show all ${w.events.length}`,
    onclick: () => { showAll = true; render(last); } }));
}

// The check-in goes by the server's clock, so say which zone that is. A server
// left on UTC is the usual surprise; the fix is one command.
function tzNote(tz) {
  if (!tz) return "server time";
  if (/^(Etc\/)?(UTC|UCT|GMT|Universal|Zulu)$/.test(tz))
    return "server time (UTC; for your own, run sudo timedatectl set-timezone Area/City, e.g. Europe/London)";
  return `server time (${tz})`;
}

// The optional alerts, off until switched on. They take effect from the next check.
function extras(w) {
  const opt = w.options || {};
  const save = (name, value) => api("/api/watchdog/options", { method: "POST", body: JSON.stringify({ name, value }) });
  const row = (name, title, text, disabled, after) => {
    const input = h("input", { type: "checkbox", checked: !!opt[name], disabled: !!disabled });
    input.addEventListener("change", async () => {
      input.disabled = true;
      try {
        await save(name, input.checked);
        toast(`${title}: ${input.checked ? "on" : "off"}.`);
        if (after) after.hidden = !input.checked;
      } catch (e) {
        input.checked = !input.checked;
        toast(e.message || "Couldn't save it.", true);
      } finally { input.disabled = !!disabled; }
    });
    return h("label", { class: "wd-opt" },
      h("span", {}, h("span", { class: "wd-opt-title", text: title }), h("span", { class: "dim wd-opt-text", text: text })),
      h("span", { class: "sw" }, input, h("i", { "aria-hidden": "true" })));
  };
  // When the check-in goes out, shown while it's on
  const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
  const day = h("select", { class: "input", "aria-label": "Day" }, ...DAYS.map((d, i) => h("option", { value: String(i + 1), text: d })));
  // Any time of day, to the minute; Set saves it (the day saves as soon as it's picked)
  const time = timePicker(opt.weekly_time || "10:00");
  const setBtn = h("button", { class: "btn small", type: "button", text: "Set" });
  day.value = String(opt.weekly_day || 7);
  day.addEventListener("change", async () => {
    try { await save("weekly_day", Number(day.value)); toast(`Check-in: ${DAYS[Number(day.value) - 1]}s from ${time.value}.`); }
    catch (e) { toast(e.message || "Couldn't save it.", true); }
  });
  setBtn.addEventListener("click", async () => {
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time.value)) { toast("Type a 24-hour time, for example 10:15 or 18:30.", true); return; }
    try { await save("weekly_time", time.value); toast(`Check-in: ${DAYS[Number(day.value) - 1]}s from ${time.value}.`); }
    catch (e) { toast(e.message || "Couldn't save it.", true); }
  });
  const when = h("div", { class: "wd-when-row", hidden: !opt.weekly },
    h("span", { class: "dim", text: "Send it on" }), day, h("span", { class: "dim", text: "from" }), time, setBtn,
    h("span", { class: "dim", text: `24-hour, ${tzNote(w.timezone)}, within 2 minutes of it` }));
  const body = h("div", { class: "wd-opts-body" },
    row("updates", "When a new AIOStreams release is out", w.channel === "nightly"
      ? "One per nightly build, with how to update. Nightly builds come out daily or more, so this can be chatty."
      : w.channel === "stable" ? "One alert per stable release, with how to update."
      : "This server runs a pinned version, so there's nothing to alert about.", !w.channel),
    // only once AIOMetadata is installed
    w.aiometadata ? row("metadata", "When a new AIOMetadata release is out", "At most one alert a day, naming the newest: "
      + "its releases can come twice a day.") : null,
    // and AIOManager's, once it's installed
    w.aiomanager ? row("manager", "When a new AIOManager release is out", "One alert per release, with how to update.") : null,
    // and MediaFlow's
    w.mediaflow ? row("mediaflow", "When a new MediaFlow release is out", "One alert per release, with how to update.") : null,
    row("reboots", "When the server restarts", "With how long it was down, and whether it shut down cleanly."),
    row("scripts", "When a script here differs from GitHub's copy", "Scripts can change several times a week, "
      + "so this can be chatty. At most one alert a day."),
    row("backups", "When a scheduled backup is made", "A failed or skipped one always alerts, with this on or off."),
    row("security", "When security updates are waiting", "Automatic updates install these by themselves, so this alerts only if they've waited 3 days, "
      + "with a reminder each week while they still wait."),
    row("weekly", "Weekly check-in", "The week's checks, alerts, disk space, newest backup and updates waiting.", false, when), when);
  // Folded until opened (a long list of switches), remembered per browser (key "aios.wdOptsOpen").
  // Folded, the right side says how many are on, and keeps up as they're switched.
  let open = false;
  try { open = localStorage.getItem("aios.wdOptsOpen") === "1"; } catch (_) {}
  const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
  chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  const word = h("span", { class: "dim wd-opts-word" });
  const tally = () => {
    const n = body.querySelectorAll(".wd-opt input:checked").length;
    word.textContent = n ? `${n} active` : "None";
    word.className = n ? "wd-opts-word ok" : "dim wd-opts-word";   // a state word is green when something's on, like Active elsewhere
  };
  const box = h("div", { class: "panel wd-opts" + (open ? "" : " folded") });
  const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(open),
    title: "Show or hide the optional alerts", onclick: () => {
      open = !open;
      try { localStorage.setItem("aios.wdOptsOpen", open ? "1" : "0"); } catch (_) {}
      box.classList.toggle("folded", !open);
      tog.setAttribute("aria-expanded", String(open));
    } }, "Also tell me", chev);
  body.addEventListener("change", tally);
  tally();
  box.append(h("div", { class: "wd-opts-head" }, h("h3", {}, tog), word), body);
  return box;
}

async function resetTally() {
  const ok = await ask({ title: "Reset the 14-day stats?", confirmLabel: "Reset", danger: true,
    body: "The day squares and today's count start again from the next check. The event history stays." });
  if (!ok) return;
  try {
    await api("/api/watchdog/tally/clear", { method: "POST" });
    toast("Stats reset.");
    render(await api("/api/watchdog"));
  } catch (e) { toast(e.message || "Couldn't reset them.", true); }
}

async function removeEvent(e) {
  try {
    await api("/api/watchdog/events/remove", { method: "POST", body: JSON.stringify({ at: e.at, kind: e.kind, text: e.text }) });
  } catch (err) { toast(err.message || "Couldn't remove it.", true); }
  try { render(await api("/api/watchdog")); } catch (_) {}
}

async function clearEvents() {
  const ok = await ask({ title: "Clear the event history?", confirmLabel: "Clear history", danger: true,
    body: "Removes every event from this list. The watchdog keeps checking, and new events show here as they happen. The 14-day strip stays." });
  if (!ok) return;
  try {
    await api("/api/watchdog/events/clear", { method: "POST" });
    showAll = false;
    toast("Event history cleared.");
    render(await api("/api/watchdog"));
  } catch (e) { toast(e.message || "Couldn't clear it.", true); }
}

// Hard to guess but easy to read back: three groups of four from 31 characters with
// no look-alikes (no 0/o, 1/l/i), about 59 bits. ntfy topics are letters, digits, - and _
function suggestTopic() {
  const abc = "abcdefghjkmnpqrstuvwxyz23456789";
  const r = crypto.getRandomValues(new Uint8Array(12));
  const c = Array.from(r, (x) => abc[x % abc.length]).join("");
  return `aios-${c.slice(0, 4)}-${c.slice(4, 8)}-${c.slice(8)}`;
}

async function changeTopic() {
  const act = actFor("watchdog.topic");
  if (!act) return;
  const input = h("input", { class: "input mono", type: "text", value: suggestTopic(), autocomplete: "off", spellcheck: "false",
    autocapitalize: "off", "aria-label": "New topic", maxlength: "64" });
  // Copy, to paste into the ntfy app rather than typing it (one wrong character and nothing arrives)
  const copy = h("button", { class: "btn small", type: "button", text: "Copy", onclick: async () => {
    try { await navigator.clipboard.writeText(input.value.trim()); toast("Copied. Paste it into the ntfy app's Subscribe to topic."); }
    catch (_) { input.select(); toast("Couldn't copy. It's selected, so copy it from there.", true); }
  } });
  const err = h("p", { class: "wd-topic-err", hidden: true });
  const sync = () => {
    const t = input.value.trim();
    const ok = /^[A-Za-z0-9_-]{12,64}$/.test(t);
    err.hidden = ok || !t;
    err.textContent = t.length < 12 ? "At least 12 characters, so nobody can guess it." : "Letters, numbers, - and _ only.";
    const btn = $("#dialog .btn.primary");
    if (btn) btn.disabled = !ok;
  };
  input.addEventListener("input", sync);
  const el = h("div", { class: "opts" },
    h("label", { class: "field" }, h("span", { text: "New topic" }), h("span", { class: "wd-topic-input" }, input, copy)), err,
    h("ol", { class: "wd-topic-steps" },
      h("li", { text: "Subscribe to it yourself in the ntfy app." }),
      h("li", { text: "Save here. A test alert is sent straight away." })),
    h("p", { class: "dim wd-topic-how", text: "Anyone who knows the topic can read your alerts, so keep it long." }));
  setTimeout(sync, 0);
  const res = await ask({ title: "Change the alert topic", confirmLabel: "Save and send test",
    body: "Alerts go to the new topic from the next check. The old one stops getting them.",
    options: { el, read: () => input.value.trim() } });
  if (!res) return;
  await runAction(act, { topic: res });
}
