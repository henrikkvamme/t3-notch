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
    else if (msg.type === "describe") result = await run(msg.tab, (h) => globalThis.__t3n?.describe(h), [msg.handle]);
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
// match the window under the pointer.
async function findTab(msg) {
  const tabs = await chrome.tabs.query({ active: true });
  const candidates = tabs.filter((t) => t.url && sameURL(t.url, msg.url));
  if (candidates.length === 0) return null;
  if (candidates.length === 1 || !msg.window) return candidates[0];
  let best = null, bestScore = Infinity;
  for (const t of candidates) {
    const w = await chrome.windows.get(t.windowId);
    const score = Math.abs(w.left - msg.window.x) + Math.abs(w.top - msg.window.y) +
      Math.abs(w.width - msg.window.w) + Math.abs(w.height - msg.window.h);
    if (score < bestScore) { best = t; bestScore = score; }
  }
  return best;
}

async function hit(msg) {
  const tab = await findTab(msg);
  if (!tab) return null;
  // The point in CSS pixels: the web area is the viewport, so scale its points to the
  // page's width.
  return run(tab.id, (px, py, areaWidth) => {
    const s = innerWidth / areaWidth;
    return globalThis.__t3n?.hit(px * s, py * s);
  }, [msg.x - msg.area.x, msg.y - msg.area.y, msg.area.w]).then((r) => (r ? { ...r, tab: tab.id } : null));
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
