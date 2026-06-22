// agent2 bridge, service worker.
// Maintains a WebSocket connection to the local agent2 sidecar at
// ws://127.0.0.1:8767/extension. agent2 sends RPC requests
// ({id, method, params}) and we respond with ({id, result} | {id, error}).
//
// Methods exposed:
//   ping                                  -> {ok, version, ts}
//   tabs.list                             -> [{id, title, url, active, windowId, ...}]
//   tabs.active                           -> {id, title, url, ...}
//   tabs.navigate({tab_id?, url})         -> {ok, tab_id, url, title}
//   tabs.create({url, active})            -> {tab_id, url, title}
//   tabs.read_text({tab_id?, max?})       -> {url, title, text, chars, truncated}
//   tabs.read_html({tab_id?, max?})       -> {url, title, html, chars, truncated}
//   tabs.click({tab_id?, selector})       -> {ok, tag, text}              EXACT CSS click
//   tabs.click_text({tab_id?, text, role?}) -> {ok, matched_text, selector}  CLICK BY VISIBLE TEXT
//   tabs.click_idx({tab_id?, idx})        -> {ok, ...}                    CLICK BY snapshot idx
//   tabs.fill({tab_id?, selector, text, submit?}) -> {ok}
//   tabs.fill_text({tab_id?, label, text, submit?}) -> {ok, matched_label}  FILL BY LABEL/PLACEHOLDER
//   tabs.evaluate({tab_id?, code})        -> {result, type}
//   tabs.screenshot({tab_id?})            -> {data_url, width, height}
//   tabs.dom_snapshot({tab_id?, max?})    -> {url, title, elements:[{idx,role,text,label,href,tag,visible}]}
//   tabs.wait_for({tab_id?, selector?, text?, timeout_ms?, visible?}) -> {ok, found, elapsed_ms}
//
// click_text and fill_text are MORE FORGIVING than CSS selectors, they let
// the model click "the Sign in button" without writing a brittle selector.

const BRIDGE_URL = "ws://127.0.0.1:8767/extension";
const RECONNECT_MS = 1000;          // faster reconnect (was 2500)
const KEEPALIVE_MS = 20000;         // ping the WS every 20s to dodge
                                    // Chrome MV3 service-worker idle.
// Single source of truth for the version is manifest.json.
const VERSION = chrome.runtime.getManifest().version;

let ws = null;
let connected = false;
let keepaliveTimer = null;

// Co-use tracking — klo owns a SET of tabs, and the user is the user.
//
// Old model (broken): klo bailed whenever the user activated any tab
// other than the most-recently-navigated one. Switching to a new tab to
// check email, opening a new tab to draft a reply, ANY tab switch
// triggered "I'll let you take it from here" — which made it impossible
// to co-use the computer. Research on shipped agents (Browserbase live
// view, Anthropic Cowork tab groups, OpenClaw profile tinting, Hermes
// session-continuity) makes the principle clear: tab switches are NOT
// takeover, only direct interaction with klo's own tab is.
//
// New model: track every tab klo owns. The takeover signal comes from a
// content-script-injected interaction listener (mousedown/keydown on
// klo's tabs). When a klo-owned tab fires that event AND it's outside
// a "klo just used this" suppression window, THAT counts as the user
// taking the wheel. Everything else — tab switches, window focus
// changes, opening new tabs, using other apps — is just multitasking.
let agentOwnedTabs = new Set();
let agentTaskActive = false;
let agentSafetyTimer = null;
const AGENT_SAFETY_TIMEOUT_MS = 30 * 60 * 1000; // 30 minutes

// "klo just did this" suppression. CDP-driven clicks/keystrokes
// generate isTrusted=true events that look like user input. Before each
// agent-initiated input action, we extend a per-tab grace window. The
// takeover listener compares incoming interaction timestamps against
// this map and ignores events that fall inside any active window.
const KLO_INPUT_GRACE_MS = 1200;
let kloInputGraceUntil = new Map();  // tabId -> epoch ms

function markKloInput(tabId) {
  if (typeof tabId !== "number") return;
  kloInputGraceUntil.set(tabId, Date.now() + KLO_INPUT_GRACE_MS);
}

function withinKloInputGrace(tabId) {
  const until = kloInputGraceUntil.get(tabId);
  if (!until) return false;
  if (Date.now() < until) return true;
  kloInputGraceUntil.delete(tabId);
  return false;
}

// Back-compat shim so any handlers that still want a "current target
// tab" hint (e.g. screenshot defaults) can ask, but takeover logic no
// longer reads it.
let agentLastNavigatedTabId = null;

function clearAgentSafetyTimer() {
  if (agentSafetyTimer) {
    clearTimeout(agentSafetyTimer);
    agentSafetyTimer = null;
  }
}

function armAgentSafetyTimer() {
  // Fallback for runs that don't fire task.end (bridge crash, agent
  // process killed mid-run). 30 minutes is long enough that the longest
  // realistic agent tasks won't truncate but short enough that we
  // recover from a stuck state without requiring a Chrome restart.
  clearAgentSafetyTimer();
  agentSafetyTimer = setTimeout(() => {
    agentTaskActive = false;
    agentLastNavigatedTabId = null;
    agentOwnedTabs.clear();
    kloInputGraceUntil.clear();
    agentSafetyTimer = null;
  }, AGENT_SAFETY_TIMEOUT_MS);
}

// Inject the takeover listener into a freshly-owned tab. The content
// script self-installs once per page; reloads re-inject naturally
// because chrome.scripting.executeScript with a fresh world.
async function attachTakeoverListener(tabId) {
  if (typeof tabId !== "number") return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: __installKloTakeoverListener,
      world: "ISOLATED",
    });
  } catch (_) {
    // Tab might be on a chrome:// page or already closed — silent
    // failure is fine; the takeover detector simply won't run there.
  }
}

// Runs INSIDE the page as a content script. Listens for the user's own
// pointer and keyboard activity on klo-owned tabs and pings the
// background. Throttled so a mouse drag doesn't flood the bridge.
function __installKloTakeoverListener() {
  if (window.__klo_takeover_v1) return;
  window.__klo_takeover_v1 = true;
  let lastFireAt = 0;
  const THROTTLE_MS = 500;
  const fire = (ev) => {
    const now = Date.now();
    if (now - lastFireAt < THROTTLE_MS) return;
    lastFireAt = now;
    try {
      chrome.runtime.sendMessage({
        kind: "klo_user_interacted",
        // Sent for context; the background uses its own grace-window
        // map and per-tab ownership to decide takeover, but the type
        // helps in debug logs.
        eventType: ev?.type || "unknown",
      });
    } catch (_) { /* extension reloaded mid-run — ignore */ }
  };
  // Capture phase + true so page code that swallows events still lets
  // us see them first.
  document.addEventListener("mousedown", fire, true);
  document.addEventListener("keydown", fire, true);
}

function markAgentActivity() {
  // Called from tabsNavigate/tabsCreate as a fallback in case task.begin
  // was missed. Sets agentTaskActive=true (idempotent) and (re-)arms the
  // safety timer.
  agentTaskActive = true;
  armAgentSafetyTimer();
}

function sendEvent(name, payload) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ kind: "event", name, payload: payload || {} }));
    } catch (_) { /* ignore */ }
  }
}

// Inbound events from the bridge. The bridge sends {kind:"event", name,
// payload} frames for run lifecycle so the extension knows precisely
// when a task starts/ends instead of guessing via an idle timer.
function handleInboundEvent(evName, payload) {
  switch (evName) {
    case "task.begin":
      agentTaskActive = true;
      agentLastNavigatedTabId = null; // fresh run — forget prior nav tab
      agentOwnedTabs.clear();         // forget previous run's tabs
      kloInputGraceUntil.clear();
      armAgentSafetyTimer();
      break;
    case "task.end":
      agentTaskActive = false;
      agentLastNavigatedTabId = null;
      agentOwnedTabs.clear();
      kloInputGraceUntil.clear();
      clearAgentSafetyTimer();
      break;
    default:
      /* unknown event — ignore */
      break;
  }
}

// ---------- WebSocket lifecycle ----------

function connect() {
  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;
  try {
    ws = new WebSocket(BRIDGE_URL);
  } catch (e) {
    scheduleReconnect();
    return;
  }
  ws.addEventListener("open", onOpen);
  ws.addEventListener("close", onClose);
  ws.addEventListener("error", onError);
  ws.addEventListener("message", onMessage);
}

function onOpen() {
  connected = true;
  publishStatus();
  ws.send(JSON.stringify({ kind: "hello", version: VERSION, ua: navigator.userAgent }));
  startKeepalive();
}

function onClose() {
  connected = false;
  publishStatus();
  stopKeepalive();
  scheduleReconnect();
}

function onError() {
  /* Logged but otherwise quiet, onClose will trigger reconnect. */
}

function scheduleReconnect() {
  setTimeout(connect, RECONNECT_MS);
}

/**
 * Chrome MV3 service workers idle out after ~30s of no activity. The
 * WebSocket dies with the worker, so the agent's next bridge call hits
 * BridgeNotConnectedError until the worker wakes up + reconnects (which
 * is silent on the agent side — looks like "extension not installed").
 *
 * Two layers of keep-alive:
 *  1. Send a `kind: "keepalive"` frame every 20s while the WS is open —
 *     the sidecar ignores it, but Chrome counts WS traffic as worker
 *     activity and won't idle us out.
 *  2. chrome.alarms wakes the worker every 30s if it does idle out,
 *     and we re-establish the connection eagerly.
 */
function startKeepalive() {
  stopKeepalive();
  keepaliveTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try { ws.send(JSON.stringify({ kind: "keepalive", ts: Date.now() })); } catch (e) { /* ignore */ }
    }
  }, KEEPALIVE_MS);
}

function stopKeepalive() {
  if (keepaliveTimer) {
    clearInterval(keepaliveTimer);
    keepaliveTimer = null;
  }
}

// Worker-wake alarm. Fires every 30s; if the WS dropped (worker was
// killed and recycled, sidecar restarted, network blip) we reconnect
// immediately instead of waiting for the user to send a message.
try {
  chrome.alarms.create("klo-bridge-wake", { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === "klo-bridge-wake" && !connected) {
      connect();
    }
  });
} catch (e) { /* alarms api not available — older Chrome */ }

// Co-use takeover detection. The OLD listeners on chrome.tabs.onActivated
// and chrome.windows.onFocusChanged are DELIBERATELY REMOVED — they
// fired on every incidental tab/window switch, which broke the user's
// ability to multitask. (See the agentOwnedTabs comment block above.)
//
// The NEW signal: content-script-injected mousedown/keydown on a
// klo-owned tab → real user interaction → real takeover. Tab switches,
// opening new tabs, alt-tabbing to Notion, none of these fire takeover.
chrome.runtime.onMessage.addListener((msg, sender, _sendResponse) => {
  if (!msg || msg.kind !== "klo_user_interacted") return;
  if (!agentTaskActive) return;
  const tabId = sender?.tab?.id;
  if (typeof tabId !== "number") return;
  if (!agentOwnedTabs.has(tabId)) return;          // not a klo tab — ignore
  if (withinKloInputGrace(tabId)) return;          // klo's own CDP input — ignore
  sendEvent("user_focus_changed", {
    taken: true,
    to_tab_id: tabId,
    window_id: sender?.tab?.windowId,
    via: "user_interacted",
  });
});

async function onMessage(event) {
  let req;
  try {
    req = JSON.parse(event.data);
  } catch {
    return;
  }
  if (!req) return;
  // Unsolicited events from the bridge (task lifecycle, etc.) come in
  // as {kind:"event", name, payload} frames — no id. Handle and return
  // before the RPC-id check below.
  if (req.kind === "event") {
    handleInboundEvent(req.name, req.payload || {});
    return;
  }
  if (typeof req.id === "undefined") return;
  try {
    const result = await handle(req.method, req.params || {});
    ws.send(JSON.stringify({ id: req.id, result }));
  } catch (err) {
    ws.send(JSON.stringify({ id: req.id, error: String(err && err.message ? err.message : err) }));
  }
}

// ---------- RPC handlers ----------

async function handle(method, params) {
  switch (method) {
    case "ping":
      return { ok: true, version: VERSION, ts: Date.now() };
    case "tabs.list":
      return await tabsList(params);
    case "tabs.active":
      return await tabsActive();
    case "tabs.navigate":
      return await tabsNavigate(params);
    case "tabs.create":
      return await tabsCreate(params);
    case "tabs.read_text":
      return await tabsReadText(params);
    case "tabs.read_html":
      return await tabsReadHtml(params);
    case "tabs.click":
      return await tabsClick(params);
    case "tabs.click_text":
      return await tabsClickText(params);
    case "tabs.click_idx":
      return await tabsClickIdx(params);
    case "tabs.fill":
      return await tabsFill(params);
    case "tabs.fill_text":
      return await tabsFillText(params);
    case "tabs.evaluate":
      return await tabsEvaluate(params);
    case "tabs.screenshot":
      return await tabsScreenshot(params);
    case "tabs.dom_snapshot":
      return await tabsDomSnapshot(params);
    case "tabs.wait_for":
      return await tabsWaitFor(params);
    case "tabs.upload_file":
      return await tabsUploadFile(params);
    case "tabs.real_click":
      return await tabsRealClick(params);
    case "tabs.scroll":
      return await tabsScroll(params);
    case "tabs.find":
      return await tabsFind(params);
    default:
      throw new Error(`unknown method: ${method}`);
  }
}


// ─── CDP-backed primitives (chrome.debugger) ──────────────────────────────────
//
// Two failure modes that synthetic events can't recover from:
//
//   1. <input type=file> with a programmatically-created File (DataTransfer)
//     , browsers refuse to upload it. The CSR upload to Apple's dev portal
//      hit exactly this. Real fix: use CDP's `DOM.setFileInputFiles` which
//      attaches a real on-disk file to the input the same way the OS file
//      picker would.
//
//   2. React submit handlers that gate on "user activation". Synthetic
//      .click() doesn't grant activation; CDP's `Input.dispatchMouseEvent`
//      does (it generates a "trusted" event). Apple's Continue button
//      needed this.
//
// Both require chrome.debugger which displays a yellow "agent2 bridge
// started debugging this browser" banner during use. We attach + immediately
// detach per call so the banner's visible only for the operation duration.

async function _withDebugger(tabId, fn) {
  const target = { tabId };
  let attached = false;
  try {
    await chrome.debugger.attach(target, "1.3");
    attached = true;
    return await fn(target);
  } finally {
    if (attached) {
      try { await chrome.debugger.detach(target); } catch (_) { /* tab may have closed */ }
    }
  }
}

function _cdp(target, method, params) {
  return new Promise((resolve, reject) => {
    chrome.debugger.sendCommand(target, method, params || {}, (result) => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else resolve(result);
    });
  });
}

async function tabsUploadFile(params) {
  const tabId = await resolveTab(params.tab_id);
  const filePath = String(params.file_path || "");
  if (!filePath) throw new Error("file_path required (absolute path on the user's machine)");
  const idx = params.idx != null ? Number(params.idx) : null;
  const selector = params.selector ? String(params.selector) : (idx != null ? `[data-agent2-idx="${idx}"]` : 'input[type=file]');

  return await _withDebugger(tabId, async (target) => {
    // Resolve the document, find the input. CDP DOM ids are tab-scoped
    // and only valid within the lifetime of this debugger session.
    const doc = await _cdp(target, "DOM.getDocument", { depth: -1 });
    const found = await _cdp(target, "DOM.querySelector", {
      nodeId: doc.root.nodeId,
      selector,
    });
    if (!found.nodeId) {
      return { ok: false, error: `no element matched selector ${selector}` };
    }
    await _cdp(target, "DOM.setFileInputFiles", {
      nodeId: found.nodeId,
      files: [filePath],
    });
    return { ok: true, selector, file_path: filePath };
  });
}

async function tabsRealClick(params) {
  const tabId = await resolveTab(params.tab_id);
  const idx = params.idx != null ? Number(params.idx) : null;
  const selector = params.selector ? String(params.selector) : (idx != null ? `[data-agent2-idx="${idx}"]` : null);
  if (!selector) throw new Error("idx or selector required");

  return await _withDebugger(tabId, async (target) => {
    // Find the element + its bounding box via CDP.
    const doc = await _cdp(target, "DOM.getDocument", { depth: -1 });
    const found = await _cdp(target, "DOM.querySelector", {
      nodeId: doc.root.nodeId,
      selector,
    });
    if (!found.nodeId) {
      return { ok: false, error: `no element matched ${selector}` };
    }
    // Scroll into view first
    await _cdp(target, "DOM.scrollIntoViewIfNeeded", { nodeId: found.nodeId });
    const box = await _cdp(target, "DOM.getBoxModel", { nodeId: found.nodeId });
    const content = box.model.content;
    // content is [x1,y1,x2,y2,x3,y3,x4,y4], center is the average
    const cx = (content[0] + content[4]) / 2;
    const cy = (content[1] + content[5]) / 2;
    // Dispatch trusted mouse events. These count as user activation, so
    // file uploads / form submits / popup-opens that synthetic events
    // can't trigger will go through.
    const opts = { type: "mousePressed", x: cx, y: cy, button: "left", clickCount: 1, buttons: 1 };
    await _cdp(target, "Input.dispatchMouseEvent", opts);
    await _cdp(target, "Input.dispatchMouseEvent", { ...opts, type: "mouseReleased" });
    return { ok: true, selector, x: cx, y: cy };
  });
}

async function tabsList(params) {
  const opts = {};
  if (params && params.current_window) opts.currentWindow = true;
  const tabs = await chrome.tabs.query(opts);
  return tabs.map(t => ({
    id: t.id,
    title: t.title,
    url: t.url,
    active: t.active,
    windowId: t.windowId,
    pinned: t.pinned,
    incognito: t.incognito,
  }));
}

async function tabsActive() {
  // Try the focused window first, then fall back to lastFocusedWindow.
  // When a request originates from the side panel, the side panel has
  // focus and `currentWindow: true` may not match a normal browser
  // window — chrome.tabs.query returns []. lastFocusedWindow is the
  // last *normal* window, which is exactly what the user means by
  // "the tab I'm working on".
  let tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length) {
    tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  }
  if (!tabs.length) {
    // Last resort: any active tab in any normal window.
    tabs = await chrome.tabs.query({ active: true, windowType: "normal" });
  }
  const tab = tabs[0];
  if (!tab) throw new Error("no active tab found in any window");
  return { id: tab.id, title: tab.title, url: tab.url, windowId: tab.windowId };
}

async function tabsNavigate(params) {
  const url = String(params.url || "");
  if (!url) throw new Error("url required");
  const tabId = await resolveTab(params.tab_id);
  // NOTE: the old "user_has_focus" pre-emptive refusal was removed in
  // the co-use rewire. It assumed any tab switch meant the user moved
  // on, which made klo unusable while the user multitasked. Real
  // takeover is now detected via the content-script interaction
  // listener on klo-owned tabs (see attachTakeoverListener). klo
  // navigates its tabs freely; the user can take over by actually
  // clicking or typing in klo's tab.
  // Activate the tab AND focus its window so the user actually sees
  // klo doing its thing. Without these the navigation happens in the
  // background — bad UX because the user thinks nothing's happening.
  await chrome.tabs.update(tabId, { url, active: true });
  const tab = await chrome.tabs.get(tabId);
  if (tab.windowId != null) {
    try { await chrome.windows.update(tab.windowId, { focused: true }); } catch (e) { /* ignore */ }
  }
  agentLastNavigatedTabId = tabId;
  agentOwnedTabs.add(tabId);
  markAgentActivity();
  await waitForTabComplete(tabId, 15000);
  // After load, attach the takeover listener — this is the signal that
  // tells us when the user actually starts driving this tab.
  attachTakeoverListener(tabId);
  const updated = await chrome.tabs.get(tabId);
  return { ok: true, tab_id: tabId, url: updated.url, title: updated.title };
}

async function tabsCreate(params) {
  const url = String(params.url || "about:blank");
  // The old pre-emptive "user_has_focus" refusal was removed in the
  // co-use rewire — see tabsNavigate above for the rationale. klo
  // creates tabs freely; takeover detection on its tabs covers the
  // real "user took the wheel" case.
  const tab = await chrome.tabs.create({ url, active: params.active !== false });
  // Bring the window to the front too — chrome.tabs.create(active:true)
  // only marks it active within its window; if Chrome is in the
  // background that window stays behind. Match tabsNavigate's UX.
  if (tab.windowId != null && params.active !== false) {
    try { await chrome.windows.update(tab.windowId, { focused: true }); } catch (e) { /* ignore */ }
  }
  agentLastNavigatedTabId = tab.id;
  agentOwnedTabs.add(tab.id);
  markAgentActivity();
  if (url !== "about:blank") {
    await waitForTabComplete(tab.id, 15000);
  }
  attachTakeoverListener(tab.id);
  const fresh = await chrome.tabs.get(tab.id);
  return { tab_id: tab.id, url: fresh.url, title: fresh.title };
}

async function tabsReadText(params) {
  const tabId = await resolveTab(params.tab_id);
  const max = Number(params.max || 12000);
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (cap) => {
      const text = (document.body && document.body.innerText) || "";
      return {
        url: location.href,
        title: document.title,
        text: text.length > cap ? text.slice(0, cap) + `\n…[truncated, ${text.length} chars]` : text,
        truncated: text.length > cap,
        chars: text.length,
      };
    },
    args: [max],
  });
  return out.result;
}

async function tabsReadHtml(params) {
  const tabId = await resolveTab(params.tab_id);
  const max = Number(params.max || 30000);
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (cap) => {
      const html = document.documentElement.outerHTML || "";
      return {
        url: location.href,
        title: document.title,
        html: html.length > cap ? html.slice(0, cap) + `<!-- truncated, ${html.length} chars -->` : html,
        truncated: html.length > cap,
        chars: html.length,
      };
    },
    args: [max],
  });
  return out.result;
}

async function tabsClick(params) {
  const tabId = await resolveTab(params.tab_id);
  const selector = String(params.selector || "");
  if (!selector) throw new Error("selector required");
  markKloInput(tabId);  // CDP click is isTrusted=true; suppress takeover
  return await _runClick(tabId, "selector", { selector });
}

async function tabsClickText(params) {
  const tabId = await resolveTab(params.tab_id);
  const text = String(params.text || "").trim();
  const role = params.role ? String(params.role).toLowerCase() : null;
  if (!text) throw new Error("text required");
  markKloInput(tabId);
  return await _runClick(tabId, "text", { text, role });
}

async function tabsClickIdx(params) {
  const tabId = await resolveTab(params.tab_id);
  const idx = Number(params.idx);
  if (!Number.isFinite(idx)) throw new Error("idx required (integer)");
  markKloInput(tabId);

  // Step 1: re-snapshot the page so data-agent2-idx attributes are
  // fresh. React/SPA re-renders blow away these attributes between
  // turns; tagging right before the click ensures the idx selector
  // resolves to the same element the model saw in PAGE INTERACTIVES.
  const [snapOut] = await chrome.scripting.executeScript({
    target: { tabId },
    func: domSnapshot,
    args: [200],
  });
  const snap = snapOut && snapOut.result;
  const targetEl = snap && Array.isArray(snap.elements)
    ? snap.elements.find(e => e.idx === idx)
    : null;
  if (!targetEl) {
    throw new Error(`no visible element at idx ${idx} (snapshot has ${snap && snap.count || 0})`);
  }

  // Step 2: PRIMARY PATH — CDP-based real mouse click via chrome.debugger.
  // Produces an isTrusted=true MouseEvent the page's JS receives as a
  // real user click. This is what nanobrowser, browser-use, Skyvern and
  // every shipped browser-agent uses — the only mechanism MV3 extensions
  // have to emit trusted events. el.click() in MAIN world is isTrusted:
  // false and SPA routers / popup blockers / strict handlers ignore it.
  const selector = `[data-agent2-idx="${idx}"]`;
  try {
    const r = await tabsRealClick({ tab_id: tabId, selector });
    if (r && r.ok) {
      // Wait briefly for the page to react. Many SPAs replace the DOM
      // synchronously, but routers + network calls need a moment.
      await new Promise(res => setTimeout(res, 200));
      const updated = await chrome.tabs.get(tabId).catch(() => null);
      return {
        ok: true,
        idx,
        tag: targetEl.tag,
        text: targetEl.text,
        url: updated && updated.url,
        title: updated && updated.title,
      };
    }
  } catch (e) {
    console.warn(`[klo] CDP click failed, falling back to MAIN-world click:`, e && e.message);
  }

  // Step 3: FALLBACK — el.click() in MAIN world. Only reached if
  // chrome.debugger refused to attach (another debugger already on the
  // tab, restricted page, etc). isTrusted=false but covers the
  // common-enough case where the framework doesn't gate on trust.
  const [clickOut] = await chrome.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    func: (sel) => {
      const el = document.querySelector(sel);
      if (!el) return { ok: false, error: `selector ${sel} not in DOM` };
      try {
        el.scrollIntoView({ block: "center" });
        el.focus && el.focus();
        el.click();
        return { ok: true, tag: el.tagName, text: (el.innerText || el.value || "").slice(0, 100) };
      } catch (err) {
        return { ok: false, error: String(err) };
      }
    },
    args: [selector],
  });
  const r = clickOut && clickOut.result;
  if (!r || !r.ok) throw new Error((r && r.error) || "click failed (both CDP and JS)");
  return { ok: true, idx, fallback: "main_world_click", ...r };
}

async function _runClick(tabId, mode, params) {
  // Single self-contained injected function, no external references.
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    func: _injectedClick,
    args: [mode, params],
  });
  const out = result && result[0];
  if (!out || !out.result) {
    throw new Error("executeScript returned no result (page may be a chrome:// URL or restricted)");
  }
  if (!out.result.ok) throw new Error(out.result.error || "click failed");
  return out.result;
}

// Self-contained: this is what gets injected. NO references to outer scope.
function _injectedClick(mode, params) {
  const norm = (s) => (s || "").trim().toLowerCase().replace(/\s+/g, " ");

  const doClick = (el, label) => {
    try { el.scrollIntoView({ block: "center", inline: "center" }); } catch (_) {}
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) {
      return { ok: false, error: `element matched but has zero size: ${label}` };
    }
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    const opts = { bubbles: true, cancelable: true, view: window, button: 0, clientX: x, clientY: y };
    el.dispatchEvent(new MouseEvent("mouseover", opts));
    el.dispatchEvent(new MouseEvent("mousedown", opts));
    el.focus && el.focus();
    el.dispatchEvent(new MouseEvent("mouseup", opts));
    el.dispatchEvent(new MouseEvent("click", opts));
    if (typeof el.click === "function") {
      try { el.click(); } catch (_) {}
    }
    return { ok: true, tag: el.tagName, text: (el.innerText || el.value || "").slice(0, 200), label };
  };

  // Re-enumerate interactive elements live — same selector as buildInteractivesContext.
  // This is more reliable than looking up a stale data-agent2-idx attribute that may
  // have been cleared by a React/framework re-render between snapshot and click.
  const getInteractiveElements = () => {
    const sel = "a[href], button, input, textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [role=textbox], [role=combobox], [role=checkbox], [role=switch], [role=option], summary, [tabindex]:not([tabindex='-1'])";
    const seen = new Set();
    const out = [];
    for (const el of document.querySelectorAll(sel)) {
      if (seen.has(el)) continue;
      seen.add(el);
      const rect = el.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0 && el.offsetParent !== null) {
        const text = ((el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("placeholder") || "") + "").trim();
        if (text) out.push(el);
      }
    }
    return out;
  };

  if (mode === "selector") {
    const el = document.querySelector(params.selector);
    if (!el) return { ok: false, error: `not found: ${params.selector}` };
    return doClick(el, params.selector);
  }

  if (mode === "idx") {
    // Try the tagged attribute first (fast path), fall back to live re-enumeration.
    let el = document.querySelector(`[data-agent2-idx="${params.idx}"]`);
    if (!el) {
      const elems = getInteractiveElements();
      el = elems[params.idx] || null;
    }
    if (!el) return { ok: false, error: `no element at idx ${params.idx} (tried attribute + live re-enumeration)` };
    return doClick(el, `idx:${params.idx}`);
  }

  if (mode === "text") {
    const target = norm(params.text);
    const role = params.role || null;
    const interactive = "a, button, [role=button], [role=link], [role=tab], [role=menuitem], input[type=submit], input[type=button], input[type=image], summary, label";
    const candidates = Array.from(document.querySelectorAll(interactive));
    const score = (el) => {
      const t = norm(el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt"));
      if (!t) return -1;
      if (role) {
        const r = (el.getAttribute("role") || "").toLowerCase();
        const tag = el.tagName.toLowerCase();
        const matches = r === role
                     || (role === "button" && (tag === "button" || (tag === "input" && /^(submit|button)$/i.test(el.type))))
                     || (role === "link" && tag === "a");
        if (!matches) return -1;
      }
      if (t === target) return 100;
      if (t.startsWith(target)) return 80;
      if (t.includes(target)) return 60;
      return -1;
    };
    let best = null, bestScore = 0;
    for (const el of candidates) {
      const s = score(el);
      if (s > bestScore) { best = el; bestScore = s; }
    }
    if (!best) return { ok: false, error: `no clickable element matching ${JSON.stringify(params.text)} (role=${role ?? "any"})` };
    const matched_text = (best.innerText || best.value || best.getAttribute("aria-label") || "").trim().slice(0, 200);
    const result = doClick(best, matched_text);
    if (!result.ok) return result;
    return { ...result, matched_text };
  }

  return { ok: false, error: `unknown click mode: ${mode}` };
}

async function tabsFillText(params) {
  const tabId = await resolveTab(params.tab_id);
  const label = String(params.label || "").trim();
  const text = String(params.text || "");
  const submit = !!params.submit;
  if (!label) throw new Error("label required");
  markKloInput(tabId);  // suppress takeover during klo's own keystrokes
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: fillByLabel,
    args: [label, text, submit],
  });
  if (!out.result.ok) throw new Error(out.result.error);
  return out.result;
}

async function tabsDomSnapshot(params) {
  const tabId = await resolveTab(params.tab_id);
  const max = Number(params.max || 100);
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: domSnapshot,
    args: [max],
  });
  return out.result;
}

async function tabsWaitFor(params) {
  const tabId = await resolveTab(params.tab_id);
  const selector = params.selector ? String(params.selector) : null;
  const text = params.text ? String(params.text) : null;
  const visible = params.visible !== false; // default true
  const timeoutMs = Math.max(100, Math.min(20000, Number(params.timeout_ms || 12000)));
  if (!selector && !text) throw new Error("selector or text required");
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: waitFor,
    args: [selector, text, visible, timeoutMs],
  });
  const result = out.result || {};
  // Enrich timeouts with the current page state so the model has fresh
  // evidence to adapt without an extra round-trip. The bare error string
  // alone trains the model to give up; a snapshot lets it pick a
  // structurally different approach (different selector, click_text,
  // press Enter, ask the user) within the same turn.
  if (!result.ok) {
    try {
      const [snap] = await chrome.scripting.executeScript({
        target: { tabId },
        func: domSnapshot,
        args: [40],
      });
      if (snap && snap.result) {
        result.snapshot_after_timeout = snap.result;
      }
    } catch (_) {
      // best-effort, if the tab is gone or scripting fails, return the
      // raw timeout error rather than masking it
    }
  }
  return result;
}

// ---- in-page functions (run via chrome.scripting; cannot reference outer scope) ----

// Each in-page function below is self-contained, chrome.scripting.executeScript
// only injects the named func, NOT any helpers referenced from outer scope.
// So performClick is inlined inside each click variant.

function clickElementBySelector(sel) {
  const el = document.querySelector(sel);
  if (!el) return { ok: false, error: `not found: ${sel}` };
  return _agent2_doClick(el, sel);
}

function clickByText(text, role) {
  const norm = (s) => (s || "").trim().toLowerCase().replace(/\s+/g, " ");
  const target = norm(text);
  const interactive = "a, button, [role=button], [role=link], [role=tab], [role=menuitem], input[type=submit], input[type=button], input[type=image], summary, label";
  const candidates = Array.from(document.querySelectorAll(interactive));
  const score = (el) => {
    const t = norm(el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt"));
    if (!t) return -1;
    if (role) {
      const r = (el.getAttribute("role") || "").toLowerCase();
      const tag = el.tagName.toLowerCase();
      const matches = r === role || (role === "button" && (tag === "button" || (tag === "input" && /^(submit|button)$/i.test(el.type))))
                                || (role === "link" && tag === "a");
      if (!matches) return -1;
    }
    if (t === target) return 100;
    if (t.startsWith(target)) return 80;
    if (t.includes(target)) return 60;
    return -1;
  };
  let best = null, bestScore = 0;
  for (const el of candidates) {
    const s = score(el);
    if (s > bestScore) { best = el; bestScore = s; }
  }
  if (!best) {
    const all = document.body ? document.body.querySelectorAll("*") : [];
    for (const el of all) {
      const t = norm(el.innerText);
      if (t && t === target) { best = el; bestScore = 50; break; }
    }
  }
  if (!best) return { ok: false, error: `no clickable element matching ${JSON.stringify(text)} (role=${role ?? "any"})` };
  const matched_text = (best.innerText || best.value || best.getAttribute("aria-label") || "").trim().slice(0, 200);
  const result = _agent2_doClick(best, matched_text);
  if (!result.ok) return result;
  return { ...result, matched_text };
}

function clickByIdx(idx) {
  const el = document.querySelector(`[data-agent2-idx="${idx}"]`);
  if (!el) return { ok: false, error: `no element at idx ${idx}, call tabs.dom_snapshot first (it tags elements with data-agent2-idx)` };
  return _agent2_doClick(el, `idx:${idx}`);
}

// Defined as a top-level function (NOT a free closure) so that when chrome.scripting
// injects clickByText / clickByIdx / clickElementBySelector, the page can also see
// _agent2_doClick, IF we inject it alongside. Since executeScript only injects the
// named func, we instead inline this logic into each caller. To avoid duplication,
// we pull a small helper defined as a string and eval'd inside each function.
//
// In practice: each click variant calls `_agent2_doClick(el, label)` which we define
// HERE as a sibling of the click variants and which is ALSO injected separately
// the first time we see we need it. To keep things simple and reliable, we inline
// the body in each click variant.
function _agent2_doClick(el, label) {
  try {
    el.scrollIntoView({ block: "center", inline: "center" });
  } catch (_) {}
  const rect = el.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) {
    return { ok: false, error: `element matched but has zero size: ${label}` };
  }
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  const opts = { bubbles: true, cancelable: true, view: window, button: 0, clientX: x, clientY: y };
  el.dispatchEvent(new MouseEvent("mouseover", opts));
  el.dispatchEvent(new MouseEvent("mousedown", opts));
  el.focus && el.focus();
  el.dispatchEvent(new MouseEvent("mouseup", opts));
  el.dispatchEvent(new MouseEvent("click", opts));
  if (typeof el.click === "function") {
    try { el.click(); } catch (_) {}
  }
  return { ok: true, tag: el.tagName, text: (el.innerText || el.value || "").slice(0, 200), label };
}

function fillByLabel(label, value, submit) {
  const norm = (s) => (s || "").trim().toLowerCase().replace(/\s+/g, " ");
  const target = norm(label);
  const candidates = Array.from(document.querySelectorAll("input, textarea, [contenteditable=true], [role=textbox], [role=combobox]"));
  const labelMatch = (el) => {
    const candidates = [
      el.getAttribute("aria-label"),
      el.getAttribute("placeholder"),
      el.getAttribute("name"),
      el.getAttribute("id"),
      el.getAttribute("title"),
    ];
    if (el.id) {
      const lbl = document.querySelector(`label[for=${CSS.escape(el.id)}]`);
      if (lbl) candidates.push(lbl.innerText);
    }
    const closestLabel = el.closest && el.closest("label");
    if (closestLabel) candidates.push(closestLabel.innerText);
    const ariaLabelledBy = el.getAttribute("aria-labelledby");
    if (ariaLabelledBy) {
      ariaLabelledBy.split(/\s+/).forEach(id => {
        const lbl = document.getElementById(id);
        if (lbl) candidates.push(lbl.innerText);
      });
    }
    for (const c of candidates) {
      const n = norm(c);
      if (!n) continue;
      if (n === target) return 100;
      if (n.includes(target)) return 60;
    }
    return -1;
  };
  let best = null, bestScore = 0;
  for (const el of candidates) {
    const s = labelMatch(el);
    if (s > bestScore) { best = el; bestScore = s; }
  }
  if (!best) return { ok: false, error: `no input matching label ${JSON.stringify(label)}` };
  best.scrollIntoView({ block: "center" });
  best.focus();
  if (best.tagName === "INPUT" || best.tagName === "TEXTAREA") {
    const proto = best.tagName === "INPUT" ? window.HTMLInputElement.prototype : window.HTMLTextAreaElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    setter ? setter.call(best, value) : (best.value = value);
    best.dispatchEvent(new Event("input", { bubbles: true }));
    best.dispatchEvent(new Event("change", { bubbles: true }));
  } else if (best.isContentEditable) {
    best.textContent = value;
    best.dispatchEvent(new Event("input", { bubbles: true }));
  }
  if (submit) {
    const form = best.closest && best.closest("form");
    if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
    else best.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, code: "Enter", keyCode: 13, which: 13 }));
  }
  return {
    ok: true,
    matched_label: best.getAttribute("aria-label") || best.getAttribute("placeholder") || best.getAttribute("name") || best.getAttribute("id") || "",
    tag: best.tagName,
  };
}

function domSnapshot(max) {
  // Clear any previous snapshot tags first.
  document.querySelectorAll("[data-agent2-idx]").forEach(el => el.removeAttribute("data-agent2-idx"));

  const interactive = Array.from(document.querySelectorAll(
    "a[href], button, input, textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [role=textbox], [role=combobox], [role=checkbox], [role=switch], [role=option], summary, label, [tabindex]:not([tabindex='-1'])"
  ));
  const seen = new Set();
  const out = [];
  for (const el of interactive) {
    if (seen.has(el)) continue;
    seen.add(el);
    const rect = el.getBoundingClientRect();
    // offsetParent===null for position:fixed elements (sticky navs, tab bars)
    // so use viewport intersection as the primary check instead.
    const visible = rect.width > 0 && rect.height > 0 &&
      rect.bottom > 0 && rect.top < (window.innerHeight || 800);
    if (!visible) continue;
    const text = ((el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("placeholder") || "") + "")
      .trim().replace(/\s+/g, " ").slice(0, 120);
    if (!text) continue;
    const idx = out.length;
    // Tag the element so click_idx can find it later, survives across
    // executeScript calls because it lives on the DOM, not in JS scope.
    try { el.setAttribute("data-agent2-idx", String(idx)); } catch (_) {}
    out.push({
      idx,
      tag: el.tagName.toLowerCase(),
      role: (el.getAttribute("role") || el.tagName.toLowerCase() === "a" ? "link" : el.tagName.toLowerCase() === "button" ? "button" : (el.tagName.toLowerCase() === "input" ? `input[${el.type}]` : el.tagName.toLowerCase())),
      text,
      label: el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.getAttribute("name") || null,
      href: el.getAttribute("href") || null,
      type: el.getAttribute("type") || null,
      checked: typeof el.checked === "boolean" ? el.checked : null,
      box: { x: Math.round(rect.left), y: Math.round(rect.top), w: Math.round(rect.width), h: Math.round(rect.height) },
    });
    if (out.length >= max) break;
  }
  return {
    url: location.href,
    title: document.title,
    count: out.length,
    elements: out,
  };
}

async function waitFor(selector, text, visible, timeoutMs) {
  const start = Date.now();
  const norm = (s) => (s || "").trim().toLowerCase().replace(/\s+/g, " ");
  const target = text ? norm(text) : null;
  const isVis = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 && el.offsetParent !== null;
  };
  while (true) {
    let found = null;
    if (selector) {
      found = document.querySelector(selector);
    } else if (target) {
      const all = document.body ? document.body.querySelectorAll("*") : [];
      for (const el of all) {
        if (norm(el.innerText) === target || (norm(el.innerText).includes(target) && el.children.length < 3)) {
          found = el;
          break;
        }
      }
    }
    if (found && (!visible || isVis(found))) {
      return { ok: true, found: true, elapsed_ms: Date.now() - start };
    }
    if (Date.now() - start > timeoutMs) {
      return { ok: false, found: false, elapsed_ms: Date.now() - start, error: `timeout after ${timeoutMs}ms waiting for ${selector ?? text}` };
    }
    await new Promise(r => setTimeout(r, 200));
  }
}

async function tabsFill(params) {
  const tabId = await resolveTab(params.tab_id);
  const selector = String(params.selector || "");
  const text = String(params.text || "");
  const submit = !!params.submit;
  if (!selector) throw new Error("selector required");
  markKloInput(tabId);
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (sel, value, doSubmit) => {
      const el = document.querySelector(sel);
      if (!el) return { ok: false, error: `not found: ${sel}` };
      el.focus();
      // Detect the "multi-line value into a single-line <input>" trap.
      // HTML's single-line input strips CR/LF via the value sanitization
      // algorithm, so the paste silently loses every line after the
      // first. Return a structured error instead of silently corrupting
      // the value — the agent can recover by looking for a textarea,
      // base64-encoding, or routing through the shell / API.
      const hasNewline = /[\r\n]/.test(value);
      if (hasNewline) {
        const isSingleLineInput = el.tagName === "INPUT" &&
          String(el.type || "text").toLowerCase() !== "textarea" &&
          el.tagName !== "TEXTAREA" && !el.isContentEditable;
        if (isSingleLineInput) {
          return {
            ok: false,
            error: "multi-line value into single-line <input>: newlines would be silently stripped. Look for a <textarea> field, or route this value through the shell / direct API.",
            error_code: "single_line_input_multiline_value",
            input_tag: el.tagName,
            input_type: String(el.type || ""),
            value_lines: value.split("\n").length,
          };
        }
      }
      if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")?.set
                    || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")?.set;
        setter ? setter.call(el, value) : (el.value = value);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      } else if (el.isContentEditable) {
        el.textContent = value;
        el.dispatchEvent(new Event("input", { bubbles: true }));
      } else {
        return { ok: false, error: `${el.tagName} is not editable` };
      }
      if (doSubmit) {
        const form = el.closest && el.closest("form");
        if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
        else el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, code: "Enter" }));
      }
      return { ok: true };
    },
    args: [selector, text, submit],
  });
  if (!out.result.ok) {
    const err = new Error(out.result.error);
    if (out.result.error_code) err.code = out.result.error_code;
    throw err;
  }
  return out.result;
}

async function tabsEvaluate(params) {
  const tabId = await resolveTab(params.tab_id);
  const code = String(params.code || "");
  if (!code) throw new Error("code required");
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    world: "MAIN",
    func: (src) => {
      try {
        // eslint-disable-next-line no-new-func
        const fn = new Function(`return (async () => { return (${src}); })();`);
        return Promise.resolve(fn()).then(v => ({ ok: true, result: v, type: typeof v }))
                                    .catch(e => ({ ok: false, error: String(e && e.message ? e.message : e) }));
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    },
    args: [code],
  });
  if (!out.result.ok) throw new Error(out.result.error);
  return { result: out.result.result, type: out.result.type };
}

async function tabsScreenshot(params) {
  // Two paths:
  //   1) native chrome.tabs.captureVisibleTab, fast, captures everything,
  //      but requires either activeTab grant (user invoked the extension)
  //      OR matching host_permissions. Some browsers/forks enforce activeTab
  //      strictly, so we treat it as best-effort.
  //   2) DOM-to-canvas via html2canvas, works without any user gesture, only
  //      needs scripting + host_permissions, captures rendered DOM. Misses
  //      browser chrome and cross-origin iframes but covers ~95% of need.

  // Try native first.
  try {
    const dataUrl = await chrome.tabs.captureVisibleTab(undefined, { format: "png" });
    if (dataUrl) {
      return { data_url: dataUrl, method: "captureVisibleTab" };
    }
  } catch (e) {
    // Fall through to canvas path.
  }

  // Canvas path. Inject html2canvas and the helper into the target tab.
  const tabId = await resolveTab(params && params.tab_id);
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["lib/html2canvas.min.js"],
  });
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    files: ["lib/screenshot_inject.js"],
  });
  const out = result && result[0] && result[0].result;
  if (!out || !out.ok) {
    throw new Error((out && out.error) || "screenshot fallback failed (canvas render returned no result)");
  }
  return { data_url: out.data_url, width: out.width, height: out.height, method: out.method };
}

// Natural-language element finder. Adapted from the BrowseAgent
// project's `findByDescription` (KazKozDev/browser-agent-chrome-extension,
// MIT). Score-based fuzzy match across innerText + aria-label +
// placeholder + title + alt + name + id + class. Returns top 10
// ranked candidates already tagged with data-agent2-idx so the
// model can hand the idx straight to tabs_click_idx — no separate
// dom_snapshot needed for "click the X" prompts. This is the
// preferred path now; dom_snapshot is the fallback for cases where
// the user wants to see ALL interactive elements.
async function tabsFind(params) {
  const tabId = await resolveTab(params.tab_id);
  const query = String(params.query || "").trim();
  if (!query) return { ok: false, error: "query required" };
  const max = Math.min(Math.max(Number(params.max || 10), 1), 25);
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (q, maxResults) => {
      // All helpers self-contained inside the injected function.
      function getRole(el) {
        const r = el.getAttribute("role");
        if (r) return r;
        const t = el.tagName.toLowerCase();
        if (t === "input") {
          const type = (el.type || "text").toLowerCase();
          if (type === "checkbox") return "checkbox";
          if (type === "radio") return "radio";
          if (type === "submit" || type === "button") return "button";
          if (type === "search") return "searchbox";
          return "textbox";
        }
        const map = {
          a: "link", button: "button", select: "combobox", textarea: "textbox",
          img: "image", h1: "heading", h2: "heading", h3: "heading",
          nav: "navigation", main: "main", form: "form", table: "table",
          li: "listitem", dialog: "dialog", summary: "button",
        };
        return map[t] || null;
      }
      function isVisible(el) {
        if (!el || el.nodeType !== 1) return false;
        const cs = getComputedStyle(el);
        if (cs.display === "none" || cs.visibility === "hidden") return false;
        if (parseFloat(cs.opacity || "1") === 0) return false;
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) return false;
        return true;
      }
      function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
      function wholeWord(text, word) {
        const w = String(word || "").trim();
        if (!w) return false;
        try {
          return new RegExp(`(^|[^\\p{L}\\p{N}_])${escRe(w)}([^\\p{L}\\p{N}_]|$)`, "iu").test(text);
        } catch { return false; }
      }

      const lowerQ = q.toLowerCase();
      const words = lowerQ.split(/\s+/).filter(Boolean);
      const candidates = [];
      // Use a reserved idx range so we don't collide with any recent
      // tabs_dom_snapshot (which starts at 0). 9000+ is the find range.
      let idxBase = 9000;
      // Find existing max in that range so successive find calls are unique.
      document.querySelectorAll("[data-agent2-idx]").forEach((el) => {
        const v = parseInt(el.getAttribute("data-agent2-idx"), 10);
        if (Number.isFinite(v) && v >= 9000 && v >= idxBase) idxBase = v + 1;
      });

      const sel = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [onclick], [tabindex]:not([tabindex="-1"])';
      document.querySelectorAll(sel).forEach((el) => {
        if (!isVisible(el)) return;
        const text = (
          (el.innerText || "") + " " +
          (el.getAttribute("aria-label") || "") + " " +
          (el.getAttribute("placeholder") || "") + " " +
          (el.getAttribute("title") || "") + " " +
          (el.getAttribute("alt") || "") + " " +
          (el.getAttribute("name") || "") + " " +
          (el.getAttribute("id") || "") + " " +
          (typeof el.className === "string" ? el.className : "")
        ).toLowerCase().trim();
        if (!text) return;

        let score = 0;
        if (text.includes(lowerQ)) score += 10;
        const matched = words.filter((w) => text.includes(w));
        if (matched.length === 0) return;
        score += (matched.length / words.length) * 5;
        for (const w of matched) if (wholeWord(text, w)) score += 1;
        score += Math.max(0, 3 - text.length / 100);

        // Tag with idx so tabs_click_idx works on the result directly.
        let idx = parseInt(el.getAttribute("data-agent2-idx") || "", 10);
        if (!Number.isFinite(idx)) {
          idx = idxBase++;
          try { el.setAttribute("data-agent2-idx", String(idx)); } catch (_) {}
        }
        const rect = el.getBoundingClientRect();
        candidates.push({
          idx,
          tag: el.tagName.toLowerCase(),
          role: getRole(el),
          text: (el.innerText || "").trim().slice(0, 80),
          aria: (el.getAttribute("aria-label") || "").slice(0, 80),
          placeholder: (el.getAttribute("placeholder") || "").slice(0, 60),
          score: Math.round(score * 100) / 100,
          visible: rect.top >= 0 && rect.top < (window.innerHeight || 9999),
        });
      });

      candidates.sort((a, b) => b.score - a.score);
      return { ok: true, query: q, results: candidates.slice(0, maxResults) };
    },
    args: [query, max],
  });
  return out.result;
}

// Scroll to bring an element into view. Targets accept idx (from a
// recent dom_snapshot — preferred), CSS selector, or visible text.
// Use before clicking when the agent isn't sure the element is in
// the viewport, or to scroll to the bottom for "load more" patterns.
async function tabsScroll(params) {
  const tabId = await resolveTab(params.tab_id);
  const idx = params.idx != null ? Number(params.idx) : null;
  const selector = params.selector ? String(params.selector) : null;
  const text = params.text ? String(params.text) : null;
  const direction = params.direction || null;  // "top", "bottom", null (= to element)
  const [out] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (idx, sel, txt, direction) => {
      if (direction === "top") {
        window.scrollTo({ top: 0, behavior: "smooth" });
        return { ok: true, scrolled_to: "top" };
      }
      if (direction === "bottom") {
        window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
        return { ok: true, scrolled_to: "bottom" };
      }
      let el = null;
      if (idx != null) el = document.querySelector(`[data-agent2-idx="${idx}"]`);
      if (!el && sel) el = document.querySelector(sel);
      if (!el && txt) {
        const lower = txt.toLowerCase();
        const candidates = document.querySelectorAll("a, button, [role=button], h1, h2, h3, h4, label, summary");
        for (const c of candidates) {
          const t = (c.innerText || c.textContent || "").trim().toLowerCase();
          if (t && t.includes(lower)) { el = c; break; }
        }
      }
      if (!el) return { ok: false, error: "no element matched" };
      el.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
      return { ok: true, scrolled_to: el.tagName };
    },
    args: [idx, selector, text, direction],
  });
  return out.result;
}

// ---------- helpers ----------

async function resolveTab(tabId) {
  if (tabId && tabId > 0) return tabId;
  // Same fallback chain as tabsActive(): when a request originates from
  // the side panel, currentWindow may resolve to no normal window.
  // lastFocusedWindow is what the user actually means by "my tab".
  let tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length) tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tabs.length) tabs = await chrome.tabs.query({ active: true, windowType: "normal" });
  const tab = tabs[0];
  if (!tab) throw new Error("no active tab to act on");
  return tab.id;
}

function waitForTabComplete(tabId, timeoutMs) {
  return new Promise((resolve) => {
    const start = Date.now();
    const check = () => {
      chrome.tabs.get(tabId, (t) => {
        if (chrome.runtime.lastError) return resolve();
        if (t && t.status === "complete") return resolve();
        if (Date.now() - start > timeoutMs) return resolve();
        setTimeout(check, 200);
      });
    };
    check();
  });
}

function publishStatus() {
  chrome.storage.local.set({
    bridge: {
      connected,
      bridge_url: BRIDGE_URL,
      version: VERSION,
      updated_at: Date.now(),
    },
  });
  // Best-effort message to side panel; ignore if no listener.
  try {
    chrome.runtime.sendMessage({ kind: "bridge_status", connected });
  } catch (_) {}
}

// ---------- bootstrap ----------

// The overlay content script is injected ON DEMAND (no manifest
// content_scripts entry), so idle browsing carries zero klo JS.
// Injection paths:
//   - toggleKloOnActiveTab() — ⌥K / toolbar click.
//   - tabs.onUpdated/onActivated below — while the panel is open
//     (klo_panel_open), so the panel follows navigations and tab
//     switches like the old always-injected behavior.
//   - reinjectOverlayIntoOpenTabs() — extension reload/update with the
//     panel open, so open tabs don't keep an orphaned script.
// lib/composio.js goes first: overlay.js reads window.Composio from
// the shared isolated world.
const OVERLAY_FILES = ["lib/composio.js", "overlay/overlay.js"];

function isInjectableUrl(url) {
  return !!url && (url.startsWith("http://") || url.startsWith("https://"));
}

async function injectOverlay(tabId) {
  // Idempotent: overlay.js bails if the same version is already
  // mounted on the page (window.__klo_overlay_v guard).
  await chrome.scripting.executeScript({
    target: { tabId, allFrames: false },
    files: OVERLAY_FILES,
  });
}

async function isPanelOpen() {
  try {
    const v = await chrome.storage.local.get("klo_panel_open");
    return !!v.klo_panel_open;
  } catch (_) {
    return false;
  }
}

// Keep the in-page panel alive across navigations and tab switches
// while it's open. The injected script auto-opens when klo_panel_open
// is set (see overlay.js bootstrap). When the panel is closed these
// are no-ops, so pages the user never summons klo on stay untouched.
async function maybeInjectForOpenPanel(tabId, url) {
  if (!tabId || !isInjectableUrl(url)) return;
  if (!(await isPanelOpen())) return;
  try { await injectOverlay(tabId); } catch (_) { /* restricted page */ }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status !== "complete") return;
  maybeInjectForOpenPanel(tabId, tab && tab.url);
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    maybeInjectForOpenPanel(tabId, tab && tab.url);
  } catch (_) { /* tab gone */ }
});

// On install OR update with the panel open, re-inject into every
// already-open http(s) tab. Tabs that were open at the moment the
// extension reloaded keep their stale (now-orphaned) content script;
// re-injecting remounts a fresh one so the open panel doesn't die.
async function reinjectOverlayIntoOpenTabs() {
  if (!(await isPanelOpen())) return;
  let tabs;
  try {
    tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
  } catch (e) {
    console.warn("[klo] tabs.query failed during reinject:", e);
    return;
  }
  for (const tab of tabs) {
    if (!tab.id) continue;
    try {
      await injectOverlay(tab.id);
    } catch (e) {
      // Some tabs (chrome web store, view-source:, file:// without
      // permission, etc.) reject injection. That's fine.
    }
  }
}

chrome.runtime.onInstalled.addListener((details) => {
  publishStatus();
  connect();
  // Reinject for both fresh installs and reloads (reason === "update"
  // when the user clicks reload at chrome://extensions).
  if (details.reason === "install" || details.reason === "update") {
    reinjectOverlayIntoOpenTabs();
  }
  // First install only: open the side panel directly in the current
  // window. No external welcome page, no "where do I click?" moment —
  // the user sees the sign-in card immediately. The firstRun flag
  // tells sidepanel.js to render the welcome copy on first paint,
  // then clears itself after Google sign-in succeeds.
  if (details.reason === "install") {
    chrome.storage.local.set({ "klo.firstRun": true }).catch(() => {});
    (async () => {
      try {
        await chrome.sidePanel.setOptions({ path: "sidepanel.html", enabled: true });
      } catch (_) {}
      try {
        const wins = await chrome.windows.getAll({ windowTypes: ["normal"] });
        const focused = wins.find((w) => w.focused) || wins[0];
        if (focused && focused.id !== undefined) {
          await chrome.sidePanel.open({ windowId: focused.id });
          return;
        }
      } catch (_) {}
      // Fallback: side panel API rejected (older Chrome, weird state) —
      // open the hosted welcome page so the user has a path forward.
      try {
        await chrome.tabs.create({
          url: "https://github.com/klo-local/klo-local#readme",
          active: true,
        });
      } catch (_) {}
    })();
  }
});

self.addEventListener("activate", () => {
  publishStatus();
  connect();
});

// Wake-up paths, service workers are ephemeral; these reconnect on demand.
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.kind === "request_status") {
    sendResponse({ connected, version: VERSION, bridge_url: BRIDGE_URL });
    return true;
  }
  if (msg && msg.kind === "reconnect") {
    if (ws) try { ws.close(); } catch (_) {}
    connect();
    sendResponse({ ok: true });
    return true;
  }
});

// Action icon click → toggle the in-page side panel via the content script.
// For pages where the content script can't run (chrome://, chrome-extension://,
// the new-tab page), fall back to Chrome's native side panel so the user
// gets a usable surface regardless.
async function toggleKloOnActiveTab() {
  // currentWindow can be undefined when the click originates from
  // a side panel; fall back to lastFocusedWindow.
  let tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length) tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tabs.length) tabs = await chrome.tabs.query({ active: true, windowType: "normal" });
  const tab = tabs[0];
  if (!tab || !tab.id) return;
  const url = tab.url || "";
  if (isInjectableUrl(url)) {
    try {
      await chrome.tabs.sendMessage(tab.id, { type: "klo.toggle_overlay" });
      return;
    } catch (_) {
      // Content script not present yet — the common case now that
      // injection is on-demand only. Inject, then retry the toggle.
      try {
        await injectOverlay(tab.id);
        // Give the script a tick to register its message listener.
        await new Promise((r) => setTimeout(r, 80));
        await chrome.tabs.sendMessage(tab.id, { type: "klo.toggle_overlay" });
        return;
      } catch (_) {
        // Fall through to side panel fallback.
      }
    }
  }
  // Fallback: open Chrome's native side panel for chrome:// etc.
  try {
    if (tab.windowId !== undefined) {
      await chrome.sidePanel.setOptions({ tabId: tab.id, path: "sidepanel.html", enabled: true });
      await chrome.sidePanel.open({ windowId: tab.windowId });
    }
  } catch (e) {
    console.warn("[klo] side panel fallback failed:", e);
  }
}

chrome.action.onClicked.addListener(() => { toggleKloOnActiveTab(); });

// MV3 service workers sleep aggressively. A periodic alarm keeps the worker
// warm enough to retry the WebSocket connection if the bridge_server
// restarts. Period: 30s (lowest reliable).
chrome.alarms.create("agent2-bridge-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "agent2-bridge-keepalive") {
    if (!connected) connect();
    publishStatus();
  }
});

// Initial connect attempt.
connect();


// ═══════════════════════════════════════════════════════════════════════════
//  Browser-agent chat orchestrator
// ═══════════════════════════════════════════════════════════════════════════
//
// The Cmd+K overlay (content script) opens a long-lived port to this service
// worker, sends a user prompt, and watches events stream back. We:
//
//   1. Snapshot the active tab so the LLM has context (URL, title, brief DOM).
//   2. POST /chat/llm-turn with {messages, tools, page_context}, get SSE back.
//   3. As tool_use blocks arrive, dispatch them to the existing tabs.* handlers.
//   4. Loop, appending tool results, until Haiku emits a text-only turn.
//   5. Stream tokens to the overlay as they arrive, feels instant.
//
// State (history) lives in chrome.storage.session per-tab so a new ⌘K on the
// same tab continues the conversation. Auth lives in chrome.storage.local
// (Supabase access token from the auth-callback flow in Phase 4).

const KLO_CLOUD_URL = "http://127.0.0.1:8789"; // Loopback-only fallback for public local builds.
// 50 rounds — generous ceiling for genuinely long agentic tasks
// (long forms, multi-page wizards, comparison across sites). Most
// turns finish in 3-5 rounds; this is the cap before the loop bails
// with "ran out of rounds." 30 was tight for YC-class work.
const CHAT_MAX_ROUNDS = 50;

// Conversations are persisted in chrome.storage.local, scoped per
// Supabase user, and survive browser restarts (unlike storage.session).
// We split each conversation into two storage records:
//   klo_conv_index__<uid>      : { [convId]: ConvIndexEntry } — small,
//                                used for the History list without
//                                deserialising 100 conversation bodies.
//   klo_conv__<uid>__<convId>  : ConvFull — only loaded when this is the
//                                active conversation or the user clicks
//                                back into it from History.
//   klo_active_conv_id__<uid>  : string | null — the conv that the chat
//                                surfaces show by default.
//
// The legacy CHAT_LOG_KEY / CHAT_HISTORY_KEY in storage.session is
// migrated into a single conv on first run and then cleared.
const CHAT_LOG_KEY     = "klo_chat_log";       // legacy, migration only
const CHAT_HISTORY_KEY = "klo_chat_history";   // legacy, migration only

const CONV_LRU_CAP = 100;
// When the first chat surface for a user reconnects after this much
// idle time has passed since the active conversation was last touched,
// archive it (it stays in History) and open a fresh thread. Keeps the
// "I left this open last week" context from leaking into a brand new
// task. Set to 12 hours.
const IDLE_NEW_CHAT_MS = 12 * 60 * 60 * 1000;

const convIndexKey    = (uid) => `klo_conv_index__${uid}`;
const convKey         = (uid, cid) => `klo_conv__${uid}__${cid}`;
const activeConvIdKey = (uid) => `klo_active_conv_id__${uid}`;

function newConvId() {
  if (typeof crypto !== "undefined" && crypto.randomUUID) return crypto.randomUUID();
  return "c-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
}

// JWT-decode the Supabase access token to recover the user id (sub
// claim). The server is the authority on token validity; locally we
// only need the sub to scope storage keys per user, so a lenient
// base64url decode is enough.
function getUserIdFromToken(token) {
  try {
    const payload = token.split(".")[1];
    if (!payload) return null;
    const b64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "===".slice((b64.length + 3) % 4);
    return JSON.parse(atob(padded)).sub || null;
  } catch (_) { return null; }
}

async function getCurrentUserId() {
  const token = await getAuthToken();
  return token ? getUserIdFromToken(token) : null;
}

async function loadConvIndex(uid) {
  const key = convIndexKey(uid);
  const v = await chrome.storage.local.get(key);
  return v[key] || {};
}

async function loadConv(uid, convId) {
  const key = convKey(uid, convId);
  const v = await chrome.storage.local.get(key);
  return v[key] || null;
}

async function getActiveConvId(uid) {
  const key = activeConvIdKey(uid);
  const v = await chrome.storage.local.get(key);
  return v[key] || null;
}

async function setActiveConvIdStored(uid, convId) {
  await chrome.storage.local.set({ [activeConvIdKey(uid)]: convId });
}

async function clearActiveConvIdStored(uid) {
  await chrome.storage.local.remove(activeConvIdKey(uid));
}

function summarizeConvForIndex(conv) {
  const firstUser = conv.log.find((e) => e.role === "user");
  const titleSrc = (firstUser && firstUser.text || "").trim();
  // Title is always the first user message (capped at 60). Empty
  // conversations never appear in the History list (filtered in
  // listConversations) so the fallback only matters for the title pill
  // itself, where "new chat" reads better than a date.
  const title = titleSrc.length > 0
    ? (titleSrc.length > 60 ? titleSrc.slice(0, 60) + "…" : titleSrc)
    : "new chat";
  const last = conv.log[conv.log.length - 1];
  const preview = last ? (last.text || "").slice(0, 80) : "";
  return {
    id: conv.id,
    title,
    preview,
    createdAt: conv.createdAt,
    updatedAt: conv.updatedAt,
    messageCount: conv.log.length,
  };
}

async function saveConv(uid, conv) {
  conv.updatedAt = Date.now();
  const index = await loadConvIndex(uid);
  index[conv.id] = summarizeConvForIndex(conv);
  // LRU cap: drop the oldest by updatedAt when over CONV_LRU_CAP, and
  // remove their full records too so storage doesn't accumulate.
  const ids = Object.keys(index);
  if (ids.length > CONV_LRU_CAP) {
    const sorted = ids.sort((a, b) => index[a].updatedAt - index[b].updatedAt);
    const toDrop = sorted.slice(0, ids.length - CONV_LRU_CAP);
    for (const id of toDrop) {
      delete index[id];
      try { await chrome.storage.local.remove(convKey(uid, id)); } catch (_) {}
    }
  }
  await chrome.storage.local.set({
    [convKey(uid, conv.id)]: conv,
    [convIndexKey(uid)]: index,
  });
}

async function createConv(uid) {
  const now = Date.now();
  const conv = {
    id: newConvId(),
    userId: uid,
    createdAt: now,
    updatedAt: now,
    title: "new chat",
    preview: "",
    messageCount: 0,
    log: [],
    history: [],
  };
  await saveConv(uid, conv);
  await setActiveConvIdStored(uid, conv.id);
  return conv;
}

async function deleteConvFromStore(uid, convId) {
  const index = await loadConvIndex(uid);
  delete index[convId];
  await chrome.storage.local.set({ [convIndexKey(uid)]: index });
  try { await chrome.storage.local.remove(convKey(uid, convId)); } catch (_) {}
  const activeId = await getActiveConvId(uid);
  if (activeId === convId) await clearActiveConvIdStored(uid);
}

// Migrate from the legacy storage.session keys exactly once per user.
// If the index already has anything, we assume migration already ran
// (or the user already has conversations from this version of the
// extension) and bail.
async function migrateLegacyChatIfNeeded(uid) {
  if (!uid) return;
  const v = await chrome.storage.session.get([CHAT_LOG_KEY, CHAT_HISTORY_KEY]);
  const oldLog  = Array.isArray(v[CHAT_LOG_KEY]) ? v[CHAT_LOG_KEY] : null;
  const oldHist = Array.isArray(v[CHAT_HISTORY_KEY]) ? v[CHAT_HISTORY_KEY] : null;
  if (!oldLog || !oldLog.length) {
    // Nothing to migrate, but still clear the legacy keys so we don't
    // re-check forever.
    await chrome.storage.session.remove([CHAT_LOG_KEY, CHAT_HISTORY_KEY]);
    return;
  }
  const index = await loadConvIndex(uid);
  if (Object.keys(index).length > 0) {
    await chrome.storage.session.remove([CHAT_LOG_KEY, CHAT_HISTORY_KEY]);
    return;
  }
  const conv = await createConv(uid);
  conv.log = oldLog;
  conv.history = oldHist || [];
  await saveConv(uid, conv);
  await chrome.storage.session.remove([CHAT_LOG_KEY, CHAT_HISTORY_KEY]);
}

// In-memory cache of the user's currently-active conversation. The
// service worker is the only writer; chat surfaces never touch storage
// directly. Cleared on sign-in / sign-out / user change.
let activeConvCache = null;  // { uid, conv } | null

async function ensureActiveConv(uid) {
  if (activeConvCache && activeConvCache.uid === uid) return activeConvCache.conv;
  await migrateLegacyChatIfNeeded(uid);
  const activeId = await getActiveConvId(uid);
  let conv = activeId ? await loadConv(uid, activeId) : null;
  if (!conv) conv = await createConv(uid);
  activeConvCache = { uid, conv };
  return conv;
}

async function newConvForUser(uid) {
  // "New chat" / "Clear chat" semantic = archive (the prior conv stays
  // in storage and shows up in History) + create.
  const conv = await createConv(uid);
  activeConvCache = { uid, conv };
  return conv;
}

async function switchConvForUser(uid, convId) {
  const conv = await loadConv(uid, convId);
  if (!conv) return null;
  await setActiveConvIdStored(uid, convId);
  activeConvCache = { uid, conv };
  return conv;
}

// Lightweight: just the index entries, sorted newest-first. Empty
// conversations (drafts created by "New chat" but never sent into) are
// filtered out so the History list isn't a wall of "Untitled chat".
async function listConversations(uid) {
  const index = await loadConvIndex(uid);
  return Object.values(index)
    .filter((e) => (e.messageCount || 0) > 0)
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

function makeSnapshotMessage(conv, conversations) {
  return {
    type: "state.snapshot",
    conversationId: conv ? conv.id : null,
    title: conv ? conv.title : "",
    log: conv ? conv.log : [],
    conversations,
    partialAssistant: currentAssistant || null,
    status: chatStatus,
    working: agentRunning,
  };
}


// ─── Tool catalog exposed to the chat brain ──────────────────────────────────
//
// We surface a curated subset of the bridge RPCs as tools. Names use
// underscore-style (Anthropic convention) but dispatch back to the dotted
// names existing handle() expects.

const CHAT_TOOLS = [
  {
    name: "tabs_active",
    description: "Get the currently active tab's URL and title. Use this to ground every web task, never guess what page the user is on.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "tabs_read_text",
    description: "Read the visible text of a page. Use for summarizing, extracting info, answering questions about content.",
    input_schema: {
      type: "object",
      properties: {
        max: { type: "integer", description: "Max characters to return (default 8000)." },
      },
    },
  },
  {
    name: "tabs_find",
    description: "FIND AN ELEMENT BY NATURAL-LANGUAGE DESCRIPTION. Use this FIRST whenever the user asks to click/interact with something on a page (\"click the members section\", \"the sign-in button\", \"that big orange CTA\"). Returns top-N ranked candidates with their idx pre-tagged — pass that idx straight to tabs_click_idx, no separate snapshot needed. Score-based fuzzy match on visible text + aria-label + placeholder + title + alt + id + class. This is the preferred click-target lookup; dom_snapshot is the fallback for cases where you want the FULL list of interactive elements.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Natural-language description of the target element. e.g. \"sign in button\", \"members section\", \"search box\", \"that orange CTA\"." },
        max: { type: "integer", description: "Max results to return (default 10, cap 25)." },
      },
      required: ["query"],
    },
  },
  {
    name: "tabs_dom_snapshot",
    description: "Snapshot ALL visible interactive elements on the page with stable indices. Use ONLY when tabs_find didn't return what you needed (e.g. you want a full inventory, or you're navigating a complex form by index). For \"click X\" prompts, prefer tabs_find first — it's faster and ranks the right element for you.",
    input_schema: {
      type: "object",
      properties: {
        max: { type: "integer", description: "Max elements (default 50)." },
      },
    },
  },
  {
    name: "tabs_click_idx",
    description: "Click an element by its idx (from a recent tabs_find or tabs_dom_snapshot). Preferred over click_text and click(selector) whenever an idx is available.",
    input_schema: {
      type: "object",
      properties: { idx: { type: "integer" } },
      required: ["idx"],
    },
  },
  {
    name: "tabs_click_text",
    description: "Click an element by its visible text. Useful when you don't have a snapshot, e.g. clicking 'Sign in' or 'Continue'.",
    input_schema: {
      type: "object",
      properties: { text: { type: "string" }, role: { type: "string" } },
      required: ["text"],
    },
  },
  {
    name: "tabs_real_click",
    description: "CDP-trusted click, required for clicks that trigger file pickers, popups, or React submit handlers that gate on user activation. Use only when click_idx fails on a button that should work.",
    input_schema: {
      type: "object",
      properties: { idx: { type: "integer" }, selector: { type: "string" } },
    },
  },
  {
    name: "tabs_fill_text",
    description: "Fill a text input by its label / placeholder. Optionally submit (presses Enter) after typing.",
    input_schema: {
      type: "object",
      properties: {
        label: { type: "string" },
        text: { type: "string" },
        submit: { type: "boolean" },
      },
      required: ["label", "text"],
    },
  },
  {
    name: "tabs_fill",
    description: "Fill a text input by exact CSS selector. Last-resort vs fill_text. Set submit:true to press Enter after.",
    input_schema: {
      type: "object",
      properties: {
        selector: { type: "string" },
        text: { type: "string" },
        submit: { type: "boolean" },
      },
      required: ["selector", "text"],
    },
  },
  {
    name: "tabs_navigate",
    description: "Send the active tab to a NEW URL (replaces what's loaded). Use only when the task requires a different page than the one in CURRENT PAGE CONTEXT. Never call this with the same URL the tab is already on — that's a refresh, and refreshing throws away the page state the user expects you to act on.",
    input_schema: {
      type: "object",
      properties: { url: { type: "string" } },
      required: ["url"],
    },
  },
  {
    name: "tabs_create",
    description: "Open a brand NEW tab. Use only when the task explicitly needs a separate tab — parallel research, opening a link the user wants to keep separate, comparison shopping. Never use this to 'go to' a page the user is already on (see CURRENT PAGE CONTEXT) — act on that tab directly.",
    input_schema: {
      type: "object",
      properties: { url: { type: "string" }, active: { type: "boolean" } },
      required: ["url"],
    },
  },
  {
    name: "tabs_wait_for",
    description: "Wait for an element (selector OR visible text) to appear. Useful after navigate/click on dynamic UIs.",
    input_schema: {
      type: "object",
      properties: {
        selector: { type: "string" },
        text: { type: "string" },
        timeout_ms: { type: "integer" },
      },
    },
  },
  {
    name: "tabs_screenshot",
    description: "Take a PNG of the active tab. Use ONLY when text-based tools have failed and you need visual disambiguation.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "tabs_scroll",
    description: "Scroll an element into view (or scroll to top/bottom of the page). Use BEFORE clicking when the target may be off-screen, after pages load to find content below the fold, or with direction:'bottom' to trigger 'load more' patterns. Pass idx (from dom_snapshot) for the most reliable targeting.",
    input_schema: {
      type: "object",
      properties: {
        idx: { type: "integer", description: "Element index from a recent dom_snapshot. Preferred." },
        selector: { type: "string", description: "CSS selector. Fallback when no idx is available." },
        text: { type: "string", description: "Visible text to match. Fallback when no idx or selector." },
        direction: { type: "string", enum: ["top", "bottom"], description: "Scroll to top or bottom of the page. Ignored if idx/selector/text is provided." },
      },
    },
  },
  {
    name: "replan",
    description: "Step back and re-plan when you're stuck, when the page state surprises you, when a tool error suggests the original plan is wrong, or when you realize the task has a sub-task you didn't anticipate (e.g. configuration that lives in a different product/site than where you started). Returns a fresh next_steps string based on everything that's happened so far. Use BEFORE you've burned more than 3-4 rounds going sideways. NOT a free re-do — only call when you've genuinely learned something that should change the plan. Don't call replan more than twice in a single task; if a third stall is coming, prefer task_complete with a partial-progress summary.",
    input_schema: {
      type: "object",
      properties: {
        reason: { type: "string", description: "What changed / what you learned that makes the original plan wrong. One sentence." },
        what_youve_done: { type: "string", description: "Brief summary of progress so far — what's been accomplished, what's still open." },
      },
      required: ["reason", "what_youve_done"],
    },
  },
  {
    name: "web_search",
    description: "Search the web. Runs DuckDuckGo in a hidden background tab in the user's own browser, scrapes the top 5 results, returns {title, url, snippet}. The user does NOT see a tab open or close — it's invisible. Use when the user says 'look online', when you need documentation/instructions for a procedure you don't already know, when an error contains a code you don't recognize, or when you suspect the task involves a product/setting you haven't located yet. Follow up with tabs_navigate to the most promising URL. Be specific in queries — 'how to white-label google oauth consent screen for supabase' is much better than 'google oauth'.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query. Be specific." },
      },
      required: ["query"],
    },
  },
  {
    name: "task_complete",
    description: "Call this when the task is fully done OR when you cannot make further progress. This is the ONLY way to end a turn without calling another action tool. result = what you did / found. success = true if the task succeeded, false if it failed or was blocked.",
    input_schema: {
      type: "object",
      properties: {
        result: { type: "string", description: "One or two sentences: what was done, or what was found, or why it failed." },
        success: { type: "boolean", description: "true if the task completed successfully, false otherwise." },
      },
      required: ["result", "success"],
    },
  },
];

// Tool name → existing handler method. Keeps the LLM-facing names tidy
// (underscore_case) while the bridge keeps its dotted names.
const TOOL_NAME_MAP = {
  tabs_active: "tabs.active",
  tabs_read_text: "tabs.read_text",
  tabs_dom_snapshot: "tabs.dom_snapshot",
  tabs_click_idx: "tabs.click_idx",
  tabs_click_text: "tabs.click_text",
  tabs_real_click: "tabs.real_click",
  tabs_fill_text: "tabs.fill_text",
  tabs_fill: "tabs.fill",
  tabs_navigate: "tabs.navigate",
  tabs_create: "tabs.create",
  tabs_wait_for: "tabs.wait_for",
  tabs_screenshot: "tabs.screenshot",
  tabs_scroll: "tabs.scroll",
  tabs_find: "tabs.find",
  task_complete: "task.complete",
};


// ─── Auth ────────────────────────────────────────────────────────────────────

async function getAuthToken() {
  const { klo_access_token } = await chrome.storage.local.get("klo_access_token");
  return klo_access_token || null;
}

// Single-flight gate. Two concurrent callers (the side panel polling
// for auth status + an authed fetch hitting 401 simultaneously) await
// the same in-flight Promise instead of each posting /auth/refresh
// and burning the rotated refresh-token race.
let _pendingRefresh = null;

// Cooldown after a failed refresh. Once a refresh fails, we know the
// stored refresh_token is dead (Supabase invalidates all sessions on
// password reset / sign-out elsewhere) and we should NOT keep hitting
// the server while it stays dead. 30s gives every other call site a
// quiet window to notice the signed-out state and stop retrying.
//
// Stored in chrome.storage.local so it survives the MV3 service
// worker being torn down and respawned.
const REFRESH_COOLDOWN_KEY = "klo_refresh_last_failure_at";
const REFRESH_COOLDOWN_MS  = 30 * 1000;

// Trade the stored refresh_token for a fresh access_token (and a new
// refresh_token, since rotation is enabled in our Supabase auth
// config). Returns true if the new pair was persisted, false if there
// was no refresh token, the call failed, or the response was empty —
// caller should treat false as "you're now signed out".
//
// Reactive only: invoked when an authed call returns 401. Three guard
// rails so a misbehaving caller can't storm /auth/refresh:
//   1. Single-flight: concurrent callers await the same in-flight
//      Promise (`_pendingRefresh` above).
//   2. Cooldown: if the previous attempt failed within 30s we return
//      false immediately without hitting the network.
//   3. Dead-token clear: on a 410 from the cloud's circuit breaker
//      (or 400/401 on the dead-token path) we run `clearAuth()` so
//      the dead refresh token never gets sent again, even after the
//      cooldown expires.
async function tryRefreshToken() {
  if (_pendingRefresh) return _pendingRefresh;
  _pendingRefresh = (async () => {
    try {
      const { [REFRESH_COOLDOWN_KEY]: lastFailAt } = await chrome.storage.local.get(REFRESH_COOLDOWN_KEY);
      if (typeof lastFailAt === "number" && Date.now() - lastFailAt < REFRESH_COOLDOWN_MS) {
        return false;
      }
      const { klo_refresh_token } = await chrome.storage.local.get("klo_refresh_token");
      if (!klo_refresh_token) return false;
      let resp;
      try {
        resp = await fetch(`${KLO_CLOUD_URL}/auth/refresh`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ refresh_token: klo_refresh_token }),
        });
      } catch (_) {
        // Network blip. Don't punish — let the next call try again.
        return false;
      }
      // 410 Gone means klo-cloud's circuit breaker has declared this
      // refresh token permanently dead. Also catch 400/401 with the
      // Supabase "refresh_token_not_found" body for older deploys.
      // In both cases, nuke the stored tokens NOW so the next
      // currentAccessToken() read returns nil and we stop trying.
      if (resp.status === 410) {
        await chrome.storage.local.set({ [REFRESH_COOLDOWN_KEY]: Date.now() });
        await clearAuth();
        return false;
      }
      if (resp.status === 400 || resp.status === 401) {
        let raw = "";
        try { raw = (await resp.text() || "").toLowerCase(); } catch (_) {}
        await chrome.storage.local.set({ [REFRESH_COOLDOWN_KEY]: Date.now() });
        if (raw.includes("not_found") || raw.includes("not found") || raw.includes("no longer valid")) {
          await clearAuth();
        }
        return false;
      }
      if (!resp.ok) {
        // Transient server error (5xx, 429 etc.). Mark cooldown so
        // we don't pile on but don't clear tokens.
        await chrome.storage.local.set({ [REFRESH_COOLDOWN_KEY]: Date.now() });
        return false;
      }
      const body = await resp.json();
      if (!body || !body.access_token) {
        await chrome.storage.local.set({ [REFRESH_COOLDOWN_KEY]: Date.now() });
        return false;
      }
      // Persist the NEW pair. Supabase rotates refresh tokens, so the
      // returned refresh_token should be different from the one we sent
      // — fall back to the existing one if the response omitted it.
      await chrome.storage.local.set({
        klo_access_token:  body.access_token,
        klo_refresh_token: body.refresh_token || klo_refresh_token,
      });
      // Successful refresh clears the cooldown so the next legitimate
      // 401 can refresh again without the 30s wait.
      await chrome.storage.local.remove(REFRESH_COOLDOWN_KEY);
      // Drop the auth-status cache so the very next pane decision uses
      // the fresh token.
      _authStatusCache = null;
      return true;
    } finally {
      _pendingRefresh = null;
    }
  })();
  return _pendingRefresh;
}

async function setAuthToken(accessToken, refreshToken) {
  await chrome.storage.local.set({
    klo_access_token: accessToken,
    klo_refresh_token: refreshToken || null,
  });
  // Wipe the auth-status cache so the next pane decision sees the new
  // token's profile, not whatever the previous user had. Also drop the
  // active-conversation cache so the next ensureActiveConv() call
  // loads the new user's history, not the previous user's.
  _authStatusCache = null;
  activeConvCache = null;
  // Re-snapshot connected surfaces so they pick up the new user's
  // conversation list and active thread immediately.
  await broadcastSnapshotForCurrentUser();
}

async function clearAuth() {
  await chrome.storage.local.remove([
    "klo_access_token",
    "klo_refresh_token",
    // Pending magic-link state shouldn't survive a sign-out, otherwise
    // the next signin would jump straight to the "click the email"
    // pending sub-view from a previous session.
    "klo_auth_pending",
  ]);
  _authStatusCache = null;
  activeConvCache = null;
  // After sign-out, surfaces flip to the signin pane; we still send an
  // empty snapshot so the chat pane is coherent if it ever shows.
  broadcast(makeSnapshotMessage(null, []));
}

async function broadcastSnapshotForCurrentUser() {
  const userId = await getCurrentUserId();
  if (!userId) {
    broadcast(makeSnapshotMessage(null, []));
    return;
  }
  const conv = await ensureActiveConv(userId);
  const conversations = await listConversations(userId);
  broadcast(makeSnapshotMessage(conv, conversations));
}

// Cached /auth/me response. Service-worker memory, lives until the
// worker is unloaded or until cache_until expires. The pane decision
// (signin vs upsell vs chat) reads subscription_status from here, so
// flipping a stale "none" to "trialing" within ~5 minutes of a Stripe
// Checkout completion is what makes the post-checkout pane refresh
// feel instant.
let _authStatusCache = null;
const AUTH_STATUS_TTL_MS = 60 * 1000;  // 60s — short enough to feel live, long enough to avoid hammering /auth/me

async function fetchAuthStatus({ force = false, _retried = false } = {}) {
  const now = Date.now();
  if (!force && _authStatusCache && _authStatusCache.cache_until > now) {
    return _authStatusCache.value;
  }
  const token = await getAuthToken();
  if (!token) {
    const value = { signed_in: false };
    _authStatusCache = { value, cache_until: now + AUTH_STATUS_TTL_MS };
    return value;
  }
  try {
    const resp = await fetch(`${KLO_CLOUD_URL}/auth/me`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (resp.status === 401) {
      // Access token expired (1h TTL). Try to swap the refresh token
      // for a fresh pair and retry once. Only after refresh fails do
      // we sign the user out — otherwise we'd kick them out every
      // hour even though their refresh token is still valid for days.
      if (!_retried) {
        const refreshed = await tryRefreshToken();
        if (refreshed) {
          return fetchAuthStatus({ force: true, _retried: true });
        }
      }
      await clearAuth();
      const value = { signed_in: false };
      _authStatusCache = { value, cache_until: now + AUTH_STATUS_TTL_MS };
      return value;
    }
    if (!resp.ok) {
      // Backend hiccup — treat as signed-in-but-status-unknown so we
      // don't accidentally bounce the user back to the signin pane on
      // a transient 500.
      return { signed_in: true, subscription_status: "unknown" };
    }
    const me = await resp.json();
    const value = {
      signed_in:           true,
      subscription_status: me.subscription_status || "none",
      plan:                me.plan || null,
      current_period_end:  me.current_period_end || null,
      email:               me.email || null,
    };
    _authStatusCache = { value, cache_until: now + AUTH_STATUS_TTL_MS };
    return value;
  } catch (_) {
    // Network failure (offline). Fall back to "signed_in but unknown
    // status" so the user keeps their chat surface available.
    return { signed_in: true, subscription_status: "unknown" };
  }
}

async function startCheckout() {
  const token = await getAuthToken();
  if (!token) return { ok: false, error: "not_signed_in" };
  try {
    // Pass redirect_to so Stripe Checkout's success/cancel URLs land
    // on our chrome-extension://EXT_ID/overlay/billing-callback.html
    // page instead of the desktop app's klo:// deep link. The callback
    // page forces an auth-status refresh and auto-closes — much
    // smoother than getting bounced into the Mac app from a browser.
    const redirect = chrome.runtime.getURL("overlay/billing-callback.html");
    const resp = await fetch(`${KLO_CLOUD_URL}/billing/checkout`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ redirect_to: redirect }),
    });
    if (!resp.ok) {
      const body = await resp.text().catch(() => "");
      return { ok: false, error: `klo-cloud ${resp.status}: ${body.slice(0, 200)}` };
    }
    const { url } = await resp.json();
    if (!url) return { ok: false, error: "no_checkout_url" };
    // Open Stripe Checkout in a new active tab. When the user closes
    // it (cancel or success), tabs.onRemoved fires and we'll
    // invalidate the cache + broadcast a status change.
    const tab = await chrome.tabs.create({ url, active: true });
    if (tab && tab.id) _checkoutTabId = tab.id;
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

let _checkoutTabId = null;
chrome.tabs.onRemoved.addListener(async (tabId) => {
  if (tabId !== _checkoutTabId) return;
  _checkoutTabId = null;
  // User closed the Stripe Checkout tab. Invalidate cache so the next
  // pane decision re-reads /auth/me, which by now should reflect the
  // webhook-driven subscription_status flip if Checkout completed.
  _authStatusCache = null;
  try {
    const value = await fetchAuthStatus({ force: true });
    broadcast({ type: "auth.status_changed", value });
  } catch (_) { /* ignore */ }
});

// ─── Composio integrations ──────────────────────────────────────────
//
// Mirrors the iOS surface (KloCloudClient.composio*). The browser flow:
//   1. composioConnect(toolkit) → POST /integrations/composio/connect
//      with redirect_to set to chrome-extension://EXT_ID/overlay/composio-callback.html.
//      Server returns a Composio OAuth URL. We open it in a new tab.
//   2. User authorizes on the toolkit's site → Composio bounces back
//      to our chrome-extension callback page.
//   3. composio-callback.js parses ?toolkit=&connectedAccountId= and
//      asks us to finalize via composioCallback() → POST /callback.
//   4. We invalidate auth-status cache + broadcast
//      "composio.connected" so any open klo surface can refresh.

async function composioListConnected() {
  // /auth/me returns integrations.composio as a dict shaped
  // `{connected_toolkits: ["gmail", ...], updated_at: "..."}`. We
  // flatten to the slug array the chat UI expects. Force a fresh
  // read so the picker reflects a connect that just landed.
  const status = await fetchAuthStatus({ force: true });
  if (!status || !status.signed_in) return { ok: false, error: "not_signed_in" };
  const composio = (status.integrations && status.integrations.composio) || {};
  const list = Array.isArray(composio)
    ? composio
    : (composio.connected_toolkits || []);
  return { ok: true, connected: list };
}

async function composioConnect(toolkit) {
  const token = await getAuthToken();
  if (!token) return { ok: false, error: "not_signed_in" };
  if (!toolkit) return { ok: false, error: "missing_toolkit" };
  try {
    const redirect = chrome.runtime.getURL("overlay/composio-callback.html");
    const resp = await fetch(`${KLO_CLOUD_URL}/integrations/composio/connect`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ toolkit, redirect_to: redirect }),
    });
    if (!resp.ok) {
      const body = await resp.text().catch(() => "");
      return { ok: false, error: `klo-cloud ${resp.status}: ${body.slice(0, 200)}` };
    }
    const data = await resp.json();
    const url = data.url || data.redirect_url;
    if (!url) return { ok: false, error: "no_oauth_url" };
    const tab = await chrome.tabs.create({ url, active: true });
    if (tab && tab.id) _composioTabId = tab.id;
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

async function composioCallback(toolkit, connectionID) {
  const token = await getAuthToken();
  if (!token) return { ok: false, error: "not_signed_in" };
  try {
    const resp = await fetch(`${KLO_CLOUD_URL}/integrations/composio/callback`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        toolkit,
        connection_id: connectionID || null,
      }),
    });
    if (!resp.ok) {
      const body = await resp.text().catch(() => "");
      return { ok: false, error: `klo-cloud ${resp.status}: ${body.slice(0, 200)}` };
    }
    // Force a status refresh + broadcast so every open klo surface
    // (sidepanel, overlay, in-flight chat agent) sees the new
    // integration immediately.
    _authStatusCache = null;
    try {
      const value = await fetchAuthStatus({ force: true });
      broadcast({ type: "auth.status_changed", value });
    } catch (_) {}
    broadcast({ type: "composio.connected", toolkit: String(toolkit).toLowerCase() });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

async function composioDisconnect(toolkit) {
  const token = await getAuthToken();
  if (!token) return { ok: false, error: "not_signed_in" };
  try {
    const resp = await fetch(`${KLO_CLOUD_URL}/integrations/composio/disconnect`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ toolkit }),
    });
    if (!resp.ok) {
      const body = await resp.text().catch(() => "");
      return { ok: false, error: `klo-cloud ${resp.status}: ${body.slice(0, 200)}` };
    }
    _authStatusCache = null;
    try {
      const value = await fetchAuthStatus({ force: true });
      broadcast({ type: "auth.status_changed", value });
    } catch (_) {}
    broadcast({ type: "composio.disconnected", toolkit: String(toolkit).toLowerCase() });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

let _composioTabId = null;
chrome.tabs.onRemoved.addListener(async (tabId) => {
  if (tabId !== _composioTabId) return;
  _composioTabId = null;
  // User closed the Composio OAuth tab. Either they finished (in
  // which case callback already invalidated the cache + broadcast)
  // or they cancelled. Either way, a status refresh is cheap insurance.
  _authStatusCache = null;
  try {
    const value = await fetchAuthStatus({ force: true });
    broadcast({ type: "auth.status_changed", value });
  } catch (_) {}
});


// ─── Page context for the LLM ────────────────────────────────────────────────

async function buildPageContext(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    return `URL: ${tab.url}\nTitle: ${tab.title}`;
  } catch (_) {
    return null;
  }
}

// Auto-snapshot the active tab's interactive elements and format them
// as an indexed list the navigator can read directly. Inspired by
// nanobrowser's pattern of pushing the indexed clickable tree into
// every navigator turn (chrome-extension/src/background/browser/dom/
// views.ts:clickableElementsToString, Apache-2.0). Without this the
// navigator has to remember to call tabs_dom_snapshot or tabs_find
// before clicking — which it often doesn't, so it falls back to
// fuzzy guesses or stalls.
//
// Returns formatted string like:
//   [0]<a href=/about>About />
//   [1]<button aria-label=menu>Menu />
//   [2]<input type=text placeholder=email />
// or null if the snapshot couldn't run (chrome:// page, etc).
// Cached selectorMap from the most recent snapshot: {idx: elementData}.
// Used by tabsClickIdx to navigate directly for <a href> elements instead
// of dispatching a click event (which SPA frameworks may swallow).
let _snapshotMap = {};

// Cache the rendered interactives string + the per-idx element map so
// rounds where the page hasn't changed (most read-only tool calls
// like screenshot, read_text, find, snapshot, web_search, replan) skip
// the chrome.scripting.executeScript round-trip entirely. Saves
// ~100-200ms per such round on heavy SPAs. Busted explicitly from the
// chat-loop dispatch after any page-mutating tool call.
let _interactivesCache = null;  // { key, text, snapshotMap }

function _bustInteractivesCache() {
  _interactivesCache = null;
}

async function buildInteractivesContext(tabId, max = 60) {
  try {
    const id = await resolveTab(tabId);
    const tab = await chrome.tabs.get(id);
    const url = tab && tab.url || "";
    if (!url || url.startsWith("chrome://") || url.startsWith("chrome-extension://") || url === "about:blank") {
      return null;
    }
    const title = (tab && tab.title || "").slice(0, 200);
    const cacheKey = `${id}|${url}|${title}`;
    if (_interactivesCache && _interactivesCache.key === cacheKey) {
      // Restore the per-idx map too — tabs_click_idx looks it up by idx
      // when it constructs the activity-log "Clicking <text>" label.
      _snapshotMap = _interactivesCache.snapshotMap;
      return _interactivesCache.text;
    }
    const [out] = await chrome.scripting.executeScript({
      target: { tabId: id },
      func: domSnapshot,
      args: [max],
    });
    const snap = out && out.result;
    if (!snap || !Array.isArray(snap.elements) || !snap.elements.length) return null;

    // Cache the full element data keyed by idx for click resolution.
    _snapshotMap = {};
    for (const el of snap.elements) _snapshotMap[el.idx] = el;

    const lines = snap.elements.map((el) => {
      const attrs = [];
      if (el.label) attrs.push(`aria-label='${String(el.label).slice(0, 40)}'`);
      if (el.type) attrs.push(`type=${el.type}`);
      if (el.href) attrs.push(`href='${String(el.href).slice(0, 60)}'`);
      const attrStr = attrs.length ? " " + attrs.join(" ") : "";
      const text = el.text ? `>${el.text}` : "";
      return `[${el.idx}]<${el.tag}${attrStr}${text} />`;
    });
    const rendered = [
      `PAGE INTERACTIVES (${snap.count} visible elements, indices are stable for this turn):`,
      ...lines,
      "",
      "Click an element by passing its [idx] to tabs_click_idx({idx: N}). The list refreshes every turn.",
    ].join("\n");
    _interactivesCache = { key: cacheKey, text: rendered, snapshotMap: _snapshotMap };
    return rendered;
  } catch (e) {
    console.warn("[klo] buildInteractivesContext failed:", e && e.message);
    return null;
  }
}

// Tools that mutate page state — busting the interactives cache after
// any of these means the next round rebuilds the snapshot. Read-only
// tools (screenshot, read_text, find, dom_snapshot, web_search,
// replan, task_complete) leave the cache intact.
const _PAGE_MUTATING_TOOLS = new Set([
  "tabs_navigate",
  "tabs_create",
  "tabs_click_idx",
  "tabs_click_text",
  "tabs_real_click",
  "tabs_fill",
  "tabs_fill_text",
  "tabs_scroll",
]);


// ─── SSE parser ──────────────────────────────────────────────────────────────

async function* parseSSE(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop();
    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (!payload) continue;
      try {
        yield JSON.parse(payload);
      } catch (e) {
        /* malformed event, skip */
      }
    }
  }
}


// ─── Single LLM turn (one /chat/llm-turn round-trip) ─────────────────────────

// 90s ceiling per turn covers Render hobby-tier cold start (~30-60s
// wake-up) + first byte from Anthropic + a full agent turn streaming
// out. Without this, fetch hangs forever when klo-cloud is asleep and
// the user sees the chat surface stuck on "thinking" with no error.
const LLM_TURN_TIMEOUT_MS = 90_000;

// Multi-agent planning. Inspired by nanobrowser's Planner+Navigator
// split. Set to false to disable the planner and run the old
// navigator-only loop. With it enabled:
//   - On round 0 we ask the planner for an initial plan.
//   - If planner says web_task=false OR done=true (e.g. greetings,
//     direct-answer questions), we emit the planner's final_answer
//     and skip the navigator entirely. No wasted tools on "hey".
//   - Otherwise, the planner's next_steps gets injected into the
//     navigator's system context as guidance, then the navigator
//     loop runs as before.
const USE_PLANNER = true;
const PLANNER_TIMEOUT_MS = 30_000;

// Single round-trip to the planner. Returns the structured plan or
// throws. Plumbed in parallel with llmTurn so timeouts and 402s are
// handled the same way (same auth, same paywall path).
async function plannerTurn({ task, history, browserState, cancelSignal }) {
  const token = await getAuthToken();
  if (!token) throw new Error("not_signed_in");

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), PLANNER_TIMEOUT_MS);
  // Mirror the user's Stop press onto this controller too — otherwise
  // a Stop during the planner stage just blocks until the planner
  // finishes (or times out).
  let cancelListener = null;
  if (cancelSignal) {
    if (cancelSignal.aborted) controller.abort();
    else {
      cancelListener = () => controller.abort();
      cancelSignal.addEventListener("abort", cancelListener, { once: true });
    }
  }
  const cleanupCancel = () => {
    if (cancelSignal && cancelListener) cancelSignal.removeEventListener("abort", cancelListener);
  };

  try {
    const resp = await fetch(`${KLO_CLOUD_URL}/chat/planner-turn`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        task,
        history: history || [],
        browser_state: browserState || {},
      }),
      signal: controller.signal,
    });
    if (resp.status === 401) {
      await clearAuth();
      throw new Error("session_expired");
    }
    if (resp.status === 402) {
      const detail = await resp.json().catch(() => ({}));
      const err = new Error("subscription_required");
      err.detail = detail;
      _authStatusCache = null;
      throw err;
    }
    if (!resp.ok) {
      // Read structured detail.code; never bubble raw body text up
      // to the user-facing error pipeline.
      let code = "upstream_error";
      let detail = null;
      try {
        const body = await resp.json();
        if (body && body.detail && typeof body.detail === "object") {
          code = body.detail.code || code;
          detail = body.detail;
        }
      } catch (_) { /* non-JSON body */ }
      console.warn(`[klo] /chat/planner-turn ${resp.status}`, code, detail);
      const err = new Error(code);
      err.detail = detail;
      throw err;
    }
    const data = await resp.json();
    return data && data.plan;
  } catch (e) {
    if (controller.signal.aborted) {
      if (cancelRequested) throw new Error("cancelled");
      throw new Error("planner timed out");
    }
    throw e;
  } finally {
    clearTimeout(timeoutId);
    cleanupCancel();
  }
}

// Web search via the user's own browser — opens DuckDuckGo's lite HTML
// endpoint (html.duckduckgo.com — designed to be parseable, no
// JS-required cards, no CAPTCHAs in normal use, privacy-friendly) in a
// BACKGROUND tab so the user's focus stays put, scrapes the result
// list with a content-script, then closes the tab. Returns
// {ok, query, results: [{title, url, snippet}]}.
//
// Why browser-side instead of a cloud search-API proxy:
//   - No third-party API key to ship, set, rotate, or pay for.
//   - Reuses the user's session (DDG doesn't need auth, but the
//     pattern keeps the door open to using sites that DO require
//     login — e.g. an internal wiki — without server-side credentials).
//   - One less network hop, one less service to keep alive.
const WEB_SEARCH_TIMEOUT_MS = 20_000;
const WEB_SEARCH_MAX_RESULTS = 5;

async function webSearchBrowser(query, cancelSignal) {
  const q = String(query || "").trim();
  if (!q) throw new Error("empty query");

  // DuckDuckGo's lite HTML endpoint. Structured, no JS, no CAPTCHA in
  // normal use. ?kl=us-en pins region so results are stable across
  // sessions; ?kp=-2 disables safe-search filtering (the agent might
  // legitimately need to research mature topics).
  const searchUrl = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(q)}&kl=us-en`;

  let createdTabId = null;
  const cancelPromise = new Promise((_, reject) => {
    if (!cancelSignal) return;
    if (cancelSignal.aborted) reject(new Error("cancelled"));
    cancelSignal.addEventListener("abort", () => reject(new Error("cancelled")), { once: true });
  });

  try {
    const tab = await chrome.tabs.create({ url: searchUrl, active: false });
    createdTabId = tab.id;
    // Race load against cancel + a wall-clock timeout.
    await Promise.race([
      waitForTabComplete(tab.id, WEB_SEARCH_TIMEOUT_MS),
      cancelPromise,
    ]);
    const [out] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: scrapeDuckDuckGoResults,
      args: [WEB_SEARCH_MAX_RESULTS],
    });
    const results = (out && Array.isArray(out.result)) ? out.result : [];
    return { ok: true, query: q, results };
  } finally {
    if (createdTabId != null) {
      // Best-effort cleanup; ignore errors (user may have closed it).
      try { await chrome.tabs.remove(createdTabId); } catch (_) {}
    }
  }
}

// Runs INSIDE the DuckDuckGo HTML results page via chrome.scripting.
// Must be self-contained — cannot reference outer scope.
function scrapeDuckDuckGoResults(maxResults) {
  const out = [];
  const nodes = document.querySelectorAll("div.result, div.result.results_links, div.result.results_links_deep");
  for (const node of nodes) {
    if (out.length >= maxResults) break;
    // Skip the "ads" container that DDG sometimes injects above
    // organic results — it has classes like result--ad / result--ad--small.
    const cls = node.className || "";
    if (cls.includes("result--ad")) continue;

    const titleA = node.querySelector("a.result__a, h2.result__title a");
    const snippetEl = node.querySelector("a.result__snippet, .result__snippet");
    if (!titleA) continue;

    let href = titleA.getAttribute("href") || "";
    // DDG wraps result hrefs in its redirector: /l/?uddg=ENCODED_URL.
    // Unwrap so the agent gets the real destination it can navigate
    // to with tabs_navigate.
    if (href.startsWith("/l/?") || href.startsWith("//duckduckgo.com/l/?")) {
      try {
        const abs = href.startsWith("//") ? "https:" + href : "https://duckduckgo.com" + href;
        const u = new URL(abs);
        const real = u.searchParams.get("uddg");
        if (real) href = decodeURIComponent(real);
      } catch (_) { /* leave href as-is */ }
    }

    out.push({
      title: (titleA.textContent || "").trim().slice(0, 200),
      url: href,
      snippet: snippetEl ? (snippetEl.textContent || "").trim().slice(0, 500) : "",
    });
  }
  return out;
}

// Snapshot of the active tab for the planner to reason about.
async function buildBrowserState(tabId) {
  try {
    const id = await resolveTab(tabId);
    const tab = await chrome.tabs.get(id);
    return {
      url: tab.url || "",
      title: (tab.title || "").slice(0, 200),
      page_summary: "",  // navigator can read text on demand; planner stays cheap
    };
  } catch (_) {
    return {};
  }
}

async function llmTurn({ messages, tools, pageContext, onEvent, cancelSignal }) {
  const token = await getAuthToken();
  if (!token) throw new Error("not_signed_in");

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), LLM_TURN_TIMEOUT_MS);
  // Mirror an external cancel signal (the user pressing Stop) onto the
  // local controller so the in-flight fetch is torn down immediately.
  let cancelListener = null;
  if (cancelSignal) {
    if (cancelSignal.aborted) controller.abort();
    else {
      cancelListener = () => controller.abort();
      cancelSignal.addEventListener("abort", cancelListener, { once: true });
    }
  }
  const cleanupCancel = () => {
    if (cancelSignal && cancelListener) cancelSignal.removeEventListener("abort", cancelListener);
  };

  let resp;
  console.log(`[klo] llmTurn → POST /chat/llm-turn tools=${(tools || []).length} msgs=${(messages || []).length} ctxLen=${(pageContext || "").length}`);
  try {
    resp = await fetch(`${KLO_CLOUD_URL}/chat/llm-turn`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        Accept: "text/event-stream",
      },
      body: JSON.stringify({ messages, tools, page_context: pageContext }),
      signal: controller.signal,
    });
  } catch (e) {
    clearTimeout(timeoutId);
    cleanupCancel();
    if (controller.signal.aborted) {
      // Distinguish user-cancel from timeout — runAgentLoop maps
      // "cancelled" to a "stopped by you" log entry instead of an error.
      if (cancelRequested) throw new Error("cancelled");
      // Stable code: humanizeError maps it to friendly cold-start copy
      // and the chat surfaces render a retry banner for it.
      throw new Error("cloud_timeout");
    }
    console.warn("[klo] /chat/llm-turn fetch failed:", e && e.message ? e.message : e);
    throw new Error("cloud_unreachable");
  }

  if (resp.status === 401) {
    clearTimeout(timeoutId);
    cleanupCancel();
    await clearAuth();
    throw new Error("session_expired");
  }
  if (resp.status === 402) {
    clearTimeout(timeoutId);
    cleanupCancel();
    // Carry the structured backend payload so the chat surface can
    // render a paywall card with a working Upgrade CTA, not just a
    // bare error string.
    const detail = await resp.json().catch(() => ({}));
    const err = new Error("subscription_required");
    err.detail = detail;
    // Subscription state changed (or wasn't ever active) — the cached
    // /auth/me is now stale.
    _authStatusCache = null;
    throw err;
  }
  if (!resp.ok) {
    clearTimeout(timeoutId);
    cleanupCancel();
    // Read the structured detail.code if the server provided one;
    // otherwise fall back to a stable upstream_error code. The raw
    // response body goes to console only — never to the user.
    let code = "upstream_error";
    let detail = null;
    try {
      const body = await resp.json();
      if (body && body.detail && typeof body.detail === "object") {
        code = body.detail.code || code;
        detail = body.detail;
      }
    } catch (_) { /* non-JSON body — keep default code */ }
    console.warn(`[klo] /chat/llm-turn ${resp.status}`, code, detail);
    const err = new Error(code);
    err.detail = detail;
    throw err;
  }

  let textOut = "";
  const toolCalls = [];

  try {
    for await (const evt of parseSSE(resp)) {
      if (evt.type === "text_delta") {
        textOut += evt.text;
        onEvent({ type: "text_delta", text: evt.text });
      } else if (evt.type === "tool_use_start") {
        onEvent({ type: "tool_use_start", name: evt.name });
      } else if (evt.type === "tool_use") {
        // Server may emit a tool_use both during streaming AND as a
        // safety-net re-emit from final_msg.content. Dedupe by id.
        if (!toolCalls.find((tc) => tc.id === evt.id)) {
          toolCalls.push({ id: evt.id, name: evt.name, input: evt.input });
        }
      } else if (evt.type === "message_stop") {
        onEvent({ type: "message_stop", stop_reason: evt.stop_reason });
      } else if (evt.type === "error") {
        // Server now emits `code` (stable, sanitized). Old payloads
        // had `message` (raw upstream text); we accept it for
        // back-compat but humanizeError's catch-all sanitizer will
        // suppress anything that looks like raw upstream output.
        throw new Error(evt.code || evt.message || "upstream_error");
      }
    }
  } catch (e) {
    if (controller.signal.aborted) {
      if (cancelRequested) throw new Error("cancelled");
      throw new Error("cloud_timeout");
    }
    throw e;
  } finally {
    clearTimeout(timeoutId);
    cleanupCancel();
  }

  // Reassemble the assistant turn for the next history entry.
  const content = [];
  if (textOut) content.push({ type: "text", text: textOut });
  for (const tc of toolCalls) {
    content.push({ type: "tool_use", id: tc.id, name: tc.name, input: tc.input });
  }

  return { text: textOut, toolCalls, content };
}


// ─── Cross-tab chat state ────────────────────────────────────────────────────
//
// Conversations are per-user, persisted in chrome.storage.local via the
// helpers near the top of this file (loadConv / saveConv / etc.). At
// any moment one of the user's conversations is the "active" one, and
// every connected klo-chat port (side panel + overlays in every tab)
// renders that same active conversation. New ports get a state.snapshot
// on connect so they can render the conversation that's already in
// progress and the History list of all conversations.
//
// Module-level state below is the LIVE TURN only:
//   chatStatus       Current "working" indicator { name } or null.
//   currentAssistant Live buffer of the in-flight assistant text. Sent
//                    to surfaces that join mid-stream so they can finish
//                    the bubble without missing the start.
//   agentRunning     Single in-flight turn at a time, across all tabs.
//
// The conversation itself (log + history) lives inside the ConvFull
// loaded into activeConvCache by ensureActiveConv(); no in-memory
// chatLog/chatHistory globals exist anymore.

// Module-level state describes the LIVE TURN only — the streaming
// buffer, the status pill, and the in-flight flag. The conversation
// itself lives in chrome.storage.local via the helpers above and is
// loaded on demand into activeConvCache. There is no cold-start
// hydration here anymore: the first port connect is what triggers
// ensureActiveConv() (and the legacy storage.session migration).
const chatPorts = new Set();
let chatStatus = null;
let currentAssistant = "";
let agentRunning = false;
// User-driven cancel. The Stop button in the chat surfaces posts
// {type:"agent.cancel"} which sets cancelRequested + aborts
// cancelController. runAgentLoop checks the flag after every await
// point; llmTurn / plannerTurn pass this signal to fetch so an
// in-flight model call also aborts immediately.
let cancelRequested = false;
let cancelController = null;

// Message-type prefixes that need to reach chrome.runtime listeners
// (sidepanel + content-script overlay) in addition to the chat ports.
// Agent-loop chatter (agent.heartbeat, log.append, tool.start, ...)
// stays port-only — those listeners live on the chat port itself.
const _RUNTIME_BROADCAST_PREFIXES = ["auth.", "composio.", "bridge.", "conversations."];

function broadcast(msg) {
  // Chat ports first — agent loop events ride these.
  for (const p of chatPorts) {
    try { p.postMessage(msg); } catch (_) { /* port may have closed */ }
  }
  // Mirror life-cycle events to chrome.runtime so surface listeners
  // (sidepanel.js, overlay.js) actually receive them. postMessage on
  // a chat port doesn't surface to runtime.onMessage, which is why
  // composio.connected was silently dropped before this fan-out.
  const t = msg && msg.type;
  if (!t || !_RUNTIME_BROADCAST_PREFIXES.some((p) => t.startsWith(p))) return;
  try {
    chrome.runtime.sendMessage(msg).catch(() => {});
  } catch (_) { /* runtime gone (worker dying) */ }
}

async function broadcastConvIndex(uid) {
  const conversations = await listConversations(uid);
  broadcast({ type: "conversations.updated", conversations });
}


// ─── Agent loop ──────────────────────────────────────────────────────────────
//
// No port arg, results stream to ALL connected ports via broadcast().

// Per-tool timeout. Stops the whole agent loop from getting stuck on
// a single hung handler (e.g. waitForTabComplete that never resolves
// because the navigated page itself stalled). 30s is generous —
// chrome.tabs.* operations are typically <1s.
const TOOL_TIMEOUT_MS = 30_000;

// Human-readable label of what a tool is about to do, for the chat
// activity log. Renders as e.g. "Opening youtube.com" or "Clicking
// 'Sign in'". Plain prose, no jargon — the user reads these scrolling
// past in the chat.
// Tools whose successful runs are noise in the activity log. The model
// often fires several finds/scrolls/reads in a row to figure out what
// to do — those are exploration moves, not page changes. We hide them
// when they succeed so the activity log only shows actions that
// actually mutate the page (clicks, types, navigations, opens).
// Errors are NOT hidden — failures still surface so the user knows
// when something's stuck. task_complete is hidden because its result
// already appears as the final assistant bubble.
const _QUIET_TOOLS = new Set([
  "tabs_screenshot",
  "tabs_dom_snapshot",
  "tabs_active",
  "tabs_find",
  "tabs_scroll",
  "tabs_read_text",
  "tabs_wait_for",
  "task_complete",
]);

// Friendly site labels — used so "Going to https://mail.google.com/..."
// reads as "Opening Gmail" instead of a URL. Order matters (longer
// first wins).
const _SITE_LABELS = [
  ["mail.google.com", "Gmail"],
  ["calendar.google.com", "Google Calendar"],
  ["docs.google.com", "Google Docs"],
  ["sheets.google.com", "Google Sheets"],
  ["drive.google.com", "Google Drive"],
  ["youtube.com", "YouTube"],
  ["github.com", "GitHub"],
  ["x.com", "X"],
  ["twitter.com", "X"],
  ["linkedin.com", "LinkedIn"],
  ["reddit.com", "Reddit"],
  ["amazon.com", "Amazon"],
  ["notion.so", "Notion"],
];

function siteLabel(u) {
  if (!u) return "";
  try {
    const host = new URL(u).hostname.replace(/^www\./, "");
    for (const [pattern, label] of _SITE_LABELS) {
      if (host === pattern || host.endsWith("." + pattern)) return label;
    }
    return host;
  } catch (_) {
    return shortUrl(u);
  }
}

function summarizeToolInput(name, input) {
  input = input || {};
  switch (name) {
    case "planner":          return "Thinking…";
    case "tabs_active":      return "Checking the tab";
    case "tabs_read_text":   return "Reading the page";
    case "tabs_dom_snapshot":return "Scanning the page";
    case "tabs_find":        return `Looking for ${input.query || "an element"}`;
    case "tabs_click_idx": {
      const cached = _snapshotMap[input.idx];
      const t = cached && cached.text;
      return t ? `Clicking ${t.slice(0, 50)}` : `Clicking element ${input.idx}`;
    }
    case "tabs_click_text":  return `Clicking ${(input.text || "").slice(0, 50)}`;
    case "tabs_real_click":  return `Clicking ${input.idx != null ? `element ${input.idx}` : input.selector || "element"}`;
    case "tabs_fill": {
      const v = input.value || "";
      return v ? `Typing "${v.slice(0, 30)}${v.length > 30 ? "…" : ""}"` : "Typing";
    }
    case "tabs_fill_text": {
      const v = input.value || "";
      const into = input.label ? ` into ${input.label.slice(0, 30)}` : "";
      return v ? `Typing "${v.slice(0, 30)}${v.length > 30 ? "…" : ""}"${into}` : `Typing${into}`;
    }
    case "tabs_navigate":    return `Opening ${siteLabel(input.url)}`;
    case "tabs_create":      return `Opening ${siteLabel(input.url)} in a new tab`;
    case "tabs_wait_for":    return `Waiting for ${input.text || input.selector || "the page"}`;
    case "tabs_screenshot":  return "Looking at the page";
    case "tabs_scroll":
      if (input.direction === "top")    return "Scrolling to the top";
      if (input.direction === "bottom") return "Scrolling to the bottom";
      return `Scrolling to ${input.text || (input.idx != null ? `element ${input.idx}` : input.selector || "element")}`;
    case "replan":           return "Re-thinking the plan";
    case "web_search":       return `Searching: ${(input.query || "").slice(0, 60)}`;
    default:
      return name.replace(/^tabs?_/, "").replace(/_/g, " ");
  }
}

// Briefer label of what just happened, shown after the tool result
// arrives. Hyphen-joined to the input summary in the UI like:
//   Opening Gmail · loaded
function summarizeToolResult(name, input, result, isError) {
  if (isError) {
    const err = (result && result.error) || "failed";
    return `couldn't (${String(err).slice(0, 80)})`;
  }
  switch (name) {
    case "planner":          return "ready";
    case "tabs_active":      return result && result.url ? `on ${siteLabel(result.url)}` : "ok";
    case "tabs_read_text":   return result && result.chars != null ? `read ${result.chars.toLocaleString()} chars` : "read";
    case "tabs_dom_snapshot":return result && Array.isArray(result.elements) ? `${result.elements.length} elements` : "scanned";
    case "tabs_find":        return result && Array.isArray(result.results) ? `${result.results.length} match${result.results.length === 1 ? "" : "es"}` : "no match";
    case "tabs_click_idx":
    case "tabs_click_text":
    case "tabs_real_click": {
      const t = result && result.text;
      if (t) return `clicked ${t.slice(0, 40)}${t.length > 40 ? "…" : ""}`;
      return "clicked";
    }
    case "tabs_fill":
    case "tabs_fill_text":   return "typed";
    case "tabs_navigate":    return "loaded";
    case "tabs_create":      return "opened";
    case "tabs_wait_for":    return "ready";
    case "tabs_screenshot":  return "looked";
    case "tabs_scroll":      return result && result.scrolled_to ? `scrolled to ${result.scrolled_to}` : "scrolled";
    case "replan":           return result && result.next_steps ? "new plan" : "ready";
    case "web_search": {
      const n = result && Array.isArray(result.results) ? result.results.length : 0;
      return n ? `${n} result${n === 1 ? "" : "s"}` : "no results";
    }
    default:                 return "done";
  }
}

function shortUrl(u) {
  if (!u) return "";
  try {
    const url = new URL(u);
    const host = url.hostname.replace(/^www\./, "");
    const path = (url.pathname + url.search).slice(0, 40);
    return path === "/" || path === "" ? host : `${host}${path}${url.search ? "" : ""}`;
  } catch (_) {
    return String(u).slice(0, 60);
  }
}

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
    promise.then(
      (v) => { clearTimeout(t); resolve(v); },
      (e) => { clearTimeout(t); reject(e); },
    );
  });
}

// Heartbeat tick — broadcast every 2s while the agent is running so
// the chat surface knows the service worker is alive. Without it, an
// SW killed mid-loop produces zero broadcasts and looks indistinguishable
// from a stuck network call. The chat surfaces watchdog this and
// surface "klo lost connection — retry?" if 5s pass with no heartbeat.
let _heartbeatInterval = null;

function startHeartbeat() {
  if (_heartbeatInterval) return;
  // Fire one immediately so a fresh chat surface gets a tick before
  // its watchdog 5s window starts.
  broadcast({ type: "agent.heartbeat", ts: Date.now() });
  _heartbeatInterval = setInterval(() => {
    broadcast({ type: "agent.heartbeat", ts: Date.now() });
  }, 2000);
}

function stopHeartbeat() {
  if (_heartbeatInterval) {
    clearInterval(_heartbeatInterval);
    _heartbeatInterval = null;
  }
}

async function runAgentLoop(prompt, tabId) {
  agentRunning = true;
  currentAssistant = "";
  cancelRequested = false;
  cancelController = new AbortController();
  const cancelSignal = cancelController.signal;
  // Helper run at every loop exit point so the next turn starts fresh.
  const finishLoopState = () => {
    agentRunning = false;
    cancelController = null;
    cancelRequested = false;
    chatStatus = null;
    currentAssistant = "";
    stopHeartbeat();
  };
  // Pushes a "stopped by you" entry, broadcasts a clean done, and
  // saves the conv. Used by every cancel-detected branch below so the
  // surfaces flip out of the working state without a red error bubble.
  const finishCancelled = async (conv, conversationUserId) => {
    const stoppedEntry = { role: "assistant", text: "_(stopped)_" };
    if (conv) conv.log.push(stoppedEntry);
    broadcast({ type: "log.append", message: stoppedEntry });
    broadcast({ type: "agent.done" });
    finishLoopState();
    if (conv && conversationUserId) {
      await saveConv(conversationUserId, conv);
      await broadcastConvIndex(conversationUserId);
    }
  };
  startHeartbeat();
  const userId = await getCurrentUserId();
  if (!userId) {
    const sev = _errorSeverity("not_signed_in");
    const errEntry = { role: "error", text: humanizeError("not_signed_in"), code: "not_signed_in", severity: sev };
    broadcast({ type: "agent.error", code: "not_signed_in", message: errEntry.text, severity: sev });
    broadcast({ type: "log.append", message: errEntry });
    finishLoopState();
    return null;
  }
  // Pin the conversation we started in so the turn always saves back to
  // the conv it began on, even if (somehow) the active conv changed
  // mid-flight.
  const conv = await ensureActiveConv(userId);
  let pageContext = await buildPageContext(tabId);
  // Cap history sent per turn so we don't ship ancient context.
  conv.history = conv.history.slice(-12);
  conv.history.push({ role: "user", content: prompt });
  console.log("[klo] agent loop starting", { prompt: prompt.slice(0, 100), historyLen: conv.history.length });

  // ── Stage 1: Planner ─────────────────────────────────────────────────
  // Decides web_task vs not. If "hey" or "what can you do?" — planner
  // answers directly with final_answer and we skip the navigator
  // entirely. If web_task — planner's next_steps becomes guidance for
  // the navigator's system context.
  let plannerGuidance = "";
  if (USE_PLANNER) {
    const plannerActivityId = `plan-${Date.now()}`;
    broadcast({
      type: "agent.tool_call",
      id: plannerActivityId,
      name: "planner",
      input: {},
      summary: "Thinking…",
    });
    try {
      const browserState = await buildBrowserState(tabId);
      const plan = await plannerTurn({
        task: prompt,
        history: conv.log.slice(-6),
        browserState,
        cancelSignal,
      });
      console.log("[klo] planner output", plan);
      const summary = plan && plan.done
        ? "answer ready"
        : "ready";
      broadcast({
        type: "agent.tool_result",
        id: plannerActivityId,
        name: "planner",
        ok: true,
        summary,
      });

      // If the user pressed Stop while the planner was thinking, exit
      // before announcing a plan or short-circuiting to a final answer.
      if (cancelRequested) { await finishCancelled(conv, userId); return null; }

      // Short-circuit: planner answered a non-web task directly
      // (greetings, meta-questions, "what can you do"). For web tasks
      // we ALWAYS run the navigator, even if the planner thinks the
      // answer is obvious — actions need execution, not narration.
      if (plan && plan.done && plan.web_task === false) {
        const finalText = (plan.final_answer || "").trim() || "Done.";
        const assistantEntry = { role: "assistant", text: finalText };
        conv.log.push(assistantEntry);
        broadcast({ type: "log.append", message: assistantEntry });
        broadcast({ type: "agent.done" });
        finishLoopState();
        await saveConv(userId, conv);
        await broadcastConvIndex(userId);
        return conv.history;
      }

      // Capture next_steps to feed the navigator as system context.
      if (plan && plan.next_steps) {
        plannerGuidance = String(plan.next_steps).trim();
      }
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      // Stop pressed during the planner stage — don't render this as a
      // failure. Just exit cleanly.
      if (msg === "cancelled" || cancelRequested) {
        broadcast({
          type: "agent.tool_result",
          id: plannerActivityId,
          name: "planner",
          ok: true,
          summary: "stopped",
        });
        await finishCancelled(conv, userId);
        return null;
      }
      console.warn("[klo] planner failed, continuing navigator-only:", msg);
      broadcast({
        type: "agent.tool_result",
        id: plannerActivityId,
        name: "planner",
        ok: false,
        summary: `planner failed (${msg.slice(0, 60)}) — proceeding without plan`,
        error: msg,
      });
      // If subscription_required came from the planner, it'll fire again
      // on the navigator's first /chat/llm-turn. Don't double-bail here.
    }
  }

  // basePageContext = URL/title + planner guidance. Stable across
  // rounds. The PAGE INTERACTIVES section (indexed clickable list) is
  // rebuilt on every round so the navigator sees fresh state after
  // each click/scroll/navigate.
  let basePageContext = pageContext || "";
  if (plannerGuidance) {
    basePageContext += `\n\nPLANNER GUIDANCE:\n${plannerGuidance}\n(Use this as a starting plan. You can deviate if the page state requires it.)`;
  }

  // How many times the navigator has called the `replan` tool this
  // task. Used to nag the model into finishing if it keeps replanning
  // instead of executing.
  let replanCount = 0;

  for (let round = 0; round < CHAT_MAX_ROUNDS; round++) {
    console.log(`[klo] round ${round} → calling llmTurn`);
    // Auto-snapshot interactive elements every round. The model sees
    // [0]<button>Sign in />, [1]<a>About />, etc. directly in its
    // system context — no need to call tabs_dom_snapshot or tabs_find
    // before clicking. After each tool call the page may have changed,
    // so we always rebuild.
    const interactives = await buildInteractivesContext(tabId);
    let turnPageContext = interactives
      ? `${basePageContext}\n\n${interactives}`
      : basePageContext;
    // Round-budget signal: when we're within the last 5 rounds, tell
    // the model so it can pace itself / call task_complete with a
    // partial-progress summary instead of brute-forcing more tries.
    const remaining = CHAT_MAX_ROUNDS - round;
    if (remaining <= 5) {
      turnPageContext += `\n\nROUND BUDGET: you have ${remaining} round${remaining === 1 ? "" : "s"} left in this task. If you can't finish cleanly, call task_complete now with a result that summarizes (1) what you accomplished, (2) what's blocking, and (3) the specific next step the user should take (URL / setting / action). Don't brute-force more attempts — synthesize and exit.`;
    }
    let turn;
    try {
      turn = await llmTurn({
        messages: conv.history,
        tools: CHAT_TOOLS,
        pageContext: turnPageContext,
        cancelSignal,
        onEvent: (evt) => {
          if (evt.type === "text_delta") {
            currentAssistant += evt.text;
            broadcast({ type: "agent.text_delta", text: evt.text });
          } else if (evt.type === "tool_use_start") {
            chatStatus = { name: evt.name };
            broadcast({ type: "agent.tool_use_start", name: evt.name });
          }
        },
      });
      console.log(
        `[klo] round ${round} llmTurn returned: toolCalls=${turn.toolCalls.length} ` +
        `text=${JSON.stringify((turn.text || "").slice(0, 200))} ` +
        `tools=${JSON.stringify(turn.toolCalls.map((tc) => ({ name: tc.name, input: tc.input })))}`
      );
      if (turn.toolCalls.length === 0) {
        console.warn(`[klo] round ${round} got 0 tool calls. Model returned text-only. Full text: ${turn.text}`);
      }
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      // User pressed Stop while the model was streaming. Exit cleanly
      // — no red error bubble, just a "_(stopped)_" assistant entry.
      if (msg === "cancelled" || cancelRequested) {
        await finishCancelled(conv, userId);
        return null;
      }
      const detail = (e && e.detail) || null;
      const sev = _errorSeverity(msg);
      const errEntry = { role: "error", text: humanizeError(msg), code: msg, detail, severity: sev };
      conv.log.push(errEntry);
      // Pass code + severity + detail through so the chat surface can
      // render the right thing — red bubble for must-act issues, a
      // paywall card for subscription_required, or a calm grey notice
      // for transient network/API hiccups.
      broadcast({ type: "agent.error", code: msg, message: errEntry.text, severity: sev, detail });
      broadcast({ type: "log.append", message: errEntry });
      finishLoopState();
      await saveConv(userId, conv);
      await broadcastConvIndex(userId);
      return null;
    }

    // Stop pressed between the model returning and us dispatching
    // tools — abort here so we don't kick off a click/navigate the
    // user just asked us not to do.
    if (cancelRequested) { await finishCancelled(conv, userId); return null; }

    conv.history.push({ role: "assistant", content: turn.content });

    if (turn.toolCalls.length === 0) {
      // Natural end. Promote the streamed text into a permanent log
      // entry, log.append on the receiving side renders markdown into
      // the live streaming bubble.
      const assistantEntry = { role: "assistant", text: turn.text };
      conv.log.push(assistantEntry);
      broadcast({ type: "log.append", message: assistantEntry });
      broadcast({ type: "agent.done" });
      finishLoopState();
      await saveConv(userId, conv);
      await broadcastConvIndex(userId);
      return conv.history;
    }

    // Execute tool calls sequentially (later calls often depend on
    // earlier results). task_complete + replan + web_search are
    // intercepted here rather than dispatched to a handler — they're
    // meta-tools that mutate loop state or hit the cloud directly.
    const toolResults = [];
    let taskDone = false;
    let taskResult = null;
    let replanMessage = null;   // fresh user-role guidance to inject after this round's tool_results
    for (const tc of turn.toolCalls) {
      // Check the cancel flag between every tool call so a Stop press
      // mid-sequence aborts before the next click/navigate fires.
      if (cancelRequested) { await finishCancelled(conv, userId); return null; }
      // task_complete is handled in-loop, not dispatched to a handler.
      // We don't broadcast an activity entry — the result text already
      // appears as the final assistant bubble below.
      if (tc.name === "task_complete") {
        taskDone = true;
        taskResult = (tc.input && tc.input.result) ? String(tc.input.result) : "Done.";
        toolResults.push({
          type: "tool_result",
          tool_use_id: tc.id,
          content: JSON.stringify({ ok: true }),
        });
        break;
      }

      // replan: re-invoke the planner with what the navigator has
      // learned so far. Returns fresh next_steps that get injected as a
      // user-role REPLAN message in the conversation history before the
      // next round. This is the navigator's escape hatch for "the
      // original plan doesn't fit anymore" — without it, the navigator
      // tends to brute-force the same broken approach until max-rounds.
      if (tc.name === "replan") {
        const reason = (tc.input && tc.input.reason) ? String(tc.input.reason) : "(no reason given)";
        const done = (tc.input && tc.input.what_youve_done) ? String(tc.input.what_youve_done) : "(no progress summary)";
        replanCount += 1;
        broadcast({
          type: "agent.tool_call",
          id: tc.id,
          name: "replan",
          input: tc.input,
          summary: "Re-thinking the plan",
        });
        let newSteps = "";
        let replanError = null;
        try {
          const browserState = await buildBrowserState(tabId);
          const augmentedTask = `${prompt}\n\nCURRENT SITUATION (from the navigator):\n- progress so far: ${done}\n- reason for replanning: ${reason}\n- this is REPLAN #${replanCount} for this task.\n\nGive a fresh next_steps that incorporates what's been learned. Be concrete about which tab/site to act on next.`;
          const plan = await plannerTurn({
            task: augmentedTask,
            history: conv.log.slice(-8),
            browserState,
            cancelSignal,
          });
          newSteps = (plan && plan.next_steps) ? String(plan.next_steps).trim() : "";
        } catch (e) {
          replanError = String(e && e.message ? e.message : e);
        }
        const ok = !replanError && !!newSteps;
        broadcast({
          type: "agent.tool_result",
          id: tc.id,
          name: "replan",
          ok,
          summary: ok ? "new plan" : `replan failed${replanError ? ` (${replanError.slice(0, 60)})` : ""}`,
          error: replanError,
        });
        toolResults.push({
          type: "tool_result",
          tool_use_id: tc.id,
          content: JSON.stringify(ok
            ? { ok: true, next_steps: newSteps, replan_count: replanCount }
            : { ok: false, error: replanError || "planner returned no next_steps" }),
          ...(ok ? {} : { is_error: true }),
        });
        if (ok) {
          // Buffer a separate user-role message that lands AFTER this
          // round's tool_results — so the model sees the new plan as a
          // discrete instruction the next time it thinks.
          const nag = replanCount >= 2
            ? " (You've replanned twice already — the next round should either execute or task_complete with a partial-progress summary.)"
            : "";
          replanMessage = {
            role: "user",
            content: `REPLAN #${replanCount}: ${newSteps}\n(Use this as your updated plan. You can still deviate if the page state requires it.)${nag}`,
          };
        }
        continue;
      }

      // web_search: hit the cloud's search endpoint.
      if (tc.name === "web_search") {
        const query = (tc.input && tc.input.query) ? String(tc.input.query) : "";
        broadcast({
          type: "agent.tool_call",
          id: tc.id,
          name: "web_search",
          input: tc.input,
          summary: `Searching: ${query.slice(0, 60)}`,
        });
        let searchResult, searchError = null;
        try {
          searchResult = await webSearchBrowser(query, cancelSignal);
        } catch (e) {
          searchError = String(e && e.message ? e.message : e);
          searchResult = { ok: false, error: searchError };
        }
        const okSearch = !searchError && searchResult && searchResult.ok !== false;
        broadcast({
          type: "agent.tool_result",
          id: tc.id,
          name: "web_search",
          ok: okSearch,
          summary: okSearch
            ? `${(searchResult.results || []).length} result${(searchResult.results || []).length === 1 ? "" : "s"}`
            : `search failed${searchError ? ` (${searchError.slice(0, 60)})` : ""}`,
          error: searchError,
        });
        toolResults.push({
          type: "tool_result",
          tool_use_id: tc.id,
          content: JSON.stringify(searchResult).slice(0, 8000),
          ...(okSearch ? {} : { is_error: true }),
        });
        continue;
      }

      const handlerName = TOOL_NAME_MAP[tc.name];
      const inputSummary = summarizeToolInput(tc.name, tc.input);
      const isQuiet = _QUIET_TOOLS.has(tc.name);
      console.log(`[klo] tool call → ${tc.name}`, tc.input);
      if (!isQuiet) {
        broadcast({
          type: "agent.tool_call",
          id: tc.id,
          name: tc.name,
          input: tc.input,
          summary: inputSummary,
        });
      }
      let result, isError = false;
      if (!handlerName) {
        result = { ok: false, error: `unknown tool: ${tc.name}` };
        isError = true;
        console.warn(`[klo] tool ${tc.name} → unknown handler`);
      } else {
        try {
          result = await withTimeout(
            handle(handlerName, tc.input || {}),
            TOOL_TIMEOUT_MS,
            `tool ${tc.name}`,
          );
          console.log(`[klo] tool ${tc.name} → ok`, result);
        } catch (e) {
          isError = true;
          result = { ok: false, error: String(e && e.message ? e.message : e) };
          console.warn(`[klo] tool ${tc.name} → error`, result.error);
        }
      }
      // Page-mutating tools invalidate the interactives cache so the
      // next round rebuilds the snapshot. Read-only tools leave it
      // intact — saves a chrome.scripting.executeScript per round
      // (~100-200ms) when the model is just verifying / reading.
      if (_PAGE_MUTATING_TOOLS.has(tc.name)) {
        _bustInteractivesCache();
      }
      const resultSummary = summarizeToolResult(tc.name, tc.input, result, isError);
      // Surface errors even for "quiet" tools — failures are signal,
      // not noise. Successful quiet runs stay hidden.
      if (!isQuiet || isError) {
        broadcast({
          type: "agent.tool_result",
          id: tc.id,
          name: tc.name,
          ok: !isError,
          summary: resultSummary,
          error: isError ? (result && result.error) : null,
        });
      }
      toolResults.push({
        type: "tool_result",
        tool_use_id: tc.id,
        content: JSON.stringify(result).slice(0, 8000),
        ...(isError ? { is_error: true } : {}),
      });
    }
    conv.history.push({ role: "user", content: toolResults });
    if (replanMessage) {
      // Surface the new plan as a separate user-role message AFTER the
      // tool_results so the model treats it as a discrete instruction
      // on its next turn.
      conv.history.push(replanMessage);
    }
    currentAssistant = "";

    if (taskDone) {
      const assistantEntry = { role: "assistant", text: taskResult };
      conv.log.push(assistantEntry);
      broadcast({ type: "log.append", message: assistantEntry });
      broadcast({ type: "agent.done" });
      finishLoopState();
      await saveConv(userId, conv);
      await broadcastConvIndex(userId);
      return conv.history;
    }
  }

  // Out of rounds. Don't dump a generic "hit max rounds" error on the
  // user — burn one final tool-less LLM turn to synthesize what was
  // accomplished, what's still blocking, and what the user should do
  // next. Far more useful than a system error message.
  let summaryText = "";
  try {
    const summaryTurn = await llmTurn({
      messages: [
        ...conv.history,
        {
          role: "user",
          content: "You're out of rounds for this task. Don't make any more tool calls. Reply with a short message that: (1) tells me what you accomplished, (2) what's still blocking finishing, (3) what I should do next — be concrete with a specific URL / setting / next action. \"Open https://console.cloud.google.com/apis/credentials/consent and update the App name field\" is good; \"try again later\" is not.",
        },
      ],
      tools: [],
      pageContext: "",
      cancelSignal,
      onEvent: () => {},
    });
    summaryText = (summaryTurn && summaryTurn.text) ? String(summaryTurn.text).trim() : "";
  } catch (e) {
    console.warn("[klo] max-rounds summary turn failed:", e && e.message ? e.message : e);
  }
  if (summaryText) {
    const summaryEntry = { role: "assistant", text: summaryText };
    conv.log.push(summaryEntry);
    broadcast({ type: "log.append", message: summaryEntry });
    broadcast({ type: "agent.done" });
  } else {
    // Synthesis failed too — show a calm notice so the user knows
    // the loop ended but isn't startled by red. The activity rows
    // above already show what happened step-by-step.
    const sev = _errorSeverity("max_rounds");
    const errEntry = { role: "error", text: humanizeError("max_rounds"), code: "max_rounds", severity: sev };
    conv.log.push(errEntry);
    broadcast({ type: "agent.error", code: "max_rounds", message: errEntry.text, severity: sev });
    broadcast({ type: "log.append", message: errEntry });
  }
  finishLoopState();
  await saveConv(userId, conv);
  await broadcastConvIndex(userId);
  return conv.history;
}


function humanizeError(code) {
  // Known, user-actionable codes — show the message we wrote.
  if (code === "not_signed_in") return "Sign in to use klo.";
  if (code === "session_expired") return "Your session expired. Sign in again.";
  if (code === "subscription_required") return "Subscribe to klo Pro to use this.";
  if (code === "busy") return "klo is still working. Give it a sec.";
  if (code === "cloud_timeout") return "klo cloud is waking up — this can take ~30 seconds. Retry in a moment.";
  if (code === "cloud_unreachable") return "Can't reach klo cloud. Check your connection and retry.";
  if (code === "planner timed out") return "klo took too long thinking. Try again?";
  if (code === "web search timed out") return "Search took too long. Try again or rephrase.";
  if (code === "max_rounds") return "Hit the round budget for this task.";

  // Stable upstream codes (klo-cloud → extension). Map to friendly
  // messages that don't leak which provider we use, billing details,
  // or request IDs.
  if (code === "upstream_overloaded") return "klo is overloaded. Try again in a moment.";
  if (code === "upstream_timeout") return "klo took too long. Try again.";
  if (code === "upstream_billing") return "Having trouble right now. Try again in a sec.";
  if (code === "upstream_error") return "Having trouble right now. Try again in a sec.";

  // Network blips bubble up as native fetch error strings; show
  // something the user can read instead of a stack-trace fragment.
  if (/Failed to fetch|NetworkError|TypeError: fetch/.test(code)) {
    return "Connection hiccup. Try again.";
  }

  // CATCH-ALL SANITIZER. Belt-and-suspenders for any code path that
  // forgets to map to a stable code — a raw upstream message must
  // NEVER reach the user's chat. Suppress anything that looks like
  // raw text (provider names, billing, request IDs, status codes,
  // stack traces, JSON braces, multi-line bodies). Raw details
  // still go to console for devs.
  const looksRaw = code && (
    /anthropic|api|credit|request_id|http|status code|traceback|exception|^\{/i.test(code)
    || code.length > 80
    || code.includes("\n")
  );
  if (looksRaw) {
    console.warn("[klo] suppressing raw error from UI:", code);
    return "Something went wrong. Try again.";
  }
  return code;
}

// Classify an error code into a severity tier so the chat UI can render
// it appropriately. The user said: "they don't all need to show or be
// red, that's scary." So we reserve the red error bubble for things the
// user genuinely has to act on, route subscription_required to its
// dedicated paywall card, and downgrade everything else (timeouts,
// transient API hiccups, soft tool failures) to a calm notice that
// sits inline like a system muttering.
function _errorSeverity(code) {
  if (code === "not_signed_in" || code === "session_expired") return "error";
  if (code === "subscription_required") return "paywall";
  return "notice";
}


// ─── Port-based message bus from the overlay ─────────────────────────────────

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "klo-chat") return;
  const isFirstPort = chatPorts.size === 0;
  chatPorts.add(port);

  // Send the newly-connected surface a state.snapshot so it can render
  // the active conversation + the History list. If the user is signed
  // out we send an empty snapshot — the surface's signin pane will be
  // visible already, but this keeps the chat surface coherent if it
  // ever shows.
  (async () => {
    const userId = await getCurrentUserId();
    if (!userId) {
      try { port.postMessage(makeSnapshotMessage(null, [])); } catch (_) {}
      return;
    }
    let conv = await ensureActiveConv(userId);
    // Idle-new-chat: when the FIRST port for a user reconnects after
    // IDLE_NEW_CHAT_MS has passed since the active conv was last
    // touched, archive it (it stays in History) and open a fresh one.
    if (
      isFirstPort
      && conv.log.length > 0
      && (Date.now() - conv.updatedAt > IDLE_NEW_CHAT_MS)
    ) {
      conv = await newConvForUser(userId);
    }
    const conversations = await listConversations(userId);
    try { port.postMessage(makeSnapshotMessage(conv, conversations)); } catch (_) {}
  })();

  port.onDisconnect.addListener(() => chatPorts.delete(port));

  port.onMessage.addListener(async (msg) => {
    if (!msg || !msg.type) return;
    const userId = await getCurrentUserId();

    if (msg.type === "user.prompt") {
      if (!userId) {
        port.postMessage({
          type: "agent.error",
          code: "not_signed_in",
          message: humanizeError("not_signed_in"),
          severity: _errorSeverity("not_signed_in"),
        });
        return;
      }
      if (agentRunning) {
        port.postMessage({
          type: "agent.error",
          code: "busy",
          message: "klo is still working on the previous turn. give it a sec.",
          severity: "notice",
        });
        return;
      }
      // Optimistically append the user message to the active conv's
      // log + broadcast so every tab paints it immediately.
      const conv = await ensureActiveConv(userId);
      const userEntry = { role: "user", text: msg.text };
      conv.log.push(userEntry);
      broadcast({ type: "log.append", message: userEntry });
      await saveConv(userId, conv);
      await broadcastConvIndex(userId);
      await runAgentLoop(msg.text, msg.tabId);
      return;
    }

    if (msg.type === "agent.cancel") {
      // The Stop button in any chat surface fires this. We flip the
      // module-level cancelRequested flag and abort the in-flight
      // controller so the SSE stream tears down immediately. The
      // agent loop checks the flag at every await point and emits a
      // "_(stopped)_" assistant entry on its way out, so the UI gets
      // a clean done event rather than a red error bubble.
      if (agentRunning) {
        cancelRequested = true;
        try { cancelController?.abort(); } catch (_) {}
      }
      return;
    }

    if (msg.type === "history.clear" || msg.type === "conversation.new") {
      if (!userId) return;
      if (agentRunning) {
        port.postMessage({
          type: "agent.error",
          code: "busy",
          message: "klo is still working. wait for it to finish before starting a new chat.",
          severity: "notice",
        });
        return;
      }
      const conv = await newConvForUser(userId);
      const conversations = await listConversations(userId);
      // Legacy event some surfaces still listen for; harmless on others.
      broadcast({ type: "log.cleared" });
      broadcast(makeSnapshotMessage(conv, conversations));
      return;
    }

    if (msg.type === "conversation.switch") {
      if (!userId || !msg.id) return;
      if (agentRunning) {
        port.postMessage({
          type: "agent.error",
          code: "busy",
          message: "klo is still working. wait for it to finish before switching chats.",
          severity: "notice",
        });
        return;
      }
      const conv = await switchConvForUser(userId, msg.id);
      if (!conv) return;
      const conversations = await listConversations(userId);
      broadcast(makeSnapshotMessage(conv, conversations));
      return;
    }

    if (msg.type === "conversation.delete") {
      if (!userId || !msg.id) return;
      const wasActive
        = activeConvCache
        && activeConvCache.uid === userId
        && activeConvCache.conv.id === msg.id;
      if (wasActive && agentRunning) {
        port.postMessage({
          type: "agent.error",
          code: "busy",
          message: "klo is still working in this chat. wait for it to finish before deleting.",
        });
        return;
      }
      await deleteConvFromStore(userId, msg.id);
      if (wasActive) {
        activeConvCache = null;
        const conv = await ensureActiveConv(userId);
        const conversations = await listConversations(userId);
        broadcast(makeSnapshotMessage(conv, conversations));
      } else {
        await broadcastConvIndex(userId);
      }
      return;
    }

    if (msg.type === "state.request") {
      if (!userId) {
        port.postMessage(makeSnapshotMessage(null, []));
        return;
      }
      const conv = await ensureActiveConv(userId);
      const conversations = await listConversations(userId);
      port.postMessage(makeSnapshotMessage(conv, conversations));
      return;
    }
  });
});


// ─── One-shot messages: auth status, sign-out ────────────────────────────────

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.type) return false;
  if (msg.type === "klo.auth_status") {
    // Was: returned just {signed_in}. Now returns the full /auth/me
    // shape so the side panel + overlay can decide between signin /
    // upsell / chat panes without each making its own backend call.
    fetchAuthStatus({ force: !!msg.force }).then(sendResponse);
    return true;
  }
  if (msg.type === "klo.set_tokens") {
    setAuthToken(msg.access_token, msg.refresh_token).then(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.type === "klo.sign_out") {
    clearAuth().then(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.type === "klo.start_checkout") {
    // Open Stripe Checkout in a new tab. Result includes ok=true even
    // if the user later cancels — completion is observed via the
    // tabs.onRemoved listener that re-fetches /auth/me.
    startCheckout().then(sendResponse);
    return true;
  }
  // Content scripts can't call chrome.tabs.create directly. They ask
  // us to open the user's webmail so they can click the magic link.
  // klo stays open across the navigation; the panel's pending state
  // is driven by klo_auth_pending in storage.local.
  if (msg.type === "klo.open_webmail") {
    chrome.tabs.create({ url: msg.url, active: true })
      .then(() => sendResponse({ ok: true }))
      .catch((e) => sendResponse({ ok: false, error: String(e) }));
    return true;
  }
  // ─── Composio ─────────────────────────────────────────────────
  if (msg.type === "klo.composio.list_connected") {
    composioListConnected().then(sendResponse);
    return true;
  }
  if (msg.type === "klo.composio.connect") {
    composioConnect(msg.toolkit).then(sendResponse);
    return true;
  }
  if (msg.type === "klo.composio.callback") {
    composioCallback(msg.toolkit, msg.connection_id).then(sendResponse);
    return true;
  }
  if (msg.type === "klo.composio.disconnect") {
    composioDisconnect(msg.toolkit).then(sendResponse);
    return true;
  }
  return false;
});


// ─── ⌘K command → toggle the in-page panel ──────────────────────────────────
//
// Routes to the same toggleKloOnActiveTab() path as the icon click, so ⌘K
// and toolbar click behave identically. content script handles the actual
// open/close + page push; chrome.sidePanel is only used as a fallback for
// chrome:// pages.

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "toggle-chat") return;
  try {
    await toggleKloOnActiveTab();
  } catch (e) {
    console.warn("[klo] ⌘K toggle failed:", e);
  }
});
