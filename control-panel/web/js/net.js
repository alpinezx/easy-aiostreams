import { $, h, clear } from "./util.js";
import { trafficCard, updateNow, fmtRate, arrowed, netOrder } from "./traffic.js";

// The Network page: the server's traffic, or the VPN tunnel's once the VPN is set up, as the
// same Traffic card the VPN page has; and each service's speed right now.

let st = null, drawn = 0;
let source = "host";
try { source = localStorage.getItem("aios.netSource") === "vpn" ? "vpn" : "host"; } catch (_) {}

const hasVpn = () => !!st && (st.vpn === "on" || st.vpn === "off");
const kind = () => (source === "vpn" && hasVpn() ? "vpn" : "host");

// All traffic / VPN tunnel, in the page heading; only once the VPN is set up
function sourceSwitch() {
  const acts = $("#net-acts");
  clear(acts);
  if (!hasVpn()) return;
  acts.append(h("div", { class: "tr-ranges", role: "group", "aria-label": "Show" },
    ...[["host", "All traffic"], ["vpn", "VPN tunnel"]].map(([k, label]) => h("button", { class: "btn small", type: "button", text: label,
      "aria-pressed": String(kind() === k), onclick: () => {
        source = k;
        try { localStorage.setItem("aios.netSource", k); } catch (_) {}
        if (location.hash !== "#net") history.replaceState(null, "", "#net");   // so #net/vpn doesn't pick the tunnel again
        show(st);
      } }))));
}

// Each container's speed now, from Docker (read while the panel is open). A stream passes
// through several on its way, so the rows add up to more than the server's total.
function services(box) {
  clear(box);
  const onVpn = st && st.vpn === "on";
  const rows = netOrder((st && st.services || []).filter((s) => s.state === "running"), onVpn);
  if (!rows.length) return;
  const measured = rows.some((s) => s.rx != null);
  box.append(h("div", { class: "panel vpn-card ns-card" },
    h("div", { class: "vpn-head" }, h("h3", { class: "tr-title", text: "By service" }), h("span", { class: "vpn-checked", text: "Right now" })),
    // Laid out as the Overview's Network list: arrows in one line, each speed right after its arrow
    h("div", { class: "ns-list" },
      ...rows.map((s) => {
        // On the VPN's network, Docker reports gluetun's counters for these too: one count, under the tunnel
        const shared = (s.key === "aiostreams" || s.via_vpn) && onVpn;
        return h("div", { class: "ns-row" },
          h("span", { class: "ns-name", text: s.name }),
          shared ? h("span", { class: "ns-shared dim", text: "Counted under VPN tunnel" })
            : s.rx == null ? h("span", { class: "ns-shared dim", text: measured ? "" : "Measuring…" })
            : [arrowed("↓", fmtRate(s.rx)), arrowed("↑", fmtRate(s.tx))]);
      })),
    h("p", { class: "vpn-note dim ns-note", text: "Includes traffic between containers. A stream passes through "
      + (onVpn ? "the VPN tunnel" : "AIOStreams") + ", then Caddy, so it's counted on both. That's why these add up to more than All traffic." })));
}

export function show(status) {
  if (status) st = status;
  // The Overview's VPN line opens the page at #net/vpn: the VPN tunnel's graph
  if (location.hash === "#net/vpn") {
    source = "vpn";
    try { localStorage.setItem("aios.netSource", "vpn"); } catch (_) {}
  }
  sourceSwitch();
  const root = $("#net-root");
  clear(root);
  const tbox = h("div", { class: "net-traffic" }), sbox = h("div", { class: "net-services" });
  root.append(tbox, sbox);
  drawn = Date.now();
  trafficCard(tbox, false, kind());
  services(sbox);
}

// Each status check: the live figures; the graph again when a new minute is in
export function setStatus(status) {
  const hadVpn = hasVpn();
  st = status;
  if (hadVpn !== hasVpn()) { show(st); return; }
  updateNow();
  const sbox = $("#net-root .net-services");
  if (sbox) services(sbox);
  const tbox = $("#net-root .net-traffic");
  if (tbox && Date.now() - drawn > 60000) { drawn = Date.now(); trafficCard(tbox, false, kind()); }
}
