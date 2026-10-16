import { $, h, clear, api, ago } from "./util.js";
import { runAction } from "./actions.js";

// The VPN page. Whether the tunnel is up, where traffic leaves (asked from
// inside the VPN container), which server address the config points at, and
// Turn VPN on / off, which runs setup-vpn-gluetun.sh with all its own checks.
// Changing the config stays in the script for now.

let checking = false, last = null, st = null;
const REGION = (() => { try { return new Intl.DisplayNames([], { type: "region" }); } catch (_) { return null; } })();
const countryName = (code) => { try { return (code && REGION && REGION.of(code)) || code; } catch (_) { return code; } };

// The on/off button follows the panel's status: which way to switch, and
// greyed out while any action runs.
export function setStatus(status) {
  st = status;
  toggle();
}

function toggle() {
  const b = $("#vpn-toggle");
  const mode = (st && st.vpn) || (last && last.mode);   // the live status first: it follows a switch within seconds
  const id = mode === "on" ? "vpn.off" : mode === "off" ? "vpn.on" : null;
  const act = id && st && st.actions.find((a) => a.id === id);
  b.hidden = !(act && act.available);
  if (b.hidden) return;
  b.textContent = act.label;
  b.className = "btn small" + (id === "vpn.on" ? " primary" : "");
  b.disabled = !!st.busy;
  b.onclick = () => runAction(act);
}

export async function show(fresh = false, status) {
  if (status) st = status;
  const box = $("#vpn-root"), btn = $("#vpn-check");
  if (checking) return;
  checking = true;
  btn.disabled = true;
  if (!box.firstChild) box.append(h("p", { class: "empty", text: "Checking the VPN…" }));
  try {
    render(await api(`/api/vpn${fresh ? "?fresh=1" : ""}`));
  } catch (e) {
    clear(box);
    box.append(h("p", { class: "empty", text: e.message || "Couldn't check the VPN." }));
  } finally {
    checking = false;
  }
}

// One labelled value in the card's grid; nothing when there's no value
function cell(label, value, mono) {
  if (!value) return null;
  return h("div", { class: "vpn-cell" }, h("div", { class: "vpn-label", text: label }),
    h("div", { class: "vpn-value" + (mono ? " mono" : ""), text: value }));
}

function render(v) {
  const box = $("#vpn-root"), btn = $("#vpn-check");
  last = v;
  toggle();
  clear(box);
  btn.disabled = v.mode !== "on";
  const [lamp, word] = v.mode !== "on" ? ["", "Off, using a direct connection"]
    : v.connected ? ["ok", "Connected"] : ["down", "Not connected"];
  const card = h("div", { class: "panel vpn-card" },
    h("div", { class: "vpn-head" },
      h("div", { class: "vpn-state" }, h("span", { class: "lamp", dataset: { s: lamp }, "aria-hidden": "true" }), h("span", { text: word })),
      v.checked_at ? h("span", { class: "vpn-checked", text: `Checked ${ago(v.checked_at)}` }) : null));
  const up = v.mode === "on" && v.connected;
  const where = h("div", { class: "vpn-grid" },
    up ? cell("Exit IP", v.exit_ip, true) : null,
    up ? cell("Location", [v.city, countryName(v.country)].filter(Boolean).join(", ")) : null,
    up ? cell("Network", v.org) : null);
  const server = h("div", { class: "vpn-grid" },
    cell("Endpoint", v.endpoint_host, true),
    cell("Server address", v.endpoint_ip ? `${v.endpoint_ip}${v.endpoint_port ? ":" + v.endpoint_port : ""}` : "", true));
  for (const g of [where, server]) if (g.childElementCount) card.append(g);
  if (v.mode === "on" && !v.connected && v.error) card.append(h("p", { class: "vpn-note", text: v.error }));
  if (v.mode === "off") {
    card.append(h("p", { class: "vpn-note dim", text: "AIOStreams is using a direct connection, so its traffic leaves from this server's own IP. Turn VPN on switches it back." }));
  }
  box.append(card);
  box.append(h("p", { class: "dim vpn-foot" }, "To switch server or config, run ", h("code", { class: "mono", text: "setup-vpn-gluetun.sh" }),
    " and choose Reconfigure VPN."));
}
