// Every dropdown (select.input) opens the panel's own list instead of the
// browser's. Phones hand a native select to the system's picker, which follows
// the phone's theme rather than the panel's; this list follows the panel's, as
// the time zone box's suggestions do. The select stays in the page as it was,
// so its value, change events and layout work as before.
import { h } from "./util.js";

let open = null;   // { sel, list, items, at }

function close(refocus) {
  if (!open) return;
  const { sel, list } = open;
  open = null;
  list.remove();
  sel.setAttribute("aria-expanded", "false");
  if (refocus) sel.focus({ preventScroll: true });
}

function choose(i) {
  const { sel, items } = open;
  const opt = items[i];
  close(true);
  if (!opt || opt.disabled || sel.selectedIndex === opt.index) return;
  sel.selectedIndex = opt.index;
  sel.dispatchEvent(new Event("input", { bubbles: true }));
  sel.dispatchEvent(new Event("change", { bubbles: true }));
}

function mark(i) {
  const { list, items } = open;
  if (i < 0 || i >= items.length) return;
  open.at = i;
  list.querySelectorAll("li").forEach((li, n) => li.classList.toggle("on", n === i));
  // scroll the list only, never the page (a page scroll closes the list)
  const li = list.children[i];
  if (li.offsetTop < list.scrollTop) list.scrollTop = li.offsetTop - 4;
  else if (li.offsetTop + li.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = li.offsetTop + li.offsetHeight - list.clientHeight + 4;
}

function place(sel, list) {
  const r = sel.getBoundingClientRect();
  const vh = window.visualViewport ? window.visualViewport.height : window.innerHeight;
  const vw = document.documentElement.clientWidth;
  list.style.minWidth = `${r.width}px`;
  list.style.maxHeight = "";
  const below = vh - r.bottom - 12, above = r.top - 12;
  const want = list.offsetHeight;
  if (want > below && above > below) {
    list.style.maxHeight = `${Math.min(want, above)}px`;
    list.style.top = `${Math.max(8, r.top - 4 - Math.min(want, above))}px`;
  } else {
    list.style.maxHeight = `${Math.max(120, below)}px`;
    list.style.top = `${r.bottom + 4}px`;
  }
  const w = list.offsetWidth;
  list.style.left = `${Math.max(8, Math.min(r.left, vw - w - 8))}px`;
}

function show(sel) {
  if (open && open.sel === sel) { close(true); return; }
  close(false);
  if (sel.disabled || !sel.getClientRects().length) return;
  const items = [...sel.options];
  if (!items.length) return;
  const list = h("ul", { class: "pick-list", role: "listbox" },
    items.map((o, i) => h("li", {
      role: "option", text: o.textContent,
      class: o.disabled ? "off" : null,
      "aria-selected": o.selected ? "true" : "false",
      "aria-disabled": o.disabled ? "true" : null,
      onpointerdown: (e) => e.preventDefault(),
      onclick: () => choose(i),
    })));
  document.body.append(list);
  open = { sel, list, items, at: -1 };
  sel.setAttribute("aria-expanded", "true");
  place(sel, list);
  mark(Math.max(0, sel.selectedIndex));
  sel.focus({ preventScroll: true });
}

function step(dir) {
  const { items } = open;
  let i = open.at;
  do i += dir; while (i >= 0 && i < items.length && items[i].disabled);
  mark(i);
}

// Mouse and touch: stop the browser's own list, open ours on release, as the
// browser does. A finger that moves (a scroll) opens nothing.
let downAt = null;
function onDown(e) {
  const sel = e.target.closest && e.target.closest("select.input");
  if (!sel) return;
  if (e.type === "pointerdown" && e.button !== 0) return;
  e.preventDefault();
  if (e.type === "pointerdown") downAt = { sel, x: e.clientX, y: e.clientY };
}
function onUp(e) {
  const d = downAt;
  downAt = null;
  if (!d || e.target.closest?.("select.input") !== d.sel) return;
  if (Math.abs(e.clientX - d.x) > 10 || Math.abs(e.clientY - d.y) > 10) return;
  e.preventDefault();
  show(d.sel);
}

function onKey(e) {
  if (open) {
    if (e.key === "ArrowDown") { e.preventDefault(); step(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); step(-1); }
    else if (e.key === "Home") { e.preventDefault(); open.at = -1; step(1); }
    else if (e.key === "End") { e.preventDefault(); open.at = open.items.length; step(-1); }
    else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); choose(open.at); }
    else if (e.key === "Escape") { e.preventDefault(); close(true); }
    else if (e.key === "Tab") close(false);
    return;
  }
  const sel = e.target.closest && e.target.closest("select.input");
  if (!sel) return;
  // Space, Enter and Alt+Down would open the browser's list; open ours.
  // Plain arrows still change the value in place, as the browser does.
  if (e.key === " " || e.key === "Enter" || (e.altKey && e.key === "ArrowDown") || e.key === "F4") {
    e.preventDefault(); show(sel);
  }
}

document.addEventListener("pointerdown", (e) => {
  if (open && !open.list.contains(e.target) && e.target !== open.sel) close(false);
  onDown(e);
}, true);
document.addEventListener("mousedown", onDown, true);
document.addEventListener("touchstart", onDown, { capture: true, passive: false });
document.addEventListener("pointerup", onUp, true);
document.addEventListener("click", (e) => { if (e.target.closest?.("select.input")) e.preventDefault(); }, true);
document.addEventListener("keydown", onKey, true);
window.addEventListener("resize", () => close(false));
// Close when whatever holds the dropdown scrolls (it would leave the list
// behind), not when something else does, such as the log view as lines arrive.
document.addEventListener("scroll", (e) => {
  if (open && (e.target === document || (e.target.contains && e.target.contains(open.sel)))) close(false);
}, true);
window.addEventListener("hashchange", () => close(false));
