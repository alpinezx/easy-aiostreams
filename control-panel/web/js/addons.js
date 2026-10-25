import { $, h, clear, api, toast, fmtBytes } from "./util.js";
import { ask, openJob } from "./actions.js";

// The Add-ons page: a card for each optional add-on that's installed, full
// width like the Overview's, each value a tile: label, the value cut off with
// "…" and its icon buttons, a quiet line. Secrets show as dots and are asked
// of the server one at a time, only when the eye or Copy is pressed, and
// never kept. Uninstall for every add-on lives here; VPN and Phone alerts keep
// their settings on their own pages.

let st = null, data = null, loading = false;

const ICON = {
  copy: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1"/></svg>',
  open: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>',
  eye: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/><path class="slash" d="M3 3l18 18"/></svg>',
};

function iconBtn(kind, label, onclick) {
  const b = h("button", { class: "ao-ic", type: "button", "aria-label": label, title: label, onclick });
  b.innerHTML = ICON[kind];
  return b;
}

async function copy(text, what) {
  try { await navigator.clipboard.writeText(text); toast(`${what} copied.`); }
  catch (_) { toast("The browser didn't allow copying.", true); }
}

const secret = (addon, name) => api(`/api/addons/${addon}/secret/${name}`).then((r) => r.value);

// A link shows its host and path, not https://
const short = (url) => url.replace(/^https?:\/\//, "");

// One tile. r: { label, note, link } | { label, note, secret: [addon, name], hidden } | { label, note, text, tone }
// | { label, note, text, tone, toggle: { on, title, change, working } }
function tile(r) {
  const value = h("span", { class: "ao-val" + (r.link || r.secret ? " mono" : "") + (r.tone ? " " + r.tone : "") });
  // While a switch's change is being made: a spinner beside the value, and the switch held where it was put
  const spin = r.toggle && r.toggle.working ? h("span", { class: "spin", "aria-hidden": "true" }) : null;
  const btns = h("span", { class: "ao-btns" });
  if (r.link) {
    value.textContent = short(r.link);
    value.title = r.link;
    const open = h("a", { class: "ao-ic", href: r.link, target: "_blank", rel: "noopener noreferrer", "aria-label": `Open ${r.label}`, title: `Open ${r.label}` });
    open.innerHTML = ICON.open;
    btns.append(iconBtn("copy", `Copy ${r.label}`, () => copy(r.link, r.label)), open);
  } else if (r.secret) {
    const hidden = r.hidden || "••••••••••";
    let shown = false;
    value.textContent = hidden;
    const eye = iconBtn("eye", `Show ${r.label}`, async () => {
      if (!shown) {
        try { const v = await secret(...r.secret); value.textContent = short(v); value.title = v; }
        catch (e) { toast(e.message || "Couldn't read it.", true); return; }
      } else { value.textContent = hidden; value.title = ""; }
      shown = !shown;
      eye.setAttribute("aria-pressed", String(shown));
      eye.setAttribute("aria-label", `${shown ? "Hide" : "Show"} ${r.label}`);
      eye.title = eye.getAttribute("aria-label");
    });
    eye.setAttribute("aria-pressed", "false");
    btns.append(iconBtn("copy", `Copy ${r.label}`, async () => {
      try { copy(await secret(...r.secret), r.label); } catch (e) { toast(e.message || "Couldn't read it.", true); }
    }), eye);
  } else {
    value.textContent = r.text;
  }
  if (r.toggle) {
    const input = h("input", { type: "checkbox", checked: r.toggle.on, disabled: !!(st && st.busy) || !!r.toggle.working, "aria-label": r.toggle.title });
    input.addEventListener("change", () => r.toggle.change(input));
    btns.append(h("label", { class: "sw", title: r.toggle.title }, input, h("i", { "aria-hidden": "true" })));
  }
  return h("div", { class: "ao-row" },
    h("div", { class: "ver-label", text: r.label }),
    h("div", { class: "ao-line" }, spin, value, btns.childNodes.length ? btns : null),
    h("div", { class: "ver-sub ao-note", text: r.note || "", title: r.note || null }));
}

const svc = (key) => ((st && st.services) || []).find((s) => s.key === key);
function certTile(host) {
  const c = ((st && st.certs) || []).find((x) => x.host === host);
  if (!c) return null;
  if (!c.ok) return { label: "Certificate", text: "Can't check", note: "Couldn't reach it on this server", tone: "warn" };
  const low = c.days_total ? c.days_left < c.days_total / 4 : c.days_left < 20;
  return { label: "Certificate", text: `${c.days_left} days left`, note: low ? "Should have renewed by now" : "Auto-renews", tone: low ? "warn" : "" };
}

// ---- the cards ----

const NAMES = { aiometadata: "AIOMetadata", aiomanager: "AIOManager", mediaflow: "MediaFlow Proxy", webhook: "Webhook relay" };

// AIOManager's sign-ups switch: open runs the script's "signups open 30" (it closes them
// itself after that), off closes them now. Either recreates its container, a few seconds,
// so the switch says so meanwhile rather than flick back while the status catches up.
const untilTime = (t) => new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
let signupsWant = null;    // "open" | "closed" while a change is being made
let signupsSince = 0;
async function setSignups(input) {
  const open = input.checked;
  signupsWant = open ? "open" : "closed";
  signupsSince = Date.now();
  render();
  try {
    const job = await api(`/api/actions/aiomanager.signups_${open ? "open" : "close"}`, { method: "POST", body: JSON.stringify({ params: {} }) });
    window.dispatchEvent(new CustomEvent("job-started"));
    const done = await waitJob(job.id);
    if (done.code !== 0) { signupsWant = null; toast(`Couldn't ${open ? "open" : "close"} sign-ups. Activity has the output.`, true); }
    else toast(open ? "Sign-ups are open for 30 minutes, then close by themselves." : "Sign-ups are closed.");
  } catch (e) {
    signupsWant = null;
    toast(e.message, true);
  }
  render();
}

function dockerCard(a) {
  const s = svc(a.id);
  const running = !!s && s.state === "running";
  const chip = !s ? ["Not running", ""] : running ? ["Running", "ok"] : s.on_purpose ? ["Stopped", ""]
    : s.state === "starting" ? ["Starting", ""] : ["Down", "bad"];
  const rows = [];
  if (a.id === "aiometadata") {
    const ver = (st && st.aiometadata && st.aiometadata.version) || a.version;
    rows.push({ label: "Configure page", link: `https://${a.domain}/configure` },
      { label: "Addon password", secret: ["aiometadata", "addon_password"], note: "For saving new configurations" },
      { label: "Dashboard", link: `https://${a.domain}/dashboard` },
      { label: "Admin key", secret: ["aiometadata", "admin_key"], note: "Opens the Dashboard" },
      { label: "Version", text: ver || "Unknown", note: "Updates are on the Overview" });
  } else if (a.id === "aiomanager") {
    const m = (st && st.aiomanager) || {};
    const open = m.signups === "open";
    // A change being made ends once the status shows it (or after a minute, whatever it shows)
    if (signupsWant && (m.signups === signupsWant || Date.now() - signupsSince > 60000)) signupsWant = null;
    const signups = signupsWant
      ? { label: "Sign-ups", text: signupsWant === "open" ? "Opening…" : "Closing…", note: "AIOManager restarts with it, a few seconds",
          toggle: { on: signupsWant === "open", title: "Working on it", working: true, change: setSignups } }
      : { label: "Sign-ups", text: open ? (m.signups_until ? `Open until ${untilTime(m.signups_until)}` : "Open") : "Closed",
          tone: open ? "warn" : "", note: open ? "Anyone with the address can make a login" : "Open for 30 minutes to make a login",
          toggle: { on: open, title: open ? "Close sign-ups now" : "Open sign-ups for 30 minutes", change: setSignups } };
    rows.push({ label: "Address", link: `https://${a.domain}` }, signups,
      { label: "Logins", text: m.logins != null ? String(m.logins) : "Unknown", note: "Each one a UUID and password" },
      { label: "Version", text: m.version || a.version || "Unknown", note: "Updates are on the Overview" });
  } else if (a.id === "mediaflow") {
    rows.push({ label: "Address", link: `https://${a.domain}` },
      { label: "API password", secret: ["mediaflow", "api_password"], note: "Goes in AIOStreams" },
      { label: "Outbound proxy", text: a.proxy || "None", note: a.proxy ? "Video goes out through it" : "Video uses this server's IP" });
  } else if (a.id === "webhook") {
    rows.push({ label: "Address", text: a.domain, note: "Gets no updates" });
  }
  const cert = certTile(a.domain);
  if (cert) rows.push(cert);
  return card({ id: a.id, name: NAMES[a.id], chip, mem: running && s.mem ? fmtBytes(s.mem) : null, rows,
    foot: a.id === "aiometadata" ? "API keys go in the Dashboard's Built-in rows only."
      : a.id === "webhook" ? "Retired. Uptime trackers can send to ntfy directly." : null });
}

function country(code) {
  try { return (code && new Intl.DisplayNames([], { type: "region" }).of(code)) || code; } catch (_) { return code; }
}

function vpnCard(v) {
  const on = v.mode === "on";
  const down = on && v.connected === false;
  const rows = [
    on ? { label: "Leaves from", text: down ? "Not connected" : [v.city, country(v.country)].filter(Boolean).join(", ") || "Unknown",
      note: v.exit_ip || "", tone: down ? "bad" : "" }
      : { label: "Leaves from", text: "This server's own IP", note: "The VPN is off" },
    { label: "Server", text: v.endpoint_host || v.endpoint_ip || "No config", note: v.endpoint_host && v.endpoint_ip ? v.endpoint_ip : "" },
  ];
  const chip = !on ? ["Off", ""] : down ? ["Not connected", "bad"] : ["Connected", "ok"];
  return card({ id: "vpn", name: "VPN", chip, rows, page: ["#vpn", "VPN page"] });
}

function alertsCard(w) {
  const last = (w.last_check || "").replace(/\s+(OK|FAIL\S*|STOPPED.*)$/, "");
  const rows = [
    // Only ever masked: the topic works like a password
    { label: "Topic", text: w.topic || "Not set", note: "Changed on the Phone alerts page" },
    { label: "Last check", text: w.running ? (last || "Not yet") : "Stopped", note: w.running ? `Every ${w.every_min || 2} minutes` : "No checks running",
      tone: w.running ? "" : "warn" },
    { label: "Watches", text: `${(w.watches || []).length} things`, note: (w.watches || []).join(", ") },
  ];
  return card({ id: "alerts", name: "Phone alerts", chip: w.running ? ["Watching", "ok"] : ["Stopped", ""], rows, page: ["#alerts", "Phone alerts page"] });
}

function card(a) {
  const btn = h("button", { class: "btn small danger", type: "button", text: "Uninstall", disabled: !!(st && st.busy), onclick: () => uninstall(a.id) });
  // With nothing to say at the foot, Uninstall sits bottom right among the values, as on the Overview
  const foot = a.page ? h("span", { class: "dim" }, "Settings are on the ", h("a", { href: a.page[0], text: a.page[1] }), ".")
    : a.foot ? h("span", { class: "dim", text: a.foot }) : null;
  return h("section", { class: "panel ao-card" },
    h("div", { class: "card-head" },
      h("h3", { text: a.name }),
      h("span", { class: "ao-head-r" }, a.mem ? h("span", { class: "dim", text: a.mem, title: "Memory in use" }) : null,
        h("span", { class: "chip " + a.chip[1], text: a.chip[0] }))),
    h("div", { class: "ao-rows" }, ...a.rows.map(tile), foot ? null : h("div", { class: "ao-btn-cell" }, btn)),
    foot ? h("div", { class: "card-foot ao-foot" }, foot, btn) : null);
}

// ---- uninstall ----
// Each one: type "uninstall", Back up first (a backup holds the add-on's
// settings, so it can be undone), and the script's own questions as tick boxes.

const waitJob = async (id) => {
  for (;;) {
    await new Promise((r) => setTimeout(r, 2000));
    try { const j = await api(`/api/jobs/${id}`); if (j.ended) return j; } catch (_) {}
  }
};

const UNINSTALL = {
  aiometadata: { title: "AIOMetadata", action: "aiometadata.uninstall", image: "Remove the AIOMetadata and Redis images too",
    body: "Its containers, its cache, its site and its saved settings are removed, including every configuration and account in its database. AIOStreams and the other add-ons stay. Remove it from your apps and AIOStreams afterwards." },
  aiomanager: { title: "AIOManager", action: "aiomanager.uninstall", image: "Remove the AIOManager image too",
    body: "Its container, its site and its saved settings are removed, including every login and everything synced to it. AIOStreams and the other add-ons stay. Addons it installed in your apps stay where they are." },
  mediaflow: { title: "MediaFlow Proxy", action: "mediaflow.uninstall", image: "Remove the MediaFlow image too",
    body: "Its container, its site, its saved settings (the API password too) and its fail2ban jail, if it has one, are removed. AIOStreams and the other add-ons stay. Switch AIOStreams' proxy setting off MediaFlow afterwards." },
  // A restore leaves the retired relay out, so a backup can't bring it back
  webhook: { title: "the webhook relay", action: "webhook.uninstall", noBackup: true,
    body: "Its container, its site, its reboot alert, its saved settings and its script are removed. AIOStreams and the other add-ons stay. It was retired, so it can't be set up again." },
  vpn: { title: "the VPN", action: "vpn.uninstall", image: "Remove the gluetun image too",
    body: "AIOStreams switches to a direct connection, and the VPN's container and everything saved for it, keys included, are removed. AIOStreams and Caddy stay." },
  alerts: { title: "phone alerts", action: "watchdog.uninstall",
    body: "Stops the checks and removes the watchdog's timer, its restart alert, and everything it saved: the topic, the event history and the daily stats. Your subscription in the ntfy app isn't touched." },
};

async function uninstall(id) {
  const u = UNINSTALL[id];
  let files = [];
  if (id === "vpn") {
    try { files = (await api("/api/vpn/configs")).filter((c) => c.kind === "file").map((c) => c.path); } catch (_) {}
  }
  const backup = h("input", { type: "checkbox", checked: true });
  const image = h("input", { type: "checkbox", checked: true });
  const confs = h("input", { type: "checkbox", checked: true });
  const gate = h("input", { class: "input", type: "text", autocomplete: "off", spellcheck: "false", "aria-label": "Type uninstall to confirm" });
  const el = h("div", { class: "opts" },
    u.noBackup ? null : h("label", { class: "check" }, backup, h("span", { text: "Back up first (a backup holds its settings, so this can be undone)" })),
    u.image ? h("label", { class: "check" }, image, h("span", { text: u.image })) : null,
    files.length ? h("label", { class: "check" }, confs, h("span", {}, "Delete the .conf ", files.length === 1 ? "file" : "files",
      " in your home folder: ", h("span", { class: "mono", text: files.map((f) => f.split("/").pop()).join(", ") }))) : null,
    h("label", { class: "field" }, h("span", { text: "Type uninstall to confirm" }), gate));
  const res = await ask({ title: `Uninstall ${u.title}?`, confirmLabel: "Uninstall", danger: true,
    body: u.body + " Its card goes afterwards.",
    options: { el, gate, word: "uninstall",
      read: () => ({ backup: !u.noBackup && backup.checked, remove_image: !!u.image && image.checked, delete_confs: files.length > 0 && confs.checked, confirm: gate.value.trim() }) } });
  if (!res) return;
  try {
    let before = null;
    if (res.backup) {
      const b = await api("/api/actions/stack.backup", { method: "POST", body: JSON.stringify({ params: {} }) });
      openJob(b.id);
      window.dispatchEvent(new CustomEvent("job-started"));
      const done = await waitJob(b.id);
      if (done.code !== 0) { toast(`The backup failed, so ${u.title} wasn't uninstalled.`, true); return; }
      // The uninstall's output replaces the backup's in the drawer; its first line keeps a way back
      const made = (done.lines || []).map((l) => (/Backup written\b.*?(aiostreams-backup-[\w.-]+?\.tar\.gz)/.exec(l.t || "") || [])[1]).find(Boolean);
      before = { text: made ? `Backed up first: ${made}.` : "Backed up first.", id: b.id };
    }
    const params = { confirm: res.confirm };
    if (u.image) params.remove_image = res.remove_image;
    if (id === "vpn") params.delete_confs = res.delete_confs;
    const job = await api(`/api/actions/${u.action}`, { method: "POST", body: JSON.stringify({ params }) });
    openJob(job.id, false, before);
    window.dispatchEvent(new CustomEvent("job-started"));
  } catch (e) {
    toast(e.message, true);
  }
}

// ---- loading ----

async function load() {
  if (loading || !st) return;
  loading = true;
  const root = $("#addons-root");
  if (!data) { clear(root); root.append(h("p", { class: "dim", text: "Reading the add-ons' settings…" })); }
  try {
    const [list, vpn, wd] = await Promise.all([
      api("/api/addons"),
      st.vpn === "on" || st.vpn === "off" ? api("/api/vpn").catch(() => null) : null,
      st.watchdog && st.watchdog.configured ? api("/api/watchdog").catch(() => null) : null,
    ]);
    data = { list, vpn, wd };
  } catch (e) {
    if (!data) { clear(root); root.append(h("p", { class: "empty", text: e.message || "Couldn't load it." })); }
    return;
  } finally { loading = false; }
  render();
}

function render() {
  if (!data) return;
  const root = $("#addons-root");
  const cards = data.list.map(dockerCard);
  if (data.vpn && data.vpn.mode !== "none") cards.push(vpnCard(data.vpn));
  if (data.wd && data.wd.configured) cards.push(alertsCard(data.wd));
  clear(root);
  root.append(cards.length ? h("div", { class: "ao-grid" }, ...cards)
    : h("p", { class: "dim", text: "No add-ons installed. The Scripts tab lists the optional ones." }));
}

export function show(status) {
  st = status;
  render();
  return load();
}

// A job just ended (an uninstall, say): look again
let wasBusy = false;
export function setStatus(status) {
  st = status;
  const busy = !!status.busy;
  if (wasBusy && !busy) load();
  else if (busy !== wasBusy || signupsWant) render();
  wasBusy = busy;
}
