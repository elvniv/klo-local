/* klo side panel, primary chat surface.
 *
 * Side panels sidestep all the content-script flake (CSP, hotkey
 * binding, host-page CSS, script load races). Click the klo icon →
 * Chrome opens this panel directly, no message passing required.
 *
 * Communication with background.js uses the same `klo-chat` port that
 * the floating overlay uses, so the agent loop is identical.
 */

const KLO_CLOUD_URL = "http://127.0.0.1:8789"; // Loopback-only fallback for public local builds.

const $ = (sel) => document.querySelector(sel);
const els = {
  signinPane:    $("#signin-pane"),
  upsellPane:    $("#upsell-pane"),
  chatPane:      $("#chat-pane"),
  signinBtn:     $("#signin-btn"),
  signinBtnLabel:$("#signin-btn-label"),
  signinCtaWrap: $("#signin-cta-wrap"),
  signinTagline: $("#signin-tagline-text"),
  signinFeedback:$("#signin-feedback"),
  upsellCta:     $("#upsell-cta"),
  upsellAlready: $("#upsell-already-subscribed"),
  body:          $("#body"),
  status:        $("#status"),
  statusText:    $("#status-text"),
  input:         $("#input"),
  inputRow:      $("#input-row"),
  sendBtn:       $("#send-btn"),
  stopBtn:       $("#stop-btn"),

  menuBtn:       $("#menu-btn"),
  menu:          $("#menu"),
  appsBtn:       $("#apps-btn"),
  mSignin:       $("#m-signin"),
  mSignout:      $("#m-signout"),
  mReconnect:    $("#m-reconnect"),
  mApps:         $("#m-apps"),
  mNewChat:      $("#m-new-chat"),
  mHistory:      $("#m-history"),
  bridgeDot:     $("#bridge-dot"),
  bridgeStat:    $("#bridge-status"),
  bridgeRow:     $("#bridge-status-row"),
  connBanner:    $("#conn-banner"),
  titlePill:     $("#title-pill"),
  titlePillText: $("#title-pill-text"),
  historyMenu:   $("#history-menu"),
  historyEmpty:  $("#history-empty"),
  historyList:   $("#history-list"),
};

const ACTIVE_STATUSES = new Set(["active", "trialing"]);

let port = null;
let assistantBuffer = "";
let assistantBubble = null;
let isWorking = false;

// Heartbeat watchdog + elapsed-time indicator. Background broadcasts
// agent.heartbeat every 2s while the loop is running; the watchdog
// fires "klo lost connection — retry?" if 5s pass with no heartbeat.
// elapsedTimer ticks the status pill every second so the user always
// sees progress instead of a frozen "thinking".
const HEARTBEAT_TIMEOUT_MS = 5000;
let lastHeartbeatAt = 0;
let elapsedTimer = null;
let watchdogTimer = null;
let elapsedSeconds = 0;
let lastUserPrompt = "";  // for the retry button
let stuckBannerShown = false;
// Cached list of conversation index entries from the most recent
// state.snapshot / conversations.updated broadcast. Used to re-render
// the History dropdown without round-tripping the background.
let conversationsCache = [];
let activeConversationId = null;

// ─── Auth gate ──────────────────────────────────────────────────────────────

// Three-pane decision: signin (no token) → upsell (token, no active sub)
// → chat (token + active/trialing sub). The auth_status background
// handler now returns subscription_status from /auth/me, so this
// function just maps the response into one of three pane states.
async function refreshAuthGate({ force = false } = {}) {
  let status = { signed_in: false };
  try {
    status = await chrome.runtime.sendMessage({ type: "klo.auth_status", force });
  } catch (_) { /* background asleep */ }

  const signedIn = !!(status && status.signed_in);
  const active   = signedIn && ACTIVE_STATUSES.has(status.subscription_status);
  // "unknown" = transient backend issue. Don't bounce the user back to
  // the upsell pane on a 500; let them keep trying. Treat as active.
  const unknown  = signedIn && status.subscription_status === "unknown";

  els.signinPane.classList.toggle("is-visible", !signedIn);
  els.upsellPane.classList.toggle("is-visible", signedIn && !active && !unknown);
  els.chatPane.classList.toggle("is-visible", signedIn && (active || unknown));
  // Hide the header chrome on signin so the iOS-style SignInScreen
  // gets the full panel real estate.
  document.body.classList.toggle("is-signedout", !signedIn);

  // First-run welcome note: shown only while signed-out, only if
  // background.js's onInstalled handler set klo.firstRun. Cleared the
  // moment the user successfully signs in.
  if (!signedIn) {
    try {
      const store = await chrome.storage.local.get("klo.firstRun");
      els.signinPane.classList.toggle("is-firstrun", !!store["klo.firstRun"]);
    } catch (_) { /* storage unavailable */ }
  } else {
    els.signinPane.classList.remove("is-firstrun");
    try { await chrome.storage.local.remove("klo.firstRun"); } catch (_) {}
  }

  if (signedIn) {
    // Pull the connected-toolkit list whenever auth flips to signed-in
    // so the header stack + picker badges paint without waiting for
    // the user to open the picker for the first time.
    refreshConnectedToolkits();
  } else {
    connectedToolkits = new Set();
    renderHeaderAppsStack?.();
  }

  if (signedIn && (active || unknown)) {
    els.input?.focus();
    // Open the chat port early so we get the initial state.snapshot
    // (active conv title + History list) without having to wait for
    // the user to send the first message.
    ensurePort();
  }

  els.mSignin.style.display  = signedIn ? "none"  : "block";
  els.mSignout.style.display = signedIn ? "block" : "none";
}

// Handle background-pushed auth-status flips (Stripe Checkout closes,
// background re-fetches /auth/me, broadcasts the new state). Lets the
// upsell pane fade to chat without the user needing to click anything.
chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.type === "auth.status_changed") {
    refreshAuthGate();
  }
});

// Re-check when the side panel regains focus (user came back from a
// Stripe Checkout tab they kept open, etc).
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refreshAuthGate({ force: true });
});

function showSigninFeedback(text, kind = "info") {
  els.signinFeedback.className = `signin-feedback is-visible ${kind}`;
  els.signinFeedback.textContent = text;
}
function hideSigninFeedback() {
  els.signinFeedback.className = "signin-feedback";
  els.signinFeedback.textContent = "";
}

// Button loading state — mirrors iOS SignInScreen.awaitingOAuth: the
// label flips to "opening google", the Google G is replaced by a small
// olive spinner, and the breathing glow pauses.
function setSigninLoading(loading) {
  if (!els.signinBtn) return;
  els.signinBtn.disabled = loading;
  els.signinCtaWrap?.classList.toggle("is-loading", loading);
  if (els.signinBtnLabel) {
    els.signinBtnLabel.textContent = loading ? "opening google" : "continue with google";
  }
}

async function startSignIn() {
  hideSigninFeedback();
  setSigninLoading(true);

  try {
    // Ask klo-cloud for the Supabase Google OAuth kickoff URL. Supabase
    // bounces the user to Google → back to Supabase → back to our
    // chrome-extension callback page with #access_token=…&refresh_token=…
    // in the URL fragment. auth-callback.js parses the fragment and
    // hands the tokens to background.js via klo.set_tokens.
    const redirect = chrome.runtime.getURL("overlay/auth-callback.html");
    const resp = await fetch(`${KLO_CLOUD_URL}/auth/oauth/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ provider: "google", redirect_to: redirect }),
    });
    if (!resp.ok) {
      const body = await resp.text().catch(() => "");
      showSigninFeedback(`couldn't start: ${resp.status} ${body.slice(0, 120)}`, "err");
      setSigninLoading(false);
      return;
    }
    const { url } = await resp.json();
    if (!url) {
      showSigninFeedback("klo-cloud returned no OAuth URL.", "err");
      setSigninLoading(false);
      return;
    }

    // Open Google in a new tab. The side panel stays open and will flip
    // to the chat pane when background broadcasts auth.status_changed.
    await chrome.tabs.create({ url, active: true });
    showSigninFeedback("pick your Google account in the new tab.", "ok");
  } catch (e) {
    const stale = e && e.message && e.message.includes("Extension context invalidated");
    const msg = stale
      ? "klo was reloaded. refresh this page or close and reopen klo."
      : `couldn't reach klo-cloud: ${e.message}`;
    showSigninFeedback(msg, "err");
    setSigninLoading(false);
  }
}

els.signinBtn.addEventListener("click", startSignIn);

// ─── Rotating tagline ───────────────────────────────────────────────
// Mirrors iOS SignInScreen.startTaglineRotation: same phrases, same
// 3.6s cadence, same fade-out / fade-in via the .is-fading class.
const SIGNIN_TAGLINES = [
  "drive your chrome with klo",
  "ask. klo runs.",
  "your browser, on autopilot",
  "your agent on call",
];
let signinTaglineIdx = 0;
let signinTaglineTimer = null;
function startSigninTaglineRotation() {
  if (!els.signinTagline || signinTaglineTimer) return;
  signinTaglineTimer = setInterval(() => {
    if (!els.signinPane.classList.contains("is-visible")) return;
    const node = els.signinTagline;
    node.classList.add("is-fading");
    setTimeout(() => {
      signinTaglineIdx = (signinTaglineIdx + 1) % SIGNIN_TAGLINES.length;
      node.textContent = SIGNIN_TAGLINES[signinTaglineIdx];
      node.classList.remove("is-fading");
    }, 400);
  }, 3600);
}
startSigninTaglineRotation();

// Opens Stripe Checkout in a new tab. background's tabs.onRemoved
// hook re-fetches /auth/me when the user closes Checkout, broadcasting
// auth.status_changed which flips this pane to chat. Mirrors the
// SignInScreen loading vocabulary: label flips, breathing glow pauses,
// button disables. The cream lock-disc stays visible the whole time.
async function startCheckoutFlow() {
  const btn = els.upsellCta;
  const wrap = $("#upsell-cta-wrap");
  const label = $("#upsell-cta-label");
  if (!btn) return;
  const restore = () => {
    btn.disabled = false;
    wrap?.classList.remove("is-loading");
    if (label) label.textContent = "subscribe with stripe";
  };
  btn.disabled = true;
  wrap?.classList.add("is-loading");
  if (label) label.textContent = "opening stripe";
  try {
    const resp = await chrome.runtime.sendMessage({ type: "klo.start_checkout" });
    if (!resp || !resp.ok) {
      const stale = resp && resp.error && String(resp.error).includes("Extension context invalidated");
      const msg = stale
        ? "klo was reloaded. refresh this page to reconnect."
        : `couldn't start checkout: ${(resp && resp.error) || "unknown error"}`;
      restore();
      alert(msg);
      return;
    }
  } catch (e) {
    restore();
    return;
  }
  setTimeout(restore, 1500);
}

els.upsellCta?.addEventListener("click", () => startCheckoutFlow());
els.upsellAlready?.addEventListener("click", () => refreshAuthGate({ force: true }));

els.mSignin.addEventListener("click", () => {
  closeMenu();
  // Bring user back to the sign-in pane regardless of which pane was
  // showing (chat or upsell).
  els.chatPane.classList.remove("is-visible");
  els.upsellPane.classList.remove("is-visible");
  els.signinPane.classList.add("is-visible");
  els.signinBtn?.focus();
});

els.mSignout.addEventListener("click", async () => {
  closeMenu();
  await chrome.runtime.sendMessage({ type: "klo.sign_out" });
  // Reset sign-in form state.
  els.signinBtn.disabled = false;
  hideSigninFeedback();
  refreshAuthGate();
});

// ─── Menu ───────────────────────────────────────────────────────────────────

function toggleMenu() { closeHistory(); els.menu.classList.toggle("is-visible"); }
function closeMenu()  { els.menu.classList.remove("is-visible"); }
function toggleHistory() { closeMenu(); els.historyMenu.classList.toggle("is-visible"); }
function closeHistory()  { els.historyMenu.classList.remove("is-visible"); }

els.menuBtn.addEventListener("click", (e) => { e.stopPropagation(); toggleMenu(); });
els.titlePill.addEventListener("click", (e) => { e.stopPropagation(); toggleHistory(); });
document.addEventListener("click", (e) => {
  if (!els.menu.contains(e.target) && e.target !== els.menuBtn) closeMenu();
  if (
    !els.historyMenu.contains(e.target)
    && e.target !== els.titlePill
    && !els.titlePill.contains(e.target)
  ) closeHistory();
});

// "New chat" archives the current and opens a fresh thread. The prior
// conv stays in History (chrome.storage.local). See background.js
// conversation.new handler.
els.mNewChat.addEventListener("click", () => {
  closeMenu();
  ensurePort();
  port.postMessage({ type: "conversation.new" });
});

els.mHistory.addEventListener("click", () => {
  closeMenu();
  // Surface the existing dropdown rather than introducing a second
  // surface. The title pill is the source of truth for "switch chat".
  els.historyMenu.classList.add("is-visible");
});

// ─── Chat input ─────────────────────────────────────────────────────────────

function autoResize() {
  els.input.style.height = "auto";
  els.input.style.height = Math.min(140, els.input.scrollHeight) + "px";
  // Toggle .has-input on the wrapping row so the send button can flip
  // from a quiet ghost outline to brand orange the moment there is
  // something to send.
  const row = els.input.closest(".input-row");
  if (row) row.classList.toggle("has-input", els.input.value.trim().length > 0);
}

els.input.addEventListener("input", () => {
  autoResize();
  updateSlashPopover();
});
els.input.addEventListener("keydown", (e) => {
  if (handleSlashKeydown(e)) return;
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    submit();
  }
});
els.input.addEventListener("blur", () => {
  // Small delay so click events on the popover land before we hide it.
  setTimeout(closeSlashPopover, 120);
});

// ─── Empty-state quick-connect chips ────────────────────────────────
// When the chat body has no real messages, render a small "START WITH
// AN APP" panel with three brand chips above the placeholder text.
// Click → opens the slash picker with the slug pre-filled so the user
// gets a one-tap path into the connect flow without typing "/".

const EMPTY_HINT_SLUGS = ["gmail", "notion", "slack"];

function renderEmptyHint() {
  if (!els.body) return;
  // Skip if already rendered or body has real content.
  if (els.body.querySelector(".empty-hint")) return;
  const hint = document.createElement("div");
  hint.className = "empty-hint";
  const chipsHTML = EMPTY_HINT_SLUGS.map((slug) => {
    if (!window.Composio?.BUNDLED_SLUGS.has(slug)) return "";
    const name = window.Composio.displayName(slug);
    const url = window.Composio.iconURL(slug);
    const color = window.Composio.color(slug);
    return `
      <button class="empty-hint-chip" data-slug="${slug}"
              style="--brand-color:${color};--brand-edge:${color}55;--brand-tint:${color}10">
        ${url ? `<img src="${url}" alt="">` : ""}
        <span>${escapeHTML(name)}</span>
      </button>`;
  }).join("");
  hint.innerHTML = `
    <span class="empty-hint-eyebrow">START WITH AN APP</span>
    <div class="empty-hint-chips">${chipsHTML}</div>
    <span class="empty-hint-trailer">or just tell klo what to do.</span>
  `;
  hint.querySelectorAll(".empty-hint-chip").forEach((btn) => {
    btn.addEventListener("click", () => {
      const slug = btn.dataset.slug;
      els.input.focus();
      els.input.value = `/${slug} `;
      autoResize();
      updateSlashPopover();
    });
  });
  els.body.appendChild(hint);
}

function updateEmptyState() {
  if (!els.body) return;
  const hasMessages = !!els.body.querySelector(".msg");
  els.body.classList.toggle("is-empty", !hasMessages);
  if (!hasMessages) renderEmptyHint();
  else {
    const hint = els.body.querySelector(".empty-hint");
    if (hint) hint.remove();
  }
}

// Re-check empty state whenever the body's children change. A
// MutationObserver beats sprinkling updateEmptyState() across every
// appendChild site — anything that mutates the DOM gets caught.
if (typeof MutationObserver !== "undefined" && els.body) {
  const obs = new MutationObserver(() => updateEmptyState());
  obs.observe(els.body, { childList: true });
  // Initial paint.
  updateEmptyState();
}

// "Apps" menu entry — open the toolkit picker as if the user typed "/".
// No dedicated input-bar button (the user found the "+" cluttering);
// the slash typing pattern + menu entry is the iOS-parity affordance.
function openAppsPicker() {
  els.input.focus();
  if (els.input.value && !els.input.value.startsWith("/")) {
    els.input.value = "/" + els.input.value;
  } else if (!els.input.value) {
    els.input.value = "/";
  }
  autoResize();
  updateSlashPopover();
}
els.mApps?.addEventListener("click", () => {
  closeMenu();
  openAppsPicker();
});

// ─── Slash-command popover (/<toolkit> autocomplete) ────────────────
// Mirrors the native scope chip input. Triggered when the
// input starts with "/" and the user is still on the first token.
// Arrow keys + Enter pick a suggestion; Esc dismisses.

const els_slash = {
  popover: $("#slash-popover"),
  row: () => els.input.closest(".input-row"),
};
let slashState = { active: false, items: [], index: 0 };
// Connected-toolkit set, refreshed from background on popover open.
// Renders the "connected" badge in slash rows for already-linked
// toolkits, matching desktop-mac TextInputView.suggestionRow.
let connectedToolkits = new Set();

async function refreshConnectedToolkits() {
  try {
    const resp = await chrome.runtime.sendMessage({ type: "klo.composio.list_connected" });
    if (resp && resp.ok) {
      connectedToolkits = new Set(
        (resp.connected || []).map((s) =>
          (typeof s === "string" ? s : (s.toolkit || s.slug || s.name || "")).toLowerCase()
        )
      );
    }
  } catch (_) { /* offline; keep last-known set */ }
  renderHeaderAppsStack();
}

// Header connected-apps stack. Up to 3 brand glyphs overlapping, then
// a "+N" overflow. Click opens the picker. Mirrors how iOS surfaces
// connection status at a glance in ConnectionsScreen.
function renderHeaderAppsStack() {
  const stack = $("#header-apps-stack");
  const label = $("#header-apps-label");
  const wrap = $("#header-apps");
  if (!stack || !wrap || !label) return;
  const slugs = Array.from(connectedToolkits).filter((s) =>
    window.Composio?.BUNDLED_SLUGS.has(s)
  );
  if (!slugs.length) {
    wrap.classList.remove("is-visible");
    return;
  }
  const visible = slugs.slice(0, 3);
  const overflow = slugs.length - visible.length;
  stack.innerHTML = "";
  visible.forEach((slug) => {
    const tile = document.createElement("span");
    const url = window.Composio.iconURL(slug);
    if (url) {
      const img = document.createElement("img");
      img.src = url;
      img.alt = window.Composio.displayName(slug);
      tile.appendChild(img);
    } else {
      tile.classList.add("monogram");
      tile.style.setProperty("--brand-color", window.Composio.color(slug));
      tile.style.setProperty("--brand-tint", window.Composio.color(slug) + "33");
      tile.textContent = window.Composio.monogram(slug);
    }
    stack.appendChild(tile);
  });
  label.textContent = overflow > 0 ? `+${overflow}` : "";
  wrap.classList.add("is-visible");
}

$("#header-apps")?.addEventListener("click", () => openAppsPicker());

function currentSlashPrefix() {
  const v = els.input.value;
  if (!v.startsWith("/")) return null;
  const rest = v.slice(1);
  if (rest.includes(" ") || rest.includes("\n")) return null;
  return rest;
}

function renderSlashPopover() {
  if (!els_slash.popover) return;
  els_slash.popover.innerHTML = "";
  slashState.items.forEach((slug, idx) => {
    const row = document.createElement("div");
    const isConnected = connectedToolkits.has(slug);
    row.className = "slash-row"
      + (idx === slashState.index ? " is-active" : "")
      + (isConnected ? " is-connected" : "");
    row.setAttribute("role", "option");
    row.dataset.slug = slug;
    const icon = document.createElement("span");
    icon.className = "slash-row-icon";
    const url = window.Composio?.iconURL(slug);
    if (url) {
      const img = document.createElement("img");
      img.src = url;
      img.alt = "";
      icon.appendChild(img);
    } else {
      icon.classList.add("monogram");
      icon.style.setProperty("--brand-color", window.Composio.color(slug));
      icon.style.setProperty("--brand-tint", window.Composio.color(slug) + "33");
      icon.textContent = window.Composio.monogram(slug);
    }
    const name = document.createElement("span");
    name.className = "slash-row-name";
    name.textContent = window.Composio.displayName(slug);
    const slugEl = document.createElement("span");
    slugEl.className = "slash-row-slug";
    slugEl.textContent = `/${slug}`;
    const enter = document.createElement("span");
    enter.className = "slash-row-enter";
    enter.textContent = "↩";
    // For connected toolkits the badge doubles as a disconnect
    // affordance: first click arms a "disconnect?" confirm, second
    // click fires klo.composio.disconnect. mousedown so we beat the
    // input's blur handler, stopPropagation so the row doesn't accept
    // the slash.
    const status = document.createElement("button");
    status.type = "button";
    status.className = "slash-row-status";
    status.textContent = "connected";
    if (isConnected) {
      status.title = `Disconnect ${window.Composio.displayName(slug)}`;
      status.addEventListener("mousedown", async (e) => {
        e.preventDefault();
        e.stopPropagation();
        if (status.disabled) return;
        if (!row.classList.contains("is-confirm")) {
          row.classList.add("is-confirm");
          status.textContent = "disconnect?";
          return;
        }
        status.disabled = true;
        status.textContent = "disconnecting…";
        let resp = null;
        try {
          resp = await chrome.runtime.sendMessage({ type: "klo.composio.disconnect", toolkit: slug });
        } catch (_) { /* background asleep */ }
        if (resp && resp.ok) {
          // composio.disconnected broadcast also lands, but refresh
          // directly so the badge flips even if the broadcast races.
          await refreshConnectedToolkits();
          renderSlashPopover();
        } else {
          row.classList.remove("is-confirm");
          status.disabled = false;
          status.textContent = "couldn't disconnect";
        }
      });
    }
    row.appendChild(icon);
    row.appendChild(name);
    row.appendChild(slugEl);
    row.appendChild(enter);
    row.appendChild(status);
    row.addEventListener("mousedown", (e) => {
      // mousedown so we beat the input's blur handler.
      e.preventDefault();
      acceptSlash(slug);
    });
    els_slash.popover.appendChild(row);
  });
}

function updateSlashPopover() {
  if (!window.Composio) return;
  const prefix = currentSlashPrefix();
  if (prefix === null) {
    closeSlashPopover();
    return;
  }
  const matches = prefix === ""
    ? Array.from(window.Composio.BUNDLED_SLUGS).sort().slice(0, 6)
    : window.Composio.matchPrefix(prefix).slice(0, 6);
  if (!matches.length) {
    closeSlashPopover();
    return;
  }
  const wasActive = slashState.active;
  slashState.active = true;
  slashState.items = matches;
  if (slashState.index >= matches.length) slashState.index = 0;
  els_slash.row()?.parentElement?.classList?.add("has-slash");
  els.inputRow?.classList.add("has-slash");
  renderSlashPopover();
  // Re-pull connected list when the popover first opens; if it was
  // already open we leave the cache alone to avoid a flicker.
  if (!wasActive) refreshConnectedToolkits().then(renderSlashPopover);
}

function closeSlashPopover() {
  slashState = { active: false, items: [], index: 0 };
  els.inputRow?.classList.remove("has-slash");
  if (els_slash.popover) els_slash.popover.innerHTML = "";
}

function acceptSlash(slug) {
  els.input.value = `/${slug} `;
  closeSlashPopover();
  autoResize();
  els.input.focus();
  const end = els.input.value.length;
  els.input.setSelectionRange(end, end);
}

function handleSlashKeydown(e) {
  if (!slashState.active || !slashState.items.length) return false;
  if (e.key === "ArrowDown") {
    e.preventDefault();
    slashState.index = (slashState.index + 1) % slashState.items.length;
    renderSlashPopover();
    return true;
  }
  if (e.key === "ArrowUp") {
    e.preventDefault();
    slashState.index = (slashState.index - 1 + slashState.items.length) % slashState.items.length;
    renderSlashPopover();
    return true;
  }
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    acceptSlash(slashState.items[slashState.index]);
    return true;
  }
  if (e.key === "Escape") {
    e.preventDefault();
    closeSlashPopover();
    return true;
  }
  if (e.key === "Tab") {
    e.preventDefault();
    acceptSlash(slashState.items[slashState.index]);
    return true;
  }
  return false;
}

// Listen for Composio connection events from background so any open
// chat surface stays in sync without a manual refresh. When the
// toolkit the user was gating on lands, fire the pending prompt;
// otherwise post a small "<X> connected — ask away." note in chat so
// the user (and the agent's conversation context) sees the new state.
chrome.runtime.onMessage.addListener((msg) => {
  if (!msg) return;
  if (msg.type === "composio.connected") {
    refreshAuthGate({ force: true });
    refreshConnectedToolkits();
    const slug = String(msg.toolkit || "").toLowerCase();
    if (pendingComposioPrompt && pendingComposioPrompt.slug === slug) {
      // Hold the gated prompt while we run the success animation,
      // then fire it once the card is fully gone — no jumpy stacking.
      const prompt = pendingComposioPrompt.prompt;
      dismissAuthGateWithSuccess(slug).then(() => sendPrompt(prompt));
    } else if (activeAuthGateEl) {
      // Different toolkit just lit, but the user did have a card up
      // for something. Show success on the active card briefly so
      // the surface doesn't feel inert.
      dismissAuthGateWithSuccess(slug);
    } else {
      // No card at all — drop a confirmation in chat so the user
      // (and the agent context) sees the state change.
      appendConnectedNote(slug);
    }
  } else if (msg.type === "composio.disconnected") {
    refreshAuthGate({ force: true });
    refreshConnectedToolkits();
  }
});

// Append an inline "<Gmail> connected" note to the chat surface
// when a Composio toolkit lands mid-session. Same vocabulary as
// the inline auth gate so the user sees the state change without
// having to refresh or start a new chat.
function appendConnectedNote(slug) {
  if (!els.body) return;
  if (!window.Composio?.BUNDLED_SLUGS.has(slug)) return;
  const name = window.Composio.displayName(slug);
  const iconURL = window.Composio.iconURL(slug);
  const tile = iconURL
    ? `<span class="msg-auth-tile"><img src="${iconURL}" alt=""></span>`
    : `<span class="msg-auth-tile monogram" style="--brand-color:${window.Composio.color(slug)};--brand-tint:${window.Composio.color(slug)}33">${window.Composio.monogram(slug)}</span>`;
  const el = document.createElement("div");
  el.className = "msg msg-auth-card";
  el.innerHTML = `
    ${tile}
    <div class="msg-auth-body">
      <span class="msg-auth-title">${escapeHTML(name)} connected.</span>
      <span class="msg-auth-sub">ask klo to use it — your earlier message can be retried.</span>
    </div>
  `;
  els.body.appendChild(el);
  els.body.scrollTop = els.body.scrollHeight;
}
els.sendBtn.addEventListener("click", submit);
els.stopBtn.addEventListener("click", requestCancel);
// Esc anywhere in the panel cancels a running turn — keyboard parity
// with the click affordance for users who never leave the textarea.
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && isWorking) {
    e.preventDefault();
    requestCancel();
  }
});

async function submit() {
  const text = els.input.value.trim();
  if (!text || isWorking) return;

  // Preflight: if the prompt starts with /<slug> and the slug is a
  // known Composio toolkit the user hasn't connected, intercept and
  // render an inline AuthInterruptCard. The prompt is held in
  // pendingComposioPrompt until the connect lands (or the user
  // dismisses), at which point we fire it through to the agent.
  const slug = parseComposioPrefix(text);
  if (slug && window.Composio?.BUNDLED_SLUGS.has(slug)) {
    const connected = await isToolkitConnected(slug);
    if (!connected) {
      els.input.value = "";
      autoResize();
      els.input.closest(".input-row")?.classList.remove("has-input");
      renderAuthGate(slug, text);
      return;
    }
  }

  els.input.value = "";
  autoResize();
  els.input.closest(".input-row")?.classList.remove("has-input");
  sendPrompt(text);
}

function parseComposioPrefix(text) {
  if (!text.startsWith("/")) return null;
  const match = text.slice(1).match(/^([a-z0-9_-]+)\b/i);
  if (!match) return null;
  return match[1].toLowerCase();
}

async function isToolkitConnected(slug) {
  try {
    const resp = await chrome.runtime.sendMessage({ type: "klo.composio.list_connected" });
    if (!resp || !resp.ok) return false;
    const list = (resp.connected || []).map((s) =>
      (typeof s === "string" ? s : (s.toolkit || s.slug || s.name || "")).toLowerCase()
    );
    return list.includes(slug);
  } catch (_) {
    // Fail closed: if we can't confirm the connection, show the
    // connect card (which is retryable) instead of letting the agent
    // hit a silent tool failure later.
    return false;
  }
}

// Pending-prompt + active-card state for the inline auth gate. Only
// one auth gate at a time; if the user fires another /<slug> before
// finishing the first, we replace the card.
let pendingComposioPrompt = null;
let activeAuthGateEl = null;

function renderAuthGate(slug, prompt) {
  // Tear down any prior card.
  if (activeAuthGateEl) {
    activeAuthGateEl.remove();
    activeAuthGateEl = null;
  }
  pendingComposioPrompt = { slug, prompt };

  const el = document.createElement("div");
  el.className = "msg msg-auth-card";
  const name = window.Composio.displayName(slug);
  const iconURL = window.Composio.iconURL(slug);
  const brandColor = window.Composio.color(slug);
  // Border, hover fill, monogram tint — all sourced from the same
  // brand swatch so the card reads as "this is about Gmail".
  el.style.setProperty("--brand-color", brandColor);
  el.style.setProperty("--brand-edge", brandColor + "55");
  el.style.setProperty("--brand-tint", brandColor + "14");
  const tile = `<span class="msg-auth-tile${iconURL ? "" : " monogram"}">` +
    (iconURL ? `<img src="${iconURL}" alt="">` : window.Composio.monogram(slug)) +
    `</span>`;
  el.innerHTML = `
    ${tile}
    <div class="msg-auth-body">
      <span class="msg-auth-title">Connect ${escapeHTML(name)}</span>
      <span class="msg-auth-sub">opens in a new tab. you'll come right back.</span>
    </div>
    <button type="button" class="msg-auth-cta">connect</button>
    <span class="msg-auth-spinner" aria-hidden="true"></span>
    <span class="msg-auth-check" aria-hidden="true"></span>
  `;
  const cta = el.querySelector(".msg-auth-cta");
  const sub = el.querySelector(".msg-auth-sub");
  cta.addEventListener("click", async () => {
    cta.disabled = true;
    el.classList.add("is-connecting");
    sub.textContent = `opening ${name.toLowerCase()} in a new tab.`;
    try {
      const resp = await chrome.runtime.sendMessage({
        type: "klo.composio.connect",
        toolkit: slug,
      });
      if (!resp || !resp.ok) {
        el.classList.remove("is-connecting");
        cta.disabled = false;
        cta.textContent = "try again";
        sub.textContent = `couldn't start: ${(resp && resp.error) || "unknown"}`;
      } else {
        sub.textContent = "finish in the new tab. we'll catch the return.";
      }
    } catch (e) {
      el.classList.remove("is-connecting");
      cta.disabled = false;
      cta.textContent = "try again";
      sub.textContent = `error: ${e.message}`;
    }
  });
  els.body.appendChild(el);
  els.body.scrollTop = els.body.scrollHeight;
  activeAuthGateEl = el;
}

// Smooth dismissal — flip to a "connected ✓" confirmation, hold for
// 700ms so the user registers the success, then fade out. Returns a
// promise that resolves after the fade completes so callers can
// sequence the pending-prompt fire after the card is fully gone.
function dismissAuthGateWithSuccess(slug) {
  if (!activeAuthGateEl) return Promise.resolve();
  const el = activeAuthGateEl;
  activeAuthGateEl = null;
  pendingComposioPrompt = null;
  const name = window.Composio?.displayName(slug) || slug;
  const sub = el.querySelector(".msg-auth-sub");
  const title = el.querySelector(".msg-auth-title");
  if (title) title.textContent = `${name} connected`;
  if (sub) sub.textContent = "running your message now.";
  el.classList.remove("is-connecting");
  el.classList.add("is-connected");
  return new Promise((resolve) => {
    setTimeout(() => {
      el.classList.add("is-fading");
      setTimeout(() => { try { el.remove(); } catch (_) {} resolve(); }, 280);
    }, 700);
  });
}

function clearAuthGate() {
  if (activeAuthGateEl) {
    activeAuthGateEl.remove();
    activeAuthGateEl = null;
  }
  pendingComposioPrompt = null;
}

// Toggle the working chrome (fiery glow on the body, stop-button
// visible, send-button hidden) without touching agent state. Called
// any time isWorking flips so we don't have to remember to update the
// CSS classes at every site.
function setWorkingChrome(on) {
  document.body.classList.toggle("is-working", !!on);
  els.inputRow?.classList.toggle("is-working", !!on);
}

// Send the cancel signal to background. Background flips the agent
// loop's cancelRequested flag and aborts the in-flight LLM stream;
// the loop emits a "_(stopped)_" assistant entry on its way out.
function requestCancel() {
  if (!isWorking) return;
  ensurePort();
  try { port.postMessage({ type: "agent.cancel" }); } catch (_) {}
}

function ensurePort() {
  if (port) return port;
  port = chrome.runtime.connect({ name: "klo-chat" });
  port.onMessage.addListener(onAgentMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    // If we're mid-stream, this means the worker died unexpectedly.
    if (isWorking) {
      finishWorking();
      appendErrorBubble("connection lost. try again");
    }
  });
  return port;
}

function sendPrompt(text) {
  // Don't paint locally — the user bubble arrives via the log.append
  // broadcast in a few ms. Single source of truth keeps every connected
  // surface (this side panel, the in-page overlay) in sync.
  lastUserPrompt = text;
  startWorkingState();
  ensurePort();
  // tabId: -1 → background uses chrome.tabs.query for the active tab.
  // The side panel itself isn't a normal tab.
  port.postMessage({ type: "user.prompt", text, tabId: -1 });
}

function startWorkingState() {
  showStatus("thinking · 0s");
  assistantBuffer = "";
  assistantBubble = null;
  isWorking = true;
  els.sendBtn.disabled = true;
  setWorkingChrome(true);
  elapsedSeconds = 0;
  lastHeartbeatAt = Date.now();
  stuckBannerShown = false;
  // Tick the elapsed counter every second so the user always sees
  // progress.
  if (elapsedTimer) clearInterval(elapsedTimer);
  elapsedTimer = setInterval(() => {
    elapsedSeconds += 1;
    refreshStatusElapsed();
  }, 1000);
  // Watchdog: if no heartbeat for >5s while we're working, the SW is
  // probably dead. Surface a stuck banner with a retry button.
  if (watchdogTimer) clearInterval(watchdogTimer);
  watchdogTimer = setInterval(() => {
    if (!isWorking) return;
    const dt = Date.now() - lastHeartbeatAt;
    if (dt > HEARTBEAT_TIMEOUT_MS && !stuckBannerShown) {
      stuckBannerShown = true;
      showStuckBanner("klo lost connection. The service worker may have stopped.");
    }
  }, 1000);
}

function refreshStatusElapsed() {
  if (!isWorking) return;
  const s = elapsedSeconds;
  let label;
  if (s < 15) label = `thinking · ${s}s`;
  else if (s < 60) label = `connecting to klo cloud… · ${s}s`;
  else label = `klo took too long · ${s}s`;
  showStatus(label);
  if (s === 60 && !stuckBannerShown) {
    stuckBannerShown = true;
    showStuckBanner("klo took too long. Retry?");
  }
}

function showStuckBanner(text) {
  // Render an inline retry banner inside the chat body. Distinct from
  // appendErrorBubble so the styling reads as a system-level alert,
  // not a klo turn that errored.
  const el = document.createElement("div");
  el.className = "msg-stuck";
  el.innerHTML = `
    <span class="msg-stuck-text"></span>
    <button type="button" class="msg-stuck-retry">Retry</button>
  `;
  el.querySelector(".msg-stuck-text").textContent = text;
  el.querySelector(".msg-stuck-retry").addEventListener("click", () => {
    el.remove();
    if (lastUserPrompt) {
      sendPrompt(lastUserPrompt);
    }
  });
  els.body.appendChild(el);
  els.body.scrollTop = els.body.scrollHeight;
  finishWorking();
}

function finishWorking() {
  isWorking = false;
  els.sendBtn.disabled = false;
  setWorkingChrome(false);
  hideStatus();
  if (elapsedTimer) { clearInterval(elapsedTimer); elapsedTimer = null; }
  if (watchdogTimer) { clearInterval(watchdogTimer); watchdogTimer = null; }
  elapsedSeconds = 0;
  stuckBannerShown = false;
}

function onAgentMessage(msg) {
  if (!msg || !msg.type) return;
  // Every broadcast counts as a sign-of-life from the SW, not just
  // explicit heartbeats — so any tool/text/log event also resets the
  // watchdog timer. agent.heartbeat is the explicit ping that fires
  // when nothing else is happening (e.g. mid-Anthropic-fetch).
  lastHeartbeatAt = Date.now();
  switch (msg.type) {
    case "agent.heartbeat":
      // Explicit liveness ping; lastHeartbeatAt already updated above.
      break;
    case "agent.text_delta":
      appendAssistantDelta(msg.text);
      break;
    case "agent.tool_use_start":
      showStatus(humanizeTool(msg.name));
      break;
    case "agent.tool_call":
      // Render a visible activity entry as the tool runs. Lets the
      // user watch klo work step by step rather than guessing what's
      // happening behind the status pill.
      appendToolActivity(msg);
      showStatus(msg.summary || humanizeTool(msg.name));
      break;
    case "agent.tool_result":
      updateToolActivity(msg);
      showStatus(msg.ok ? "thinking" : `${humanizeTool(msg.name)} failed`);
      break;
    case "log.append":
      // Final message after a turn completes (user, assistant, or
      // error). For assistant entries this promotes the in-progress
      // streaming bubble to its final markdown-rendered form.
      // Without this handler, assistant bubbles stay as raw streamed
      // text and tool-only turns produce no bubble at all.
      renderLogEntry(msg.message);
      break;
    case "log.cleared":
      els.body.innerHTML = "";
      assistantBuffer = "";
      assistantBubble = null;
      finishWorking();
      break;
    case "state.snapshot":
      // Background sends this whenever a port connects + on
      // state.request + after conversation.* events. Replays the
      // active conversation so reopening the side panel shows the
      // chat that happened in the in-page overlay (and vice-versa),
      // and refreshes the History dropdown.
      renderSnapshot(msg);
      break;
    case "conversations.updated":
      // Light index-only broadcast emitted after a turn finalizes
      // (so the row's preview/updatedAt move) without re-rendering
      // the whole conversation.
      conversationsCache = Array.isArray(msg.conversations) ? msg.conversations : [];
      renderConversationsList();
      break;
    case "agent.done":
      finishWorking();
      break;
    case "agent.error":
      finishWorking();
      if (msg.code === "subscription_required") {
        appendPaywallBubble(msg.message || msg.detail?.message);
      } else if (msg.code === "cloud_timeout" || msg.code === "cloud_unreachable") {
        // Cold-start / connectivity — recoverable. Render the retry
        // banner so the user can re-issue the prompt in one click.
        showStuckBanner(msg.message || "klo cloud is unreachable. Retry?");
      } else {
        appendErrorBubble(msg.message || msg.code || "something went wrong");
      }
      break;
  }
}

// ─── Rendering helpers ──────────────────────────────────────────────────────

function showStatus(text) {
  if (text == null) {
    els.status.classList.remove("is-visible");
    return;
  }
  els.status.classList.add("is-visible");
  els.statusText.textContent = text;
}
function hideStatus() { showStatus(null); }

function appendUserBubble(text) {
  const el = document.createElement("div");
  el.className = "msg is-user";
  el.innerHTML = `<div class="msg-role">you</div><div class="msg-text"></div>`;
  el.querySelector(".msg-text").textContent = text;
  els.body.appendChild(el);
  els.body.scrollTop = els.body.scrollHeight;
}

function appendAssistantDelta(delta) {
  // Don't create an empty bubble for an empty/whitespace delta — wait
  // for actual content. Without this guard, a content_block of type
  // "text" with no body produces a visible "klo" bubble with no text.
  if (!assistantBubble && (!delta || !delta.trim())) return;
  if (!assistantBubble) {
    assistantBubble = document.createElement("div");
    assistantBubble.className = "msg is-assistant";
    assistantBubble.innerHTML = `<div class="msg-role">klo</div><div class="msg-text"></div>`;
    els.body.appendChild(assistantBubble);
  }
  assistantBuffer += delta;
  assistantBubble.querySelector(".msg-text").textContent = assistantBuffer;
  els.body.scrollTop = els.body.scrollHeight;
}

// Promote a finalized log entry into a chat bubble. For assistant
// entries this either upgrades the in-progress streaming bubble to a
// markdown-rendered final, or creates a fresh bubble if no text was
// streamed (tool-only turn, or this surface joined after the stream).
function renderLogEntry(entry) {
  if (!entry || !entry.role) return;
  console.log("[klo sidepanel] renderLogEntry", { role: entry.role, hasText: !!entry.text, len: (entry.text || "").length });
  if (entry.role === "user") {
    appendUserBubble(entry.text);
  } else if (entry.role === "assistant") {
    // No text? The agent ran tools but didn't summarize. The activity
    // entries above already show what happened — don't pollute the
    // chat with a void bubble or an apologetic placeholder.
    const text = (entry.text || "").trim();
    if (!text) {
      if (assistantBubble) {
        assistantBubble.remove();
        assistantBubble = null;
        assistantBuffer = "";
      }
      return;
    }
    if (assistantBubble) {
      const target = assistantBubble.querySelector(".msg-text");
      target.innerHTML = renderMarkdown(text);
      assistantBubble = null;
      assistantBuffer = "";
    } else {
      const el = document.createElement("div");
      el.className = "msg is-assistant";
      el.innerHTML = `<div class="msg-role">klo</div><div class="msg-text"></div>`;
      el.querySelector(".msg-text").innerHTML = renderMarkdown(text);
      els.body.appendChild(el);
    }
  } else if (entry.role === "error") {
    if (entry.code === "subscription_required") {
      appendPaywallBubble(entry.text);
    } else if (
      (entry.code === "cloud_timeout" || entry.code === "cloud_unreachable")
      && els.body.querySelector(".msg-stuck")
    ) {
      // Live cloud errors already rendered as the retry banner —
      // don't double up with a second bubble. (Snapshot replays have
      // no banner, so history still shows the message.)
    } else {
      appendErrorBubble(entry.text);
    }
  }
  els.body.scrollTop = els.body.scrollHeight;
}

// Track in-flight tool-activity bubbles by tool_use_id so we can flip
// them from pending → done/failed when the result arrives. Lets the
// user see exactly what klo is doing each step, not just a status pill.
const toolActivityById = new Map();

function appendToolActivity(call) {
  const el = document.createElement("div");
  el.className = "msg-tool is-pending";
  el.innerHTML = `<span class="msg-tool-arrow">→</span><span class="msg-tool-text"></span>`;
  el.querySelector(".msg-tool-text").textContent = call.summary || call.name;
  els.body.appendChild(el);
  if (call.id) toolActivityById.set(call.id, el);
  els.body.scrollTop = els.body.scrollHeight;
}

function updateToolActivity(result) {
  const el = result.id ? toolActivityById.get(result.id) : null;
  if (!el) return;
  el.classList.remove("is-pending");
  el.classList.toggle("is-error", !result.ok);
  el.classList.toggle("is-done", result.ok);
  const textEl = el.querySelector(".msg-tool-text");
  const baseText = textEl.textContent;
  const sep = result.ok ? " · " : " — ";
  textEl.textContent = `${baseText}${sep}${result.summary || (result.ok ? "done" : "failed")}`;
  els.body.scrollTop = els.body.scrollHeight;
}

// Replay the entire conversation log into the chat surface. Triggered
// when this port connects and on every history.clear, conversation.*,
// or focus-driven state.request. Catches mid-stream state too — if the
// agent is in flight when we connect, restore the partial assistant
// text into a live bubble so subsequent text_delta events accumulate
// into it.
function renderSnapshot(snap) {
  // The snapshot now carries both the active conversation and a light
  // list of every conversation for the History dropdown.
  activeConversationId = snap.conversationId || null;
  conversationsCache = Array.isArray(snap.conversations) ? snap.conversations : [];
  setTitlePill(snap.title);
  renderConversationsList();

  els.body.innerHTML = "";
  assistantBuffer = "";
  assistantBubble = null;
  for (const entry of (snap.log || [])) {
    renderLogEntry(entry);
  }
  if (snap.partialAssistant) {
    assistantBubble = document.createElement("div");
    assistantBubble.className = "msg is-assistant";
    assistantBubble.innerHTML = `<div class="msg-role">klo</div><div class="msg-text"></div>`;
    assistantBuffer = snap.partialAssistant;
    assistantBubble.querySelector(".msg-text").textContent = assistantBuffer;
    els.body.appendChild(assistantBubble);
  }
  if (snap.working) {
    isWorking = true;
    els.sendBtn.disabled = true;
    setWorkingChrome(true);
    if (snap.status && snap.status.name) showStatus(humanizeTool(snap.status.name));
    else showStatus("thinking");
  } else {
    finishWorking();
  }
  els.body.scrollTop = els.body.scrollHeight;
}

function appendErrorBubble(text) {
  const el = document.createElement("div");
  el.className = "msg is-error";
  el.innerHTML = `<div class="msg-role">klo</div><div class="msg-text"></div>`;
  el.querySelector(".msg-text").textContent = text;
  els.body.appendChild(el);
  els.body.scrollTop = els.body.scrollHeight;
}

// ─── Title pill + History dropdown rendering ────────────────────────────────

function setTitlePill(title) {
  const t = (title || "").trim();
  els.titlePillText.textContent = t || "new chat";
  // The pill auto-truncates with text-overflow:ellipsis; setting a
  // title attribute gives the user the full string on hover.
  els.titlePill.title = t || "Start a new chat";
}

// Coarse "today / yesterday / this week / older" bucket headings. We
// stick with relative groups so the History list reads at a glance —
// exact dates would force the eye to parse, dates aren't the answer
// to "where's the chat I had earlier".
function bucketForTimestamp(ms, now = Date.now()) {
  const day = 24 * 60 * 60 * 1000;
  const today = new Date(now); today.setHours(0, 0, 0, 0);
  const startOfToday = today.getTime();
  const startOfYesterday = startOfToday - day;
  const startOfWeek = startOfToday - 6 * day;  // last 7 days, "this week"
  if (ms >= startOfToday) return "Today";
  if (ms >= startOfYesterday) return "Yesterday";
  if (ms >= startOfWeek) return "This week";
  return "Older";
}

function relativeTime(ms, now = Date.now()) {
  const s = Math.max(0, Math.floor((now - ms) / 1000));
  if (s < 60)        return `${s}s`;
  if (s < 60 * 60)   return `${Math.floor(s / 60)}m`;
  if (s < 24 * 3600) return `${Math.floor(s / 3600)}h`;
  if (s < 7 * 86400) return `${Math.floor(s / 86400)}d`;
  return `${Math.floor(s / (7 * 86400))}w`;
}

function renderConversationsList() {
  const list = conversationsCache;
  els.historyList.innerHTML = "";
  if (!list || list.length === 0) {
    els.historyEmpty.classList.remove("is-hidden");
    return;
  }
  els.historyEmpty.classList.add("is-hidden");

  // Group by bucket while preserving updatedAt-desc order.
  const buckets = ["Today", "Yesterday", "This week", "Older"];
  const grouped = { Today: [], Yesterday: [], "This week": [], Older: [] };
  for (const entry of list) grouped[bucketForTimestamp(entry.updatedAt)].push(entry);

  for (const name of buckets) {
    const rows = grouped[name];
    if (!rows.length) continue;
    const heading = document.createElement("div");
    heading.className = "history-group-heading";
    heading.textContent = name;
    els.historyList.appendChild(heading);
    for (const entry of rows) {
      els.historyList.appendChild(buildHistoryRow(entry));
    }
  }
}

function buildHistoryRow(entry) {
  const row = document.createElement("button");
  row.type = "button";
  row.className = "history-row";
  if (entry.id === activeConversationId) row.classList.add("is-active");
  row.dataset.convId = entry.id;
  row.innerHTML = `
    <span class="history-row-title"></span>
    <span class="history-row-meta">
      <span class="history-row-preview"></span>
      <span class="history-row-time"></span>
    </span>
    <button class="history-row-delete" type="button" aria-label="Delete chat">×</button>
  `;
  row.querySelector(".history-row-title").textContent = entry.title || "Untitled chat";
  row.querySelector(".history-row-preview").textContent = entry.preview || "";
  row.querySelector(".history-row-time").textContent = relativeTime(entry.updatedAt);
  row.addEventListener("click", (e) => {
    // Clicks on the inner delete button are routed below; the row's
    // own click switches conversations.
    if (e.target.closest(".history-row-delete")) return;
    ensurePort();
    port.postMessage({ type: "conversation.switch", id: entry.id });
    closeHistory();
  });
  row.querySelector(".history-row-delete").addEventListener("click", (e) => {
    e.stopPropagation();
    ensurePort();
    port.postMessage({ type: "conversation.delete", id: entry.id });
  });
  return row;
}

// Rendered when the backend returns 402 mid-session. Looks like a
// chat bubble (so it sits in the conversation flow) but has the
// orange-tinted paywall surface and an embedded Upgrade button that
// triggers the same Stripe Checkout flow as the upsell pane.
function appendPaywallBubble(message) {
  const el = document.createElement("div");
  el.className = "msg is-error is-paywall";
  el.innerHTML = `
    <div class="msg-role">klo</div>
    <div class="msg-text"></div>
    <button class="msg-cta" type="button">
      Subscribe — $20/mo
      <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
        <path d="M3 8H13M13 8L8.5 3.5M13 8L8.5 12.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </button>
  `;
  el.querySelector(".msg-text").textContent = message || "Your subscription's inactive.";
  const cta = el.querySelector(".msg-cta");
  cta.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    startCheckoutFlow();
  });
  els.body.appendChild(el);
  els.body.scrollTop = els.body.scrollHeight;
}

function humanizeTool(name) {
  const nice = {
    tabs_active:       "checking tab",
    tabs_read_text:    "reading the page",
    tabs_dom_snapshot: "scanning the page",
    tabs_click_idx:    "clicking",
    tabs_click_text:   "clicking",
    tabs_real_click:   "clicking",
    tabs_fill_text:    "filling field",
    tabs_fill:         "filling field",
    tabs_navigate:     "navigating",
    tabs_create:       "opening new tab",
    tabs_wait_for:     "waiting",
    tabs_screenshot:   "looking at the screen",
  };
  return nice[name] || name;
}

// Tiny markdown subset, no library, no XSS surface.
function renderMarkdown(src) {
  let s = escapeHTML(src);
  s = s.replace(/```([\s\S]*?)```/g, (_m, code) => `<pre><code>${code}</code></pre>`);
  s = s.replace(/`([^`\n]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/_([^_\n]+)_/g, "<em>$1</em>");
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
                '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  s = s.replace(/(^|[\s])(https?:\/\/[^\s<]+)/g,
                '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>');
  s = s.replace(/\n/g, "<br>");
  return s;
}

function escapeHTML(s) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ─── Bridge status ─────────────────────────────────────────────────────────
//
// The bridge connects the extension to the klo Mac app over a local
// WebSocket. Three states the user sees:
//   - LIVE        (olive dot)     — Mac app running, bridge connected
//   - WAITING     (pulsing olive) — panel has been open 5s+ without a
//                                   connection. Click opens download.
//   - IDLE        (grey dot)      — fresh open, still establishing.
// The 5s grace exists because MV3 service workers cold-start; surfacing
// "waiting" instantly would flicker for every panel open.

const BRIDGE_WAITING_AFTER_MS = 5000;
let bridgeFirstOpenedAt = Date.now();
let bridgeEverConnected = false;
let bridgeWaitingTimer = null;

function renderBridge(connected) {
  if (connected) bridgeEverConnected = true;
  const isWaiting = !connected
    && !bridgeEverConnected
    && Date.now() - bridgeFirstOpenedAt >= BRIDGE_WAITING_AFTER_MS;

  els.bridgeDot.classList.toggle("ok", !!connected);
  els.bridgeDot.classList.toggle("err", !connected && !isWaiting && bridgeEverConnected);
  els.bridgeDot.classList.toggle("waiting", isWaiting);
  els.bridgeRow?.classList.toggle("is-waiting", isWaiting);

  if (connected) {
    els.bridgeStat.textContent = "bridge: live";
  } else if (isWaiting) {
    els.bridgeStat.textContent = "waiting for klo mac app";
  } else {
    els.bridgeStat.textContent = "bridge: idle";
  }

  // Inline chat banner — only for the regression case (Mac app was
  // connected this session and went away), so users without the Mac
  // app never see it.
  const macAppLost = !connected && bridgeEverConnected;
  if (els.connBanner) {
    els.connBanner.classList.toggle("is-visible", macAppLost);
    if (macAppLost) {
      els.connBanner.textContent = "Mac app not connected — open klo on your Mac.";
    }
  }
}
function refreshBridge() {
  chrome.runtime.sendMessage({ kind: "request_status" }, (resp) => {
    if (chrome.runtime.lastError || !resp) return renderBridge(false);
    renderBridge(resp.connected);
  });
}
els.mReconnect.addEventListener("click", () => {
  chrome.runtime.sendMessage({ kind: "reconnect" }, () => refreshBridge());
});
els.bridgeRow?.addEventListener("click", () => {
  if (!els.bridgeRow.classList.contains("is-waiting")) return;
  chrome.tabs.create({
    url: "https://github.com/klo-local/klo-local#readme",
    active: true,
  }).catch(() => {});
});
els.bridgeRow?.addEventListener("keydown", (e) => {
  if ((e.key === "Enter" || e.key === " ") && els.bridgeRow.classList.contains("is-waiting")) {
    e.preventDefault();
    els.bridgeRow.click();
  }
});
chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.kind === "bridge_status") renderBridge(msg.connected);
});

// Force a re-render at the 5s mark so the chip flips to "waiting" even
// if no bridge_status broadcast lands between now and then.
bridgeWaitingTimer = setTimeout(refreshBridge, BRIDGE_WAITING_AFTER_MS + 100);

// ─── Storage change → refresh auth (e.g. magic link callback finished) ──────

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && (changes.klo_access_token || changes.klo_refresh_token)) {
    refreshAuthGate();
  }
});

// ─── Boot ───────────────────────────────────────────────────────────────────

refreshAuthGate();
refreshBridge();
setInterval(refreshBridge, 5000);
