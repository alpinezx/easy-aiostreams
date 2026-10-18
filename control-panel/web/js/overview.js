import { $, h, clear, setText, fmtDur, fmtBytes, api, toast, ago, extIcon } from "./util.js";
import { runAction, openJob, rebootServer, restartService } from "./actions.js";
import { openReleases, remember, behind } from "./releases.js";
import { days, todayLine, parseCheck } from "./alerts.js";

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

const RESTARTABLE = new Set(["aiostreams", "mediaflow", "webhook"]);
const hist = {};          // cpu history per service, for the sparklines
const keys = {};          // last structure key per region, so we only rebuild on real changes
const SVG = "http://www.w3.org/2000/svg";

const STATE_WORD = {
  running: "Running", starting: "Starting", stopped: "Stopped", missing: "Not created",
  unhealthy: "Unhealthy", restarting: "Restarting", paused: "Stopped manually",
};
const stateOf = (s) => (s.on_purpose && s.state !== "running" ? "paused" : s.state);

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
  for (const s of st.services) {
    if (s.state !== "running") { hist[s.key] = []; continue; }
    (hist[s.key] ||= []).push(s.cpu ?? 0);
    if (hist[s.key].length > 36) hist[s.key].shift();
  }
}

export function render(st, goLogs) {
  window.__channel = st.channel;
  lastSt = st;
  if (st.version && relFor !== relChannel(st)) { relFor = relChannel(st); rel = null; loadReleases(false); }
  remember(rel, runningTag(st));
  hero(st); path(st); rows(st, goLogs); side(st);
}

function certChip(st, long) {
  if (!st.cert.ok) return h("span", { class: "chip warn", text: long ? "Couldn't check HTTPS certificate" : "Couldn't check" });
  const d = st.cert.days_left;
  return h("span", { class: "chip " + (d < 7 ? "bad" : d < 21 ? "warn" : "ok"), title: st.cert.host ? `For ${st.cert.host}. Caddy renews it by itself.` : null,
    text: long ? `HTTPS certificate good for ${d} days` : `${d} days left` });
}

// ---------------- hero ----------------
function hero(st) {
  const avail = Object.fromEntries(st.actions.map((a) => [a.id, a]));
  const aio = st.services.find((s) => s.key === "aiostreams");
  const key = [st.overall, st.headline, st.domain, st.channel, st.version, st.build_tag, st.vpn, !!st.busy, aio && aio.state,
    st.cert && st.cert.ok, st.cert && st.cert.days_left, st.installed, st.docker_ok, relLoading, rel && rel.checked_at, rel && rel.error].join("|");
  rebuild("#hero", key, (el) => {
    el.append(h("div", { class: "hero-head", "aria-live": "polite" },
      h("span", { class: "lamp", dataset: { s: st.overall }, "aria-hidden": "true" }),
      h("h1", { class: "headline", text: st.headline })));
    // Open AIOStreams on a line of its own, then one chip for the build and version, then the update bits.
    if (st.domain) el.append(h("div", { class: "hero-open" }, h("a", { class: "btn small open-site", href: `https://${st.domain}`, target: "_blank", rel: "noopener noreferrer",
      title: `Opens https://${st.domain} in a new tab` }, "Open AIOStreams", extIcon())));
    // The certificate lives in This server; it comes up here only when it needs attention.
    if (st.cert && (!st.cert.ok || st.cert.days_left < 21)) el.append(h("div", { class: "hero-meta" }, certChip(st, true)));
    // The version card has a slot of its own, so wide screens can put the request flow above it
    const ver = $("#ver");
    clear(ver);
    if (st.version) ver.append(versionCard(st, avail));

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

// The build in a card of its own, laid out like AIOStreams' own Version card:
// Running, Latest, and the buttons, with the channel in the corner.
function versionCard(st, avail) {
  const nightly = relChannel(st) === "nightly";
  const running = runningTag(st);
  const [latest, latestSub, btns, fresh] = updateBits(st);
  const col = (label, value, sub) => h("div", {},
    h("div", { class: "ver-label", text: label }), h("div", { class: "ver-value" }, value), h("div", { class: "ver-sub", text: sub || "" }));
  const upd = st.installed && avail["stack.update"];
  // Update sits with Check now, blue only when a newer release is out
  if (upd && upd.available) btns.unshift(h("button", { class: "btn small" + (fresh ? " primary" : ""), type: "button", text: "Update",
    disabled: !!st.busy, title: "Update AIOStreams, or switch between stable and nightly", onclick: () => runAction(upd) }));
  return h("section", { class: "panel ver-card", "aria-label": "AIOStreams version" },
    h("div", { class: "ver-head" },
      h("h2", { text: "AIOStreams" }),
      h("span", { class: "chip" + (nightly ? " warn" : " ok"), text: nightly ? "Nightly" : "Stable",
        title: nightly ? "AIOStreams' nightly builds (Docker tag: nightly). Switch with Update." : "AIOStreams' stable releases (Docker tag: latest). Switch with Update." })),
    h("div", { class: "ver-grid" },
      col("Running", `v${st.version}`, nightly ? (running ? `Nightly ${running.slice(0, -8)}` : "") : releasedAgo(running)),
      col("Latest", latest, latestSub),
      h("div", { class: "ver-btns" }, ...btns)));
}

// ---------------- signal path ----------------
function node(s) {
  const st = stateOf(s);
  return h("div", { class: "node", dataset: { s: st, svc: s.key } },
    h("div", { class: "node-name", text: s.name }),
    h("div", { class: "node-state" }, h("span", { class: "word", text: STATE_WORD[st] || st }),
      " ", h("span", { class: "dim", dataset: { up: s.key }, text: uptime(s) })));
}

function path(st) {
  const main = st.services.filter((s) => !s.addon);
  const addons = st.services.filter((s) => s.addon);
  const restart = st.installed && st.actions.find((a) => a.id === "stack.restart");
  const key = st.services.map((s) => `${s.key}:${stateOf(s)}`).join(",") + st.docker_ok + !!st.busy + !!(restart && restart.available);
  const el = rebuild("#path", key, (el) => {
    el.append(h("div", { class: "path-head" }, h("h2", { class: "path-title", text: "Request flow" })));
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
      restart && restart.available ? h("button", { class: "btn small", type: "button", text: "Restart stack", disabled: !!st.busy,
        title: "Restart Caddy, AIOStreams and anything in between", onclick: () => runAction(restart) }) : null));
  });
  // line the add-on trunk up under the Caddy node
  const caddyNode = el.querySelector('.node[data-svc="caddy"]');
  const ul = el.querySelector(".addons");
  if (caddyNode && ul && window.innerWidth > 720) {
    const r = el.querySelector(".chain").getBoundingClientRect();
    const c = caddyNode.getBoundingClientRect();
    ul.style.setProperty("--trunk", `${Math.round(c.left - r.left + 22)}px`);
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

function rows(st, goLogs) {
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

function side(st) {
  const el = $("#side");
  const w = st.watchdog || {};
  const avail = Object.fromEntries(st.actions.map((a) => [a.id, a]));
  clear(el);   // small and cheap; its only buttons are the watchdog ones, rebuilt rarely enough below
  const hs = st.host || {};
  const host = h("section", { class: "panel host" },
    h("div", { class: "card-head" }, h("h3", { text: "This server" })));
  const grid = h("div", { class: "stat-grid" });
  if (hs.uptime != null) grid.append(stat("Up for", fmtDur(hs.uptime), `since ${dayMonth(Date.now() - hs.uptime * 1000)}`));
  if (st.cert) {
    const d = st.cert.days_left;
    grid.append(st.cert.ok
      ? stat("HTTPS certificate", `${d} day${d === 1 ? "" : "s"} left`, "Caddy renews it by itself", d < 7 ? "bad" : d < 21 ? "warn" : "")
      : stat("HTTPS certificate", "Couldn't check", "", "warn"));
  }
  if (st.vpn === "on" || st.vpn === "off") {
    grid.append(stat("VPN", st.vpn === "on" ? "On" : "Off", st.vpn === "on" ? "Traffic goes through it" : "A direct connection"));
  }
  if (hs.load) {
    const pct = (hs.load[0] / (hs.cpus || 1)) * 100;
    grid.append(stat("Load", hs.load[0].toFixed(2), `on ${hs.cpus} CPU${hs.cpus > 1 ? "s" : ""}`, tone(pct, 75, 90)));
  }
  for (const [label, used, total, warn] of [["Memory", hs.mem_used, hs.mem_total, 80], ["Disk", hs.disk_used, hs.disk_total, 80]]) {
    if (!total) continue;
    const pct = (used / total) * 100;
    grid.append(stat(label, `${fmtBytes(used)} of ${fmtBytes(total)}`, `${Math.round(pct)}% used, ${fmtBytes(total - used)} free`, tone(pct, warn, 90)));
  }
  host.append(grid, h("div", { class: "card-foot" },
    h("button", { class: "btn small danger", type: "button", text: "Reboot server", onclick: rebootServer })));
  el.append(host);

  // Phone alerts are an optional add-on: the card only appears once they're set up, so it never
  // reads as something missing. The Scripts tab lists the add-on for anyone who wants it.
  if (!w.configured) return;
  const wd = h("section", { class: "panel wd" }, h("div", { class: "card-head" }, h("h3", { text: "Phone alerts" }),
    h("a", { href: "#alerts", class: "dim card-link", text: "Details" })));
  const chk = parseCheck(w.last_check);
  const failed = /^FAIL/.test(chk.result);
  wd.append(h("div", { class: "stat-grid" },
    stat("Watchdog", w.running ? "Running" : "Stopped", w.running ? "Checks every 2 min" : "No checks running", w.running ? "" : "warn"),
    stat("Last check", chk.at ? ago(chk.at) : "None yet", chk.at ? new Date(chk.at * 1000).toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : ""),
    stat("Result", !w.running ? "Stopped" : failed ? "Failed" : chk.result === "OK" ? "All passed" : "—",
      failed ? chk.result.replace(/^FAIL:\s*/, "").slice(0, 70) : "", failed ? "warn" : "")));
  loadWdDays();
  if (wdDays && wdDays.length) {
    wd.append(h("div", { class: "wd-mini" },
      h("div", { class: "vpn-label", text: "Last 14 days" }), days(wdDays),
      h("div", { class: "dim wd-today", text: todayLine(wdDays) })));
  }
  const btns = h("div", { class: "card-foot" });
  const id = w.running ? "watchdog.stop" : "watchdog.start";
  for (const [aid, cls] of [[id, ""], ["watchdog.test", ""]]) {
    const a = avail[aid];
    if (a && a.available) btns.append(h("button", { class: `btn small ${cls}`, type: "button", text: a.label, disabled: !!st.busy, onclick: () => runAction(a) }));
  }
  wd.append(btns);
  el.append(wd);
}
