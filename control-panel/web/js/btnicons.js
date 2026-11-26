// Icons before the words on the pages' action buttons, and on phones a card's row of buttons as
// two even columns: pairs along the bottom, an odd one out on its own above them (Update on a
// version card). One pass over each page whenever it redraws, so the pages' own code stays as it
// is. Dialogs and drawers (outside the pages), filters, toggles and quiet links keep plain words.

const RESTART = '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>';
const UPDATE = '<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>';
const COPY = '<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>';
const BIN = '<path d="M4 7h16M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>';   // the same bin as the rows' and cards' icon-only ones
const STOP = '<rect x="3" y="3" width="18" height="18" rx="2.5"/>';   // as big as the round icons look beside it
const START = '<path d="M7 4v16l13-8z"/>';
const SHIELD = '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>';
const BELL = '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>';
const CLOCK = '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>';
const CHECK = '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>';
const LIST = '<path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/>';
const SLIDERS = '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>';
const CARDS = '<path d="m3 10 2.5-2.5L3 5"/><path d="m3 19 2.5-2.5L3 14"/><path d="M10 6h11"/><path d="M10 12h11"/><path d="M10 18h11"/>';
const TICK = '<path d="M20 6 9 17l-5-5"/>';

const ICONS = {
  "Update": UPDATE, "Update VPN": UPDATE, "Install updates": UPDATE,
  "Check now": CHECK,
  // All releases: a stack of sheets, one version on another; List updates stays a list (of packages)
  "All releases": '<path d="M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z"/><path d="M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12"/><path d="M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17"/>',
  "List updates": LIST,
  "Show output": '<path d="m4 17 6-6-6-6"/><path d="M12 19h8"/>',
  "Restart stack": RESTART, "Restart": RESTART, "Restart panel": RESTART,
  "Reboot server": '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>',
  "Stop": STOP, "Stop watchdog": STOP,
  "Start": START, "Start watchdog": START,
  "Turn VPN off": SHIELD + '<path d="m4 4 16 16"/>', "Turn VPN on": SHIELD,
  "Send test alert": BELL, "Change topic": BELL,
  "Back up now": '<rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',
  "Set schedule": CLOCK, "Set time zone": CLOCK,
  "Restore": '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>',
  "Copy restore command": COPY, "Copy scp command": COPY, "Copy": COPY,
  "Lock": '<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  "Unlock": '<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 9.9-1"/>',
  "Delete": BIN, "Remove": BIN, "Uninstall": BIN, "Clear activity": BIN, "Clear history": BIN, "Free up space": BIN,
  "Set limits": SLIDERS, "Change config": SLIDERS, "Settings": SLIDERS,
  "Change server": '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
  "Use": TICK, "Set": TICK,
  // a five-pointed star with rounded points, outlined like the pencil beside it
  "What's new": '<path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>',
  "Fold all cards": CARDS, "Open all cards": CARDS,
};
// Round icons read larger than square ones at the same size, so they're drawn a touch smaller
const ROUND = new Set(["Check now", "Restart stack", "Restart", "Restart panel", "Reboot server", "Restore",
  "Set schedule", "Set time zone", "Change server"]);
// Shorter words where a phone has half its width for them (the copy icon says "Copy"); the full one is the label
const SHORT = { "Copy restore command": "Restore command", "Copy scp command": "scp command" };
// Buttons left alone: filters and toggles, header links, the log viewer's own controls
const SKIP = ".fold-act, .icon-only, .hero-edit, .tr-ranges .btn, .lg-row .btn, .lg-acts .btn, .wd-today-wrap .btn";

// Phones: these rows laid out as two columns, in this order (lower first). With an odd number,
// the first sits on its own above the pairs; the rest go in pairs, the action on the right.
const GRIDS = ".ver-btns, .vpnc-foot, .card-foot, .vpn-card-acts, .maint-foot, .scripts-panel .cmd-btns";
// Version cards: Update across the top, All releases and Check now under it
const ORDER = {
  "Update": 0, "All releases": 1, "Check now": 2,
  "List updates": 0, "Install updates": 1,
  "Send test alert": 0, "Stop": 1, "Start": 1,
  "Change config": 0, "Change server": 1, "Update VPN": 2,
};
const OUTPUT_ORDER = { "Install updates": 0, "Reboot server": 1, "Show output": 2, "List updates": 3 };
// Scripts' rows: Copy, Update, Remove
const SCRIPTS_ORDER = { "Copy": 0, "Update": 1, "Remove": 2 };

function svg(word) {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox", "0 0 24 24");
  s.setAttribute("aria-hidden", "true");
  s.setAttribute("class", ROUND.has(word) ? "bi round" : "bi");
  s.innerHTML = ICONS[word];
  return s;
}

// The button's word: its first label for buttons holding two
function wordOf(b) {
  const first = b.querySelector(":scope > span");
  if (first && first.textContent.trim()) return first.textContent.trim();
  return b.textContent.trim();
}

// A button redrawn mid-check reads Checking…: it's still Check now, so it keeps its icon and place
// (one that already had a word, like Restore while its backup is checked, stays what it was)
const ALIAS = { "Checking…": "Check now" };

function iconize(b) {
  if (b.matches(SKIP)) return;
  const shown = wordOf(b);
  const word = ALIAS[shown] ? (b.dataset.act || ALIAS[shown]) : shown;
  if (!ICONS[word]) return;
  b.dataset.act = word;   // kept while the word reads Checking…, so the button keeps its place
  b.classList.add("btn-i");
  if (b.querySelector("svg.bi")) return;
  if (SHORT[word] && !b.querySelector(".bw")) {
    b.textContent = "";
    const w = document.createElement("span");
    w.className = "bw";
    w.dataset.short = SHORT[word];
    w.textContent = word;
    b.append(w);
    b.setAttribute("aria-label", word);
  }
  b.prepend(svg(word));
}

function gridRows(view) {
  for (const row of view.querySelectorAll(GRIDS)) {
    // .ver-upd: an open card's Update, which phones show as the corner icon instead
    const btns = [...row.children].filter(b => b.classList.contains("btn-i") && !b.hidden && !b.classList.contains("btn-spacer") && !b.classList.contains("ver-upd"));
    if (btns.length < 2) { row.classList.remove("btn-grid"); continue; }
    row.classList.add("btn-grid");
    const isScripts = row.matches(".scripts-panel .cmd-btns");
    // System updates with Show output: Install updates across the top, Show output and List updates under it
    const order = isScripts ? SCRIPTS_ORDER : row.querySelector(":scope > .maint-out") ? OUTPUT_ORDER : ORDER;
    const sorted = [...btns].sort((a, b) => (order[a.dataset.act] ?? 5) - (order[b.dataset.act] ?? 5));
    sorted.forEach((b, i) => {
      b.dataset.ord = i;
      b.classList.toggle("btn-alone", btns.length % 2 === 1 && i === 0);
    });
  }
}

function pass(view) {
  view.querySelectorAll(".btn").forEach(iconize);
  gridRows(view);
}

for (const view of document.querySelectorAll("main .view")) {
  pass(view);
  new MutationObserver(() => pass(view)).observe(view, { childList: true, subtree: true, characterData: true });
}
