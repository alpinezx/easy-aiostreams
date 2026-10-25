// Edit's drawer, for two lists: the Overview's cards (which show and in what order) and the
// rail's pages (Overview always first). One layout each for the install, saved on the
// server, so a phone and a desktop match.
import { $, h, clear, api, toast } from "./util.js";

const CARDS = {
  flow: ["Request flow", "Visitors through Caddy to AIOStreams, and the add-ons"],
  aiostreams: ["AIOStreams", "Its version and updates"],
  aiometadata: ["AIOMetadata", "Its version, updates and pages"],
  aiomanager: ["AIOManager", "Its version, updates and sign-ups"],
  alerts: ["Phone alerts", "The watchdog, its last check and 14 days"],
  vpn: ["VPN", "Whether it's connected, where traffic leaves and the server"],
  server: ["This server", "Uptime, certificate, memory, disk and backups"],
  services: ["Services", "Each container, with Logs, Restart and Stop"],
};
const PAGES = {
  logs: ["Logs", "Each service's logs, filtered and searched"],
  activity: ["Activity", "What the panel has done"],
  net: ["Network", "Traffic graphs and each service's speed"],
  backups: ["Backup & Restore", "Backups, the schedule and Restore"],
  maint: ["Maintenance", "Free space, system updates and log limits"],
  addons: ["Add-ons", "Each optional add-on, with Uninstall"],
  vpn: ["VPN", "The tunnel, its server and configs"],
  alerts: ["Phone alerts", "The watchdog and its alerts"],
  scripts: ["Scripts", "The setup scripts and panel updates"],
  terminal: ["Terminal", "A shell on the server"],
};

let hasAlerts = false;    // the Phone alerts card only exists once the watchdog is set up
let hasMeta = false;      // and AIOMetadata's once it's installed
let hasMgr = false;       // and AIOManager's
let hasVpn = false;       // and the VPN's once it's set up (on or off)

// A rail page is listed while its tab is there: main.js hides the ones a server hasn't set up
const railTab = (id) => document.querySelector(`.rail-links .tab[data-view="${id}"]`);

const MODES = {
  overview: {
    items: CARDS, url: "/api/overview-layout", title: "Edit the Overview",
    hint: "Show or hide each card, and drag ≡ to move it.",
    listed: (id) => !((id === "alerts" && !hasAlerts) || (id === "aiometadata" && !hasMeta) || (id === "aiomanager" && !hasMgr) || (id === "vpn" && !hasVpn)),
    // Order and visibility are CSS on the view, so the cards' own repaints don't touch them.
    // Each card takes a full row of its own.
    apply(cards) {
      const view = $("#view-overview");
      cards.forEach((c, i) => view.style.setProperty(`--o-${c.id}`, String(i + 1)));
      view.dataset.hide = cards.filter((c) => !c.show).map((c) => c.id).join(" ");
    },
  },
  rail: {
    items: PAGES, url: "/api/rail-layout", title: "Edit the menu",
    hint: "Show or hide each page, and drag ≡ to move it. Overview stays first.",
    listed: (id) => { const t = railTab(id); return !!t && !t.hidden; },
    apply(cards) {
      cards.forEach((c, i) => {
        const t = railTab(c.id);
        if (!t) return;
        t.style.order = String(i + 1);
        t.classList.toggle("user-hidden", !c.show);
      });
    },
  },
};
for (const m of Object.values(MODES)) {
  m.defaults = () => Object.keys(m.items).map((id) => ({ id, show: true }));
  m.cards = m.defaults();
  m.saveTimer = null;
}

let mode = MODES.overview;
let lastFocus = null;

for (const m of Object.values(MODES)) {
  api(m.url).then((r) => { m.cards = r.cards; m.apply(m.cards); if (isOpen() && mode === m) list(); }).catch(() => {});
}

export function applyLayout(st) {
  hasAlerts = !!(st.watchdog && st.watchdog.configured);
  hasMeta = !!st.aiometadata;
  hasMgr = !!st.aiomanager;
  hasVpn = st.vpn === "on" || st.vpn === "off";
  MODES.overview.apply(MODES.overview.cards);
}

function save(m) {
  m.apply(m.cards);
  clearTimeout(m.saveTimer);
  m.saveTimer = setTimeout(async () => {
    // The drawer's rows work on `cards` itself, so the server's answer isn't swapped in
    try { await api(m.url, { method: "PUT", body: JSON.stringify({ cards: m.cards }) }); }
    catch (e) { toast(e.message || "Couldn't save the layout.", true); }
  }, 300);
}

const isOpen = () => !$("#lay-drawer").hidden;

// "overview" (Edit beside the headline) or "rail" (Edit menu at the rail's foot)
export function openLayout(which = "overview") {
  mode = MODES[which] || MODES.overview;
  lastFocus = document.activeElement;
  // The rail's opens on the left, beside the rail and its Edit menu button; the Overview's on the right, by its Edit
  $("#lay-drawer").classList.toggle("from-left", mode === MODES.rail);
  $("#lay-title").textContent = mode.title;
  $("#lay-hint").textContent = mode.hint;
  list();
  $("#lay-drawer").hidden = false;
  $("#scrim").hidden = false;
  $("#lay-x").focus();
}

export function closeLayout() {
  if (!isOpen()) return;
  $("#lay-drawer").hidden = true;
  if ($("#dialog").hidden && $("#drawer").hidden && $("#rel-drawer").hidden) $("#scrim").hidden = true;
  if (lastFocus && lastFocus.isConnected && lastFocus.focus) lastFocus.focus();
}

// Items that aren't on this server (Phone alerts before the watchdog, an add-on not installed) keep their place in
// the saved order but aren't listed, so nothing reads as missing.
function list() {
  const m = mode;
  const ul = $("#lay-list");
  clear(ul);
  for (const c of m.cards) {
    if (!m.listed(c.id)) continue;
    const [title, text] = m.items[c.id];
    const input = h("input", { type: "checkbox", "aria-label": `Show ${title}` });
    input.checked = c.show;
    input.addEventListener("change", () => { m.cards.find((x) => x.id === c.id).show = input.checked; save(m); });
    const grip = h("button", { class: "lay-grip", type: "button", "aria-label": `Move ${title}`,
      title: "Drag to move it, or use the arrow keys" });
    grip.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 8h14M5 12h14M5 16h14"/></svg>';
    // A page's row carries its rail icon, so it's easy to match up
    const icon = m === MODES.rail && railTab(c.id) ? railTab(c.id).querySelector("svg").cloneNode(true) : null;
    if (icon) icon.classList.add("lay-icon");
    const li = h("li", { class: "lay-row", dataset: { id: c.id } }, icon,
      h("div", { class: "lay-text" }, h("span", { class: "lay-title", text: title }), h("span", { class: "dim lay-sub", text: text })),
      h("label", { class: "sw" }, input, h("i", { "aria-hidden": "true" })),
      grip);
    drag(grip, li, ul, m);
    grip.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
      e.preventDefault();
      const to = e.key === "ArrowUp" ? li.previousElementSibling : li.nextElementSibling;
      if (!to) return;
      e.key === "ArrowUp" ? to.before(li) : to.after(li);
      grip.focus();
      reorder(ul, m);
    });
    ul.append(li);
  }
}

// The saved order follows the list; unlisted items stay where they were among the rest
function reorder(ul, m) {
  const ids = [...ul.children].map((li) => li.dataset.id);
  const byId = Object.fromEntries(m.cards.map((c) => [c.id, c]));
  const out = [];
  let n = 0;
  for (const c of m.cards) out.push(ids.includes(c.id) ? byId[ids[n++]] : c);
  if (out.some((c, i) => c !== m.cards[i])) { m.cards = out; save(m); }
}

// Hold the handle and move it, with a mouse or a finger. The row follows the pointer and
// the others close up around it. The listeners are on the page, not the handle: moving the
// row in the list would drop a pointer capture.
function drag(grip, li, ul, m) {
  grip.addEventListener("pointerdown", (e) => {
    if (e.button) return;
    e.preventDefault();
    const id = e.pointerId;
    const grab = e.clientY - li.getBoundingClientRect().top;
    li.classList.add("dragging");
    const move = (ev) => {
      if (ev.pointerId !== id) return;
      const y = ev.clientY;
      const next = [...ul.children].find((x) => x !== li && x.getBoundingClientRect().top + x.offsetHeight / 2 > y);
      if (next) { if (li.nextElementSibling !== next) next.before(li); } else if (ul.lastElementChild !== li) ul.append(li);
      li.style.transform = "";
      li.style.transform = `translateY(${y - grab - li.getBoundingClientRect().top}px)`;
    };
    const end = (ev) => {
      if (ev.pointerId !== id) return;
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", end);
      document.removeEventListener("pointercancel", end);
      li.classList.remove("dragging");
      li.style.transform = "";
      reorder(ul, m);
      grip.focus();
    };
    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", end);
    document.addEventListener("pointercancel", end);
  });
}

$("#lay-x").addEventListener("click", closeLayout);
// Reset puts the list being edited back; for the Overview, this browser's folds too (overview.js listens)
$("#lay-reset").addEventListener("click", () => {
  const m = mode;
  m.cards = m.defaults(); list(); save(m);
  if (m === MODES.overview) window.dispatchEvent(new CustomEvent("layout-reset"));
});
$("#scrim").addEventListener("click", closeLayout);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && $("#dialog").hidden) closeLayout(); });
