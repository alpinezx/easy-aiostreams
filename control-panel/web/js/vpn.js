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

// The address list in Change server and Change config: fastest first, the
// fastest one not in use picked to start with. pick(a) runs on each choice.
function fillAddresses(list, r, pick) {
  clear(list);
  if (!r.addresses.length) list.append(h("p", { class: "vpn-note", text: r.error || "The lookup found no addresses." }));
  let first = null;
  for (const a of r.addresses) {
    const radio = h("input", { type: "radio", name: "vpn-addr", value: a.ip });
    radio.addEventListener("change", () => pick(a));
    if (!first && !a.in_use) first = radio;
    list.append(h("label", { class: "addr" }, radio,
      h("span", { class: "mono", text: a.ip }),
      h("span", { class: "addr-tags" },
        a.recommended ? h("span", { class: "chip ok", text: "Recommended" }) : null,
        a.in_use ? h("span", { class: "chip", text: "In use now" }) : null),
      h("span", { class: "addr-ms", text: a.ms == null ? "no reply" : `${a.ms} ms` })));
  }
  if (first) { first.checked = true; first.dispatchEvent(new Event("change")); }
}

// A quick look in the browser, so a half-copied config is caught while
// pasting; the server checks it again properly before anything is saved.
function looksLikeWireGuard(t) {
  return ["[Interface]", "[Peer]"].every((x) => t.includes(x))
    && ["PrivateKey", "Address", "PublicKey", "Endpoint"].every((k) => new RegExp(`^\\s*${k}\\s*=\\s*\\S`, "mi").test(t));
}

// A new WireGuard config, pasted or from a file. The server checks it and
// keeps it where only root can read it; the key never comes back to the
// page. With a name as its endpoint, the addresses are listed as in Change
// server. The config in use now is kept, for Put the old config back.
async function changeConfig() {
  const act = actFor("vpn.config");
  if (!act || !last) return;
  let checked = null, chosen = null, timer = null;
  const area = h("textarea", { class: "input mono conf-paste", rows: "8", spellcheck: "false", autocomplete: "off",
    "aria-label": "WireGuard config", placeholder: "[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\nPublicKey = ...\nEndpoint = ..." });
  const file = h("input", { type: "file", accept: ".conf,text/plain", hidden: true });
  const note = h("span", { class: "conf-note dim", text: "Your current config is kept, so you can go back to it." });
  const pasteBox = h("div", { class: "conf-box" }, area,
    h("div", { class: "conf-row" }, h("button", { class: "btn small", type: "button", text: "Choose file", onclick: () => file.click() }), file, note));
  const summary = h("div", { class: "conf-sum", hidden: true });
  const list = h("div", { class: "addr-list", role: "radiogroup", "aria-label": "Server addresses", hidden: true });
  const then = last.mode === "on" ? "The stack restarts with it, so streams pause for up to a minute."
    : "It's used the next time the VPN is turned on.";
  const answer = ask({ title: "Change config", confirmLabel: "Use this config",
    body: `Paste your VPN provider's WireGuard config, or choose its .conf file. ${then}`,
    options: { el: h("div", { class: "conf-wrap" }, pasteBox, summary, list), read: () => ({ ip: chosen }) } });
  const ok = document.querySelector("#dialog .btn.primary");
  ok.disabled = true;

  const check = async () => {
    const text = area.value;
    if (!looksLikeWireGuard(text)) {
      note.textContent = text.trim() ? "That doesn't look like a whole WireGuard config yet." : "Your current config is kept, so you can go back to it.";
      note.className = "conf-note " + (text.trim() ? "warn-text" : "dim");
      return;
    }
    note.textContent = "Checking it…"; note.className = "conf-note dim";
    try {
      checked = await api("/api/vpn/config", { method: "POST", body: JSON.stringify({ conf: text }) });
    } catch (e) {
      note.textContent = e.message; note.className = "conf-note warn-text";
      return;
    }
    area.value = "";                 // the key leaves the page once the server has it
    pasteBox.hidden = true;
    clear(summary);
    summary.append(
      h("div", { class: "vpn-grid conf-grid" },
        cell("Endpoint", `${checked.endpoint_host || checked.endpoint_ip}:${checked.endpoint_port}`, true),
        cell("Address", checked.address, true),
        cell("Private key", "Saved, not shown")),
      h("button", { class: "btn small quiet conf-again", type: "button", text: "Use a different one",
        onclick: () => { summary.hidden = true; list.hidden = true; pasteBox.hidden = false; ok.disabled = true; chosen = null; area.focus(); } }));
    summary.hidden = false;
    if (checked.endpoint_ip) { chosen = checked.endpoint_ip; ok.disabled = false; return; }
    list.hidden = false;
    clear(list);
    list.append(h("p", { class: "dim addr-wait", text: `Looking up ${checked.endpoint_host} and timing each address from this server…` }));
    try {
      fillAddresses(list, await api("/api/vpn/config/addresses"), (a) => { chosen = a.ip; ok.disabled = false; });
    } catch (e) {
      clear(list);
      list.append(h("p", { class: "vpn-note", text: e.message || "Couldn't look the addresses up." }));
    }
  };
  area.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(check, 400); });
  file.addEventListener("change", async () => {
    const f = file.files[0];
    file.value = "";
    if (!f) return;
    if (f.size > 8192) { note.textContent = "That file is too big to be a WireGuard config."; note.className = "conf-note warn-text"; return; }
    area.value = await f.text();
    check();
  });
  const res = await answer;
  if (res && res.ip) runAction(act, res);
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
    fillAddresses(list, r, (a) => { chosen = a.ip; ok.disabled = a.in_use; });
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
  const use = actFor("vpn.use"), upd = actFor("vpn.update"), conf = actFor("vpn.config"), back = actFor("vpn.revert");
  if (v.previous && back) {
    card.append(h("div", { class: "vpn-prev" },
      h("span", { class: "dim", text: `Config changed ${ago(v.previous.changed_at)}${v.previous.endpoint_host ? `, from ${v.previous.endpoint_host}` : ""}.` }),
      h("button", { class: "btn small", type: "button", text: "Put the old config back", disabled: !!(st && st.busy), onclick: () => runAction(back) })));
  }
  if (use || upd || conf) {
    card.append(h("div", { class: "vpn-card-acts" },
      use ? h("button", { class: "btn small", type: "button", text: "Change server", disabled: !!(st && st.busy),
        title: "Pick another address for the same server name, timed from this server", onclick: changeServer }) : null,
      conf ? h("button", { class: "btn small", type: "button", text: "Change config", disabled: !!(st && st.busy),
        title: "Use a different WireGuard config, pasted or from a file", onclick: changeConfig }) : null,
      upd ? h("button", { class: "btn small", type: "button", text: "Update VPN", disabled: !!(st && st.busy),
        title: "Pull the newest gluetun v3 release", onclick: () => runAction(upd) }) : null));
  }
  box.append(card);
}
