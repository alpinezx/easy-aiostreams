// The colours picked in the Overview's Edit (this browser only), set before the page paints so it
// doesn't flash the other scheme first. A plain script, loaded ahead of the stylesheet.
try {
  const t = localStorage.getItem("aios.theme");
  // Keep in step with THEMES and MORE in layout.js (a test checks)
  if (["light", "dark", "slate", "dracula", "mocha", "tokyo", "gruvbox", "onedark", "flexoki", "kanagawa", "nightowl", "solardark", "ghdark", "ayu", "latte", "ghlight", "solarlight", "gruvlight", "everlight", "tokyoday", "novel", "aerogel", "basic", "material", "onelight", "dawn"].includes(t)) document.documentElement.dataset.theme = t;
} catch (_) { /* no storage: follow the device */ }
