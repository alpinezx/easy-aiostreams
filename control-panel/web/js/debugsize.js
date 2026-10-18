// TEMPORARY (dev only, never merged): a readout of the screen and page sizes, for the phone
// menu running taller than the screen. Turn on with ?sizes=1 once, off with ?sizes=0.
let on = false;
try {
  const q = new URLSearchParams(location.search).get("sizes");
  if (q === "1") localStorage.setItem("debug-sizes", "1");
  if (q === "0") localStorage.removeItem("debug-sizes");
  on = localStorage.getItem("debug-sizes") === "1";
} catch (_) {}

if (on) {
  const box = document.createElement("pre");
  box.style.cssText = "position:fixed;left:4px;bottom:4px;z-index:9999;margin:0;padding:6px 8px;max-width:calc(100vw - 8px);" +
    "background:rgba(0,0,0,.85);color:#7fffa0;font:11px/1.35 monospace;border:1px solid #7fffa0;border-radius:6px;white-space:pre-wrap;pointer-events:none";
  const log = [];
  const widest = () => {
    const w = document.documentElement.clientWidth;
    let best = null, right = w + 1;
    for (const e of document.querySelectorAll("body *")) {
      if (box.contains(e) || e === box) continue;
      const r = e.getBoundingClientRect();
      if (r.width && r.right > right) { right = r.right; best = e; }
    }
    return best ? `${best.tagName.toLowerCase()}.${String(best.className).split(" ").join(".")} to ${Math.round(right)}` : "none";
  };
  const read = () => {
    const d = document.documentElement, vv = window.visualViewport;
    const rail = document.querySelector(".rail");
    const probe = document.createElement("div");
    probe.style.cssText = "position:fixed;top:0;height:100dvh;width:1px;visibility:hidden";
    document.body.append(probe);
    const dvh = probe.getBoundingClientRect().height;
    probe.style.height = "100vh";
    const vh = probe.getBoundingClientRect().height;
    probe.remove();
    return [
      `inner ${innerWidth}x${innerHeight}  dpr ${devicePixelRatio}`,
      vv ? `visual ${Math.round(vv.width)}x${Math.round(vv.height)}  scale ${vv.scale.toFixed(2)}  top ${Math.round(vv.offsetTop)}` : "visual n/a",
      `doc client ${d.clientWidth}x${d.clientHeight}  scroll ${d.scrollWidth}x${d.scrollHeight}`,
      `100vh ${Math.round(vh)}  100dvh ${Math.round(dvh)}  scrollY ${Math.round(scrollY)}`,
      rail ? `menu ${Math.round(rail.getBoundingClientRect().height)} tall` : "login page",
      `wider than screen: ${widest()}`,
    ];
  };
  // The first few seconds matter most (right after signing in), so keep what was seen then
  const t0 = Date.now();
  const tick = () => {
    const lines = read();
    const s = ((Date.now() - t0) / 1000).toFixed(1);
    const key = lines.join("|");
    if (log.length < 6 && (!log.length || log[log.length - 1].key !== key)) log.push({ s, key, wide: lines[5] });
    box.textContent = [...lines, "", "first seconds:", ...log.map((l) => `${l.s}s ${l.wide.replace("wider than screen: ", "wide: ")} | ${l.key.split("|")[2].replace("doc client ", "")}`)].join("\n");
  };
  const start = () => { document.body.append(box); tick(); setInterval(tick, 500); };
  if (document.body) start(); else addEventListener("DOMContentLoaded", start);
}
