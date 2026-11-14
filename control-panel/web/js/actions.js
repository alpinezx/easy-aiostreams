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

export function ask({ title, body, confirmLabel, danger, options, alt }) {
  return new Promise((resolve) => {
    const done = (v) => { closeDialog(); resolve(v); };
    openDialog([
      h("h3", { id: "dialog-title", text: title }),
      // A "\n" in the body starts a new line
      body ? h("p", {}, ...body.split("\n").flatMap((t, i) => i ? [h("br"), t] : [t])) : null,
      options ? options.el : null,
      h("div", { class: "btns" },
        h("button", { class: "btn", type: "button", text: "Cancel", onclick: () => done(null) }),
        alt ? h("button", { class: "btn", type: "button", text: alt.label, onclick: () => done(alt.value) }) : null,
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
// With the VPN set up but switched off, Start, Restart and Update would ask whether to go on
// without it: the dialog says so, and confirming answers yes (without_vpn)
const VPN_OFF_NOTE = "The VPN is switched off, so AIOStreams' traffic, debrid included, goes out through this server's own IP.";

// Restart stack names only what it restarts here: "Restart AIOStreams, Caddy and the VPN?"
function restartWhat(act) {
  if (act.id !== "stack.restart") return null;
  const parts = ["AIOStreams", "Caddy"];
  if (window.__vpn === "on") parts.push("the VPN");
  if (window.__tunnel) parts.push("the Cloudflare Tunnel");
  return `Restart ${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}?`;
}

// lead: an opening line for the confirm, such as why the VPN's Restart in Services restarts the stack
export async function runAction(act, params, lead) {
  const vpnOff = window.__vpn === "off" && ["stack.start", "stack.restart", "stack.update"].includes(act.id);
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
      body: "Pulls the newest image and recreates the container. Streams stop loading for a minute or so." + (vpnOff ? " " + VPN_OFF_NOTE : ""),
      confirmLabel: "Update", options: { el, read: () => ({ backup: backup.checked, channel: sel.value || null, without_vpn: vpnOff }) },
    });
    if (wantNotes) { openKnown(); return; }
    if (!res) return;
    if (res.channel && res.channel === channelNow) res.channel = null;
    params = res;
  } else if (["aiometadata.update", "aiomanager.update", "mediaflow.update"].includes(act.id)) {
    const [name, effect] = {
      "aiometadata.update": ["AIOMetadata", "its catalogs stop loading for a minute or so"],
      "aiomanager.update": ["AIOManager", "its site is offline for a minute or so"],
      "mediaflow.update": ["MediaFlow Proxy", "streams through it pause for a few seconds"],
    }[act.id];
    const backup = h("input", { type: "checkbox", id: "meta-backup", checked: true });
    const res = await ask({
      title: `Update ${name}`,
      body: `Gets its newest release and restarts it, so ${effect}. `
        + "If the new release doesn't start, the previous one is put back by itself.",
      confirmLabel: "Update",
      options: { el: h("div", { class: "opts" }, h("label", { class: "check" }, backup, h("span", { text: "Back up first" }))),
        read: () => ({ backup: backup.checked }) },
    });
    if (!res) return;
    params = res;
  } else if (act.id === "vpn.update" && act.backup) {
    const backup = h("input", { type: "checkbox", id: "vpn-backup", checked: true });
    const res = await ask({
      title: "Update VPN",
      body: "Gets the newest gluetun v3 release. If there is one and the VPN is on, the stack restarts and streams pause "
        + "for up to a minute. If the new release doesn't connect, the previous one is put back by itself.",
      confirmLabel: "Update",
      options: { el: h("div", { class: "opts" }, h("label", { class: "check" }, backup, h("span", { text: "Back up first" }))),
        read: () => ({ backup: backup.checked }) },
    });
    if (!res) return;
    params = res;
  } else if (act.confirm || vpnOff) {
    const addonsNote = act.id === "stack.restart" && window.__addons ? "Add-ons aren't restarted: use Restart on their row in Services." : null;
    const body = [lead, restartWhat(act), act.confirm, addonsNote, vpnOff ? VPN_OFF_NOTE : null].filter(Boolean).join(" ");
    // The stack's own action is labelled Restart (beside Start and Stop), but its confirm names what it is
    const label = act.id === "stack.restart" ? "Restart stack" : act.label;
    const ok = await ask({ title: `${label}?`, body, confirmLabel: label, danger: /stop|forget|delete|uninstall/i.test(act.id) });
    if (!ok) return;
    if (vpnOff) params = { ...(params || {}), without_vpn: true };
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
  $("#drawer-sub").textContent = ok ? "Finished without errors." : "Open the lines marked red to see why.";
  const foot = $("#drawer-foot"); clear(foot);
  // A restore leaves this panel looking at the folder it moved aside, until it restarts.
  const restored = ok && job.action === "stack.restore";
  if (restored) $("#drawer-sub").textContent = "Restart the panel now, so it picks up the restored install.";
  if (!ok && job.action === "stack.restore") {
    $("#drawer-sub").textContent = "If the output ends with Nothing was changed, nothing was. Otherwise your previous install is kept as a set-aside folder on Backup & Restore.";
  }
  foot.append(...[h("span", { class: "result " + (ok ? "ok" : "bad"), text: ok ? "Done" : `Exited with code ${code}` }),
    restored ? h("button", { class: "btn small primary", type: "button", text: "Restart panel",
      onclick: () => window.dispatchEvent(new CustomEvent("restart-panel")) }) : null,
    h("button", { class: "btn small", style: null, type: "button", text: "Close", onclick: closeDrawer })].filter(Boolean));
  foot.children[1].style.marginLeft = "auto";
  // Updates that need a restart (a new kernel, say) can be finished from here
  if (ok && job.action === "maint.updates") offerReboot(job.id);
}

async function offerReboot(id) {
  let r;
  try { r = await api("/api/server/reboot-needed"); } catch (_) { return; }
  if (!r.needed || openId !== id) return;
  $("#drawer-sub").textContent = "Finished without errors. A restart is needed to finish installing them.";
  const foot = $("#drawer-foot");
  const btn = h("button", { class: "btn small danger", type: "button", text: "Reboot server", onclick: rebootServer });
  btn.style.marginLeft = "auto";
  foot.children[1].style.marginLeft = "";
  foot.insertBefore(btn, foot.children[1]);
}

// before: { text, id } for a job that ran first and led to this one (Back up first, before an
// uninstall). Its line opens this drawer, with a link to its output, so it isn't lost.
export async function openJob(id, reconnecting, before) {
  if (es) { es.close(); es = null; }
  if (!reconnecting) lastFocus = document.activeElement;
  openId = id;
  let job;
  try { job = await api(`/api/jobs/${id}`); }
  catch (e) {
    if (!reconnecting) { toast(e.message, true); return; }
    // The panel itself restarted (a maintenance job restarts Docker). A job it ran
    // outside itself carries on; once the panel's back it no longer knows this one.
    if (openId !== id || $("#drawer").hidden) return;
    const foot = $("#drawer-foot"); clear(foot);
    if (e.status === 404) {
      closeDrawer();
      toast("The panel restarted while that ran. How it ended is under the cards on this page.");
      window.dispatchEvent(new CustomEvent("job-finished"));
      return;
    }
    $("#drawer-sub").textContent = "The panel is restarting with Docker. The job carries on on the server; this reconnects by itself.";
    foot.append(h("span", { class: "spin", "aria-hidden": "true" }), h("span", { class: "dim", text: "Reconnecting" }));
    setTimeout(() => openJob(id, true, before), 3000);
    return;
  }
  const term = $("#drawer-term"); clear(term);
  if (before) {
    term.append(h("div", { class: "ln job-before" }, `${before.text} `,
      h("a", { href: "#", text: "View its output", onclick: (e) => { e.preventDefault(); openJob(before.id); } })));
  }
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
  // A quiet log looked like a crash: say a long job is expected to pause
  const wait = job.action === "stack.restore"
    ? "Working. A restore takes a few minutes, and the output pauses while things restart."
    : "Working. Some jobs take a few minutes, and the output can pause along the way.";
  foot.append(h("span", { class: "spin", "aria-hidden": "true" }), h("span", { class: "dim", text: wait }));
  es = new EventSource(`/api/jobs/${id}/stream`);
  es.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.done) { es.close(); es = null; finish(job, m.code); window.dispatchEvent(new CustomEvent("job-finished")); return; }
    addLine(term, m.k, m.t);
  };
  es.onerror = () => { /* EventSource reconnects by itself; stream resumes from the start, so avoid duplicates */
    if (es) { es.close(); es = null; openJob(id, true, before); }
  };
}

// ---------- reboot the whole server ----------
export async function rebootServer() {
  const ok = await ask({ title: "Reboot the server?", confirmLabel: "Reboot now", danger: true,
    body: "The whole server restarts. AIOStreams, the VPN and this panel are offline for a minute or two, and streams already playing will drop. They all start again by themselves." });
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
