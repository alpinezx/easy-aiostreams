import { $, api, toast } from "./util.js";
import { render, record } from "./overview.js";
import * as logs from "./logs.js";
import { showActivity, showBackups } from "./activity.js";
import { currentJobId, openJob } from "./actions.js";
import * as terminal from "./terminal.js";

let status = null;
let view = "overview";
let pendingLogs = null;
let lastBusy = null;
let timer = null;

const VIEWS = ["overview", "logs", "activity", "backups", "terminal"];
let terminalOn = false;

function route() {
  const v = location.hash.slice(1).split("/")[0];
  view = VIEWS.includes(v) && (v !== "terminal" || terminalOn) ? v : "overview";
  for (const name of VIEWS) $(`#view-${name}`).hidden = name !== view;
  document.querySelectorAll(".tab").forEach((t) => t.toggleAttribute("aria-current", false));
  const active = document.querySelector(`.tab[data-view="${view}"]`);
  active.setAttribute("aria-current", "page");
  if (view !== "logs") logs.hide();
  if (status) enter();
}

function enter() {
  if (view === "logs") { logs.show(status, pendingLogs); pendingLogs = null; }
  if (view === "activity") showActivity().catch(() => {});
  if (view === "backups") showBackups(status).catch(() => {});
  if (view === "overview") render(status, goLogs);
  if (view === "terminal") terminal.show(status);
}

function goLogs(container) { pendingLogs = container; location.hash = "#logs"; }

async function tick() {
  clearTimeout(timer);
  try {
    status = await api("/api/status");
    $("#offline").hidden = true;
    document.title = `${status.headline} - Easy AIOStreams`;
    record(status);
    if (view === "overview") render(status, goLogs);

    // an action just finished while the output panel was closed: say so
    if (lastBusy && !status.busy) {
      if (currentJobId() !== lastBusy) {
        try {
          const j = await api(`/api/jobs/${lastBusy}`);
          toast(j.code === 0 ? j.done : `${j.label} failed. Open Activity to see why.`, j.code !== 0);
        } catch (_) {}
      }
      if (view === "activity") showActivity().catch(() => {});
      if (view === "backups") showBackups(status).catch(() => {});
    }
    lastBusy = status.busy;
  } catch (e) {
    if (e.message !== "signed out") $("#offline").hidden = false;
  }
  timer = setTimeout(tick, document.hidden ? 15000 : status && status.busy ? 1500 : 4000);
}

async function boot() {
  const me = await api("/api/me");
  $("#who").textContent = me.user;
  $("#demo").hidden = !me.demo;
  terminalOn = !!me.terminal;
  $("#tab-terminal").hidden = !terminalOn;
  for (const id of ["#restart-panel", "#restart-panel-2"]) $(id).addEventListener("click", () => {
    if (confirm("Restart the panel? It will be unavailable for a few seconds and any open terminal will close.")) terminal.restartPanel();
  });
  logs.init();
  $("#logout").addEventListener("click", async () => {
    await api("/api/logout", { method: "POST" }).catch(() => {});
    location.href = "/login";
  });
  window.addEventListener("hashchange", route);
  window.addEventListener("job-started", tick);
  window.addEventListener("job-finished", tick);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
  window.addEventListener("resize", () => { if (status && view === "overview") { /* trunk position */ render(status, goLogs); } });
  route();
  await tick();
  enter();
}
boot();
