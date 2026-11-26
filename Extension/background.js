// T3 Notch browser bridge. T3 Notch (the macOS app) runs a WebSocket server on this Mac;
// the release app listens on 127.0.0.1:47823 and the dev build on 47824. The server only
// accepts this extension's origin. It asks what is under a screen point in a page, and this
// worker answers from the matching tab with page.js.

const PORTS = [47823, 47824];
const sockets = new Map(); // port -> WebSocket
const retry = new Map(); // port -> delay in ms

function connect(port) {
  const old = sockets.get(port);
  if (old && (old.readyState === WebSocket.OPEN || old.readyState === WebSocket.CONNECTING)) return;
  let ws;
  try {
    ws = new WebSocket(`ws://127.0.0.1:${port}/t3notch`);
  } catch {
    return schedule(port);
  }
  sockets.set(port, ws);
  ws.onopen = () => {
    retry.set(port, 1000);
    ws.send(JSON.stringify({ type: "hello", version: chrome.runtime.getManifest().version, browser: navigator.userAgent }));
    updateBadge();
  };
  ws.onmessage = (e) => handle(ws, e.data);
  ws.onclose = () => {
    if (sockets.get(port) === ws) sockets.delete(port);
    updateBadge();
    schedule(port);
  };
  ws.onerror = () => {}; // onclose follows
}

function schedule(port) {
  const delay = retry.get(port) ?? 1000;
  retry.set(port, Math.min(delay * 2, 30000));
  setTimeout(() => connect(port), delay);
}

const connectAll = () => PORTS.forEach(connect);
const connected = () => [...sockets.values()].some((s) => s.readyState === WebSocket.OPEN);

function updateBadge() {
  chrome.action.setBadgeText({ text: connected() ? "" : "off" });
  chrome.action.setBadgeBackgroundColor({ color: "#777" });
}

// Keep the worker alive while connected (Chrome 116+ counts WebSocket traffic), and come
// back after the browser stops it.
setInterval(() => {
  for (const s of sockets.values()) if (s.readyState === WebSocket.OPEN) s.send('{"type":"ping"}');
}, 20000);
chrome.alarms.create("t3n-reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(connectAll);
chrome.runtime.onStartup.addListener(connectAll);
chrome.runtime.onInstalled.addListener(connectAll);
connectAll();

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg?.type === "status") reply({ connected: connected(), ports: [...sockets.entries()].filter(([, s]) => s.readyState === WebSocket.OPEN).map(([p]) => p) });
});

// --- Requests from T3 Notch ---

async function handle(ws, data) {
  let msg;
  try { msg = JSON.parse(data); } catch { return; }
  if (!msg.id) return;
  let result = null;
  try {
    if (msg.type === "hit") result = await hit(msg);
    else if (msg.type === "sibling") result = await run(msg.tab, (h, d) => globalThis.__t3n?.sibling(h, d), [msg.handle, msg.dir]);
    else if (msg.type === "describe") result = await describe(msg);
  } catch (e) {
    result = null;
  }
  if (result && msg.type !== "describe") result.tab ??= msg.tab;
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ id: msg.id, ok: !!result, result }));
}

const sameURL = (a, b) => {
  try {
    const x = new URL(a), y = new URL(b);
    x.hash = ""; y.hash = "";
    return x.href === y.href;
  } catch { return a === b; }
};

// The tab the point is in: active, with the page's URL, in the window whose bounds best
// match the window under the pointer. The score (distance in points) goes back to the app,
// which takes the closest answer when two browsers show the same page.
async function findTab(msg) {
  const tabs = await chrome.tabs.query({ active: true });
  const candidates = tabs.filter((t) => t.url && sameURL(t.url, msg.url));
  if (candidates.length === 0) return null;
  if (!msg.window) return { tab: candidates[0], score: null };
  let best = null, bestScore = Infinity;
  for (const t of candidates) {
    const w = await chrome.windows.get(t.windowId);
    const score = Math.abs(w.left - msg.window.x) + Math.abs(w.top - msg.window.y) +
      Math.abs(w.width - msg.window.w) + Math.abs(w.height - msg.window.h);
    if (score < bestScore) { best = t; bestScore = score; }
  }
  return { tab: best, score: bestScore };
}

async function hit(msg) {
  const found = await findTab(msg);
  if (!found) return null;
  const { tab, score } = found;
  // The point in CSS pixels: the web area is the viewport, so scale its points to the
  // page's width.
  return run(tab.id, (px, py, areaWidth) => {
    const s = innerWidth / areaWidth;
    return globalThis.__t3n?.hit(px * s, py * s);
  }, [msg.x - msg.area.x, msg.y - msg.area.y, msg.area.w]).then((r) => (r ? { ...r, tab: tab.id, score } : null));
}

// The element as page.js describes it, plus where it comes from in the code: the components
// around it and the source file, when the page's framework says (a development build).
async function describe(msg) {
  const mark = "t" + Math.random().toString(36).slice(2);
  const result = await run(msg.tab, (h, m) => globalThis.__t3n?.describe(h, m), [msg.handle, mark]);
  if (!result) return null;
  try {
    const [{ result: code }] = await chrome.scripting.executeScript({
      target: { tabId: msg.tab }, world: "MAIN", func: sourceOf, args: [mark],
    });
    if (code) Object.assign(result, code);
  } catch {}
  return result;
}

// Runs in the page's own world. Finds the marked element, takes the mark away, and reads
// what React, Vue or Svelte keep on it in development: component names (nearest first) and
// the file and line that made it.
function sourceOf(mark) {
  // The element can be inside open shadow roots, where the document's own query does not look.
  const find = (root) => {
    const hit = root.querySelector(`[data-t3n-pick="${mark}"]`);
    if (hit) return hit;
    for (const host of root.querySelectorAll("*")) {
      const inner = host.shadowRoot && find(host.shadowRoot);
      if (inner) return inner;
    }
    return null;
  };
  const el = find(document);
  if (!el) return null;
  el.removeAttribute("data-t3n-pick");
  const components = [];
  let source = null;
  // Where each component around the element is used, nearest first: "Name at file:line".
  const usedAt = [];
  const extra = {};
  try {
    // The styles that decide how the element looks, without the values every element has.
    const cs = getComputedStyle(el), r = el.getBoundingClientRect();
    const plain = new Set(["none", "normal", "auto", "0px", "static", "visible", "rgba(0, 0, 0, 0)", "start", "stretch", "row", "nowrap", "0s", "0 1 auto", "baseline"]);
    const css = [`width:${Math.round(r.width)}px`, `height:${Math.round(r.height)}px`];
    for (const p of ["display", "position", "flex", "flex-direction", "align-items", "justify-content", "gap", "grid-template-columns",
      "padding", "margin", "border", "border-radius", "background-color", "color", "font-family", "font-size", "font-weight",
      "line-height", "text-align", "box-shadow", "opacity", "overflow", "z-index", "cursor"]) {
      const v = cs.getPropertyValue(p);
      if (!v || plain.has(v) || v.length > 140 || (p === "opacity" && v === "1") || (p === "border" && v.startsWith("0px"))) continue;
      css.push(`${p}:${p === "font-family" ? v.split(",")[0] : v}`);
    }
    extra.css = css.join("; ");
    const root = document.documentElement;
    const dark = root.classList.contains("dark") || root.dataset.theme === "dark" ||
      (!root.classList.contains("light") && root.dataset.theme !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
    extra.viewport = `${innerWidth}x${innerHeight} px at ${devicePixelRatio}x, scrolled to ${Math.round(scrollX)},${Math.round(scrollY)}, ${dark ? "dark" : "light"} theme`;
    // A name for the element when it has none of its own: the first label inside it.
    const named = el.matches("[aria-label],[placeholder],[alt],[title]") ? el : el.querySelector("[aria-label],[placeholder],[alt]");
    const hint = named && (named.getAttribute("aria-label") || named.getAttribute("placeholder") || named.getAttribute("alt") || named.getAttribute("title"));
    if (hint) extra.hint = hint.slice(0, 120);
  } catch {}
  const add = (name) => {
    if (typeof name === "string" && name && name.length < 80 && components.length < 8 && components.at(-1) !== name) components.push(name);
  };
  // A dev server's URL or a bundler's path, as a path in the project.
  const tidy = (file) => String(file)
    .replace(/^webpack-internal:\/\/\/(\([^)]*\)\/)?/, "").replace(/^webpack:\/\/[^/]*\//, "")
    .replace(/^https?:\/\/[^/]+/, "").replace(/^\/@fs/, "").replace(/\?[^:]*/, "").replace(/^\.\//, "");
  const library = /node_modules|react-dom|react\.development|jsx-dev-runtime|jsx-runtime|chunk-[A-Z0-9]+\.js/;
  try {
    const key = Object.keys(el).find((k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"));
    // The file and line that wrote this fiber's JSX.
    const written = (f) => {
      const s = f._debugSource; // React 18 and older
      if (s?.fileName) return `${tidy(s.fileName)}:${s.lineNumber}${s.columnNumber ? ":" + s.columnNumber : ""}`;
      if (typeof f._debugStack?.stack === "string") { // React 19
        for (const line of f._debugStack.stack.split("\n").slice(1)) {
          const m = line.match(/((?:https?|webpack-internal|file):\/\/[^\s)]+?):(\d+):(\d+)\)?\s*$/);
          if (m && !library.test(m[1])) return `${tidy(m[1])}:${m[2]}:${m[3]}`;
        }
      }
      return null;
    };
    for (let f = key ? el[key] : null, n = 0; f && n < 300; f = f.return, n++) {
      if (!source) source = written(f);
      const t = f.type;
      const name = typeof t === "function" ? t.displayName || t.name
        : t && typeof t === "object" ? t.displayName || t.render?.displayName || t.render?.name || t.type?.displayName || t.type?.name : null;
      const before = components.length;
      add(name);
      if (components.length > before && name.length > 2 && usedAt.length < 5) {
        const at = written(f);
        if (at) usedAt.push(`${name} at ${at}`);
      }
    }
    for (let v = el.__vueParentComponent, n = 0; v && n < 50; v = v.parent, n++) {
      add(v.type?.__name || v.type?.name);
      if (!source && v.type?.__file) source = tidy(v.type.__file);
    }
    const loc = el.__svelte_meta?.loc;
    if (!source && loc?.file) source = `${tidy(loc.file)}:${loc.line}:${loc.column}`;
  } catch {}
  return { components, source, usedAt, ...extra };
}

// Runs `func` in the tab's top frame, injecting page.js first if it is not there yet.
async function run(tabId, func, args) {
  const call = async () => (await chrome.scripting.executeScript({ target: { tabId }, func, args }))[0]?.result;
  let result = await call();
  if (result === undefined || result === null) {
    const [{ result: present }] = await chrome.scripting.executeScript({ target: { tabId }, func: () => !!globalThis.__t3n });
    if (present) return result ?? null;
    await chrome.scripting.executeScript({ target: { tabId }, files: ["page.js"] });
    result = await call();
  }
  return result ?? null;
}
