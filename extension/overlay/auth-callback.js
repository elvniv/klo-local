/* klo extension auth callback.
 *
 * This page is loaded in two situations:
 *
 *   1. ACTION=START — user opened this page directly (rare; the normal
 *      entry point is the side panel). Shows the iOS-style outline
 *      capsule that kicks off Google OAuth via /auth/oauth/start.
 *
 *   2. CALLBACK from Supabase Google OAuth. Supabase redirects back
 *      here with `#access_token=...&refresh_token=...` in the URL
 *      fragment. We pull tokens out, hand them to the background
 *      service worker via chrome.runtime.sendMessage, and auto-close
 *      once the worker confirms storage.
 */

const KLO_CLOUD_URL = "http://127.0.0.1:8789"; // Loopback-only fallback for public local builds.

const $ = (sel) => document.querySelector(sel);
const els = {
  signin:    $("#signin-form"),
  callback:  $("#callback-handler"),
  sendBtn:   $("#send-btn"),
  sendLabel: $("#send-btn-label"),
  ctaWrap:   $("#cta-wrap"),
  tagline:   $("#tagline-text"),
  status:    $("#status"),
};

function setStatus(text, kind = "info") {
  els.status.className = `status ${kind}`;
  els.status.textContent = text;
}

// Mirrors SignInScreen.awaitingOAuth: label flips, glow pauses,
// button disables. The cream Google-G disc stays so the affordance
// reads even when loading — same iOS pattern.
function setLoading(loading) {
  if (!els.sendBtn) return;
  els.sendBtn.disabled = loading;
  els.ctaWrap?.classList.toggle("is-loading", loading);
  if (els.sendLabel) {
    els.sendLabel.textContent = loading ? "opening google" : "continue with google";
  }
}

// Swap the rotating tagline copy out of cycle and into a single static
// message — used when the page is mid-callback or post-activation so
// the user sees the right state instantly.
function setTagline(text) {
  if (!els.tagline) return;
  els.tagline.classList.add("is-fading");
  setTimeout(() => {
    els.tagline.textContent = text;
    els.tagline.classList.remove("is-fading");
  }, 200);
}

async function startSignIn() {
  setLoading(true);
  setStatus("opening google sign-in.", "info");
  try {
    const redirect = chrome.runtime.getURL("overlay/auth-callback.html");
    const resp = await fetch(`${KLO_CLOUD_URL}/auth/oauth/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ provider: "google", redirect_to: redirect }),
    });
    if (!resp.ok) {
      const body = await resp.text();
      setStatus(`klo-cloud ${resp.status}: ${body.slice(0, 200)}`, "err");
      setLoading(false);
      return;
    }
    const { url } = await resp.json();
    if (!url) {
      setStatus("klo-cloud returned no OAuth URL.", "err");
      setLoading(false);
      return;
    }
    window.location.href = url;
  } catch (e) {
    const stale = e && e.message && e.message.includes("Extension context invalidated");
    const msg = stale
      ? "klo was reloaded. refresh this page to reconnect."
      : `couldn't reach klo-cloud: ${e.message}`;
    setStatus(msg, "err");
    setLoading(false);
  }
}

function parseFragment(fragment) {
  const out = {};
  if (!fragment) return out;
  const trimmed = fragment.startsWith("#") ? fragment.slice(1) : fragment;
  for (const pair of trimmed.split("&")) {
    const [k, v] = pair.split("=").map(decodeURIComponent);
    if (k) out[k] = v;
  }
  return out;
}

async function handleCallback() {
  const params = parseFragment(window.location.hash);
  const accessToken = params.access_token;
  const refreshToken = params.refresh_token;
  if (!accessToken) return false;

  // Hide the Google button, show the spinner card.
  if (els.signin) els.signin.style.display = "none";
  els.callback?.classList.add("is-visible");
  setTagline("activating klo");

  try {
    const ack = await chrome.runtime.sendMessage({
      type: "klo.set_tokens",
      access_token: accessToken,
      refresh_token: refreshToken || null,
    });
    if (!ack || !ack.ok) throw new Error("background didn't acknowledge");

    // Clear any legacy magic-link pending flag.
    try { await chrome.storage.local.remove("klo_auth_pending"); } catch (_) {}

    const status = await chrome.runtime.sendMessage({ type: "klo.auth_status" });
    if (!status || !status.signed_in) throw new Error("token didn't persist");

    setStatus("klo activated. you can close this tab.", "ok");
    setTagline("hit ⌥K on any page to talk to klo");

    setTimeout(() => {
      try { window.close(); } catch (_) {}
    }, 2000);
  } catch (e) {
    setStatus(`activation failed: ${e.message}`, "err");
  }
  return true;
}

// ─── Rotating tagline (same cadence + phrases as SignInScreen) ──────
const TAGLINES = [
  "activate klo on this browser",
  "drive your chrome with klo",
  "ask. klo runs.",
  "your agent on call",
];
let taglineIdx = 0;
let taglineTimer = null;
function startTaglineRotation() {
  if (taglineTimer) return;
  taglineTimer = setInterval(() => {
    if (!els.tagline || els.callback?.classList.contains("is-visible")) return;
    els.tagline.classList.add("is-fading");
    setTimeout(() => {
      taglineIdx = (taglineIdx + 1) % TAGLINES.length;
      els.tagline.textContent = TAGLINES[taglineIdx];
      els.tagline.classList.remove("is-fading");
    }, 400);
  }, 3600);
}

// ─── Boot ───────────────────────────────────────────────────────────
(async function init() {
  els.sendBtn?.addEventListener("click", startSignIn);

  const wasCallback = await handleCallback();
  if (!wasCallback) {
    const status = await chrome.runtime.sendMessage({ type: "klo.auth_status" }).catch(() => null);
    if (status && status.signed_in) {
      if (els.signin) els.signin.style.display = "none";
      setStatus("klo is ready. hit ⌥K on any page.", "ok");
      setTagline("you're already in");
    } else {
      startTaglineRotation();
    }
  }
})();
