// The part of the page actually on screen, as CSS variables (--vv-h, --vv-top). Firefox on
// Android can keep the page laid out 285px taller after the keyboard closes, even into the next
// page, with the view shifted down to match; anything sized by 100vh or pinned top/bottom then
// runs off screen. The visual viewport stays right, so the phone menu and the login card use it.
//
// It can also report nonsense while the tab is in the background (a height of 0), and nothing
// re-measures until the next resize: the phone menu then opened 0px tall, only dimming the page.
// So a height under 120px is ignored (CSS falls back to 100dvh), and fit() runs again when the
// page comes back into view and each time the menu opens.
const vv = window.visualViewport;
const root = document.documentElement.style;

export function fit() {
  if (!vv || document.visibilityState === "hidden" || vv.height < 120) {
    root.removeProperty("--vv-h");
    root.removeProperty("--vv-top");
    return;
  }
  root.setProperty("--vv-h", `${Math.round(vv.height)}px`);
  root.setProperty("--vv-top", `${Math.round(Math.max(0, vv.offsetTop))}px`);
}

if (vv) {
  vv.addEventListener("resize", fit);
  vv.addEventListener("scroll", fit);
  window.addEventListener("pageshow", fit);
  document.addEventListener("visibilitychange", fit);
  fit();
}
