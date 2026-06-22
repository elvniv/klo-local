/* klo billing callback.
 *
 * Loaded by Stripe Checkout's success_url and cancel_url after a
 * subscription flow that started from the chrome extension. Two
 * states:
 *
 *   - ?ok=1   → payment captured. Force /auth/me to refresh so the
 *                upsell pane in the extension flips to chat. Auto-
 *                close the tab.
 *   - ?cancel=1 → user backed out. Just close the tab; pane stays on
 *                  upsell so they can retry.
 *
 * Mirrors auth-callback.js's pattern: live in the chrome-extension://
 * origin, talk to background via chrome.runtime, then close.
 */

const $ = (sel) => document.querySelector(sel);

const params = new URLSearchParams(window.location.search);
const ok = params.get("ok") === "1";
const canceled = params.get("cancel") === "1";

if (canceled) {
  $("#title").textContent = "Checkout canceled.";
  $("#subtitle").textContent = "No charge was made. You can close this tab.";
  $("#tag-label").textContent = "Canceled";
  setTimeout(() => {
    try { window.close(); } catch (_) {}
  }, 1500);
} else if (ok) {
  $("#title").textContent = "Activating klo…";
  $("#subtitle").textContent = "Confirming your subscription with Stripe.";
  // Force a fresh /auth/me read so the upsell pane in the side panel
  // and in-page overlay both flip to chat. Background also broadcasts
  // auth.status_changed which any open klo surface listens for.
  (async () => {
    try {
      const status = await chrome.runtime.sendMessage({ type: "klo.auth_status", force: true });
      if (status && status.signed_in && (status.subscription_status === "active" || status.subscription_status === "trialing")) {
        $("#title").textContent = "You're in.";
        $("#subtitle").textContent = "Hit ⌥K on any page. Closing this tab.";
        $("#tag-label").textContent = "Active";
        setTimeout(() => {
          try { window.close(); } catch (_) {}
        }, 1500);
      } else {
        // Stripe charged but our DB hasn't caught up — the webhook
        // either hasn't fired yet or didn't reach us. Tell the user
        // to give it a beat and come back; the side panel's
        // visibilitychange handler will retry on focus.
        $("#title").textContent = "Hold on a sec.";
        $("#subtitle").textContent = "Stripe is confirming with klo. If this stays for more than 30 seconds, refresh the side panel and click \"I already subscribed\".";
        $("#tag-label").textContent = "Syncing";
      }
    } catch (e) {
      // chrome.* unreachable — extension was reloaded mid-flow.
      const stale = e && e.message && String(e.message).includes("Extension context invalidated");
      const msg = stale
        ? "klo was reloaded — refresh this page to reconnect."
        : `Couldn't reach klo: ${e && e.message ? e.message : e}`;
      $("#status").className = "status err";
      $("#status").textContent = msg;
    }
  })();
} else {
  // No params at all — shouldn't happen via Stripe but render
  // something graceful if a user opens the URL directly.
  $("#title").textContent = "Nothing to do here.";
  $("#subtitle").textContent = "You can close this tab.";
}
