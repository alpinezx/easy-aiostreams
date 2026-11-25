import { $, h, clear } from "./util.js";
import { trafficCard, updateNow, setTunnelOff, liveRate, fmtRate, arrowed, netOrder, clearHistory } from "./traffic.js";

// The Network page: the server's traffic, or the VPN tunnel's once the VPN is set up, as the
// same Traffic card the VPN page has; and each service's speed right now.

let st = null, drawn = 0;
let source = "host";
try { source = localStorage.getItem("aios.netSource") === "vpn" ? "vpn" : "host"; } catch (_) {}

const hasVpn = () => !!st && (st.vpn === "on" || st.vpn === "off");
const kind = () => (source === "vpn" && hasVpn() ? "vpn" : "host");

// The page heading: the time range (from traffic.js), then All traffic / VPN tunnel once the VPN
// is set up; the bin (as on Logs) at the Traffic card's top right. On a phone All traffic / VPN
// tunnel sit in the Traffic card under its title instead (a second copy; CSS shows one).
const BIN = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/></svg>';
function bin() {
  const b = h("button", { class: "btn small icon-only tr-bin", type: "button", title: "Clear traffic history",
    "aria-label": "Clear traffic history", onclick: async () => { if (await clearHistory(kind(), hasVpn())) show(st); } });
  b.innerHTML = BIN + '<span class="tr-word">Clear</span>';   // the word shows on a computer
  return b;
}
function sources() {
  return h("div", { class: "tr-ranges", role: "group", "aria-label": "Show" },
    ...[["host", "All traffic"], ["vpn", "VPN"]].map(([k, label]) => h("button", { class: "btn small", type: "button", text: label,
      "aria-pressed": String(kind() === k), onclick: () => {
        source = k;
        try { localStorage.setItem("aios.netSource", k); } catch (_) {}
        if (location.hash !== "#net") history.replaceState(null, "", "#net");   // so #net/vpn doesn't pick the tunnel again
        // The card being looked at stays until the other view's figures are in (the first time after a
        // reload they're fetched), so By service under it doesn't jump up into an empty gap meanwhile
        document.querySelectorAll('.tr-ranges[aria-label="Show"] .btn').forEach((b) => b.setAttribute("aria-pressed", String(b.textContent.trim() === label)));
        const tbox = $("#net-root .net-traffic");
        if (tbox) { drawn = Date.now(); drawTraffic(tbox); } else show(st);
      } })));
}
const drawTraffic = (tbox) => trafficCard(tbox, false, kind(),
  { ranges: $("#net-ranges"), tool: bin(), sub: hasVpn() ? h("div", { class: "tr-src" }, sources()) : null });
function sourceSwitch() {
  const acts = $("#net-acts");
  clear(acts);
  if (hasVpn()) acts.append(sources());
}

// Whether a phone shows By service open (folded until opened)
let nsOpen = false;
try { nsOpen = localStorage.getItem("aios.nsOpen") === "1"; } catch (_) {}

// Each container's speed now, from Docker (read while the panel is open). A stream passes
// through several on its way, so the rows add up to more than the server's total.
function services(box) {
  clear(box);
  const onVpn = st && st.vpn === "on";
  const rows = netOrder((st && st.services || []).filter((s) => s.state === "running"), onVpn);
  if (!rows.length) return;
  const measured = rows.some((s) => s.rx != null);
  // On a phone the title folds the card to one line with the count, like the Overview's cards:
  // folded until opened, remembered per browser. A computer shows it all, with a plain title.
  const card = h("div", { class: "panel vpn-card ns-card" + (nsOpen ? "" : " folded") });
  const chev = h("span", { class: "path-chev", "aria-hidden": "true" });
  chev.innerHTML = '<svg viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>';
  const tog = h("button", { class: "path-toggle fold-toggle", type: "button", "aria-expanded": String(nsOpen), onclick: () => {
    nsOpen = !nsOpen;
    try { localStorage.setItem("aios.nsOpen", nsOpen ? "1" : "0"); } catch (_) {}
    card.classList.toggle("folded", !nsOpen);
    tog.setAttribute("aria-expanded", String(nsOpen));
  } }, "By service", chev);
  card.append(
    h("div", { class: "vpn-head" }, h("h3", { class: "tr-title ns-lbl", text: "By service" }), h("h3", { class: "tr-title ns-tog" }, tog),
      h("span", { class: "vpn-checked ns-now", text: "Right now" }),
      h("span", { class: "vpn-checked ns-count", text: `${rows.length} service${rows.length === 1 ? "" : "s"}` })),
    // Laid out as the Overview's Network list: arrows in one line, each speed right after its arrow
    h("div", { class: "ns-list" },
      ...rows.map((s) => {
        // On the VPN's network, Docker reports gluetun's counters for these too: one count, under the tunnel
        const shared = (s.key === "aiostreams" || s.via_vpn) && onVpn;
        // The VPN's own row is the tunnel, as the graph's Now has it. Docker's figure for the gluetun container adds up
        // every interface in it (the tunnel and the encrypted link out), so it counts the same bytes twice.
        const tunnel = s.key === "gluetun" ? liveRate("vpn") : null;
        const rx = tunnel ? tunnel[0] : s.rx, tx = tunnel ? tunnel[1] : s.tx;
        return h("div", { class: "ns-row" },
          h("span", { class: "ns-name", text: s.name }),
          shared ? h("span", { class: "ns-shared dim", text: "Counted under VPN" })
            : rx == null ? h("span", { class: "ns-shared dim", text: measured ? "" : "Measuring…" })
            : h("span", { class: "ns-speeds" }, arrowed("↓", fmtRate(rx)), arrowed("↑", fmtRate(tx))));
      })));
  box.append(card);
}

export function show(status) {
  if (status) st = status;
  setTunnelOff(st && st.vpn === "off");
  // The Overview's VPN line opens the page at #net/vpn: the VPN tunnel's graph
  if (location.hash === "#net/vpn") {
    source = "vpn";
    try { localStorage.setItem("aios.netSource", "vpn"); } catch (_) {}
  }
  sourceSwitch();
  // Phones: the bin at the end of the heading's Traffic line (a computer has it in the card's corner)
  const pb = $("#net-pbin");
  clear(pb);
  pb.append(bin());
  const root = $("#net-root");
  clear(root);
  const tbox = h("div", { class: "net-traffic" }), sbox = h("div", { class: "net-services" });
  root.append(tbox, sbox);
  drawn = Date.now();
  drawTraffic(tbox);
  services(sbox);
}

// Each status check: the live figures; the graph again when a new minute is in
export function setStatus(status) {
  const hadVpn = hasVpn();
  st = status;
  if (hadVpn !== hasVpn()) { show(st); return; }
  setTunnelOff(st && st.vpn === "off");
  updateNow();
  const sbox = $("#net-root .net-services");
  if (sbox) services(sbox);
  const tbox = $("#net-root .net-traffic");
  if (tbox && Date.now() - drawn > 60000) { drawn = Date.now(); drawTraffic(tbox); }
}
