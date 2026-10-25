// The colours picked on the Edit menu (this browser only), set before the page paints so it
// doesn't flash the other scheme first. A plain script, loaded ahead of the stylesheet.
try {
  const t = localStorage.getItem("aios.theme");
  if (t === "light" || t === "dark") document.documentElement.dataset.theme = t;
} catch (_) { /* no storage: follow the device */ }
