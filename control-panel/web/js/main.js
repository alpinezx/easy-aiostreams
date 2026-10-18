import "./debugsize.js";
import "./viewport.js";
import { $, api, toast } from "./util.js";
import { render, record } from "./overview.js";
import * as logs from "./logs.js";
import { showActivity, showBackups } from "./activity.js";
import { currentJobId, openJob } from "./actions.js";
import * as terminal from "./terminal.js";
import * as scripts from "./scripts.js";
import * as vpn from "./vpn.js";

let status = null;
let view = "overview";
let pendingLogs = null;
let lastBusy = null;
let timer = null;

const VIEWS = ["overview", "logs", "activity", "backups", "scripts", "vpn", "terminal"];
let terminalOn = false;
let vpnSetUp = false;     // the VPN page shows once setup-vpn-gluetun.sh has set the VPN up

function route() {
  const v = location.hash.slice(1).split("/")[0];
  view = VIEWS.includes(v) && (v !== "terminal" || terminalOn) && (v !== "vpn" || vpnSetUp) ? v : "overview";
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
  if (view === "scripts") scripts.show(status, terminalOn);
  if (view === "terminal") terminal.show(status);
  if (view === "vpn") vpn.show(false, status);
}

// Phones: the rail is a drawer, opened from the menu button and closed by its X, the
// backdrop, Escape, or picking a page.
function navOpen(open) {
  const nav = $("#nav");
  if (nav.classList.contains("open") === open) return;
  nav.classList.toggle("open", open);
  $("#nav-scrim").hidden = !open;
  $("#nav-open").setAttribute("aria-expanded", String(open));
  document.documentElement.style.overflow = open ? "hidden" : "";
  (open ? $("#nav-x") : $("#nav-open")).focus();
}

function initNav() {
  $("#nav-open").addEventListener("click", () => navOpen(true));
  $("#nav-x").addEventListener("click", () => navOpen(false));
  $("#nav-scrim").addEventListener("click", () => navOpen(false));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") navOpen(false); });
  $("#nav").addEventListener("click", (e) => { if (e.target.closest("a")) navOpen(false); });
  window.matchMedia("(max-width: 720px)").addEventListener("change", () => navOpen(false));

  // Desktop: the rail shows icons only, so each one names itself beside the rail on hover or focus.
  // Drawn outside the rail, which scrolls on short windows and would clip it.
  const tip = $("#tip");
  const show = (e) => {
    const el = e.target.closest("[data-tip]");
    if (!el || window.innerWidth <= 720) return;
    const r = el.getBoundingClientRect();
    tip.textContent = el.dataset.tip;
    tip.style.left = `${$("#nav").getBoundingClientRect().right + 8}px`;
    tip.style.top = `${r.top + r.height / 2}px`;
    tip.hidden = false;
  };
  const hide = () => { tip.hidden = true; };
  const nav = $("#nav");
  nav.addEventListener("mouseover", show);
  nav.addEventListener("focusin", show);
  nav.addEventListener("mouseleave", hide);
  nav.addEventListener("focusout", hide);
  nav.addEventListener("scroll", hide);
  nav.addEventListener("click", hide);
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
    // The VPN page appears once the VPN has been set up (on or off), never before
    const vpnNow = status.vpn === "on" || status.vpn === "off";
    if (vpnNow !== vpnSetUp) {
      vpnSetUp = vpnNow;
      $("#tab-vpn").hidden = !vpnSetUp;
      if (location.hash.slice(1) === "vpn" || view === "vpn") route();   // opened at #vpn, or the VPN was removed
    }

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
      if (view === "vpn") vpn.show(true, status);     // a VPN switch just finished: check again
    }
    if (view === "vpn") vpn.setStatus(status);
    lastBusy = status.busy;
  } catch (e) {
    if (e.message !== "signed out") $("#offline").hidden = false;
  }
  timer = setTimeout(tick, document.hidden ? 15000 : status && status.busy ? 1500 : 4000);
}

async function boot() {
  const me = await api("/api/me");
  // One login, so the name isn't shown; it's on Sign out's tooltip.
  $("#logout").dataset.tip = `Sign out (${me.user})`;
  scripts.versionChip(me.version);
  scripts.loadPanelVersion(false);      // the header chip turns amber when there's an update
  $("#demo").hidden = !me.demo;
  terminalOn = !!me.terminal;
  $("#tab-terminal").hidden = !terminalOn;
  $("#vpn-check").addEventListener("click", () => vpn.show(true, status));
  for (const id of ["#restart-panel", "#restart-panel-2"]) $(id).addEventListener("click", () => {
    if (confirm("Restart the panel? It will be unavailable for a few seconds and any open terminal will close.")) terminal.restartPanel();
  });
  logs.init();
  initNav();
  $("#logout").addEventListener("click", async () => {
    await api("/api/logout", { method: "POST" }).catch(() => {});
    location.href = "/login";
  });
  window.addEventListener("hashchange", route);
  window.addEventListener("job-started", tick);
  window.addEventListener("job-finished", tick);
  window.addEventListener("restart-panel", () => terminal.restartPanel());
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
  window.addEventListener("resize", () => { if (status && view === "overview") { /* trunk position */ render(status, goLogs); } });
  route();
  await tick();
  enter();
}
boot();
