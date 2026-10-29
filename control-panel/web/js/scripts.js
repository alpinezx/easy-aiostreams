// The Scripts tab: the stack's setup scripts, whether each is on this server and matches
// GitHub's main, and the commands to run or update them, over SSH or in the panel's terminal.
import { $, h, api, clear, toast, ago } from "./util.js";
import { shellAs, runInTerminal } from "./terminal.js";
import { ask } from "./actions.js";

const REPO = "https://github.com/alpinezx/easy-aiostreams";
const GUIDE = `${REPO}/blob/main/docs/basic/control-panel.md`;
const ADDONS_GUIDE = `${REPO}/blob/main/docs/other-scripts.md`;
const RAW_BASE = "https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/";
const FALLBACK = [
  { id: "aiostreams", label: "AIOStreams menu", file: "setup-aiostreams.sh", present: true },
  { id: "aiometadata", label: "AIOMetadata", file: "setup-aiometadata.sh", present: false },
  { id: "aiomanager", label: "AIOManager", file: "setup-aiomanager.sh", present: false },
  { id: "watchdog", label: "Phone alerts", file: "setup-watchdog.sh", present: false },
  { id: "vpn", label: "VPN (Gluetun)", file: "setup-vpn-gluetun.sh", present: false },
  { id: "mediaflow", label: "MediaFlow Proxy", file: "setup-mediaflow.sh", present: false },
];
// The AIOStreams menu runs backup and restore through setup-backup.sh, and
// Maintenance through setup-maintenance.sh, and only downloads them when
// they're missing, so its Update refreshes all three.
const UPDATE_WITH = { aiostreams: ["setup-backup.sh", "setup-maintenance.sh"] };

let cmp = null, cmpLoading = false, cmpAsked = false, last = null;

// ---------------- the panel's own version and update ----------------
let ver = null, verLoading = false;

export async function loadPanelVersion(force) {
  verLoading = true;
  if (last) render();
  try { ver = await api(`/api/panel/version${force ? "?force=1" : ""}`); }
  catch (e) { ver = { ...(ver || {}), latest: null, newer: false, error: e.message }; }
  verLoading = false;
  versionChip();
  if (last) render();
  if (force) toast(ver.error ? `Couldn't check. ${ver.error}` : ver.newer ? `Control panel ${ver.latest} is available.` : "The control panel is up to date.", !!ver.error);
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

function panelSection() {
  const v = ver || {};
  const branch = v.branch && v.branch !== "main" ? ` (${v.branch} branch, for testing)` : "";
  let state;
  if (verLoading && !ver) state = h("span", { class: "chip", text: "Checking…" });
  else if (v.running) state = h("span", { class: "chip warn", text: "Updating…" });
  else if (v.newer) state = h("span", { class: "chip warn", text: `${v.latest} available` });
  else if (v.latest) state = h("span", { class: "chip ok", text: "Up to date" });
  else if (v.error) state = h("span", { class: "chip warn", title: v.error, text: "Couldn't check" });
  const checked = v.checked_at ? `Checked against GitHub${branch} ${ago(v.checked_at)}.` : "";
  const lastLine = v.last
    ? h("details", {}, h("summary", { text: `Last update ${ago(v.last.at)}: ${v.last.ok ? "finished" : "didn't finish"}. Show its output` }),
        h("pre", { text: v.last.tail.join("\n") }))
    : null;
  return h("section", { class: "panel panel-ver" },
    h("div", { class: "panel-ver-head" },
      h("h3", { text: "Control panel" }),
      v.current ? h("span", { class: "chip", text: `v${v.current}` }) : null,
      state,
      h("span", { class: "btns" },
        h("button", { class: "btn small", type: "button", text: verLoading ? "Checking…" : "Check now", disabled: verLoading,
          onclick: () => loadPanelVersion(true) }),
        v.newer && !v.running ? h("button", { class: "btn small primary", type: "button", text: `Update to ${v.latest}`, onclick: () => updatePanel(v) }) : null)),
    checked ? h("p", { class: "dim", text: checked }) : null,
    lastLine);
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
      if (j.current !== oldVersion || (wasDown && !j.running)) { location.reload(); return; }
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
  if (force) toast(cmp.error ? `Couldn't compare with GitHub. ${cmp.error}` : "Compared with GitHub.", !!cmp.error);
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

function row(x, cmd, updateCmd, termOn) {
  const tags = [x.present
    ? h("span", { class: "sdot-tag", "data-s": "ok", title: "On this server" }, h("i", { class: "sdot", "aria-hidden": "true" }), h("span", { class: "sr-only", text: "On this server" }))
    : h("span", { class: "sdot-tag", "data-s": "off", text: "Not installed" })];
  if (x.present && differs(x)) {
    tags.push(h("span", { class: "chip warn small-chip", text: "Differs from GitHub",
      title: `This copy doesn't match the one on GitHub (${(cmp && cmp.branch) || "main"} branch). Update fetches GitHub's.` }));
  }
  // An add-on's script that's still here once the add-on is uninstalled can go
  const removable = x.present && x.in_use === false && x.id !== "aiostreams";
  const run = h("button", { class: "btn small", type: "button", text: x.present ? "Run in terminal" : "Get and run", disabled: !termOn,
    title: !termOn ? "Needs the panel's web terminal, which is switched off (see the note above)."
      : x.present ? "Types the command into the panel's terminal. Check it, then press Enter."
      : "Types the command into the panel's terminal: it downloads the script, then runs it. Check it, then press Enter.",
    onclick: () => runInTerminal(cmd) });
  // The command itself is on Copy's tooltip; spelt out, it crowded the row (and phones)
  return h("li", {},
    h("span", { class: "cmd-label" }, x.label, ...tags),
    h("span", { class: "cmd-btns" }, run,
      copyBtn("Copy", cmd, "Copied. Paste it into an SSH session or the Terminal tab.", cmd),
      // An invisible stand-in keeps the buttons lined up down the list.
      updateCmd ? h("button", { class: "btn small quiet", type: "button", text: "Update",
          title: `Replace it with GitHub's newest copy (${(cmp && cmp.branch) || "main"} branch)`, onclick: () => updateScript(x, updateCmd) })
        : h("span", { class: "btn small quiet btn-spacer", "aria-hidden": "true", text: "Update" }),
      removable ? h("button", { class: "btn small quiet danger", type: "button", text: "Remove",
        title: `Deletes ${x.file} from this server. ${x.label} isn't set up, so nothing else changes.`, onclick: () => removeScript(x) })
        : h("span", { class: "btn small quiet btn-spacer", "aria-hidden": "true", text: "Remove" })));
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
  const fetchCmd = (f) => `curl -fsSL ${RAW_BASE}${f} -o ${f}.new && chmod 755 ${f}.new && mv ${f}.new ${f}`;
  const fetchTo = (f) => asUser ? `sudo sh -c 'cd ${dir} && ${fetchCmd(f)}'` : `cd ${dir} && ${fetchCmd(f)}`;
  const updateOf = (x) => {
    const files = [x.file, ...(UPDATE_WITH[x.id] || [])];
    return `${files.map(fetchTo).join(" && ")} && echo "Updated ${files.join(" and ")}"`;
  };
  const rowOf = (x) => x.present
    ? row(x, `sudo bash ${dir}/${x.file}`, updateOf(x), terminalOn)
    : row(x, `${fetchTo(x.file)} && sudo bash ${dir}/${x.file}`, null, terminalOn);
  // The AIOStreams script comes with every install; the rest are optional extras, kept apart
  // so the list doesn't read as a checklist to complete.
  const core = scripts.filter((x) => x.id === "aiostreams"), addons = scripts.filter((x) => x.id !== "aiostreams");

  const checked = cmpLoading ? "Comparing with GitHub…"
    : !cmp ? "" : cmp.error ? `Couldn't compare with GitHub: ${cmp.error}`
    : `Compared with GitHub${cmp.branch && cmp.branch !== "main" ? ` (${cmp.branch} branch, for testing)` : ""} ${ago(cmp.checked_at)}.`;

  box.append(panelSection());
  if (!terminalOn) {
    box.append(h("p", { class: "note" }, "Run in terminal needs the panel's web terminal, which is switched off. Switch it on with setup-ui.sh over SSH (see the ",
      h("a", { href: GUIDE, target: "_blank", rel: "noopener noreferrer", text: "control panel guide" }), "). Copy and Update work either way."));
  }
  box.append(h("section", { class: "panel scripts-panel" },
    h("ul", { class: "cmds" }, ...core.map(rowOf)),
    addons.length ? h("h3", { class: "sub-head", text: "Optional add-ons" }) : null,
    addons.length ? h("p", { class: "addons-note" }, h("b", { text: "These are optional. Most setups don't need any of them." }),
      " Read what each one does before adding it: ",
      h("a", { href: ADDONS_GUIDE, target: "_blank", rel: "noopener noreferrer", text: "Other scripts guide" }), ".") : null,
    addons.length ? h("ul", { class: "cmds" }, ...addons.map(rowOf)) : null,
    h("div", { class: "scripts-foot" },
      h("span", { class: "dim", text: checked }),
      h("button", { class: "btn small", type: "button", text: cmpLoading ? "Checking…" : "Check now", disabled: cmpLoading,
        title: "Compare the scripts here with GitHub's copies now", onclick: () => loadCompare(true) }))));
}
