// The Scripts tab: the stack's setup scripts, whether each is on this server and matches
// GitHub's main, and the commands to run or update them, over SSH or in the panel's terminal.
import { $, h, api, clear, toast, ago } from "./util.js";
import { shellAs, runInTerminal } from "./terminal.js";

const REPO = "https://github.com/alpinezx/easy-aiostreams";
const GUIDE = `${REPO}/blob/main/docs/basic/control-panel.md`;
const RAW_BASE = "https://raw.githubusercontent.com/alpinezx/easy-aiostreams/refs/heads/main/";
const FALLBACK = [
  { id: "aiostreams", label: "AIOStreams menu", file: "setup-aiostreams.sh", present: true },
  { id: "vpn", label: "VPN (Gluetun)", file: "setup-vpn-gluetun.sh", present: false },
  { id: "mediaflow", label: "MediaFlow Proxy", file: "setup-mediaflow.sh", present: false },
  { id: "watchdog", label: "Phone alerts", file: "setup-watchdog.sh", present: false },
  { id: "webhook", label: "Webhook relay", file: "setup-webhook.sh", present: false },
];
// The AIOStreams menu runs backup and restore through setup-backup.sh and only
// downloads it when it's missing, so its Update refreshes both.
const UPDATE_WITH = { aiostreams: ["setup-backup.sh"] };

let cmp = null, cmpLoading = false, cmpAsked = false, last = null;

async function loadCompare(force) {
  cmpLoading = true;
  if (last) render();
  try { cmp = await api(`/api/scripts/compare${force ? "?force=1" : ""}`); }
  catch (e) { cmp = { files: {}, error: e.message }; }
  cmpLoading = false;
  if (last) render();
  if (force) toast(cmp.error ? `Couldn't compare with GitHub. ${cmp.error}` : "Compared with GitHub.", !!cmp.error);
}

export function show(status, terminalOn) {
  last = { status, terminalOn };
  if (!cmpAsked) { cmpAsked = true; loadCompare(false); }
  render();
}

// Whether this row's script(s) differ from main: true, false, or null when it can't be told.
function differs(x) {
  if (!cmp || !cmp.files) return null;
  const files = [x.file, ...(UPDATE_WITH[x.id] || [])].map((f) => cmp.files[f]).filter((f) => f && f.present);
  if (!files.length || files.some((f) => f.differs == null)) return files.some((f) => f.differs) ? true : null;
  return files.some((f) => f.differs);
}

function copyBtn(text, cmd, msg) {
  return h("button", { class: "btn small quiet", type: "button", text, onclick: async () => {
    try { await navigator.clipboard.writeText(cmd); toast(msg); } catch (_) { toast(cmd); }
  } });
}

function row(x, cmd, updateCmd, termOn) {
  const tags = [x.present
    ? h("span", { class: "sdot-tag", "data-s": "ok", title: "Found on this server" }, h("i", { class: "sdot", "aria-hidden": "true" }), h("span", { class: "sr-only", text: "Found on this server" }))
    : h("span", { class: "sdot-tag", "data-s": "warn" }, h("i", { class: "sdot", "aria-hidden": "true" }), "Get and run")];
  if (x.present && differs(x)) {
    tags.push(h("span", { class: "chip warn small-chip", text: "Differs from GitHub",
      title: "This copy doesn't match the one on GitHub's main branch. Update fetches GitHub's. (Expected while you're testing changes from dev.)" }));
  }
  const run = h("button", { class: "btn small", type: "button", text: "Run in terminal", disabled: !termOn,
    title: termOn ? "Types the command into the panel's terminal. Check it, then press Enter." : "Needs the panel's web terminal, which is switched off (see the note above).",
    onclick: () => runInTerminal(cmd) });
  return h("li", {},
    h("span", { class: "cmd-label" }, x.label, ...tags),
    h("code", { class: "mono cmd", text: cmd, title: cmd }),
    h("span", { class: "cmd-btns" }, run,
      copyBtn("Copy", cmd, "Copied. Paste it into an SSH session or the Terminal tab."),
      // An invisible stand-in keeps the buttons lined up down the list.
      updateCmd ? copyBtn("Update", updateCmd, "Copied. Paste it into an SSH session or the Terminal tab to fetch the newest version from GitHub.")
        : h("span", { class: "btn small quiet btn-spacer", "aria-hidden": "true", text: "Update" })));
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
  const rows = scripts.map((x) => x.present
    ? row(x, `sudo bash ${dir}/${x.file}`, updateOf(x), terminalOn)
    : row(x, `${fetchTo(x.file)} && sudo bash ${dir}/${x.file}`, null, terminalOn));

  const checked = cmpLoading ? "Comparing with GitHub…"
    : !cmp ? "" : cmp.error ? `Couldn't compare with GitHub: ${cmp.error}`
    : `Compared with GitHub's main branch ${ago(cmp.checked_at)}.`;

  if (!terminalOn) {
    box.append(h("p", { class: "note" }, "Run in terminal needs the panel's web terminal, which is switched off. Switch it on with setup-ui.sh over SSH (see the ",
      h("a", { href: GUIDE, target: "_blank", rel: "noopener noreferrer", text: "control panel guide" }), "). Copy and Update work either way."));
  }
  box.append(h("section", { class: "panel scripts-panel" },
    h("p", { class: "dim", text: "The AIOStreams script comes with the install, and its menu also runs backups and restores (options 7 and 8). The others are separate downloads. A green dot means the script is on this server; an orange Get and run means it is not yet, and its command downloads it and then runs it." }),
    h("p", { class: "dim", text: "Update fetches the newest version of a script you already have from GitHub, without running it. The AIOStreams menu's Update also fetches the backup script it uses, so the two stay in step." }),
    h("ul", { class: "cmds" }, ...rows),
    h("div", { class: "scripts-foot" },
      h("span", { class: "dim", text: checked }),
      h("button", { class: "btn small", type: "button", text: cmpLoading ? "Checking…" : "Check now", disabled: cmpLoading,
        title: "Compare the scripts here with GitHub's main branch now", onclick: () => loadCompare(true) })),
    h("p", { class: "dim" }, `Scripts live in ${dir}${uc ? ` (${uc.dir} is a shortcut to it)` : ""}. Only root can change files there: to edit a script over SFTP, connect as root. `,
      asUser ? `These commands use sudo, as ${uc.user} would over SSH. ` : "",
      "Source and docs: ", h("a", { href: REPO, target: "_blank", rel: "noopener noreferrer", text: "github.com/alpinezx/easy-aiostreams" }), "."),
    h("p", { class: "dim", text: "To restore a backup, use the Backup & Restore tab." })));
}
