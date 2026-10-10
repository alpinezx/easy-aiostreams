import { $, h, clear, api, ago, fmtBytes, toast } from "./util.js";
import { openJob, runAction, ask } from "./actions.js";

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
    box.append(h("button", { class: "item", type: "button", onclick: () => openJob(j.id) },
      h("span", {}, h("span", { class: "what", text: j.label }), " ", h("span", { class: "dim", text: actionGroup(j.action) })),
      h("span", { class: "when", text: ago(j.started) }),
      h("span", { class: `chip ${state[1]}`, text: state[0] })));
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
  if (!items.length) {
    box.append(h("p", { class: "empty", text: "No backups on this server yet. Use Back up now to make one." }));
    box.lastChild.style.padding = "18px 16px";
    return;
  }
  for (const it of items) {
    // Restore runs as root, so use the root-owned copy. For scp, prefer the copy in a normal user's
    // home (readable without root); fall back to root's copy.
    const userDir = it.dirs.find((d) => d.startsWith("/home/"));
    const cmd = userDir ? `scp ${userDir.split("/")[2]}@YOUR_SERVER:${userDir}/${it.name} .` : `scp root@YOUR_SERVER:${it.dirs[0]}/${it.name} .`;
    const mainDir = it.dirs.find((d) => !d.startsWith("/home/")) || it.dirs[0];
    const restore = `sudo bash ${status.install_dir || "/opt/aiostreams"}/setup-aiostreams.sh restore ${mainDir}/${it.name}`;
    box.append(backupRow(it, cmd, restore, status));
  }
}

async function copy(text, okMsg) {
  try { await navigator.clipboard.writeText(text); toast(okMsg); } catch (_) { toast(text); }
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
      h("div", { class: "what mono" }, it.name, it.locked ? h("span", { class: "lock-tag", text: "Locked" }) : null),
      h("div", { class: "when", text: `${fmtBytes(it.size)}, made ${ago(it.mtime)}, saved in ${it.dirs.join(" and ")}` })),
    h("div", { class: "btns" },
      h("button", { class: "btn small", type: "button", text: "Copy restore command", onclick: () => copy(restore, "Copied. Paste it into the Terminal tab or an SSH session to restore from this backup.") }),
      h("button", { class: "btn small", type: "button", text: "Copy scp command", onclick: () => copy(cmd, "Copied. Replace YOUR_SERVER with your server's address.") }),
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
