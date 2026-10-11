import { $, h, clear } from "./util.js";
import { renderMarkdown } from "./md.js";

let lastFocus = null;
let known = null;

export function remember(rel, version) {
  known = rel && rel.releases.length && version ? { rel, version } : null;
}

export function openKnown() {
  if (known) openReleases(known.rel, known.version);
}

// One line for the Update dialog, or null when there's no check to go on.
export function whatsNewLine(onOpen) {
  if (!known) return null;
  const newer = known.rel.releases.filter((r) => cmpVer(r.tag, known.version) > 0);
  const text = newer.length
    ? `${newer[0].tag} is out, ${newer.length} release${newer.length === 1 ? "" : "s"} newer than your v${known.version}. `
    : `You're on the latest release, v${known.version}. `;
  return h("p", { class: "whats-new" }, text,
    h("button", { class: "linkish", type: "button", text: newer.length ? "See what's new" : "See release notes", onclick: onOpen }));
}

export function cmpVer(a, b) {
  const pa = a.replace(/^v/, "").split(".").map(Number), pb = b.replace(/^v/, "").split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  return 0;
}

function isOpen() { return !$("#rel-drawer").hidden; }

export function closeReleases() {
  if (!isOpen()) return;
  $("#rel-drawer").hidden = true;
  if ($("#dialog").hidden && $("#drawer").hidden) $("#scrim").hidden = true;
  if (lastFocus && lastFocus.isConnected && lastFocus.focus) lastFocus.focus();
}

function fill(body, r) {
  if (body.childElementCount) return;
  body.append((r.body || "").trim() ? renderMarkdown(r.body) : h("p", { class: "dim", text: "No notes for this release." }));
  if (r.url) body.append(h("p", { class: "rel-gh" },
    h("a", { href: r.url, target: "_blank", rel: "noopener noreferrer", text: "View on GitHub ↗" })));
}

export function openReleases(rel, version) {
  lastFocus = document.activeElement;
  const list = $("#rel-list");
  clear(list);
  const newer = rel.releases.filter((r) => cmpVer(r.tag, version) > 0).length;
  const capped = newer >= rel.keep && newer === rel.releases.length ? "+" : "";
  $("#rel-sub").textContent = `Stable releases, newest first. You're running v${version}, `
    + (newer ? `${newer}${capped} release${newer === 1 ? "" : "s"} behind.` : "the latest.");
  rel.releases.forEach((r, i) => {
    const c = cmpVer(r.tag, version);
    const body = h("div", { class: "rel-body" });
    const open = i === 0 || c > 0;
    const d = h("details", { class: "rel", open },
      h("summary", {},
        h("span", { class: "rel-tag", text: r.tag }),
        c === 0 ? h("span", { class: "chip ok", text: "Running" }) : c > 0 ? h("span", { class: "chip warn", text: "New" }) : null,
        h("span", { class: "rel-when", text: r.published ? new Date(r.published).toLocaleDateString() : "" })),
      body);
    if (open) fill(body, r);
    d.addEventListener("toggle", () => { if (d.open) fill(body, r); });
    list.append(d);
  });
  list.scrollTop = 0;
  $("#rel-drawer").hidden = false;
  $("#scrim").hidden = false;
  $("#rel-x").focus();
}

$("#rel-x").addEventListener("click", closeReleases);
$("#scrim").addEventListener("click", closeReleases);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && $("#dialog").hidden) closeReleases(); });
