// Just enough Markdown for GitHub release notes: headings, bullets, paragraphs,
// code blocks, **bold**, `code` and [links](https://...). Builds DOM nodes and
// never uses innerHTML, so the notes stay plain text whatever they contain.
import { h } from "./util.js";

const INLINE = /\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https:\/\/[^)\s]+)\)/g;

function inline(text) {
  const out = [];
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[1] != null) out.push(h("strong", {}, inline(m[1])));
    else if (m[2] != null) out.push(h("code", { text: m[2] }));
    else out.push(h("a", { href: m[4], target: "_blank", rel: "noopener noreferrer" }, inline(m[3])));
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function renderMarkdown(src) {
  const frag = document.createDocumentFragment();
  let list = null, para = null, code = null;
  const flush = () => { list = null; para = null; };
  for (const raw of src.replace(/\r\n?/g, "\n").split("\n")) {
    if (code) {
      if (/^\s*```/.test(raw)) { code = null; continue; }
      code.textContent += (code.textContent ? "\n" : "") + raw;
      continue;
    }
    const line = raw.trimEnd();
    let m;
    if (/^\s*```/.test(line)) {
      flush();
      code = h("code");
      frag.append(h("pre", {}, code));
    } else if (!line.trim()) {
      flush();
    } else if ((m = /^(#{1,6})\s+(.*)$/.exec(line))) {
      flush();
      frag.append(h(m[1].length <= 2 ? "h4" : "h5", {}, inline(m[2])));
    } else if ((m = /^\s*[-*+]\s+(.*)$/.exec(line))) {
      para = null;
      if (!list) { list = h("ul"); frag.append(list); }
      list.append(h("li", {}, inline(m[1])));
    } else if (list && /^\s{2,}\S/.test(raw)) {
      list.lastChild.append(" ", ...inline(line.trim()));
    } else {
      list = null;
      if (para) para.append(" ", ...inline(line.trim()));
      else { para = h("p", {}, inline(line.trim())); frag.append(para); }
    }
  }
  return frag;
}
