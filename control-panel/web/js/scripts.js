// The Scripts tab: the stack's setup scripts, whether each is on this server and matches
// GitHub's main, and the commands to run or update them, over SSH or in the panel's terminal.
import { $, h, api, clear, toast, ago } from "./util.js";
import { shellAs, runInTerminal } from "./terminal.js";
import { ask } from "./actions.js";
import { openChangelog } from "./releases.js";

const REPO = "https://github.com/alpinezx/easy-aiostreams";
const TERMINAL_GUIDE = `${REPO}/blob/main/docs/basic/control-panel.md#turning-on-the-terminal`;
const ADDONS_GUIDE = `${REPO}/blob/main/docs/other-scripts.md`;
const RAW_BASE = "https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/scripts/";
const FALLBACK = [
  { id: "aiostreams", label: "AIOStreams", file: "setup-aiostreams.sh", present: true },
  { id: "aiometadata", label: "AIOMetadata", file: "setup-aiometadata.sh", present: false },
  { id: "aiomanager", label: "AIOManager", file: "setup-aiomanager.sh", present: false },
  { id: "watchdog", label: "Phone alerts", file: "setup-watchdog.sh", present: false },
  { id: "vpn", label: "VPN (Gluetun)", file: "setup-vpn-gluetun.sh", present: false },
  { id: "mediaflow", label: "MediaFlow Proxy", file: "setup-mediaflow.sh", present: false },
];
// The AIOStreams menu runs backup and restore through setup-backup.sh,
// Maintenance through setup-maintenance.sh and the Cloudflare Tunnel through
// setup-tunnel.sh, and only downloads them when they're missing, so its Update
// refreshes them all (one not on this server doesn't count as differing).
const UPDATE_WITH = { aiostreams: ["setup-backup.sh", "setup-maintenance.sh", "setup-tunnel.sh"] };
// On GitHub the AIOStreams script and those three sit in scripts/core, the add-ons in scripts/others.
const CORE = ["setup-aiostreams.sh", ...UPDATE_WITH.aiostreams];
const rawUrl = (f) => `${RAW_BASE}${CORE.includes(f) ? "core" : "others"}/${f}`;

let cmp = null, cmpLoading = false, cmpAsked = false, last = null;

// ---------------- the panel's own version and update ----------------
let ver = null, verLoading = false, verRecheck = 0;

export async function loadPanelVersion(force) {
  verLoading = true;
  if (last) render();
  try { ver = await api(`/api/panel/version${force ? "?force=1" : ""}`); }
  catch (e) { ver = { ...(ver || {}), latest: null, newer: false, error: e.message }; }
  verLoading = false;
  versionChip();
  if (last) render();
  // An update still running (started elsewhere, or just ending): ask again until it's over
  if (ver && ver.running) { clearTimeout(verRecheck); verRecheck = setTimeout(() => loadPanelVersion(false), 3000); }
}

export function versionChip(current) {
  const chip = $("#panel-version");
  const cur = current || (ver && ver.current);
  if (!chip || !cur) return;
  chip.hidden = false;
  const newer = ver && ver.newer;
  chip.className = "chip ver-chip" + (newer ? " warn" : "");
  // Kept short: the rail is narrow. The tooltip and the Scripts tab name the new version.
  chip.textContent = newer ? `v${cur} ↑` : `v${cur}`;
  chip.title = newer ? `Control panel ${ver.latest} is available. Update it on the Scripts tab.` : "The control panel's version. Updates are on the Scripts tab.";
}

// The line at the top of the page: when GitHub was last asked, the panel's last update, and the
// page's own buttons. One Check now covers the panel and the scripts.
function statusLine(terminalOn) {
  const v = ver || {};
  const branch = v.branch && v.branch !== "main" ? ` (${v.branch} branch, for testing)` : "";
  const busy = verLoading || cmpLoading;
  const times = [v.checked_at, cmp && !cmp.error ? cmp.checked_at : null].filter(Boolean);
  const checked = busy ? "Checking GitHub…"
    : cmp && cmp.error ? `Couldn't compare the scripts with GitHub: ${cmp.error}`
    : times.length ? `Checked against GitHub${branch} ${ago(Math.min(...times))}.` : "";
  // Only a panel update that didn't finish: the panel restarted since, so this is the one place its output is left.
  // One that finished needs no line.
  const lastLine = v.last && !v.last.ok && !v.running
    ? h("details", {}, h("summary", { text: `Last update ${ago(v.last.at)}: didn't finish. Show its output` }),
        h("pre", { text: v.last.tail.join("\n") }))
    : null;
  return h("div", { class: "scripts-status" },
    h("div", { class: "scripts-status-text" }, checked ? h("p", { class: "dim", text: checked }) : null,
      // A setting, not a fault (many keep the web terminal off), so a plain line rather than an amber note
      terminalOn ? null : h("p", { class: "dim term-off" }, "Run in terminal is off with the web terminal. ",
        // on phones this half takes a line of its own, so the link never splits
        h("span", { class: "term-off-how" },
          h("a", { href: TERMINAL_GUIDE, target: "_blank", rel: "noopener noreferrer", text: "Switch it on over SSH" }), " if you want it.")),
      lastLine),
    h("span", { class: "btns" },
      h("button", { class: "btn small", type: "button", text: "What's new", title: "The changes since this panel's version, from the project's changelog",
        onclick: showChangelog }),
      h("button", { class: "btn small", type: "button", text: busy ? "Checking…" : "Check now", disabled: busy,
        title: "Check the panel's version and compare the scripts here with GitHub's copies now", onclick: checkAll })));
}

async function checkAll() {
  await Promise.all([loadPanelVersion(true), loadCompare(true)]);
  const problem = (ver && ver.error) || (cmp && cmp.error);
  if (problem) { toast(`Couldn't check. ${problem}`, true); return; }
  const n = ((last && last.status && last.status.scripts) || []).filter((x) => x.present && differs(x)).length;
  const found = [ver && ver.newer ? `Control panel ${ver.latest} is available` : "",
    n ? `${n === 1 ? "A script differs" : `${n} scripts differ`} from GitHub` : ""].filter(Boolean);
  toast(found.length ? `${found.join(". ")}.` : "Everything matches GitHub.");
}

// The panel's own row. Its Update rebuilds the panel, so unlike a script's it only appears when
// there's a newer version. setup-ui.sh refuses from the panel's terminal whatever would cut it off.
function panelRow(cmd, termOn) {
  const v = ver || {};
  let state;
  if (verLoading && !ver) state = h("span", { class: "chip small-chip", text: "Checking…" });
  else if (v.running) state = h("span", { class: "chip warn small-chip", text: "Updating…" });
  else if (v.newer) state = h("span", { class: "chip warn small-chip", text: `${v.latest} available` });
  else if (v.latest) state = h("span", { class: "chip ok small-chip", text: "Up to date" });
  else if (v.error) state = h("span", { class: "chip warn small-chip", title: v.error, text: "Couldn't check" });
  return h("li", {},
    h("span", { class: "cmd-label" }, sdot("ok", "Running"), "Control panel",
      v.current ? h("span", { class: "chip small-chip", text: `v${v.current}` }) : null, state),
    h("span", { class: "cmd-btns" }, runBtn(true, cmd, termOn),
      copyBtn("Copy", cmd, "Copied. Paste it into an SSH session or the Terminal tab.", cmd),
      v.newer && !v.running ? h("button", { class: "btn small primary", type: "button", text: "Update",
          title: `Update the control panel to ${v.latest}`, onclick: () => updatePanel(v) }) : spacer("Update"),
      spacer("Remove")));
}

// What's new: the project's changelog, entries since this panel's version marked
let logLoading = false;
export async function showChangelog(e) {
  if (logLoading) return;
  logLoading = true;
  // GitHub can take up to 10s to fail; say so on the button meanwhile
  const btn = e && e.currentTarget;
  if (btn) { btn.disabled = true; btn.textContent = "Loading…"; }
  try {
    const log = await api("/api/panel/changelog");
    if (!log.entries.length) toast(`Couldn't load the changelog. ${log.error || "It's empty."}`, true);
    else openChangelog(log);
  } catch (err) { toast(`Couldn't load the changelog. ${err.message}`, true); }
  finally {
    logLoading = false;
    if (btn) { btn.disabled = false; btn.textContent = "What's new"; }
  }
}

async function updatePanel(v) {
  const ok = await ask({ title: `Update the control panel to ${v.latest}?`, confirmLabel: "Update",
    body: "It downloads the new version from GitHub and rebuilds the panel. The panel is away for about a minute and this page reloads by itself. AIOStreams and your add-ons aren't touched." });
  if (!ok) return;
  let res;
  try { res = await api("/api/panel/update", { method: "POST", body: JSON.stringify({ confirm: "update" }) }); }
  catch (e) { toast(e.message || "Couldn't start the update.", true); return; }
  if (res.demo) { toast("Demo mode: nothing was updated."); return; }
  waitForNewPanel(v.current);
}

// The update runs outside the panel and replaces it. Wait for the new one to answer, or for the
// update's own log to say it stopped, whichever comes first.
function waitForNewPanel(oldVersion) {
  const note = h("p", { class: "dim", text: "Downloading and rebuilding. This page reloads when the new version answers." });
  const box = h("div", { class: "veil-box" }, h("h3", { text: "Updating the control panel" }), note);
  const veil = h("div", { class: "veil", role: "alert" }, box);
  document.body.append(veil);
  const started = Date.now() / 1000;
  let wasDown = false;
  const poll = async () => {
    let j = null;
    try {
      const r = await fetch("/api/panel/version", { credentials: "same-origin", cache: "no-store", headers: { "X-UI-Request": "1" } });
      if (r.ok) j = await r.json(); else wasDown = true;
    } catch (_) { wasDown = true; }
    if (j) {
      // The new panel can answer a second or two before the update job writes its last line and ends:
      // reload only once the job is over, or the page shows Updating and "didn't finish" until a refresh.
      if (!j.running && (j.current !== oldVersion || wasDown)) { location.reload(); return; }
      if (!j.running && j.last && j.last.at >= started - 5 && !j.last.ok) {
        note.textContent = "The update stopped before the new panel was built. Nothing was changed. Its output:";
        box.append(h("pre", { class: "veil-log", text: j.last.tail.join("\n") }),
          h("button", { class: "btn small", type: "button", text: "Close", onclick: () => { veil.remove(); loadPanelVersion(false); } }));
        return;
      }
    }
    if (Date.now() / 1000 - started > 900) {
      note.textContent = "Taking longer than usual. Over SSH, /opt/aiostreams/ui-state/last-update.log shows how far it got.";
      return;
    }
    setTimeout(poll, 3000);
  };
  setTimeout(poll, 4000);
}

async function loadCompare(force) {
  cmpLoading = true;
  if (last) render();
  try { cmp = await api(`/api/scripts/compare${force ? "?force=1" : ""}`); }
  catch (e) { cmp = { files: {}, error: e.message }; }
  cmpLoading = false;
  pill();
  if (last) render();
}

// The "Script updates" pill at the top: how many rows here differ from GitHub's copy.
// Checked once when the panel opens (GitHub's answer is kept for hours), and again
// whenever the Scripts tab compares or updates.
let statusScripts = null;
export function checkScripts(status) {
  statusScripts = (status && status.scripts) || statusScripts;
  if (!cmpAsked) { cmpAsked = true; loadCompare(false); } else pill();
}

// The Overview rebuilds its top row now and then; it calls this to fill the pill in again
export function pill() {
  const rows = (last && last.status && last.status.scripts) || statusScripts || [];
  const n = cmp && cmp.files && !cmp.error ? rows.filter((x) => x.present && differs(x)).length : 0;
  const branch = cmp && cmp.branch && cmp.branch !== "main" ? ` (${cmp.branch} branch)` : "";
  for (const el of [$("#scripts-pill")]) {
    if (!el) continue;
    el.hidden = !n;
    el.textContent = n === 1 ? "Script update" : `${n} script updates`;
    el.title = `${n === 1 ? "A script" : `${n} scripts`} here ${n === 1 ? "differs" : "differ"} from GitHub's copy${branch}. Update ${n === 1 ? "it" : "them"} on the Scripts tab.`;
  }
}

export function show(status, terminalOn) {
  last = { status, terminalOn };
  if (!cmpAsked) { cmpAsked = true; loadCompare(false); }
  if (!ver && !verLoading) loadPanelVersion(false);
  render();
}

// Whether this row's script(s) differ from main: true, false, or null when it can't be told.
function differs(x) {
  if (!cmp || !cmp.files) return null;
  const files = [x.file, ...(UPDATE_WITH[x.id] || [])].map((f) => cmp.files[f]).filter((f) => f && f.present);
  if (!files.length || files.some((f) => f.differs == null)) return files.some((f) => f.differs) ? true : null;
  return files.some((f) => f.differs);
}

function copyBtn(text, cmd, msg, title) {
  return h("button", { class: "btn small quiet", type: "button", text, title, onclick: async () => {
    try { await navigator.clipboard.writeText(cmd); toast(msg); } catch (_) { toast(cmd); }
  } });
}

// An invisible stand-in keeps the buttons lined up down the list.
const spacer = (text) => h("span", { class: "btn small quiet btn-spacer", "aria-hidden": "true", "data-for": text, text });

// Run in terminal and Get and run are the same width: each holds the other's words, unseen
function runBtn(present, cmd, termOn) {
  const [label, other] = present ? ["Run in terminal", "Get and run"] : ["Get and run", "Run in terminal"];
  return h("button", { class: "btn small run-btn", type: "button", disabled: !termOn,
    title: !termOn ? "Needs the panel's web terminal, which is switched off (see the note above)."
      : present ? "Types the command into the panel's terminal. Check it, then press Enter."
      : "Types the command into the panel's terminal: it downloads the script, then runs it. Check it, then press Enter.",
    onclick: () => runInTerminal(cmd) }, h("span", { text: label }), h("span", { class: "run-alt", "aria-hidden": "true", text: other }));
}

// Each row's state as a dot before its name: green, set up here; amber, the script is here but
// its add-on isn't set up (Remove deletes it); grey, not on this server
function sdot(s, why) {
  return h("span", { class: "sdot-tag", "data-s": s, title: why }, h("i", { class: "sdot", "aria-hidden": "true" }), h("span", { class: "sr-only", text: why }));
}

function row(x, cmd, updateCmd, termOn) {
  const idle = x.present && x.in_use === false && x.id !== "aiostreams";
  const dot = !x.present ? sdot("off", "Not on this server") : idle ? sdot("warn", `The script is here, but ${x.label} isn't set up`) : sdot("ok", "Set up on this server");
  const tags = [!x.present ? h("span", { class: "sdot-word", "data-s": "off", text: "Not downloaded or installed" })
    : idle ? h("span", { class: "sdot-word", "data-s": "warn", text: "Downloaded, not set up",
      title: `${x.file} is on this server, but ${x.label} isn't set up. Get it going with Run in terminal, or Remove deletes the script.` }) : null];
  if (x.present && differs(x)) {
    tags.push(h("span", { class: "chip warn small-chip", text: "Differs from GitHub",
      title: `This copy doesn't match the one on GitHub (${(cmp && cmp.branch) || "main"} branch). Update fetches GitHub's.` }));
  }
  // An add-on's script that's still here once the add-on is uninstalled can go
  const removable = idle;
  // The command itself is on Copy's tooltip; spelt out, it crowded the row (and phones)
  return h("li", {},
    h("span", { class: "cmd-label" }, dot, x.label, ...tags),
    h("span", { class: "cmd-btns" }, runBtn(x.present, cmd, termOn),
      copyBtn("Copy", cmd, "Copied. Paste it into an SSH session or the Terminal tab.", cmd),
      updateCmd ? h("button", { class: "btn small quiet", type: "button", text: "Update",
          title: `Replace it with GitHub's newest copy (${(cmp && cmp.branch) || "main"} branch)`, onclick: () => updateScript(x, updateCmd) })
        : spacer("Update"),
      removable ? h("button", { class: "btn small quiet danger", type: "button", text: "Remove",
        title: `Deletes ${x.file} from this server. ${x.label} isn't set up, so nothing else changes.`, onclick: () => removeScript(x) })
        : spacer("Remove")));
}

// Update replaces the script here with GitHub's main copy, checked before anything changes.
// The command is still offered, for anyone who'd rather run it over SSH.
async function updateScript(x, cmd) {
  const files = [x.file, ...(UPDATE_WITH[x.id] || [])].join(" and ");
  const copy = h("button", { class: "btn small quiet", type: "button", text: "Copy the command instead", onclick: async () => {
    try { await navigator.clipboard.writeText(cmd); toast("Copied. Paste it into an SSH session or the Terminal tab."); } catch (_) { toast(cmd); }
  } });
  const ok = await ask({ title: `Update ${x.label}?`, confirmLabel: "Update",
    body: `Replaces ${files} on this server with GitHub's newest copy (the ${(cmp && cmp.branch) || "main"} branch, which this panel follows). `
      + "It's downloaded and checked first, so a failed download changes nothing.",
    options: { el: h("div", { class: "opts upd-opts" }, copy), read: () => true } });
  if (!ok) return;
  try {
    const r = await api(`/api/scripts/${encodeURIComponent(x.id)}/update`, { method: "POST" });
    toast(`Updated ${r.updated.join(" and ")}.` + (r.note ? ` ${r.note}` : ""), false);
    await loadCompare(false);
    show(await api("/api/status"), last.terminalOn);
  } catch (e) { toast(e.message || "Couldn't update it.", true); }
}

async function removeScript(x) {
  const ok = await ask({ title: `Remove ${x.file}?`, confirmLabel: "Remove", danger: true,
    body: `${x.label} isn't set up on this server, so its script only takes up a line here. Get and run fetches it again any time.` });
  if (!ok) return;
  try {
    await api(`/api/scripts/${encodeURIComponent(x.id)}/remove`, { method: "POST" });
    toast(`Removed ${x.file}.`);
    show(await api("/api/status"), last.terminalOn);
  } catch (e) { toast(e.message || "Couldn't remove it.", true); }
}

function render() {
  const { status, terminalOn } = last;
  const box = $("#scripts-root");
  clear(box);
  const dir = (status && status.install_dir) || "/opt/aiostreams";
  const scripts = (status && status.scripts) || FALLBACK;
  const uc = status && status.user_copy;
  const asUser = uc && shellAs(status) !== "root";
  // Scripts live in the install folder, which only root can write to, so as the user every step
  // goes through sudo. Fetch to a temporary name first, so a failed download never leaves a broken script.
  const fetchCmd = (f) => `curl -fsSL ${rawUrl(f)} -o ${f}.new && chmod 755 ${f}.new && mv ${f}.new ${f}`;
  const fetchTo = (f) => asUser ? `sudo sh -c 'cd ${dir} && ${fetchCmd(f)}'` : `cd ${dir} && ${fetchCmd(f)}`;
  const updateOf = (x) => {
    const files = [x.file, ...(UPDATE_WITH[x.id] || [])];
    return `${files.map(fetchTo).join(" && ")} && echo "Updated ${files.join(" and ")}"`;
  };
  const rowOf = (x) => x.present
    ? row(x, `sudo bash ${dir}/${x.file}`, updateOf(x), terminalOn)
    : row(x, `${fetchTo(x.file)} && sudo bash ${dir}/${x.file}`, null, terminalOn);
  // The panel and the AIOStreams script come with every install; the rest are optional extras, kept apart
  // so the list doesn't read as a checklist to complete.
  const core = scripts.filter((x) => x.id === "aiostreams"), addons = scripts.filter((x) => x.id !== "aiostreams");

  box.append(statusLine(terminalOn));
  box.append(h("section", { class: "panel scripts-panel scripts-core" },
    h("ul", { class: "cmds" }, panelRow(`sudo bash ${dir}/control-panel/setup-ui.sh`, terminalOn), ...core.map(rowOf))));
  if (addons.length) {
    box.append(h("section", { class: "panel scripts-panel" },
      h("h3", { class: "sub-head", text: "Optional add-ons" }),
      h("p", { class: "addons-note" }, h("b", { text: "Most setups need none of these." }), " ",
        // "Read" and the link wrap together, so the link never starts a line alone
        h("span", { class: "nowrap" }, "Read ", h("a", { href: ADDONS_GUIDE, target: "_blank", rel: "noopener noreferrer", text: "what each one does" })), " first."),
      h("ul", { class: "cmds" }, ...addons.map(rowOf))));
  }
}
