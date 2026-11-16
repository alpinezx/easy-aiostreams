// Drawers, dialogs and the phone menu slide in with a short animation that starts invisible
// (the drawers fade in from opacity 0; the menu starts off screen). Firefox can stop a tab's
// animation clock: seen after the panel reloaded itself following a rebuild, with the page's
// `performance` reading null. Each animation then stays on its first frame, so a drawer opened
// but showed nothing and the page only dimmed. Here a slide that hasn't moved after a moment is
// finished by hand, which shows its end state, and with no `performance` at all there's no
// motion in the first place.
const root = document.documentElement;
if (!window.performance) root.classList.add("still");

const seen = new WeakMap();   // animation -> { t: its time when first looked at, at: then }

function check() {
  if (!window.performance) root.classList.add("still");
  let stuck = false;
  for (const a of document.getAnimations()) {
    if (a.playState !== "running") continue;
    let finite = true;
    try { finite = a.effect.getComputedTiming().iterations !== Infinity; } catch { /* keep it */ }
    if (!finite) continue;    // a spinner: it never ends, so never finish it
    const t = a.currentTime, prev = seen.get(a), now = Date.now();
    if (!prev || prev.t !== t) { seen.set(a, { t, at: now }); stuck = true; continue; }
    if (now - prev.at >= 300) { try { a.finish(); } catch { /* gone already */ } }
    else stuck = true;
  }
  return stuck;
}

// Whatever opens something is a click or a key (or a page change): look twice after each one
let timer = null;
function soon() {
  clearTimeout(timer);
  let tries = 0;
  const run = () => { if (check() && ++tries < 4) timer = setTimeout(run, 200); };
  timer = setTimeout(run, 150);
}
document.addEventListener("click", soon, true);
document.addEventListener("keydown", soon, true);
window.addEventListener("hashchange", soon);
