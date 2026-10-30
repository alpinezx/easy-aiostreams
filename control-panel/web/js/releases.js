import { $, h, clear, extIcon } from "./util.js";
import { renderMarkdown } from "./md.js";

// A nightly's GitHub release appears before its Docker image is pushed; don't offer it until the image has had time.
const IMAGE_WAIT = 30 * 60 * 1000;

let lastFocus = null;
let known = null;

// Stable tags compare as numbers. Nightly tags are timestamps, so comparing them as text is chronological.
export function cmpTag(a, b, channel) {
  if (channel === "nightly") return a < b ? -1 : a > b ? 1 : 0;
  const pa = a.replace(/^v/, "").split(".").map(Number), pb = b.replace(/^v/, "").split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  return 0;
}

export const tagLabel = (tag) => (tag.endsWith("-nightly") ? `nightly ${tag.slice(0, -8)}` : tag);

const building = (r, channel) => channel === "nightly" && r.published && Date.now() - Date.parse(r.published) < IMAGE_WAIT;

// What's newer than the running build, leaving out nightlies whose image isn't out yet.
export function behind(rel, running) {
  const newer = rel.releases.filter((r) => cmpTag(r.tag, running, rel.channel) > 0 && !building(r, rel.channel));
  const capped = newer.length >= rel.keep && newer.length === rel.releases.length ? "+" : "";
  const noun = rel.channel === "nightly" ? "build" : "release";
  return { newer, count: `${newer.length}${capped} ${noun}${newer.length === 1 ? "" : "s"}` };
}

export function remember(rel, running) {
  known = rel && rel.releases.length && running ? { rel, running } : null;
}

export function openKnown() {
  if (known) openReleases(known.rel, known.running);
}

// One line for the Update dialog, or null when there's no check to go on.
export function whatsNewLine(onOpen) {
  if (!known) return null;
  const { rel, running } = known;
  const { newer, count } = behind(rel, running);
  const nightly = rel.channel === "nightly";
  const text = newer.length
    ? (nightly ? `A newer nightly is out, ${count} newer than your ${tagLabel(running)}. ` : `${newer[0].tag} is out, ${count} newer than your ${running}. `)
    : (nightly ? `You're on the newest nightly, ${tagLabel(running)}. ` : `You're on the latest release, ${running}. `);
  return h("p", { class: "whats-new" }, text,
    h("button", { class: "linkish", type: "button", text: newer.length ? "See what's new" : "See release notes", onclick: onOpen }));
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
    h("a", { href: r.url, target: "_blank", rel: "noopener noreferrer" }, "View on GitHub", extIcon())));
}

function mark(r, running, channel) {
  const c = cmpTag(r.tag, running, channel);
  if (c === 0) return h("span", { class: "chip ok", text: "Running" });
  if (c < 0) return null;
  if (building(r, channel)) return h("span", { class: "chip", title: "Released minutes ago. Its Docker image is usually ready within half an hour; Update would still get the previous one until then.", text: "Image building" });
  return h("span", { class: "chip warn", text: "New" });
}

export function openReleases(rel, running) {
  lastFocus = document.activeElement;
  const list = $("#rel-list");
  clear(list);
  const nightly = rel.channel === "nightly";
  const { newer, count } = behind(rel, running);
  // AIOStreams' by default; AIOMetadata's list carries its own name and page
  const name = rel.name || "AIOStreams";
  $("#rel-title").textContent = nightly ? `${name} nightly builds` : `${name} releases`;
  $("#rel-sub").textContent = `${nightly ? "Nightly builds" : rel.name ? "Releases" : "Stable releases"}, newest first. You're running ${tagLabel(running)}, `
    + (newer.length ? `${count} behind.` : "the latest.");
  const foot = $("#rel-foot");
  foot.href = rel.page || "https://github.com/Viren070/AIOStreams/releases";
  foot.firstChild.textContent = rel.page ? "Every release on GitHub " : "Every release on GitHub, nightlies included ";
  rel.releases.forEach((r, i) => {
    const body = h("div", { class: "rel-body" });
    const open = i === 0 || newer.includes(r);
    const d = h("details", { class: "rel", open },
      h("summary", {},
        h("span", { class: "rel-tag", text: tagLabel(r.tag) }),
        mark(r, running, rel.channel),
        h("span", { class: "rel-when", text: r.published ? new Date(r.published).toLocaleString([], nightly
          ? { dateStyle: "short", timeStyle: "short" } : { dateStyle: "short" }) : "" })),
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

// easy-aiostreams' own CHANGELOG.md, in the same drawer: one box per date,
// each change tagged by its kind, the ones since this panel's version opened.
const KIND = { new: ["New", "cl-new"], fixed: ["Fixed", "cl-fixed"], docs: ["Docs", "cl-docs"] };

function inlineMd(text) {
  // One line of markdown; renderMarkdown wraps it in a paragraph, kept inline here.
  const frag = renderMarkdown(text);
  const p = frag.firstChild;
  return p && p.nodeName === "P" ? [...p.childNodes] : [frag];
}

export function openChangelog(log) {
  lastFocus = document.activeElement;
  const list = $("#rel-list");
  clear(list);
  const news = log.entries.filter((e) => e.new).length;
  $("#rel-title").textContent = "What's new";
  $("#rel-sub").textContent = news
    ? `${news === 1 ? "One change" : `${news} changes`} since your control panel's v${log.current}, newest first.`
    : `Nothing newer than your control panel's v${log.current}. The latest changes, newest first.`;
  const foot = $("#rel-foot");
  foot.href = log.page;
  foot.firstChild.textContent = "The full changelog on GitHub ";
  const days = [];
  for (const e of log.entries) {
    if (!days.length || days[days.length - 1].date !== e.date) days.push({ date: e.date, items: [] });
    days[days.length - 1].items.push(e);
  }
  days.forEach((d, i) => {
    const fresh = d.items.some((e) => e.new);
    list.append(h("details", { class: "rel", open: fresh || (!news && i === 0) },
      h("summary", {},
        h("span", { class: "rel-tag", text: d.date }),
        fresh ? h("span", { class: "chip warn", text: "New to you" }) : null,
        h("span", { class: "rel-when cl-count", text: `${d.items.length} ${d.items.length === 1 ? "change" : "changes"}` })),
      h("ul", { class: "rel-body cl-list" }, ...d.items.map((e) => {
        const [word, cls] = KIND[e.kind] || KIND.new;
        return h("li", { class: e.new ? "cl-fresh" : null }, h("span", { class: `cl-kind ${cls}`, text: word }), h("span", {}, ...inlineMd(e.text)));
      }))));
  });
  if (!days.length) list.append(h("p", { class: "dim", text: log.error ? `Couldn't load the changelog. ${log.error}` : "The changelog is empty." }));
  list.scrollTop = 0;
  $("#rel-drawer").hidden = false;
  $("#scrim").hidden = false;
  $("#rel-x").focus();
}

$("#rel-x").addEventListener("click", closeReleases);
$("#scrim").addEventListener("click", closeReleases);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && $("#dialog").hidden) closeReleases(); });
