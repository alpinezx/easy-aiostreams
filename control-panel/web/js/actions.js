import { $, h, clear, api, toast, fmtDur } from "./util.js";
import { openKnown, whatsNewLine } from "./releases.js";

// ---------- modal dialog ----------
let lastFocus = null;

function closeDialog() {
  const d = $("#dialog");
  d.hidden = true; clear(d);
  $("#scrim").hidden = !$("#drawer").hidden ? false : true;
  if (lastFocus && lastFocus.focus) lastFocus.focus();
}

function openDialog(content) {
  const d = $("#dialog");
  lastFocus = document.activeElement;
  clear(d); d.append(...content.filter(Boolean));
  d.hidden = false; $("#scrim").hidden = false;
  const first = d.querySelector("input, select, button.primary, button");
  if (first) first.focus();
}

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (!$("#dialog").hidden) closeDialog();
  else if (!$("#drawer").hidden) closeDrawer();
});
$("#scrim").addEventListener("click", () => { if (!$("#dialog").hidden) closeDialog(); else closeDrawer(); });

export function ask({ title, body, confirmLabel, danger, options }) {
  return new Promise((resolve) => {
    const done = (v) => { closeDialog(); resolve(v); };
    openDialog([
      h("h3", { id: "dialog-title", text: title }),
      body ? h("p", { text: body }) : null,
      options ? options.el : null,
      h("div", { class: "btns" },
        h("button", { class: "btn", type: "button", text: "Cancel", onclick: () => done(null) }),
        h("button", { class: "btn primary" + (danger ? " danger" : ""), type: "button", text: confirmLabel,
          disabled: !!(options && options.gate),
          onclick: () => done(options ? options.read() : true) })),
    ]);
    if (options && options.gate) {          // confirm stays off until the word is typed
      const btn = $("#dialog .btn.primary");
      options.gate.addEventListener("input", () => { btn.disabled = options.gate.value.trim().toLowerCase() !== options.word; });
      options.gate.focus();
    }
  });
}

// ---------- running an action ----------
export async function runAction(act, params) {
  if (act.id === "stack.update") {
    const channelNow = window.__channel || "latest";
    const backup = h("input", { type: "checkbox", id: "up-backup", checked: true });
    // Only real choices: staying put, or moving to the channel you are not on.
    const onStable = channelNow === "latest", onNightly = channelNow === "nightly";
    const sel = h("select", { class: "input", id: "up-channel" },
      h("option", { value: "", text: `Stay on ${onStable ? "stable" : channelNow}` }),
      onStable ? null : h("option", { value: "latest", text: "Switch to stable" }),
      onNightly ? null : h("option", { value: "nightly", text: "Switch to nightly" }));
    // "See what's new" swaps the dialog for the releases drawer; Update is one click away after.
    let wantNotes = false;
    const notes = whatsNewLine(() => { wantNotes = true; $("#dialog .btns .btn:not(.primary)").click(); });
    // Nightly can migrate AIOStreams' database past what stable understands, and stable then won't start.
    // The way back is the backup taken before the switch to nightly, which Update notes as such.
    let wayBack = null;
    if (onNightly) {
      try {
        const list = await api("/api/backups");
        wayBack = list.filter((b) => (b.note || "").startsWith("Before switching stable → nightly"))
          .sort((a, b) => b.mtime - a.mtime)[0] || null;
      } catch (_) {}
    }
    const warn = h("p", { class: "switch-warn", hidden: true });
    sel.addEventListener("change", () => {
      backup.disabled = sel.value === "nightly";
      if (sel.value === "nightly") {
        backup.checked = true;
        warn.textContent = "Nightly can upgrade AIOStreams' database, and once it has, stable won't start on it any more. "
          + "The way back to stable is then restoring the backup this makes now, so Back up first stays on for this switch.";
      } else if (sel.value === "latest") {
        warn.textContent = "This works if nightly hasn't upgraded AIOStreams' database. If it has, stable refuses to start and keeps "
          + "restarting (its log says \"Database is at migration ...\"). The safe way back is restoring the backup made before "
          + "you switched to nightly" + (wayBack ? `: ${wayBack.name} on the Backup & Restore tab.` : ", from the Backup & Restore tab.");
      }
      warn.hidden = !sel.value;
    });
    const el = h("div", { class: "opts" },
      notes,
      h("label", { class: "check" }, backup, h("span", { text: "Back up first" })),
      h("label", { class: "field" }, h("span", { text: "Build channel" }), sel),
      warn);
    const res = await ask({
      title: "Update or switch build",
      body: "Pulls the newest image and recreates the container. Streams stop loading for a minute or so.",
      confirmLabel: "Update", options: { el, read: () => ({ backup: backup.checked, channel: sel.value || null }) },
    });
    if (wantNotes) { openKnown(); return; }
    if (!res) return;
    if (res.channel && res.channel === channelNow) res.channel = null;
    params = res;
  } else if (act.confirm) {
    const ok = await ask({ title: `${act.label}?`, body: act.confirm, confirmLabel: act.label, danger: /stop/i.test(act.id) });
    if (!ok) return;
  }
  try {
    const job = await api(`/api/actions/${act.id}`, { method: "POST", body: JSON.stringify({ params: params || {} }) });
    openJob(job.id);
    window.dispatchEvent(new CustomEvent("job-started"));
  } catch (e) {
    toast(e.message, true);
  }
}

export async function restartService(s) {
  const ok = await ask({ title: `Restart ${s.name}?`, confirmLabel: "Restart",
    body: `Only ${s.name} restarts. Everything else keeps running. It can take up to 15 seconds.` });
  if (!ok) return;
  toast(`Restarting ${s.name}...`);
  try {
    await api(`/api/services/${encodeURIComponent(s.key)}/restart`, { method: "POST", body: "{}" });
    toast(`${s.name} restarted.`);
    window.dispatchEvent(new CustomEvent("job-started"));
  } catch (e) {
    toast(e.message, true);
  }
}

// ---------- job drawer ----------
let es = null;
let openId = null;

export function currentJobId() { return $("#drawer").hidden ? null : openId; }

export function closeDrawer() {
  if (es) { es.close(); es = null; }
  openId = null;
  $("#drawer").hidden = true;
  if ($("#dialog").hidden) $("#scrim").hidden = true;
  if (lastFocus && lastFocus.focus) lastFocus.focus();
}
$("#drawer-x").addEventListener("click", closeDrawer);

function addLine(term, k, t) {
  const stick = term.scrollTop + term.clientHeight >= term.scrollHeight - 30;
  term.append(h("div", { class: `ln ${k}`, text: t || " " }));
  if (stick) term.scrollTop = term.scrollHeight;
}

function finish(job, code) {
  const ok = code === 0;
  $("#drawer-title").textContent = ok ? job.done : `${job.label} failed`;
  $("#drawer-sub").textContent = ok ? "Finished without errors." : "Open the lines marked red to see why. Nothing else was changed.";
  const foot = $("#drawer-foot"); clear(foot);
  foot.append(h("span", { class: "result " + (ok ? "ok" : "bad"), text: ok ? "Done" : `Exited with code ${code}` }),
    h("button", { class: "btn small", style: null, type: "button", text: "Close", onclick: closeDrawer }));
  foot.lastChild.style.marginLeft = "auto";
}

export async function openJob(id) {
  if (es) { es.close(); es = null; }
  lastFocus = document.activeElement;
  openId = id;
  const job = await api(`/api/jobs/${id}`);
  const term = $("#drawer-term"); clear(term);
  $("#drawer").hidden = false; $("#scrim").hidden = false;
  $("#drawer-x").focus();
  const foot = $("#drawer-foot"); clear(foot);

  if (job.ended) {
    job.lines.forEach((l) => addLine(term, l.k, l.t));
    finish(job, job.code);
    term.scrollTop = term.scrollHeight;
    return;
  }
  $("#drawer-title").textContent = `${job.running}…`;
  $("#drawer-sub").textContent = "Running the same script you'd run over SSH. You can close this; it keeps going.";
  foot.append(h("span", { class: "spin", "aria-hidden": "true" }), h("span", { class: "dim", text: "Working" }));
  es = new EventSource(`/api/jobs/${id}/stream`);
  es.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.done) { es.close(); es = null; finish(job, m.code); window.dispatchEvent(new CustomEvent("job-finished")); return; }
    addLine(term, m.k, m.t);
  };
  es.onerror = () => { /* EventSource reconnects by itself; stream resumes from the start, so avoid duplicates */
    if (es) { es.close(); es = null; openJob(id); }
  };
}

// ---------- reboot the whole server ----------
export async function rebootServer() {
  const input = h("input", { class: "input", type: "text", autocomplete: "off", spellcheck: "false", placeholder: "reboot", "aria-label": "Type reboot to confirm" });
  const ok = await ask({ title: "Reboot the server?", confirmLabel: "Reboot now", danger: true,
    body: "The whole server restarts. AIOStreams, the VPN and this panel are offline for a minute or two, and streams already playing will drop. They all start again by themselves. Type reboot to confirm.",
    options: { el: input, gate: input, word: "reboot", read: () => true } });
  if (!ok) return;
  try { await api("/api/server/reboot", { method: "POST", body: JSON.stringify({ confirm: "reboot" }) }); }
  catch (e) { toast(e.message || "Couldn't start the reboot.", true); return; }
  const note = h("p", { class: "dim", text: "This page reconnects by itself when the server is back." });
  const veil = h("div", { class: "veil", role: "alert" }, h("div", { class: "veil-box" },
    h("h3", { text: "Rebooting the server" }), note));
  document.body.append(veil);
  const started = Date.now();
  let wasDown = false;
  const poll = async () => {
    let up = true;
    try { const r = await fetch("/api/me", { credentials: "same-origin", cache: "no-store" }); up = r.status < 500; }
    catch (_) { up = false; }
    if (!up) { wasDown = true; note.textContent = "Server is restarting. Waiting for it to come back..."; }
    if ((up && wasDown) || Date.now() - started > 40000 && up && !wasDown) { location.reload(); return; }
    if (Date.now() - started > 600000) { note.textContent = "Taking longer than usual. Check the server's console if this doesn't clear."; return; }
    setTimeout(poll, 3000);
  };
  setTimeout(poll, 6000);
}
