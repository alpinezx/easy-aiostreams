import { $, h, clear, api, ago } from "./util.js";

// The VPN page: read-only for now. Whether the tunnel is up, where traffic
// leaves (asked from inside the VPN container), and which server address the
// config points at. Changing the config stays in setup-vpn-gluetun.sh.

let checking = false;
const REGION = (() => { try { return new Intl.DisplayNames([], { type: "region" }); } catch (_) { return null; } })();
const countryName = (code) => { try { return (code && REGION && REGION.of(code)) || code; } catch (_) { return code; } };

export async function show(fresh = false) {
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

function render(v) {
  const box = $("#vpn-root"), btn = $("#vpn-check");
  clear(box);
  btn.disabled = v.mode !== "on";
  const [lamp, word] = v.mode !== "on" ? ["", "Off, using a direct connection"]
    : v.connected ? ["ok", "Connected"] : ["down", "Not connected"];
  const card = h("div", { class: "panel vpn-card" },
    h("div", { class: "vpn-state" }, h("span", { class: "lamp", dataset: { s: lamp }, "aria-hidden": "true" }), h("span", { text: word })));
  const kv = h("dl", { class: "kv" });
  const row = (k, val, mono) => { if (val) kv.append(h("dt", { text: k }), h("dd", { class: mono ? "mono" : null, text: val })); };
  if (v.mode === "on" && v.connected) {
    row("Exit IP", v.exit_ip, true);
    row("Location", [v.city, countryName(v.country)].filter(Boolean).join(", "));
    row("Network", v.org);
  }
  row("Endpoint", v.endpoint_host, true);
  row("Server address", v.endpoint_ip ? `${v.endpoint_ip}${v.endpoint_port ? ":" + v.endpoint_port : ""}` : "", true);
  if (v.checked_at) row("Checked", ago(v.checked_at));
  if (kv.childElementCount) card.append(kv);
  if (v.mode === "on" && !v.connected && v.error) card.append(h("p", { class: "vpn-note", text: v.error }));
  if (v.mode === "off") {
    card.append(h("p", { class: "vpn-note dim" }, "AIOStreams is using a direct connection. To turn the VPN back on, run ",
      h("code", { class: "mono", text: "setup-vpn-gluetun.sh" }), " and choose Turn VPN ON (it's on the ", h("a", { href: "#scripts", text: "Scripts" }), " page)."));
  }
  box.append(card);
  box.append(h("p", { class: "dim vpn-foot" }, "To switch server or config, run ", h("code", { class: "mono", text: "setup-vpn-gluetun.sh" }),
    " and choose Reconfigure VPN."));
}
