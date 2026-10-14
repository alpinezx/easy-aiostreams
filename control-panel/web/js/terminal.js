// Web terminal view. The Terminal tab only exists when setup-ui.sh switched it
// on. A second key (not the login) unlocks it; the key is exchanged for a
// one-time ticket, and the ticket opens the WebSocket.
import { $, h, api, clear, toast } from "./util.js";
import { ask } from "./actions.js";

let term = null, fit = null, sock = null, ro = null;
let built = false;

const root = () => $("#term-root");

export async function restartPanel() {
  try {
    await api("/api/panel/restart", { method: "POST" });
  } catch (e) { toast(e.message || "Couldn't restart the panel.", true); return; }
  toast("Restarting the panel. This page will reload in a few seconds.");
  // wait until the new process answers, then reload
  setTimeout(async function poll(n = 0) {
    try { await fetch("/api/me", { credentials: "same-origin" }); location.reload(); }
    catch (_) { if (n < 30) setTimeout(() => poll(n + 1), 1500); }
  }, 4000);
}

let remembered = false;
let lastStatus = null;
let pendingCmd = null;      // from Run in terminal: typed into the shell once it's open, never sent

// Which user the shell runs as: the login user with a ~/aiostreams shortcut (like SSHing in
// as them), or root. Remembered on this device.
function userCopy(st = lastStatus) { return (st && st.user_copy) || null; }
export function shellAs(st = lastStatus) {
  const uc = userCopy(st);
  let v = null;
  try { v = localStorage.getItem("aios.termAs"); } catch (_) {}
  if (!uc) return "root";
  return v === "root" || v === uc.user ? v : uc.user;
}
function setShellAs(v) { try { localStorage.setItem("aios.termAs", v); } catch (_) {} }
function sudoNote(uc) {
  if (!uc) return "";
  if (uc.sudo === "nopass") return `${uc.user} can use sudo without a password, so scripts run as they would over SSH.`;
  if (uc.sudo === "password") return `sudo will ask for ${uc.user}'s password the first time. To skip that, you can give ${uc.user} passwordless sudo (look up "passwordless sudo" for your Linux version, or ask an AI assistant to walk you through it).`;
  return `${uc.user} can't use sudo on this server, so the scripts won't run as ${uc.user}. Choose root instead.`;
}

// Use this browser's "stay unlocked" if it has one, otherwise ask for the key.
async function start(message) {
  try {
    const r = await api("/api/terminal/ticket", { method: "POST", body: "{}" });
    remembered = true;
    open(r.ticket, r.idle_minutes);
  } catch (_) { remembered = false; gate(message); }
}

async function switchUser() {
  const uc = userCopy();
  if (!uc) return;
  const to = shellAs() === "root" ? uc.user : "root";
  const ok = await ask({ title: `Switch to ${to}?`, confirmLabel: "Switch",
    body: `This ends the current shell, and anything still running in it, then opens a new one as ${to}.` });
  if (!ok) return;
  setShellAs(to);
  closeSocket();
  start();
}

// Types a command into the shell for the person to check and send with Enter. If the shell
// isn't open yet (or the terminal is locked), it waits and is typed once the shell opens.
export function runInTerminal(cmd) {
  pendingCmd = cmd;
  if (location.hash !== "#terminal") location.hash = "#terminal";
  typePending();
}

function typePending() {
  if (!pendingCmd || !sock || sock.readyState !== 1) return;
  sock.send(JSON.stringify({ i: pendingCmd }));
  pendingCmd = null;
  toast("Typed into the terminal. Check it, then press Enter to run it.");
  if (term) term.focus();
}

async function lockNow(shellGone) {
  try { await api("/api/terminal/lock", { method: "POST", body: "{}" }); } catch (_) {}
  remembered = false;
  gate(shellGone === true ? "Locked. The key is needed to open the terminal again."
    : "Locked. The shell keeps running on the server; the key is needed to get back to it.", true);
}

function gate(message, info) {
  closeSocket();
  clear(root());
  const err = h("p", { class: "form-err" + (info ? " note-ok" : ""), role: "alert", text: message || "" });
  const input = h("input", { class: "input", type: "password", autocomplete: "off", spellcheck: "false",
    placeholder: "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", "aria-label": "Terminal key" });
  const go = h("button", { class: "btn primary", type: "submit", text: "Open terminal" });
  const keep = h("input", { type: "checkbox", checked: true });
  const uc = userCopy();
  let asSel = null, asNote = null;
  if (uc) {
    asSel = h("select", { class: "input", "aria-label": "Open the shell as" },
      h("option", { value: uc.user, text: `${uc.user} (recommended)` }),
      h("option", { value: "root", text: "root" }));
    asSel.value = shellAs();
    asNote = h("p", { class: "dim term-as-note" });
    const sync = () => { asNote.textContent = asSel.value === "root"
      ? `Not recommended while ${uc.user} is available. A backup you make here as root is only saved in /root, with no copy in ${uc.user}'s home to scp. The panel's own buttons and the Scripts tab's commands still act as ${uc.user}.`
      : sudoNote(uc); };
    asSel.addEventListener("change", () => { setShellAs(asSel.value); sync(); });
    sync();
  }
  const form = h("form", { class: "term-gate", onsubmit: async (e) => {
    e.preventDefault();
    go.disabled = true; err.textContent = "";
    try {
      const r = await api("/api/terminal/unlock", { method: "POST", body: JSON.stringify({ key: input.value, remember: keep.checked }) });
      input.value = "";
      remembered = keep.checked;
      open(r.ticket, r.idle_minutes);
    } catch (e2) { err.classList.remove("note-ok"); err.textContent = e2.message || "Couldn't unlock."; go.disabled = false; input.select(); }
  } },
    h("h3", { text: "Terminal key" }),
    h("p", { class: "dim", text: "This is a separate key from your login. It was printed once when the terminal was switched on with setup-ui.sh." }),
    input,
    uc ? h("label", { class: "field" }, h("span", { text: "Open the shell as" }), asSel) : null,
    asNote,
    h("label", { class: "check term-keep" }, keep, h("span", { text: "Stay unlocked while I'm signed in on this device" })),
    go, err);
  root().append(form);
  input.focus();
}

// Touch scrolling. xterm.js 6 fakes scrolling in code (its own scrollbar, no
// real scroll area), which feels sticky on phones. On touch screens a clear,
// real scroll area sits over the terminal instead, so Android's own drag,
// fling and overscroll apply, and its position drives the terminal's.
// A tap on it focuses the terminal, so the keyboard still comes up.
const TOUCH = window.matchMedia("(pointer: coarse)").matches;

function nativeScroll(box) {
  if (!TOUCH || !term) return;
  box.classList.add("touch");
  const layer = h("div", { class: "touch-scroll", "aria-hidden": "true" });
  const spacer = h("div", { class: "touch-spacer" });
  layer.append(spacer);
  box.append(layer);
  const t = term;
  const lineH = () => {
    const r = box.querySelector(".xterm-rows > div");
    return (r && r.getBoundingClientRect().height) || 17;
  };
  let mine = false;           // a terminal scroll this layer caused
  let touching = false, lastUser = 0;
  const size = () => {
    const b = t.buffer.active;
    spacer.style.height = Math.round(layer.clientHeight + b.baseY * lineH()) + "px";
  };
  const follow = () => {      // put the layer where the terminal is
    size();
    const want = Math.round(t.buffer.active.viewportY * lineH());
    if (Math.abs(layer.scrollTop - want) > 1) { mine = true; layer.scrollTop = want; }
  };
  layer.addEventListener("scroll", () => {
    if (mine) { mine = false; return; }
    lastUser = performance.now();
    const line = Math.round(layer.scrollTop / lineH());
    if (line !== t.buffer.active.viewportY) t.scrollToLine(line);
  }, { passive: true });
  // Long-press opens a small menu (Paste, Select text). Any movement cancels it,
  // so scrolling never triggers it.
  let pressTimer = 0, px = 0, py = 0, pressed = false;
  const cancelPress = () => { clearTimeout(pressTimer); pressTimer = 0; };
  layer.addEventListener("touchstart", (e) => {
    touching = true; pressed = false; cancelPress();
    if (e.touches.length !== 1) return;
    px = e.touches[0].clientX; py = e.touches[0].clientY;
    pressTimer = setTimeout(() => {
      pressTimer = 0; pressed = true;
      if (navigator.vibrate) { try { navigator.vibrate(12); } catch (_) {} }
      pressMenu(box, px, py);
    }, 480);
  }, { passive: true });
  layer.addEventListener("touchmove", (e) => {
    const p = e.touches[0];
    if (p && Math.hypot(p.clientX - px, p.clientY - py) > 10) cancelPress();
  }, { passive: true });
  const up = () => { touching = false; cancelPress(); };
  layer.addEventListener("touchend", up, { passive: true });
  layer.addEventListener("touchcancel", up, { passive: true });
  layer.addEventListener("contextmenu", (e) => e.preventDefault());
  // a tap (not a scroll, not a long-press) focuses the terminal so the keyboard opens
  layer.addEventListener("click", () => { if (pressed) { pressed = false; return; } t.focus(); });
  // New output or a resize: keep the layer in step, but never fight a swipe or a fling.
  const busy = () => touching || performance.now() - lastUser < 600;
  t.onWriteParsed(() => { size(); if (!busy()) follow(); });
  t.onResize(() => setTimeout(follow, 0));
  t.onScroll(() => { if (!busy()) follow(); });
  new ResizeObserver(() => follow()).observe(layer);
  follow();
}

// ---- long-press menu, paste, and a selectable copy of the text ----------
function closeMenu() { const m = $("#term-menu"); if (m) m.remove(); }

function pressMenu(box, x, y) {
  closeMenu();
  const item = (label, fn) => h("button", { class: "btn small", type: "button", text: label,
    onclick: (e) => { e.stopPropagation(); closeMenu(); fn(); } });
  const menu = h("div", { class: "term-menu", id: "term-menu", role: "menu" },
    item("Paste", pasteClipboard), item("Select text", () => selectView(box)));
  document.body.append(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.max(8, Math.min(window.innerWidth - r.width - 8, x - r.width / 2)) + "px";
  menu.style.top = Math.max(8, y - r.height - 14) + "px";
  setTimeout(() => document.addEventListener("pointerdown", function off(e) {
    if (!menu.contains(e.target)) { closeMenu(); document.removeEventListener("pointerdown", off, true); }
  }, true), 0);
}

async function pasteClipboard() {
  if (!term) return;
  let text = "";
  try { text = await navigator.clipboard.readText(); }
  catch (_) { toast("Chrome didn't allow reading the clipboard. Tap the terminal, then use your keyboard's clipboard button.", true); return; }
  if (!text) { toast("The clipboard is empty."); return; }
  term.paste(text);
  term.focus();
}

// The terminal's text (recent history plus the screen) as ordinary page text,
// so the phone's own selection handles and Copy work on it.
function termText(maxLines = 3000) {
  const b = term.buffer.active, out = [];
  const first = Math.max(0, b.length - maxLines);
  let viewAt = 0;
  for (let i = first; i < b.length; i++) {
    const line = b.getLine(i);
    if (!line) continue;
    if (i === b.viewportY) viewAt = out.length;
    const str = line.translateToString(true);
    if (line.isWrapped && out.length) out[out.length - 1] += str;   // the terminal wrapped it; join it back
    else out.push(str);
  }
  while (out.length && !out[out.length - 1].trim()) out.pop();
  return { text: out.join("\n"), viewAt, lines: out.length };
}

function selectView(box) {
  if (!term) return;
  const old = box.querySelector(".term-select-wrap");
  if (old) old.remove();
  if (document.activeElement && document.activeElement.blur) document.activeElement.blur();   // put the keyboard away
  const { text, viewAt, lines } = termText();
  const pre = h("pre", { class: "term-select", text });
  const done = () => wrap.remove();
  const wrap = h("div", { class: "term-select-wrap" },
    h("div", { class: "term-select-bar" },
      h("span", { class: "dim", text: "Long-press to select" }),
      h("button", { class: "btn small", type: "button", text: "Copy all", onclick: async () => {
        try { await navigator.clipboard.writeText(text); toast("Copied everything shown."); }
        catch (_) { toast("Couldn't copy. Select the text and use Copy instead.", true); }
      } }),
      h("button", { class: "btn small primary", type: "button", text: "Done", onclick: done })),
    pre);
  box.append(wrap);
  // start where the terminal was looking
  const lh = pre.scrollHeight / Math.max(1, lines);
  pre.scrollTop = Math.max(0, viewAt * lh);
}

// On phones, make the terminal exactly fill the rest of the screen, so the page
// itself has nothing to scroll and swipes only move the terminal.
function fitBox() {
  const box = $("#xterm-box");
  if (!box) return;
  if (box.classList.contains("kb")) return;          // keyboard mode sizes it instead
  if (window.innerWidth > 720) { box.style.height = ""; return; }
  const top = box.getBoundingClientRect().top + window.scrollY;
  box.style.height = Math.max(260, Math.floor(window.innerHeight - top - 14)) + "px";
}
// With the on-screen keyboard up, Android only shrinks the visible area and
// scrolls the page to keep the hidden input in view, so page and terminal
// fight over scrolling. While it's up, the terminal fills exactly the space
// above the keyboard instead, with the prompt at the bottom.
function kbFit() {
  const box = $("#xterm-box"), vv = window.visualViewport;
  if (!box || !vv) return;
  const open = window.innerWidth <= 720 && window.innerHeight - vv.height > 120 && !root().closest("[hidden]");
  if (open) {
    const was = box.classList.contains("kb");
    box.classList.add("kb");
    document.documentElement.classList.add("kb-open");
    box.style.top = Math.round(vv.offsetTop) + "px";
    box.style.height = Math.floor(vv.height) + "px";
    if (!was && term) setTimeout(() => { try { fit.fit(); term.scrollToBottom(); } catch (_) {} }, 50);
  } else if (box.classList.contains("kb")) {
    box.classList.remove("kb");
    document.documentElement.classList.remove("kb-open");
    box.style.top = "";
    fitBox();
    if (term) setTimeout(() => { try { fit.fit(); term.scrollToBottom(); } catch (_) {} }, 50);
  }
}
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", kbFit);
  window.visualViewport.addEventListener("scroll", kbFit);
}
window.addEventListener("resize", () => { fitBox(); });
window.addEventListener("orientationchange", () => setTimeout(fitBox, 300));

function closeSocket() {
  if (sock) { try { sock.close(); } catch (_) {} sock = null; }
  if (ro) { ro.disconnect(); ro = null; }
  if (term) { term.dispose(); term = null; }
}

function ended(msg, shellGone) {
  const bar = $("#term-bar");
  if (bar) {
    clear(bar);
    bar.append(h("span", { class: "dim", text: msg }),
      h("span", { class: "term-bar-btns" },
        h("button", { class: "btn small", type: "button", text: "New session", onclick: () => start() }),
        remembered ? h("button", { class: "btn small quiet", type: "button", text: "Lock",
          title: "Ask for the key next time", onclick: () => lockNow(shellGone) }) : null));
  }
}

function open(ticket, idle) {
  clear(root());
  const bar = h("div", { class: "term-bar", id: "term-bar" },
    h("span", { class: "dim", text: `Shell on the server as ${shellAs()}. Idle for ${idle} minute${idle === 1 ? "" : "s"} closes it.` }),
    h("span", { class: "term-bar-btns" },
      userCopy() ? h("button", { class: "btn small quiet", type: "button", title: "End this shell and open a new one as the other user",
        text: `Switch to ${shellAs() === "root" ? userCopy().user : "root"}`, onclick: switchUser }) : null,
      h("button", { class: "btn small quiet", type: "button", text: "Disconnect", title: "Leave the shell running and come back later",
        onclick: () => { closeSocket(); ended(remembered ? "Disconnected. The shell is still running on the server." : "Disconnected. The shell is still running on the server. Enter the key again to get back to it."); } }),
      remembered ? h("button", { class: "btn small quiet", type: "button", text: "Lock", title: "Disconnect and ask for the key next time", onclick: lockNow }) : null,
      h("button", { class: "btn small quiet danger", type: "button", text: "End session", title: "Close the shell and everything running in it",
        onclick: () => { if (sock && sock.readyState === 1) sock.send(JSON.stringify({ x: 1 })); } })));
  const box = h("div", { class: "xterm-box", id: "xterm-box" });
  root().append(bar, box);
  fitBox();

  const css = getComputedStyle(document.documentElement);
  term = new window.Terminal({
    fontFamily: css.getPropertyValue("--mono") || "monospace", fontSize: 13, cursorBlink: true, scrollback: 5000,
    theme: { background: css.getPropertyValue("--sunk").trim() || "#111", foreground: css.getPropertyValue("--text").trim() || "#eee" },
  });
  fit = new window.FitAddon.FitAddon();
  term.loadAddon(fit);
  // The fit measures the terminal's parent including its padding, so the terminal goes in an
  // unpadded inner box; otherwise it takes one row too many and the last line is cut off.
  const host = h("div", { class: "xterm-host" });
  box.append(host);
  term.open(host);
  fit.fit();

  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/api/terminal/ws?ticket=${encodeURIComponent(ticket)}&as=${encodeURIComponent(shellAs())}`);
  ws.binaryType = "arraybuffer";
  sock = ws;
  const send = (o) => { if (ws.readyState === 1) ws.send(JSON.stringify(o)); };
  // A fresh shell needs a moment to print its prompt before a command is typed in.
  ws.onopen = () => { send({ r: [term.cols, term.rows] }); term.focus(); setTimeout(typePending, 700); };
  ws.onmessage = (ev) => {
    if (typeof ev.data === "string") {
      let m = {}; try { m = JSON.parse(ev.data); } catch (_) {}
      if (m.resumed) { term.write("\x1b[2m[Reconnected to your running session]\x1b[0m\r\n"); return; }
      if (m.end) { const t = term; closeSocketKeepTerm(); ended(m.end, true); if (t) t.write(`\r\n\x1b[2m[${m.end}]\x1b[0m\r\n`); }
    } else term.write(new Uint8Array(ev.data));
  };
  ws.onclose = (ev) => {
    if (sock === ws) { sock = null; if (ev.code === 4403) { gate("That unlock expired or was refused. Enter the key again."); } else ended(remembered ? "Connection lost. The shell keeps running on the server." : "Connection lost. The shell keeps running on the server. Enter the key again to get back to it."); }
  };
  nativeScroll(box);
  term.onData((d) => send({ i: d }));
  term.onResize(({ cols, rows }) => send({ r: [cols, rows] }));
  ro = new ResizeObserver(() => { if (!root().closest("[hidden]")) { try { fit.fit(); } catch (_) {} } });
  ro.observe(box);
}

// keep the screen text visible after the shell ends
function closeSocketKeepTerm() {
  if (sock) { try { sock.close(); } catch (_) {} sock = null; }
}

export function show(status) {
  lastStatus = status;
  if (!built) { built = true; start(); }
  else { fitBox(); if (fit) { try { fit.fit(); } catch (_) {} } typePending(); }
}
