// The Overview's cards: which show and in what order, set from Edit's drawer. One layout
// for the install, saved on the server, so a phone and a desktop match.
import { $, h, clear, api, toast } from "./util.js";

const CARDS = {
  flow: ["Request flow", "Visitors through Caddy to AIOStreams, and the add-ons"],
  aiostreams: ["AIOStreams", "Its version and updates"],
  server: ["This server", "Uptime, certificate, memory, disk and backups"],
  alerts: ["Phone alerts", "The watchdog, its last check and 14 days"],
  services: ["Services", "Each container, with Logs, Restart and Stop"],
};
const DEFAULT = Object.keys(CARDS).map((id) => ({ id, show: true }));

let cards = DEFAULT;
let hasAlerts = false;    // the Phone alerts card only exists once the watchdog is set up
let lastFocus = null, saveTimer = null;

api("/api/overview-layout").then((r) => { cards = r.cards; apply(); if (isOpen()) list(); }).catch(() => {});

// Order and visibility are CSS on the view, so the cards' own repaints don't touch them.
// Each card takes a full row of its own.
function apply() {
  const view = $("#view-overview");
  cards.forEach((c, i) => view.style.setProperty(`--o-${c.id}`, String(i + 1)));
  view.dataset.hide = cards.filter((c) => !c.show).map((c) => c.id).join(" ");
}

export function applyLayout(st) {
  hasAlerts = !!(st.watchdog && st.watchdog.configured);
  apply();
}

function save() {
  apply();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    // The drawer's rows work on `cards` itself, so the server's answer isn't swapped in
    try { await api("/api/overview-layout", { method: "PUT", body: JSON.stringify({ cards }) }); }
    catch (e) { toast(e.message || "Couldn't save the layout.", true); }
  }, 300);
}

const isOpen = () => !$("#lay-drawer").hidden;

export function openLayout() {
  lastFocus = document.activeElement;
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

// Cards that aren't on this server (Phone alerts before the watchdog) keep their place in
// the saved order but aren't listed, so nothing reads as missing.
function list() {
  const ul = $("#lay-list");
  clear(ul);
  for (const c of cards) {
    if (c.id === "alerts" && !hasAlerts) continue;
    const [title, text] = CARDS[c.id];
    const input = h("input", { type: "checkbox", "aria-label": `Show ${title}` });
    input.checked = c.show;
    input.addEventListener("change", () => { cards.find((x) => x.id === c.id).show = input.checked; save(); });
    const grip = h("button", { class: "lay-grip", type: "button", "aria-label": `Move ${title}`,
      title: "Drag to move it, or use the arrow keys" });
    grip.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 8h14M5 12h14M5 16h14"/></svg>';
    const li = h("li", { class: "lay-row", dataset: { id: c.id } },
      h("div", { class: "lay-text" }, h("span", { class: "lay-title", text: title }), h("span", { class: "dim lay-sub", text: text })),
      h("label", { class: "sw" }, input, h("i", { "aria-hidden": "true" })),
      grip);
    drag(grip, li, ul);
    grip.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
      e.preventDefault();
      const to = e.key === "ArrowUp" ? li.previousElementSibling : li.nextElementSibling;
      if (!to) return;
      e.key === "ArrowUp" ? to.before(li) : to.after(li);
      grip.focus();
      reorder(ul);
    });
    ul.append(li);
  }
}

// The saved order follows the list; unlisted cards stay where they were among the rest
function reorder(ul) {
  const ids = [...ul.children].map((li) => li.dataset.id);
  const byId = Object.fromEntries(cards.map((c) => [c.id, c]));
  const out = [];
  let n = 0;
  for (const c of cards) out.push(ids.includes(c.id) ? byId[ids[n++]] : c);
  if (out.some((c, i) => c !== cards[i])) { cards = out; save(); }
}

// Hold the handle and move it, with a mouse or a finger. The row follows the pointer and
// the others close up around it. The listeners are on the page, not the handle: moving the
// row in the list would drop a pointer capture.
function drag(grip, li, ul) {
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
      reorder(ul);
      grip.focus();
    };
    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", end);
    document.addEventListener("pointercancel", end);
  });
}

$("#lay-x").addEventListener("click", closeLayout);
$("#lay-reset").addEventListener("click", () => { cards = DEFAULT.map((c) => ({ ...c })); list(); save(); });
$("#scrim").addEventListener("click", closeLayout);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && $("#dialog").hidden) closeLayout(); });
