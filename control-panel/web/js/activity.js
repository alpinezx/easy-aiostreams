import { $, h, clear, api, ago, fmtBytes, toast } from "./util.js";
import { openJob, runAction, ask } from "./actions.js";
import { tagLabel } from "./releases.js";

// The panel reads each backup's build in the background; look again a few times while it does.
let buildTimer = null, buildTries = 0;
// This server's public IP for the scp command, looked up once per page load. null: not found.
let serverIp;

export async function showActivity() {
  const box = $("#jobs"); clear(box);
  const jobs = await api("/api/jobs");
  const cb = $("#clear-activity");
  cb.disabled = !jobs.some((j) => j.ended);
  cb.onclick = async () => {
    const ok = await ask({ title: "Clear activity?", confirmLabel: "Clear", danger: true,
      body: "This removes the list of finished actions and their saved output. Anything still running stays." });
    if (!ok) return;
    try { await api("/api/jobs", { method: "DELETE" }); toast("Activity cleared."); }
    catch (e) { toast(e.message || "Couldn't clear it.", true); }
    showActivity().catch(() => {});
  };
  if (!jobs.length) {
    box.append(h("p", { class: "empty", style: null, text: "Nothing has run from here yet. Actions you start on the Overview page show up in this list." }));
    box.lastChild.style.padding = "18px 16px";
    return;
  }
  for (const j of jobs) {
    const state = !j.ended ? ["Running", ""] : j.code === 0 ? ["Done", "ok"] : ["Failed", "bad"];
    // The whole row opens the output; the label is the button, so the keyboard reaches it too.
    const row = h("div", { class: "item job", onclick: (e) => { if (!e.target.closest(".job-x")) openJob(j.id); } },
      h("button", { class: "job-open", type: "button" },
        h("span", { class: "what", text: j.label }), " ", h("span", { class: "dim", text: actionGroup(j.action) })),
      h("span", { class: "when", text: ago(j.started) }),
      h("span", { class: `chip ${state[1]}`, text: state[0] }));
    const x = h("button", { class: "btn small quiet job-x", type: "button", title: "Remove from Activity", "aria-label": `Remove ${j.label} from Activity`, disabled: !j.ended,
      onclick: async () => {
        try { await api(`/api/jobs/${j.id}`, { method: "DELETE" }); }
        catch (e) { toast(e.message || "Couldn't remove it.", true); }
        showActivity().catch(() => {});
      } });
    x.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/></svg>';
    row.append(x);
    box.append(row);
  }
}

function actionGroup(id) {
  return { stack: "AIOStreams", mediaflow: "MediaFlow Proxy", webhook: "Webhook relay", watchdog: "Phone alerts" }[id.split(".")[0]] || "";
}

export async function showBackups(status) {
  const box = $("#backups"); clear(box);
  const act = (status.actions || []).find((a) => a.id === "stack.backup");
  const b = $("#backup-now");
  b.disabled = !act || !act.available || !!status.busy;
  b.onclick = () => runAction(act);
  showSetAsides().catch(() => {});
  const items = await api("/api/backups");
  if (serverIp === undefined) serverIp = await api("/api/server-address").then((r) => r.ip || null, () => null);
  // An IPv6 address needs brackets in scp's user@host:path.
  const host = !serverIp ? "YOUR_SERVER" : serverIp.includes(":") ? `[${serverIp}]` : serverIp;
  clearTimeout(buildTimer);
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
  const build = it.build ? `, AIOStreams ${tagLabel(it.build.tag)}` : "";
  const input = h("input", { class: "input", type: "text", autocomplete: "off", spellcheck: "false", placeholder: "restore", "aria-label": "Type restore to confirm" });
  const el = h("div", { class: "opts" },
    h("ul", { class: "check-list ok" }, ...res.notes.map((n) => h("li", { text: n }))),
    h("p", { class: "dim small", text: "This restore's own output won't stay in Activity afterwards: that list is part of what gets rolled back." }),
    input);
  const ok = await ask({ title: "Roll your AIOStreams setup back?", danger: true, confirmLabel: "Restore",
    body: `Restores ${it.name} (made ${ago(it.mtime)}${build}). The current install is moved aside, not deleted. AIOStreams restarts, so streams stop for a minute or two, and the panel restarts at the end. Type restore to confirm.`,
    options: { el, gate: input, word: "restore", read: () => true } });
  if (!ok) return;
  try {
    const job = await api("/api/actions/stack.restore", { method: "POST", body: JSON.stringify({ params: { name: it.name, confirm: "restore" } }) });
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

  return h("div", { class: "item bk" + (it.locked ? " locked" : "") },
    h("span", {},
      h("div", { class: "what mono" }, it.name,
        it.build ? h("span", { class: "build-tag", title: `AIOStreams ${it.build.version}, ${it.build.tag.endsWith("-nightly") ? "nightly build" : "stable release"} ${it.build.tag}`, text: tagLabel(it.build.tag) }) : null,
        it.locked ? h("span", { class: "lock-tag", text: "Locked" }) : null),
      h("div", { class: "when", text: `${fmtBytes(it.size)}, made ${ago(it.mtime)}, saved in ${it.dirs.join(" and ")}` })),
    h("div", { class: "btns" },
      h("button", { class: "btn small", type: "button", text: "Restore", disabled: !!status.busy,
        title: "Roll your AIOStreams setup back to this backup, after checking it's safe to do from here",
        onclick: (e) => startRestore(it, restore, e.currentTarget) }),
      h("button", { class: "btn small", type: "button", text: "Copy restore command", onclick: () => copy(restore, "Copied. Paste it into the Terminal tab or an SSH session to restore from this backup.") }),
      h("button", { class: "btn small", type: "button", text: "Copy scp command", onclick: () => copy(cmd, cmd.includes("@YOUR_SERVER:")
        ? "Copied. Replace YOUR_SERVER with your server's address."
        : "Copied. Run it in a terminal on your own computer to download this backup.") }),
      h("button", { class: "btn small", type: "button", text: it.locked ? "Unlock" : "Lock", "aria-pressed": String(!!it.locked), onclick: async () => {
        if (await saveMeta(it, { locked: !it.locked })) toast(it.locked ? "Unlocked." : "Locked. It can't be deleted from here until you unlock it.");
        refresh();
      } }),
      del),
    noteLine);
}

// Old installs a restore moved aside. Only shown when there are some.
async function showSetAsides() {
  const wrap = $("#set-asides"), box = $("#set-aside-list");
  const items = await api("/api/set-asides");
  clear(box);
  wrap.hidden = !items.length;
  for (const it of items) {
    const size = it.size != null ? fmtBytes(it.size) : "size unknown";
    const when = it.when ? `set aside ${ago(it.when)}` : "";
    box.append(h("div", { class: "item bk" },
      h("span", {},
        h("div", { class: "what mono", text: it.name }),
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
