// The part of the page actually on screen, as CSS variables (--vv-h, --vv-top). Firefox on
// Android can keep the page laid out 285px taller after the keyboard closes, even into the next
// page, with the view shifted down to match; anything sized by 100vh or pinned top/bottom then
// runs off screen. The visual viewport stays right, so the phone menu and the login card use it.
const vv = window.visualViewport;
if (vv) {
  const root = document.documentElement.style;
  const fit = () => {
    root.setProperty("--vv-h", `${Math.round(vv.height)}px`);
    root.setProperty("--vv-top", `${Math.round(vv.offsetTop)}px`);
  };
  vv.addEventListener("resize", fit);
  vv.addEventListener("scroll", fit);
  fit();
}
