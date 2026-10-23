import { $, h, clear } from "./util.js";
import { trafficCard, updateNow, fmtRate } from "./traffic.js";

// The Network page: the server's traffic, or the VPN tunnel's once the VPN is set up, as the
// same Traffic card the VPN page has; and each service's speed right now.

let st = null, drawn = 0;
let source = "host";
try { source = localStorage.getItem("aios.netSource") === "vpn" ? "vpn" : "host"; } catch (_) {}

const hasVpn = () => !!st && (st.vpn === "on" || st.vpn === "off");
const kind = () => (source === "vpn" && hasVpn() ? "vpn" : "host");

// Whole server / VPN tunnel, in the page heading; only once the VPN is set up
function sourceSwitch() {
  const acts = $("#net-acts");
  clear(acts);
  if (!hasVpn()) return;
  acts.append(h("div", { class: "tr-ranges", role: "group", "aria-label": "Show" },
    ...[["host", "Whole server"], ["vpn", "VPN tunnel"]].map(([k, label]) => h("button", { class: "btn small", type: "button", text: label,
      "aria-pressed": String(kind() === k), onclick: () => {
        source = k;
        try { localStorage.setItem("aios.netSource", k); } catch (_) {}
        show(st);
      } }))));
}

// Each container's speed now, from Docker (read while the panel is open). A stream passes
// through several on its way, so the rows add up to more than the server's total.
function services(box) {
  clear(box);
  const rows = (st && st.services || []).filter((s) => s.state === "running");
  if (!rows.length) return;
  const onVpn = st.vpn === "on";
  const measured = rows.some((s) => s.rx != null);
  box.append(h("div", { class: "panel vpn-card ns-card" },
    h("div", { class: "vpn-head" }, h("h3", { class: "tr-title", text: "By service" }), h("span", { class: "vpn-checked", text: "Right now" })),
    h("div", { class: "ns-list" },
      h("div", { class: "ns-row ns-head" }, h("span", { text: "Service" }), h("span", { class: "num", text: "Down" }), h("span", { class: "num", text: "Up" })),
      ...rows.map((s) => {
        // On the VPN's network, Docker reports gluetun's counters for AIOStreams too: one count, under the tunnel
        const shared = s.key === "aiostreams" && onVpn;
        return h("div", { class: "ns-row" },
          h("span", { class: "ns-name", text: s.name }),
          shared ? h("span", { class: "ns-shared dim", text: "Counted under VPN tunnel" })
            : [h("span", { class: "num", text: s.rx != null ? fmtRate(s.rx) : measured ? "" : "Measuring…" }),
              h("span", { class: "num", text: s.tx != null ? fmtRate(s.tx) : "" })]);
      })),
    h("p", { class: "vpn-note dim ns-note", text: "Each container's traffic, including what passes between them: a stream comes in"
      + (onVpn ? " through the VPN tunnel" : " to AIOStreams") + ", goes over to Caddy and out to the viewer, so it shows on both, and these add up to more than the whole server's." })));
}

export function show(status) {
  if (status) st = status;
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
