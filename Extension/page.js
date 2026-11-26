// Runs in the page's isolated world. T3 Notch asks what is under a point, steps to a
// sibling, and describes an element the user picked. Elements are kept by handle number
// only as weak references, so the page can drop them.
(() => {
  if (globalThis.__t3n) return;

  const byHandle = new Map(); // handle -> WeakRef(element)
  const handles = new WeakMap(); // element -> handle
  let nextHandle = 1;

  const handleOf = (el) => {
    let h = handles.get(el);
    if (!h) {
      h = nextHandle++;
      handles.set(el, h);
      byHandle.set(h, new WeakRef(el));
      if (byHandle.size > 4000) {
        for (const [k, ref] of byHandle) if (!ref.deref()) byHandle.delete(k);
      }
    }
    return h;
  };
  const get = (h) => byHandle.get(h)?.deref() ?? null;

  // The parent across shadow roots (a shadow root's parent is its host).
  const parentOf = (el) => el.parentElement ?? (el.parentNode instanceof ShadowRoot ? el.parentNode.host : null);

  const clip = (s, n) => {
    s = (s ?? "").replace(/\s+/g, " ").trim();
    return s.length > n ? s.slice(0, n - 1) + "…" : s;
  };

  const interactive = new Set(["a", "button", "input", "select", "textarea", "label", "summary", "option", "video", "audio", "img", "canvas"]);
  const interactiveRoles = new Set(["button", "link", "checkbox", "radio", "tab", "menuitem", "option", "switch", "textbox", "combobox", "slider", "searchbox"]);
  const generic = new Set(["div", "span", "section", "main", "article", "html", "body"]);

  const role = (el) => el.getAttribute("role") || null;
  const name = (el) =>
    clip(el.getAttribute("aria-label") || el.getAttribute("alt") || el.getAttribute("title") ||
      (el.tagName === "INPUT" ? el.getAttribute("placeholder") : "") || "", 80) || null;

  // "button · Save", "a · Pricing", "div.card".
  const label = (el) => {
    const tag = el.tagName.toLowerCase();
    const r = role(el);
    let kind = r ? `${tag}[${r}]` : tag;
    if (!r && el.id && el.id.length <= 24) kind += `#${el.id}`;
    else if (!r && typeof el.className === "string" && el.className.trim()) kind += "." + el.className.trim().split(/\s+/)[0].slice(0, 24);
    let n = name(el);
    if (!n && el.children.length === 0) n = clip(el.textContent, 40) || null;
    if (!n && ["a", "button", "h1", "h2", "h3", "h4", "label", "summary", "li", "p"].includes(tag)) n = clip(el.innerText, 40) || null;
    return n ? `${kind} · ${n}` : kind;
  };

  const isInteractive = (el) =>
    interactive.has(el.tagName.toLowerCase()) || interactiveRoles.has(role(el)) || el.isContentEditable && !parentOf(el)?.isContentEditable;

  // The element and its ancestors, smallest first, with viewport rects in CSS pixels.
  const chain = (start) => {
    const vw = innerWidth, vh = innerHeight;
    const nodes = [];
    for (let el = start; el && nodes.length < 40; el = parentOf(el)) {
      const r = el.getBoundingClientRect();
      const x = Math.max(r.left, 0), y = Math.max(r.top, 0);
      const w = Math.min(r.right, vw) - x, h = Math.min(r.bottom, vh) - y;
      if (w < 1 || h < 1) continue;
      nodes.push({ id: handleOf(el), x, y, w, h, label: label(el), tag: el.tagName.toLowerCase(), interactive: isInteractive(el) });
    }
    // The element you most likely mean: an interactive element a few levels up (a click on a
    // button's icon means the button), else the smallest element that is not a bare wrapper.
    let preferred = nodes.slice(0, 4).findIndex((n) => n.interactive);
    if (preferred < 0) preferred = Math.max(0, nodes.findIndex((n) => !generic.has(n.tag) || /·/.test(n.label)));
    const p = nodes[preferred];
    if (p && p.w * p.h > 0.8 * vw * vh) preferred = 0;
    return { nodes, preferred, innerWidth: vw, innerHeight: vh, url: location.href, title: document.title };
  };

  const hit = (x, y) => {
    let el = document.elementFromPoint(x, y);
    // Into open shadow roots, down to the innermost element.
    while (el?.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el ? chain(el) : null;
  };

  const visible = (el) => {
    const r = el.getBoundingClientRect();
    return Math.min(r.right, innerWidth) - Math.max(r.left, 0) >= 4 && Math.min(r.bottom, innerHeight) - Math.max(r.top, 0) >= 4;
  };

  const sibling = (h, dir) => {
    const el = get(h);
    if (!el) return null;
    for (let s = dir < 0 ? el.previousElementSibling : el.nextElementSibling; s; s = dir < 0 ? s.previousElementSibling : s.nextElementSibling) {
      if (visible(s)) return chain(s);
    }
    return null;
  };

  // A CSS selector that finds this element: an id where one is unique, else tag and
  // :nth-of-type steps from the nearest unique id or the root.
  const selector = (el) => {
    const parts = [];
    for (let e = el; e && e.nodeType === 1 && parts.length < 12; e = e.parentElement) {
      if (e.id && /^[A-Za-z][\w-]*$/.test(e.id) && e.getRootNode().querySelectorAll(`#${e.id}`).length === 1) {
        parts.unshift(`#${e.id}`);
        break;
      }
      const tag = e.tagName.toLowerCase();
      if (tag === "html" || tag === "body") { parts.unshift(tag); break; }
      const same = e.parentElement ? [...e.parentElement.children].filter((c) => c.tagName === e.tagName) : [];
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(e) + 1})` : tag);
    }
    return parts.join(" > ");
  };

  const isPassword = (el) => el.tagName === "INPUT" && (el.type === "password" || el.autocomplete?.includes("password"));

  // URLs lose credentials, and on public hosts their query and fragment, where reset
  // tokens and session keys live. The same rule as PickContext.sanitize in the app.
  const URL_ATTRS = new Set(["href", "src", "action", "formaction", "poster", "cite", "background",
    "ping", "data", "xlink:href", "manifest", "longdesc", "itemid", "codebase", "usemap"]);
  const isLocalHost = (raw) => {
    const h = raw.replace(/^\[|\]$/g, "").toLowerCase();
    if (!h) return false;
    if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || !h.includes(".") && !h.includes(":")) return true;
    const v4 = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (v4) {
      const [a, b] = [+v4[1], +v4[2]];
      return a === 127 || a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
    }
    return h.includes(":") && (h === "::1" || /^f[cd][0-9a-f]{0,2}:/.test(h) || h.startsWith("fe80:"));
  };
  const cleanURL = (v) => {
    let u;
    try { u = new URL(v, location.href); } catch { return v; }
    if (u.protocol !== "http:" && u.protocol !== "https:" && u.protocol !== "ws:" && u.protocol !== "wss:") return v;
    u.username = ""; u.password = "";
    if (!isLocalHost(u.hostname)) { u.search = ""; u.hash = ""; }
    return u.href;
  };
  // srcset and imagesrcset hold URL lists with sizes: dropped, like style.
  const DROP_ATTRS = new Set(["value", "style", "nonce", "srcset", "imagesrcset"]);
  const cleanAttr = (name, v) => {
    const n = name.toLowerCase();
    if (n === "ping") return v.trim().split(/\s+/).filter(Boolean).map(cleanURL).join(" ");
    return URL_ATTRS.has(n) || /^(https?|wss?):\/\//i.test(v.trim()) ? cleanURL(v.trim()) : v;
  };

  // The element's HTML without scripts, styles, inline handlers, typed values or data URLs.
  const cleanHTML = (el, max) => {
    const copy = el.cloneNode(true);
    const all = [copy, ...copy.querySelectorAll("*")];
    for (const e of all) {
      if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"].includes(e.tagName) && e !== copy) { e.remove(); continue; }
      if (e.tagName === "svg" || e.tagName === "SVG") { e.replaceChildren(); }
      for (const a of [...e.attributes]) {
        const v = a.value;
        if (a.name.startsWith("on") || DROP_ATTRS.has(a.name.toLowerCase()) ||
          /^\s*(data|blob|javascript):/i.test(v)) { e.removeAttribute(a.name); continue; }
        const c = cleanAttr(a.name, v);
        if (c.length > 200) e.setAttribute(a.name, c.slice(0, 199) + "…");
        else if (c !== v) e.setAttribute(a.name, c);
      }
      if (e.tagName === "TEXTAREA") e.textContent = "";
    }
    const html = copy.outerHTML;
    return html.length > max ? html.slice(0, max - 1) + "…" : html;
  };

  const describe = (h) => {
    const el = get(h);
    if (!el) return null;
    const attributes = {};
    for (const a of el.attributes) {
      if (DROP_ATTRS.has(a.name.toLowerCase()) || a.name.startsWith("on") || /^\s*(data|blob|javascript):/i.test(a.value)) continue;
      attributes[a.name] = clip(cleanAttr(a.name, a.value), 200);
    }
    let value = null;
    if ((el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") && !isPassword(el)) value = clip(el.value, 2000) || null;
    const path = [];
    for (let e = parentOf(el); e && path.length < 30; e = parentOf(e)) path.unshift(label(e));
    return {
      selector: selector(el),
      tag: el.tagName.toLowerCase(),
      role: role(el),
      name: name(el),
      label: label(el),
      text: isPassword(el) ? null : clip(el.innerText ?? el.textContent, 4000) || null,
      value,
      html: cleanHTML(el, 6000),
      attributes,
      path,
      url: location.href,
      title: document.title,
    };
  };

  globalThis.__t3n = { hit, sibling, describe };
})();
