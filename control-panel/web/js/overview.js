import { $, h, clear, setText, fmtDur, fmtBytes, api, toast, ago, extIcon } from "./util.js";
import { runAction, openJob, rebootServer, restartService } from "./actions.js";
import { openReleases, remember, behind } from "./releases.js";
import { days, todayLine, parseCheck } from "./alerts.js";
import { pill as scriptsPill } from "./scripts.js";
import { scheduleText } from "./activity.js";
import { applyLayout, openLayout } from "./layout.js";
import { countryName } from "./vpn.js";
import { loadTraffic, trafficData, trafficStale, summaryLine, feedNet, nowRate, today, fmtRate } from "./traffic.js";

// ---------------- update check ----------------
let rel = null, relLoading = false, relFor = null, lastSt = null;

const relChannel = (st) => (st.channel === "nightly" ? "nightly" : "stable");

// The release tag of the build actually running. A nightly is only known by the tag in its metadata.json.
function runningTag(st) {
  if (!st.version) return null;
  const t = st.build_tag || "";
  if (relChannel(st) === "nightly") return t.endsWith("-nightly") ? t : null;
  return t.startsWith("v") ? t : `v${st.version}`;
}

async function loadReleases(force) {
  const chan = relFor;
  relLoading = true;
  if (lastSt) hero(lastSt);
  let got;
  try { got = await api(`/api/aiostreams-releases?channel=${chan}${force ? "&force=1" : ""}`); }
  catch (e) { got = { channel: chan, releases: [], error: e.message }; }
  if (chan !== relFor) return;      // the build channel changed while this was out
  rel = got;
  relLoading = false;
  const running = lastSt && runningTag(lastSt);
  remember(rel, running);
  if (lastSt) hero(lastSt);
  if (force && running) {
    const { newer } = behind(rel, running);
    const nightly = chan === "nightly";
    if (!rel.releases.length) toast(`Couldn't check for updates. ${rel.error || ""}`.trim(), true);
    else if (newer.length) toast(nightly ? "A newer nightly is out." : `${newer[0].tag} is available.`);
    else toast(nightly ? "You're on the newest nightly." : `${running} is the latest release.`);
  }
}

// The version card's Latest column: [value, line under it, buttons, whether a newer release is out]
function updateBits(st) {
  const running = runningTag(st);
  if (!running) {
    return [h("span", { class: "warn", text: "Can't tell",
      title: "The running image has no nightly tag in its metadata, so there's nothing to compare. An Update usually fixes it." }),
      "Which nightly is running is unknown", [], false];
  }
  const nightly = relChannel(st) === "nightly";
  let value, sub = "", fresh = false;
  if (!rel) {
    value = h("span", { class: "dim", text: "Checking…" });
  } else if (!rel.releases.length) {
    value = h("span", { class: "warn", title: rel.error || "GitHub listed no releases for this channel.", text: "Couldn't check" });
    sub = "GitHub didn't answer";
  } else {
    const { newer, count } = behind(rel, running);
    sub = rel.checked_at ? `Checked ${ago(rel.checked_at)}` : "";
    if (!newer.length) {
      value = h("span", { class: "ok", text: "Up to date" });
    } else {
      const top = newer[0];
      fresh = true;
      const when = top.published ? `, newest released ${ago(Date.parse(top.published) / 1000)}` : "";
      value = h("button", { class: "linkish warn", type: "button", title: `${count} behind${when}. Click for what's new; use Update to get it.`,
        text: nightly ? "Newer nightly out" : `${top.tag} available`, onclick: () => openReleases(rel, running) });
    }
  }
  const btns = [h("button", { class: "btn small", type: "button", text: relLoading ? "Checking…" : "Check now",
    disabled: relLoading, title: `Ask GitHub for the latest AIOStreams ${nightly ? "nightly" : "release"} now`, onclick: () => loadReleases(true) })];
  if (rel && rel.releases.length) {
    btns.push(h("button", { class: "btn small", type: "button", text: "All releases",
      title: `What changed in each AIOStreams ${nightly ? "nightly build" : "release"}`, onclick: () => openReleases(rel, running) }));
  }
  return [value, sub, btns, fresh];
}

// When the running release came out, if GitHub's list has it
function releasedAgo(running) {
  const r = rel && running && rel.releases.find((x) => x.tag === running);
  return r && r.published ? `Released ${ago(Date.parse(r.published) / 1000)}` : "";
}

const RESTARTABLE = new Set(["aiostreams", "mediaflow", "webhook", "aiometadata"]);
const hist = {};          // cpu history per service, for the sparklines
const keys = {};          // last structure key per region, so we only rebuild on real changes
const SVG = "http://www.w3.org/2000/svg";

const STATE_WORD = {
  running: "Running", starting: "Starting", stopped: "Stopped", missing: "Not created",
  unhealthy: "Unhealthy", restarting: "Restarting", paused: "Stopped manually",
};
const stateOf = (s) => (s.on_purpose && s.state !== "running" ? "paused" : s.state);

// A container's CPU is Docker's figure, up to 100% per CPU. Coloured by its share
// of the whole server, like Load, and only once the last 3 readings were all that
// high, so a short burst (a search) doesn't flash amber.
function cpuTone(h, cpus) {
  if (!h || h.length < 3) return "";
  const low = Math.min(...h.slice(-3)) / cpus;
  return low >= 90 ? "bad" : low >= 75 ? "warn" : "";
}

function uptime(s) {
  if (s.state !== "running" || !s.started_at) return "";
  return fmtDur((Date.now() - Date.parse(s.started_at)) / 1000);
}

function rebuild(region, key, build) {
  const el = $(region);
  if (keys[region] === key) return el;
  keys[region] = key;
  clear(el); build(el);
  return el;
}

// Called once per status poll (not per repaint) so sparklines get one point per poll.
export function record(st) {
  feedNet(st.net);
  for (const s of st.services) {
    if (s.state !== "running") { hist[s.key] = []; continue; }
    (hist[s.key] ||= []).push(s.cpu ?? 0);
    if (hist[s.key].length > 36) hist[s.key].shift();
  }
}

// ---------------- folding ----------------
// Every card folds to one line holding what matters most, and anything that needs a look
// stays on that line. Remembered per browser, so a phone can keep cards folded and a
// desktop open. Only the request flow and the list of certificates start folded.
const FOLD_KEYS = { flow: "aios.flowFolded" };
const DEFAULT_FOLDED = new Set(["flow", "certs"]);
const foldKey = (id) => FOLD_KEYS[id] || `aios.fold.${id}`;
const folds = {};
function isFolded(id) {
  if (!(id in folds)) {
    let v = null;
    try { v = localStorage.getItem(foldKey(id)); } catch (_) {}
    folds[id] = v == null ? DEFAULT_FOLDED.has(id) : v !== "0";
  }
  return folds[id];
}
// Edit's Reset to default: forget this browser's folds, so each card is back to how it starts
window.addEventListener("layout-reset", () => {
  for (const id of Object.keys(folds)) {
    delete folds[id];
    try { localStorage.removeItem(foldKey(id)); } catch (_) {}
  }
  if (lastSt) render(lastSt, lastGoLogs);
});
function setFold(id) {
  folds[id] = !isFolded(id);
  try { localStorage.setItem(foldKey(id), folds[id] ? "1" : "0"); } catch (_) {}
  if (lastSt) render(lastSt, lastGoLogs);
}
function chev() {
  const c = h("span", { class: "path-chev", "aria-hidden": "true" });
  c.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  return c;
}
// The title as the fold button, as on the request flow
function foldTitle(id, label) {
  const f = isFolded(id);
  return h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(!f),
    title: f ? `Show all of ${label}` : `Fold ${label} to one line`, onclick: () => setFold(id) }, label, chev());
}
// The folded line: [text or element, tone, tooltip], empty ones left out
function foldSum(items) {
  return h("ul", { class: "path-sum fold-sum" }, ...items.filter((x) => x && x[0]).map(([v, tone, title]) =>
    h("li", { class: tone || null, title: title || null }, v)));
}

let lastGoLogs = null;
export function render(st, goLogs) {
  window.__channel = st.channel;
  lastSt = st;
  lastGoLogs = goLogs;
  if (st.version && relFor !== relChannel(st)) { relFor = relChannel(st); rel = null; loadReleases(false); }
  remember(rel, runningTag(st));
  hero(st); path(st); rows(st, goLogs); side(st);
  applyLayout(st);
}

// Caddy renews a certificate with about a third of its life left, so it only gets
// this low when renewal has failed for a while: amber under a quarter, red under 7 days.
// Relative, so shorter certificates (45 days) don't turn amber on every renewal.
function certTone(c) {
  const d = c.days_left;
  return d < 7 ? "bad" : d < (c.days_total ? c.days_total / 4 : 21) ? "warn" : "";
}

// Every certificate to show: the per-site list when the server sends it, else the single main one
function allCerts(st) {
  return st.certs && st.certs.length ? st.certs : st.cert ? [st.cert] : [];
}

// The certificate most in need of attention: a failed check first, then the fewest days left
function worstCert(st) {
  const cs = allCerts(st);
  return cs.find((c) => !c.ok) || cs.slice().sort((a, b) => a.days_left - b.days_left)[0] || null;
}

function certChip(st, long) {
  const c = worstCert(st);
  if (!c.ok) return h("span", { class: "chip warn", title: c.host ? `For ${c.host}` : null, text: long ? "Couldn't check HTTPS certificate" : "Couldn't check" });
  const d = c.days_left;
  return h("span", { class: "chip " + (certTone(c) || "ok"), title: c.host ? `For ${c.host}. Caddy renews it by itself.` : null,
    text: long ? `HTTPS certificate good for ${d} days` : `${d} days left` });
}

// ---------------- hero ----------------
function hero(st) {
  const avail = Object.fromEntries(st.actions.map((a) => [a.id, a]));
  const aio = st.services.find((s) => s.key === "aiostreams");
  const key = [st.overall, st.headline, st.domain, st.channel, st.version, st.build_tag, st.vpn, !!st.busy, aio && aio.state,
    allCerts(st).map((c) => `${c.host}:${c.ok}:${c.days_left}:${c.days_total}`).join(","), st.installed, st.docker_ok, relLoading, rel && rel.checked_at, rel && rel.error, isFolded("aiostreams"),
    JSON.stringify(st.aiometadata || null), isFolded("aiometadata")].join("|");
  rebuild("#hero", key, (el) => {
    // The headline, and after it the "Script updates" pill while a setup script here differs
    // from GitHub (it drops below the headline when they don't fit on one line).
    // Opening AIOStreams is the version card's title.
    el.append(h("div", { class: "hero-head" },
      h("span", { class: "lamp", dataset: { s: st.overall }, "aria-hidden": "true" }),
      h("h1", { class: "headline", "aria-live": "polite", text: st.headline }),
      h("a", { class: "chip warn scripts-pill", id: "scripts-pill", href: "#scripts", hidden: true }),
      st.installed ? editBtn() : null));
    scriptsPill();
    // The certificate lives in This server; it comes up here only when it needs attention.
    const wc = worstCert(st);
    if (wc && (!wc.ok || certTone(wc))) el.append(h("div", { class: "hero-meta" }, certChip(st, true)));
    // The version card has a slot of its own, so wide screens can put the request flow above it
    const ver = $("#ver");
    clear(ver);
    if (st.version) ver.append(versionCard(st, avail));
    // AIOMetadata's card, only once it's installed (it isn't nudged)
    const meta = $("#meta");
    clear(meta);
    if (st.aiometadata) meta.append(metaCard(st, avail));

    if (!st.installed) {
      el.append(h("p", { class: "empty", text: "AIOStreams isn't installed on this server yet. Run setup-aiostreams.sh over SSH first." }));
      return;
    }
    // Start and Stop sit on AIOStreams' row in Services, and Restart stack on the request path.
    if (st.busy) {
      el.append(h("div", { class: "toolbar" }, h("span", { class: "busy-note" }, h("span", { class: "spin", "aria-hidden": "true" }), "An action is running",
        h("button", { class: "btn small", type: "button", text: "View output", onclick: () => openJob(st.busy) }))));
    }
  });
}

// Edit: which cards the Overview shows, and their order, in a drawer
function editBtn() {
  const b = h("button", { class: "btn small quiet hero-edit", type: "button", title: "Show, hide or reorder the cards on this page", onclick: openLayout });
  b.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20h4L19 9l-4-4L4 16v4zM14 6l4 4"/></svg>Edit';
  return b;
}

// The build in a card of its own, laid out like AIOStreams' own Version card:
// the version here, the latest, and the buttons, with the channel in the corner. No
// labels: the values say what they are ("v2.36.0", "Up to date", "v2.36.1 available").
// A card's own pages, in blue beside its title, each opening in a new tab
function cardPages(domain, pages) {
  return h("span", { class: "card-pages" }, ...pages.map(([label, path]) => h("a", { class: "card-page",
    href: `https://${domain}${path}`, target: "_blank", rel: "noopener noreferrer",
    title: `Opens https://${domain}${path} in a new tab` }, label, extIcon())));
}

// AIOMetadata's releases, from GitHub, kept 3 hours like AIOStreams'. Check now asks again.
let metaRel = null, metaRelLoading = false;
async function loadMetaReleases(force) {
  if (metaRelLoading) return;
  metaRelLoading = true;
  if (lastSt) { keys["#hero"] = null; hero(lastSt); }
  try { metaRel = await api(`/api/aiometadata-releases${force ? "?force=1" : ""}`); }
  catch (e) { metaRel = { channel: "aiometadata", releases: [], error: e.message }; }
  metaRel.name = "AIOMetadata";
  metaRel.page = "https://github.com/cedya77/aiometadata/releases";
  metaRelLoading = false;
  if (lastSt) { keys["#hero"] = null; hero(lastSt); }
  if (force && lastSt && lastSt.aiometadata) {
    const running = `v${lastSt.aiometadata.version}`;
    const top = metaRel.releases.length ? behind(metaRel, running).newer[0] : null;
    if (!metaRel.releases.length) toast(`Couldn't check for updates. ${metaRel.error || ""}`.trim(), true);
    else toast(top ? `AIOMetadata ${top.tag} is available.` : `AIOMetadata ${running} is the latest release.`);
  }
}

// AIOMetadata's card, laid out like AIOStreams'. Its releases come up to twice a day, so a
// newer one is a plain line, never amber or a blue button: Update only when pressed.
function metaCard(st, avail) {
  const m = st.aiometadata;
  const running = `v${m.version}`;
  if (!metaRel) loadMetaReleases(false);
  const list = metaRel && metaRel.releases.length ? metaRel : null;
  const top = list ? behind(list, running).newer[0] : null;
  const mine = list && list.releases.find((r) => r.tag === running);
  const latest = !metaRel ? h("span", { class: "dim", text: "Checking…" })
    : !list ? h("span", { class: "warn", title: metaRel.error || "", text: "Couldn't check" })
    : h("span", { class: top ? "quiet" : "ok", text: top ? `${top.tag} available` : "Up to date" });
  const upd = avail["aiometadata.update"];
  const updBtn = upd && upd.available ? h("button", { class: "btn small", type: "button", text: "Update", disabled: !!st.busy,
    title: "Update AIOMetadata to its newest release, with a backup first", onclick: () => runAction(upd) }) : null;
  const title = h("div", { class: "fold-title" },
    h("h2", {}, foldTitle("aiometadata", "AIOMetadata")),
    m.domain ? cardPages(m.domain, [["Dashboard", "/dashboard"], ["Configure", "/configure"]]) : null);
  if (isFolded("aiometadata")) {
    return h("section", { class: "panel ver-card folded", "aria-label": "AIOMetadata version" },
      h("div", { class: "ver-head" }, title, foldSum([[running], [latest]]), updBtn));
  }
  const col = (value, sub) => h("div", {}, h("div", { class: "ver-value" }, value), h("div", { class: "ver-sub", text: sub || "" }));
  return h("section", { class: "panel ver-card", "aria-label": "AIOMetadata version" },
    h("div", { class: "ver-head" }, title),
    h("div", { class: "ver-grid" },
      col(running, mine && mine.published ? `Released ${ago(Date.parse(mine.published) / 1000)}` : ""),
      h("div", { class: "ver-right" },
        col(latest, top && top.published ? `Released ${ago(Date.parse(top.published) / 1000)}` : list ? `Checked ${ago(metaRel.checked_at)}` : ""),
        h("div", { class: "ver-btns" }, updBtn,
          h("button", { class: "btn small", type: "button", text: metaRelLoading ? "Checking…" : "Check now", disabled: metaRelLoading,
            title: "Ask GitHub for the latest AIOMetadata release now", onclick: () => loadMetaReleases(true) }),
          list ? h("button", { class: "btn small", type: "button", text: "All releases",
            title: "What changed in each AIOMetadata release", onclick: () => openReleases(list, running) }) : null))));
}

function versionCard(st, avail) {
  const nightly = relChannel(st) === "nightly";
  const running = runningTag(st);
  const [latest, latestSub, btns, fresh] = updateBits(st);
  const col = (value, sub) => h("div", {},
    h("div", { class: "ver-value" }, value), h("div", { class: "ver-sub", text: sub || "" }));
  const upd = st.installed && avail["stack.update"];
  // Update sits with Check now, blue only when a newer release is out
  if (upd && upd.available) btns.unshift(h("button", { class: "btn small" + (fresh ? " primary" : ""), type: "button", text: "Update",
    disabled: !!st.busy, title: "Update AIOStreams, or switch between stable and nightly", onclick: () => runAction(upd) }));
  // The title folds the card like the others; its two pages are links beside it
  const title = h("div", { class: "fold-title" },
    h("h2", {}, foldTitle("aiostreams", "AIOStreams")),
    st.domain ? cardPages(st.domain, [["Dashboard", "/dashboard"], ["Configure", "/stremio/configure"]]) : null);
  if (isFolded("aiostreams")) {
    // One line: the version running, whether a newer one is out, and Update
    return h("section", { class: "panel ver-card folded", "aria-label": "AIOStreams version" },
      h("div", { class: "ver-head" }, title,
        foldSum([[nightly && running ? `Nightly ${running.slice(0, -8)}` : `v${st.version}`], [latest]]),
        btns[0] && btns[0].textContent === "Update" ? btns[0] : null));
  }
  return h("section", { class: "panel ver-card", "aria-label": "AIOStreams version" },
    h("div", { class: "ver-head" }, title,
      h("span", { class: "chip" + (nightly ? " warn" : " ok"), text: nightly ? "Nightly" : "Stable",
        title: nightly ? "AIOStreams' nightly builds (Docker tag: nightly). Switch with Update." : "AIOStreams' stable releases (Docker tag: latest). Switch with Update." })),
    h("div", { class: "ver-grid" },
      col(`v${st.version}`, nightly ? (running ? `Nightly ${running.slice(0, -8)}` : "") : releasedAgo(running)),
      h("div", { class: "ver-right" }, col(latest, latestSub), h("div", { class: "ver-btns" }, ...btns))));
}

// ---------------- signal path ----------------
function node(s) {
  const st = stateOf(s);
  // On phones only the name shows, so the state is on its tooltip and for screen readers too
  return h("div", { class: "node", dataset: { s: st, svc: s.key }, title: `${s.name}: ${STATE_WORD[st] || st}` },
    h("div", { class: "node-name", text: s.name }),
    h("div", { class: "node-state" }, h("span", { class: "word", text: STATE_WORD[st] || st }),
      " ", h("span", { class: "dim", dataset: { up: s.key }, text: uptime(s) })));
}

// Folded until someone opens it (see folding above)
function path(st) {
  const folded = isFolded("flow");
  const main = st.services.filter((s) => !s.addon);
  const addons = st.services.filter((s) => s.addon);
  const restart = st.installed && st.actions.find((a) => a.id === "stack.restart");
  const key = st.services.map((s) => `${s.key}:${stateOf(s)}`).join(",") + st.docker_ok + !!st.busy + !!(restart && restart.available) + folded;
  const restartBtn = () => restart && restart.available ? h("button", { class: "btn small", type: "button", text: "Restart stack", disabled: !!st.busy,
    title: "Restart Caddy, AIOStreams and anything in between", onclick: () => runAction(restart) }) : null;
  const el = rebuild("#path", key, (el) => {
    el.classList.toggle("folded", folded);
    const head = h("div", { class: "path-head" }, h("h2", { class: "path-title" }, foldTitle("flow", "Request flow")));
    el.append(head);
    if (folded) {
      // One line: a dot per service, coloured like the boxes, and Restart stack beside them
      head.append(h("ul", { class: "path-sum" }, ...st.services.map((s) => {
        const sx = stateOf(s);
        return h("li", { dataset: { s: sx }, title: `${s.name}: ${STATE_WORD[sx] || sx}` }, h("i", { "aria-hidden": "true" }), s.name);
      })), restartBtn());
      return;
    }
    const chain = h("div", { class: "chain" });
    chain.append(h("div", { class: "path-start" }, h("i"), "Visitors"));
    let upstreamOk = true;   // everything before this point is running
    main.forEach((s) => {
      const ok = s.state === "running";
      chain.append(h("span", { class: "link " + (upstreamOk && ok ? "live" : "broken") }));
      chain.append(node(s));
      upstreamOk = upstreamOk && ok;
    });
    el.append(chain);
    if (addons.length) {
      const caddy = main.find((s) => s.key === "caddy");
      const wrap = h("div", { class: "addons-wrap" });
      const ul = h("ul", { class: "addons" });
      addons.forEach((s) => {
        const ok = s.state === "running" && caddy && caddy.state === "running";
        ul.append(h("li", { class: ok ? "live" : "broken" }, node(s)));
      });
      wrap.append(ul);
      el.append(wrap);
      el.dataset.hasAddons = "1";
    }
    // Buttons that do something substantial sit at the card's bottom right
    el.append(h("div", { class: "card-foot path-foot" },
      addons.length ? h("p", { class: "addon-note", text: "Add-ons hang off Caddy, each on its own subdomain." }) : null,
      restartBtn()));
  });
  // line the add-on trunk up under the Caddy node
  const caddyNode = el.querySelector('.node[data-svc="caddy"]');
  const ul = el.querySelector(".addons");
  if (caddyNode && ul) {
    const r = el.querySelector(".chain").getBoundingClientRect();
    const c = caddyNode.getBoundingClientRect();
    ul.style.setProperty("--trunk", `${Math.round(c.left - r.left + (window.innerWidth > 720 ? 22 : 14))}px`);
  }
  for (const s of st.services) setText(el, `[data-up="${s.key}"]`, uptime(s));
}

// ---------------- service rows ----------------
function spark(values) {
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("class", "spark"); svg.setAttribute("viewBox", "0 0 96 28"); svg.setAttribute("aria-hidden", "true");
  const area = document.createElementNS(SVG, "path"); area.setAttribute("class", "area");
  const line = document.createElementNS(SVG, "path"); line.setAttribute("class", "line");
  svg.append(area, line);
  fillSpark(svg, values);
  return svg;
}
function fillSpark(svg, values) {
  const v = values.length > 1 ? values : [0, 0];
  const max = Math.max(5, ...v);
  const pts = v.map((y, i) => [(i / (v.length - 1)) * 96, 26 - (y / max) * 22]);
  const d = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" ");
  svg.querySelector(".line").setAttribute("d", d);
  svg.querySelector(".area").setAttribute("d", `${d} L96 28 L0 28 Z`);
}

// Folded: how many are running, their memory, and any that aren't, by name
function svcHead(st) {
  const f = isFolded("services");
  $("#rows").hidden = f;
  const up = st.services.filter((s) => s.state === "running");
  const mem = up.reduce((n, s) => n + (s.mem || 0), 0);
  const el = rebuild("#svc-head", st.services.map((s) => `${s.key}:${stateOf(s)}`).join(",") + f, (el) => {
    el.classList.toggle("folded", f);
    el.append(h("h2", { class: "sec" }, foldTitle("services", "Services")));
    if (!f) return;
    el.append(foldSum([[`${up.length} of ${st.services.length} running`, up.length === st.services.length ? "ok" : ""],
      [h("span", { dataset: { mem: "1" } })],
      ...st.services.filter((s) => s.state !== "running").map((s) => {
        const sx = stateOf(s);
        return [`${s.name}: ${(STATE_WORD[sx] || sx).toLowerCase()}`, sx === "paused" ? "warn" : "bad"];
      })]));
  });
  setText(el, "[data-mem]", mem ? `${fmtBytes(mem)} memory` : "");
}

function rows(st, goLogs) {
  svcHead(st);
  const avail = Object.fromEntries(st.actions.map((a) => [a.id, a]));
  const key = st.services.map((s) => `${s.key}:${stateOf(s)}`).join(",") + !!st.busy;
  const el = rebuild("#rows", key, (el) => {
    el.append(h("div", { class: "row row-head" }, h("span", { text: "Service" }), h("span", { text: "Status and image" }),
      h("span", { class: "num", text: "CPU" }), h("span", { class: "num", text: "Memory" }), h("span", { class: "spark-cell", text: "Recent CPU" }), h("span")));
    for (const s of st.services) {
      const sx = stateOf(s);
      // Three fixed slots (Logs, Restart, Start/Stop), left empty when a service lacks one, so the buttons line up down the table
      const slot = [h("span", { class: "slot" }), h("span", { class: "slot" }), h("span", { class: "slot" })];
      const acts = h("div", { class: "acts" }, ...slot);
      if (s.present) slot[0].append(h("button", { class: "btn small", type: "button", text: "Logs", onclick: () => goLogs(s.container) }));
      if (RESTARTABLE.has(s.key) && s.present) {
        slot[1].append(h("button", { class: "btn small", type: "button", text: "Restart",
          disabled: !!st.busy || s.state !== "running",
          title: s.state === "running" ? `Restart only ${s.name}` : "Only available while it's running",
          onclick: () => restartService(s) }));
      }
      // AIOStreams' Start / Stop are the stack's (Stop leaves Caddy up); the add-ons have their own
      if (s.addon || s.key === "aiostreams") {
        const id = `${s.addon ? s.key : "stack"}.${s.state === "running" ? "stop" : "start"}`;
        const a = avail[id];
        if (a && a.available) slot[2].append(h("button", { class: "btn small" + (s.state === "running" ? " danger" : ""), type: "button", text: a.label, disabled: !!st.busy, onclick: () => runAction(a) }));
      }
      el.append(h("div", { class: "row", dataset: { svc: s.key } },
        // What the service does is on hover, keeping each row to the name
        h("div", {}, h("div", { class: "name", text: s.name, title: s.role || null })),
        h("div", {}, h("div", { class: "state-word", dataset: { s: sx } }, h("span", { dataset: { w: "1" } })),
          h("div", { class: "img", dataset: { img: "1" }, title: s.image || "" })),
        h("div", { class: "num", dataset: { cpu: "1" } }),
        h("div", { class: "num", dataset: { mem: "1" } }),
        h("div", { class: "spark-cell" }, spark(hist[s.key] || [])),
        acts));
    }
  });
  for (const s of st.services) {
    const row = el.querySelector(`.row[data-svc="${s.key}"]`);
    if (!row) continue;
    const sx = stateOf(s);
    const up = uptime(s);
    // "Up for 27m" rather than "Running for 27m": short enough to stay on one line.
    const word = sx === "running" && up ? `Up for ${up}` : (STATE_WORD[sx] || sx) + (up ? ` for ${up}` : "");
    setText(row, "[data-w]", word + (s.restarts ? `, restarted ${s.restarts}×` : ""));
    setText(row, "[data-img]", s.image || "");
    setText(row, "[data-cpu]", s.state === "running" && s.cpu != null ? `${s.cpu}%` : "");
    const cpuEl = row.querySelector("[data-cpu]");
    if (cpuEl) cpuEl.className = "num " + cpuTone(hist[s.key], (st.host && st.host.cpus) || 1);
    setText(row, "[data-mem]", s.state === "running" && s.mem != null ? fmtBytes(s.mem) : "");
    const sv = row.querySelector("svg.spark");
    if (sv) fillSpark(sv, hist[s.key] || []);
  }
}

// The Phone alerts card's 14-day strip comes from the watchdog's own page data,
// fetched at most once a minute (the status poll runs every few seconds).
let wdDays = null, wdDaysAt = 0, wdDaysLoading = false;
async function loadWdDays() {
  if (wdDaysLoading || Date.now() - wdDaysAt < 60000) return;
  wdDaysLoading = true;
  try { wdDays = (await api("/api/watchdog")).tally || []; wdDaysAt = Date.now(); if (lastSt) side(lastSt); }
  catch (_) { wdDaysAt = Date.now(); }
  finally { wdDaysLoading = false; }
}

// The VPN card's details come from the VPN page's own data (the server asks from inside
// gluetun at most once a minute), fetched again within a minute, or at once when it's switched.
let vpnInfo = null, vpnAt = 0, vpnFor = null, vpnLoading = false;
async function loadVpn(mode, fresh) {
  if (vpnLoading || (!fresh && mode === vpnFor && Date.now() - vpnAt < 60000)) return;
  vpnLoading = true;
  if (fresh && lastSt) side(lastSt);
  try { vpnInfo = await api(`/api/vpn${fresh ? "?fresh=1" : ""}`); }
  catch (_) { vpnInfo = null; }
  vpnAt = Date.now(); vpnFor = mode; vpnLoading = false;
  if (lastSt) side(lastSt);
  if (fresh && vpnInfo) toast(vpnInfo.connected ? "The VPN is connected." : vpnInfo.error || "The VPN isn't connected.", !vpnInfo.connected);
}

// ---------------- side panels ----------------
// One labelled value with a quiet line under it, like the version card and
// AIOStreams' own System card. Coloured only when it needs a look.
function stat(label, value, sub, tone) {
  return h("div", { class: "stat" }, h("div", { class: "ver-label", text: label }),
    h("div", { class: "stat-value" + (tone ? " " + tone : ""), text: value }),
    h("div", { class: "ver-sub", text: sub || "" }));
}
const tone = (pct, warn, bad) => (pct >= bad ? "bad" : pct >= warn ? "warn" : "");
const dayMonth = (ms) => new Date(ms).toLocaleDateString([], { day: "numeric", month: "short" });

// This server folded: uptime, memory, disk and the last backup, plus the certificate or
// load only when they need a look
function hostSum(st) {
  const hs = st.host || {};
  const pct = (u, t) => Math.round((u / t) * 100);
  const bk = st.backup;
  const bad = bk && bk.every !== "off" && bk.last && (bk.last.status === "failed" || bk.last.status === "skipped");
  const load = hs.load ? (hs.load[0] / (hs.cpus || 1)) * 100 : 0;
  const wc = worstCert(st);
  return foldSum([
    [hs.uptime != null ? `Up ${fmtDur(hs.uptime)}` : ""],
    [wc && !wc.ok ? "Certificate: couldn't check" : wc && certTone(wc) ? `Certificate: ${wc.days_left} days left` : "",
      wc && !wc.ok ? "warn" : wc && certTone(wc)],
    [load >= 75 ? `Load ${hs.load[0].toFixed(2)}` : "", tone(load, 75, 90)],
    [hs.mem_total ? `Memory ${pct(hs.mem_used, hs.mem_total)}%` : "", hs.mem_total && tone(pct(hs.mem_used, hs.mem_total), 80, 90)],
    [hs.disk_total ? `Disk ${pct(hs.disk_used, hs.disk_total)}%` : "", hs.disk_total && tone(pct(hs.disk_used, hs.disk_total), 80, 90)],
    [bk ? (bad ? `Last scheduled backup ${bk.last.status === "skipped" ? "skipped" : "failed"}` : bk.newest ? `Backup ${ago(bk.newest)}` : "No backup yet") : "",
      bad || (bk && !bk.newest) ? "warn" : ""]]);
}

// HTTPS certificates. One site: a single tile. Several: folded to one tile with the soonest
// expiry, open to one tile per site. A cert that needs a look keeps the list open.
function certTiles(grid, st) {
  const certs = allCerts(st);
  if (!certs.length) return;
  if (certs.length === 1) {
    const c = certs[0], d = c.days_left;
    grid.append(c.ok
      ? stat("HTTPS certificate", `${d} day${d === 1 ? "" : "s"} left`, certTone(c) ? "Not renewed yet: check Caddy's logs" : "Auto-renews", certTone(c))
      : stat("HTTPS certificate", "Couldn't check", "", "warn"));
    return;
  }
  const needsLook = certs.some((c) => !c.ok || certTone(c));
  const folded = isFolded("certs") && !needsLook;
  const w = worstCert(st);
  if (folded) {
    grid.append(h("div", { class: "stat" }, h("div", { class: "ver-label cert-fold" }, foldTitle("certs", "HTTPS certificates")),
      h("div", { class: "stat-value", text: `${w.days_left} day${w.days_left === 1 ? "" : "s"} left` }),
      h("div", { class: "ver-sub", text: `soonest of ${certs.length} sites` })));
    return;
  }
  grid.append(h("div", { class: "cert-head" }, needsLook
    ? h("span", { class: "ver-label", text: "HTTPS certificates" })
    : foldTitle("certs", "HTTPS certificates")));
  for (const c of certs) {
    const d = c.days_left, label = c.label || c.host;
    grid.append(c.ok
      ? stat(label, `${d} day${d === 1 ? "" : "s"} left`, certTone(c) ? "Not renewed yet: check Caddy's logs" : c.host, certTone(c))
      : stat(label, "Couldn't check", c.host, "warn"));
  }
}

function side(st) {
  const el = $("#side");
  const w = st.watchdog || {};
  const avail = Object.fromEntries(st.actions.map((a) => [a.id, a]));
  clear(el);   // small and cheap; its only buttons are the watchdog ones, rebuilt rarely enough below
  const hs = st.host || {};
  const hostFolded = isFolded("server");
  const host = h("section", { class: "panel host" + (hostFolded ? " folded" : "") },
    h("div", { class: "card-head" }, h("h3", {}, foldTitle("server", "This server"))));
  if (hostFolded) host.firstChild.append(hostSum(st));
  const grid = h("div", { class: "stat-grid" });
  if (hs.uptime != null) grid.append(stat("Up for", fmtDur(hs.uptime), `since ${dayMonth(Date.now() - hs.uptime * 1000)}`));
  certTiles(grid, st);
  if (hs.load) {
    const pct = (hs.load[0] / (hs.cpus || 1)) * 100;
    grid.append(stat("Load", hs.load[0].toFixed(2), `on ${hs.cpus} CPU${hs.cpus > 1 ? "s" : ""}`, tone(pct, 75, 90)));
  }
  for (const [label, used, total, warn] of [["Memory", hs.mem_used, hs.mem_total, 80], ["Disk", hs.disk_used, hs.disk_total, 80]]) {
    if (!total) continue;
    const pct = (used / total) * 100;
    grid.append(stat(label, `${fmtBytes(used)} of ${fmtBytes(total)}`, `${Math.round(pct)}% used, ${fmtBytes(total - used)} free`, tone(pct, warn, 90)));
  }
  // The server's own network card, everything in and out (the VPN's tunnel travels through it
  // too): the speed now and today's totals
  if (st.net && st.net.host) {
    if (trafficStale("host")) loadTraffic(false, "host").then(() => { if (lastSt) side(lastSt); }).catch(() => {});
    const n = nowRate(trafficData("host"), "host"), t = today(trafficData("host"));
    const net = stat("Network", n ? "" : "Measuring…", t && (t[0] || t[1]) ? `Today ↓ ${fmtBytes(t[0])} ↑ ${fmtBytes(t[1])}` : "");
    // Down and up on a line each, so the value keeps its height however long the numbers are
    if (n) net.children[1].append(h("span", { class: "nowrap", text: `↓ ${fmtRate(n[0])}` }), h("span", { class: "nowrap", text: `↑ ${fmtRate(n[1])}` }));
    grid.append(net);
  }
  // The newest backup, any kind, and the schedule; amber when the last scheduled one failed or was skipped
  const bk = st.backup;
  if (bk) {
    const bad = bk.every !== "off" && bk.last && (bk.last.status === "failed" || bk.last.status === "skipped");
    grid.append(stat("Last backup", bk.newest ? ago(bk.newest) : "None yet",
      bad ? `The last scheduled one ${bk.last.status === "skipped" ? "was skipped" : "failed"}` : scheduleText(bk), bad ? "warn" : ""));
  }
  // Reboot sits in the last row's spare room, at its right, rather than a row of its own
  grid.append(h("div", { class: "grid-btn" },
    h("button", { class: "btn small danger", type: "button", text: "Reboot server", onclick: rebootServer })));
  if (!hostFolded) host.append(grid);
  el.append(host);
  vpnCard(el, st, avail);

  // Phone alerts are an optional add-on: the card only appears once they're set up, so it never
  // reads as something missing. The Scripts tab lists the add-on for anyone who wants it.
  if (!w.configured) return;
  const wdFolded = isFolded("alerts");
  const chk = parseCheck(w.last_check);
  const failed = /^FAIL/.test(chk.result);
  const wd = h("section", { class: "panel wd" + (wdFolded ? " folded" : "") }, h("div", { class: "card-head" },
    h("h3", {}, foldTitle("alerts", "Phone alerts")),
    wdFolded ? foldSum([[w.running ? "Running" : "Stopped", w.running ? "ok" : "warn"],
      [w.running ? (failed ? "Last check failed" : chk.result === "OK" ? "All passed" : "") : "", failed ? "warn" : "ok"],
      [w.running && chk.at ? `Checked ${ago(chk.at)}` : ""]]) : null,
    h("a", { href: "#alerts", class: "dim card-link", text: "Details" })));
  if (wdFolded) { el.append(wd); return; }
  wd.append(h("div", { class: "stat-grid" },
    stat("Watchdog", w.running ? "Running" : "Stopped", w.running ? "Checks every 2 min" : "No checks running", w.running ? "ok" : "warn"),
    stat("Last check", chk.at ? ago(chk.at) : "None yet", chk.at ? new Date(chk.at * 1000).toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : ""),
    stat("Result", !w.running ? "Stopped" : failed ? "Failed" : chk.result === "OK" ? "All passed" : "—",
      failed ? chk.result.replace(/^FAIL:\s*/, "").slice(0, 70) : "", failed ? "warn" : w.running && chk.result === "OK" ? "ok" : "")));
  loadWdDays();
  const btns = h("div", { class: "card-foot" });
  const id = w.running ? "watchdog.stop" : "watchdog.start";
  for (const [aid, cls] of [[id, ""], ["watchdog.test", ""]]) {
    const a = avail[aid];
    if (a && a.available) btns.append(h("button", { class: `btn small ${cls}`, type: "button", text: a.label, disabled: !!st.busy, onclick: () => runAction(a) }));
  }
  // The buttons share the 14-day strip's row, at its right, rather than a row of their own
  if (wdDays && wdDays.length) {
    wd.append(h("div", { class: "wd-mini" },
      h("div", { class: "wd-mini-main" }, h("div", { class: "vpn-label", text: "Last 14 days" }), days(wdDays),
        h("div", { class: "dim wd-today", text: todayLine(wdDays) })), btns));
  } else wd.append(btns);
  el.append(wd);
}

// The VPN, once it's set up (on or off), like Phone alerts: whether it's connected, where
// traffic leaves and the server, with Turn VPN off/on and Check now. The rest is on its page.
function vpnCard(el, st, avail) {
  const mode = st.vpn;
  if (mode !== "on" && mode !== "off") return;
  loadVpn(mode, false);
  const v = vpnInfo && vpnInfo.mode === mode ? vpnInfo : null;
  const up = mode === "on" && v && v.connected;
  const country = up ? countryName(v.country) : "";
  const where = up ? v.city || country : "";
  const [word, sub, tn] = mode === "off" ? ["Off", "A direct connection", ""]
    : vpnLoading && !v ? ["On", "Checking…", ""]
    : !v ? ["On", "Couldn't check", "warn"]
    : v.connected ? ["Connected", v.checked_at ? `Checked ${ago(v.checked_at)}` : "", "ok"]
    : ["Not connected", (v.error || "").slice(0, 70), "bad"];
  const folded = isFolded("vpn");
  const card = h("section", { class: "panel vpnc" + (folded ? " folded" : "") }, h("div", { class: "card-head" },
    h("h3", {}, foldTitle("vpn", "VPN")),
    folded ? foldSum([[word, tn], [where]]) : null,
    h("a", { href: "#vpn", class: "dim card-link", text: "Details" })));
  el.append(card);
  if (folded) return;
  // Short values, so they fit beside their labels on a phone: the city with the country under it,
  // the server's address with its name under it (that can break at its dots, never mid-word)
  let server = null;
  if (v && (v.endpoint_ip || v.endpoint_host)) {
    server = stat("Server", v.endpoint_ip || v.endpoint_host, "");
    const host = v.endpoint_ip && v.endpoint_host;
    if (host) server.lastChild.append(...host.split(".").flatMap((p, i) => i ? [".", h("wbr"), p] : [p]));
  }
  card.append(h("div", { class: "stat-grid" },
    stat("Tunnel", word, sub, tn),
    up ? stat("Leaves from", where || "Unknown", [where !== country ? country : "", v.exit_ip].filter(Boolean).join(", ")) : null,
    server));
  // What's going through it now and today, quietly at the left; the graph is on the VPN page
  if (mode === "on" && trafficStale()) loadTraffic().then(() => { if (lastSt) side(lastSt); }).catch(() => {});
  const line = mode === "on" ? summaryLine(trafficData()) : [];
  // Turning it on with no config saved asks for one, which only the VPN page does
  const btns = h("div", { class: "card-foot vpnc-foot" }, line.length ? h("a", { class: "vpnc-traffic dim", href: "#vpn",
    title: "The traffic graph is on the VPN page" }, ...line.map((t) => h("span", { text: t }))) : null);
  const a = avail[mode === "on" ? "vpn.off" : "vpn.on"];
  if (a && a.available && !(mode === "off" && v && v.has_config === false)) {
    btns.append(h("button", { class: "btn small", type: "button", text: a.label, disabled: !!st.busy, onclick: () => runAction(a) }));
  }
  if (mode === "on") {
    btns.append(h("button", { class: "btn small", type: "button", text: vpnLoading ? "Checking…" : "Check now", disabled: vpnLoading,
      title: "Ask from inside the VPN where traffic leaves now", onclick: () => loadVpn(mode, true) }));
  }
  card.append(btns);
}
