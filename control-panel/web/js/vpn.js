import { $, h, clear, api, ago } from "./util.js";
import { runAction, ask } from "./actions.js";

// The VPN page. Whether the tunnel is up, where traffic leaves (asked from
// inside the VPN container), which server address the config points at, and
// the buttons, each running setup-vpn-gluetun.sh with all its own checks:
// Turn VPN on / off, Change server (another address for the same config) and
// Update VPN. Changing the config itself stays in the script for now.

let checking = false, last = null, st = null;
const REGION = (() => { try { return new Intl.DisplayNames([], { type: "region" }); } catch (_) { return null; } })();
const countryName = (code) => { try { return (code && REGION && REGION.of(code)) || code; } catch (_) { return code; } };

const actFor = (id) => { const a = st && st.actions.find((x) => x.id === id); return a && a.available ? a : null; };

// The buttons follow the panel's status: which way to switch, and greyed out
// while any action runs.
export function setStatus(status) {
  st = status;
  toggle();
}

function toggle() {
  const b = $("#vpn-toggle");
  const mode = (st && st.vpn) || (last && last.mode);   // the live status first: it follows a switch within seconds
  const id = mode === "on" ? "vpn.off" : mode === "off" ? "vpn.on" : null;
  const act = id && st && st.actions.find((a) => a.id === id);
  for (const x of document.querySelectorAll("#vpn-root .vpn-card-acts .btn")) x.disabled = !!(st && st.busy);
  b.hidden = !(act && act.available);
  if (b.hidden) return;
  b.textContent = act.label;
  b.disabled = !!st.busy;
  b.onclick = () => runAction(act);
}

// Another address for the same config: the script looks the endpoint's name
// up again and times each address from this server, fastest first.
async function changeServer() {
  const act = actFor("vpn.use");
  if (!act || !last) return;
  let chosen = null;
  const list = h("div", { class: "addr-list", role: "radiogroup", "aria-label": "Server addresses" },
    h("p", { class: "dim addr-wait", text: "Looking the addresses up and timing each one from this server…" }));
  const then = last.mode === "on" ? "Switching restarts the stack, so streams pause for up to a minute."
    : "It's used the next time the VPN is turned on.";
  const answer = ask({ title: "Change server", confirmLabel: "Use this server",
    body: `Same config and keys, a different address for ${last.endpoint_host}. ${then}`,
    options: { el: list, read: () => chosen } });
  const ok = document.querySelector("#dialog .btn.primary");
  ok.disabled = true;
  try {
    const r = await api("/api/vpn/addresses");
    clear(list);
    if (!r.addresses.length) list.append(h("p", { class: "vpn-note", text: r.error || "The lookup found no addresses." }));
    let first = null;
    for (const a of r.addresses) {
      const radio = h("input", { type: "radio", name: "vpn-addr", value: a.ip });
      radio.addEventListener("change", () => { chosen = a.ip; ok.disabled = a.in_use; });
      if (!first && !a.in_use) first = radio;
      list.append(h("label", { class: "addr" }, radio,
        h("span", { class: "mono", text: a.ip }),
        h("span", { class: "addr-tags" },
          a.recommended ? h("span", { class: "chip ok", text: "Recommended" }) : null,
          a.in_use ? h("span", { class: "chip", text: "In use now" }) : null),
        h("span", { class: "addr-ms", text: a.ms == null ? "no reply" : `${a.ms} ms` })));
    }
    if (first) { first.checked = true; first.dispatchEvent(new Event("change")); }
  } catch (e) {
    clear(list);
    list.append(h("p", { class: "vpn-note", text: e.message || "Couldn't look the addresses up." }));
  }
  const ip = await answer;
  if (ip) runAction(act, { ip });
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
  const use = actFor("vpn.use"), upd = actFor("vpn.update");
  if (use || upd) {
    card.append(h("div", { class: "vpn-card-acts" },
      use ? h("button", { class: "btn small", type: "button", text: "Change server", disabled: !!(st && st.busy),
        title: "Pick another address for the same server name, timed from this server", onclick: changeServer }) : null,
      upd ? h("button", { class: "btn small", type: "button", text: "Update VPN", disabled: !!(st && st.busy),
        title: "Pull the newest gluetun v3 release", onclick: () => runAction(upd) }) : null));
  }
  box.append(card);
  box.append(h("p", { class: "dim vpn-foot" }, "To use a different config, run ", h("code", { class: "mono", text: "setup-vpn-gluetun.sh" }),
    " and choose Reconfigure VPN."));
}
