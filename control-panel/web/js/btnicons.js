// Icons before the words on the pages' action buttons, and on phones a card's row of buttons as
// two even columns: pairs along the bottom, an odd one out on its own above them (All releases on
// a version card). One pass over each page whenever it redraws, so the pages' own code stays as it
// is. Dialogs and drawers (outside the pages), filters, toggles and quiet links keep plain words.

const RESTART = '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>';
const UPDATE = '<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>';
const COPY = '<rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>';
const BIN = '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>';
const STOP = '<rect x="4.5" y="4.5" width="15" height="15" rx="2"/>';
const START = '<path d="M7 4v16l13-8z"/>';
const SHIELD = '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>';
const BELL = '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>';
const CLOCK = '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>';
const TERMINAL = '<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>';
const CHECK = '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>';
const LIST = '<path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/>';
const SLIDERS = '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>';
const CARDS = '<path d="m3 10 2.5-2.5L3 5"/><path d="m3 19 2.5-2.5L3 14"/><path d="M10 6h11"/><path d="M10 12h11"/><path d="M10 18h11"/>';
const TICK = '<path d="M20 6 9 17l-5-5"/>';

const ICONS = {
  "Update": UPDATE, "Update VPN": UPDATE, "Install updates": UPDATE,
  "Check now": CHECK,
  "All releases": LIST, "List updates": LIST,
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
  "Delete": BIN, "Remove": BIN, "Uninstall": BIN, "Clear activity": BIN, "Free up space": BIN,
  "Set limits": SLIDERS, "Change config": SLIDERS,
  "Change server": '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
  "Use": TICK, "Set": TICK,
  "What's new": '<path d="M12 2.5l2.2 6.8 7.1 2.7-7.1 2.7L12 21.5l-2.2-6.8L2.7 12l7.1-2.7z"/>',
  "Run in terminal": TERMINAL, "Get and run": TERMINAL,
  "Fold all cards": CARDS, "Open all cards": CARDS,
};
// Round icons read larger than square ones at the same size, so they're drawn a touch smaller
const ROUND = new Set(["Check now", "Restart stack", "Restart", "Restart panel", "Reboot server", "Restore",
  "Set schedule", "Set time zone", "Change server"]);
const SHORT = {};
// Buttons left alone: filters and toggles, header links, the log viewer's own controls
const SKIP = ".fold-act, .icon-only, .hero-edit, .tr-ranges .btn, .lg-row .btn, .lg-acts .btn, .term-gate .btn, .wd-today-wrap .btn, .wd-sub .btn";

// Phones: these rows laid out as two columns, in this order (lower first). With an odd number,
// the first sits on its own above the pairs; the rest go in pairs, the action on the right.
const GRIDS = ".ver-btns, .vpnc-foot, .card-foot, .vpn-card-acts, .maint-foot, .scripts-panel .cmd-btns";
const ORDER = {
  "All releases": 0, "Check now": 1, "Update": 2,
  "List updates": 0, "Install updates": 1,
  "Send test alert": 0, "Stop": 1, "Start": 1,
  "Change config": 0, "Change server": 1, "Update VPN": 2,
  "Run in terminal": 0, "Get and run": 0, "Copy": 1, "Remove": 3,
};

function svg(word) {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox", "0 0 24 24");
  s.setAttribute("aria-hidden", "true");
  s.setAttribute("class", ROUND.has(word) ? "bi round" : "bi");
  s.innerHTML = ICONS[word];
  return s;
}

// The button's word: its first label for buttons holding two (Run in terminal / Get and run)
function wordOf(b) {
  const first = b.querySelector(":scope > span");
  if (first && first.textContent.trim()) return first.textContent.trim();
  return b.textContent.trim();
}

function iconize(b) {
  if (b.matches(SKIP)) return;
  const word = wordOf(b);
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
    const btns = [...row.children].filter(b => b.classList.contains("btn-i") && !b.hidden && !b.classList.contains("btn-spacer"));
    if (btns.length < 2) { row.classList.remove("btn-grid"); continue; }
    row.classList.add("btn-grid");
    const sorted = [...btns].sort((a, b) => (ORDER[a.dataset.act] ?? 5) - (ORDER[b.dataset.act] ?? 5));
    // Scripts: Run in terminal (or Get and run) always across the top; an odd one left over (Remove,
    // when there's an Update too) across the next row; the pairs (Copy and Update) along the bottom
    const runTop = row.matches(".scripts-panel .cmd-btns") && btns.length > 2;
    if (runTop && (btns.length - 1) % 2 === 1) sorted.splice(1, 0, sorted.pop());
    sorted.forEach((b, i) => {
      b.dataset.ord = i;
      const wide = runTop ? i === 0 || ((btns.length - 1) % 2 === 1 && i === 1) : btns.length % 2 === 1 && i === 0;
      b.classList.toggle("btn-alone", wide);
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
