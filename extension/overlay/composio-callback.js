/* extension/overlay/composio-callback.js
 *
 * Reached after Composio redirects back from the toolkit's OAuth.
 * URL shape:
 *   chrome-extension://EXT_ID/overlay/composio-callback.html
 *     ?toolkit=<slug>&connectedAccountId=<id>
 *
 * Surface stays minimal and on-brand. The progress ring spins while
 * the POST is in flight, fills to a complete circle on success, and
 * a checkmark pops in beside the tile. A visible countdown ticks
 * down to the auto-close.
 */

const KLO_CLOUD_URL = "http://127.0.0.1:8789"; // Loopback-only fallback for public local builds.

const $ = (sel) => document.querySelector(sel);

function param(name) {
  return new URLSearchParams(window.location.search).get(name);
}

function setStatus(text, kind = "info") {
  const el = $("#status");
  el.className = `status ${kind}`;
  el.textContent = text;
}

function renderBrand(slug) {
  const tile = $("#brand-tile");
  if (!tile) return;
  // Paint the surface in the toolkit's brand color. Body bloom,
  // tagline rules, progress ring, and checkmark all read from --brand
  // so the whole page reads as "this is about <Gmail>".
  const color = Composio.color(slug);
  document.documentElement.style.setProperty("--brand", color);
  const url = Composio.iconURL(slug);
  if (url) {
    const img = document.createElement("img");
    img.src = url;
    img.alt = Composio.displayName(slug);
    tile.appendChild(img);
  } else {
    tile.classList.add("monogram");
    tile.textContent = Composio.monogram(slug);
  }
  $("#title").textContent = `connecting ${Composio.displayName(slug)}`;
  $("#tagline-text").textContent = `${Composio.displayName(slug).toUpperCase()} · OAUTH`;
}

function showSuccess(slug) {
  // Stop spinning, complete the ring, pop the checkmark, swap copy.
  const ring = $("#progress-ring");
  ring.classList.remove("is-spinning");
  ring.classList.add("is-complete");
  $("#card").classList.add("is-success");
  $("#title").textContent = `${Composio.displayName(slug)} connected`;
  $("#subtitle").textContent = "you can close this tab.";
  $("#tagline-text").textContent = `${Composio.displayName(slug).toUpperCase()} · LIVE`;
}

function startCountdown(seconds, onZero) {
  const el = $("#countdown");
  let remaining = seconds;
  el.textContent = `CLOSING IN ${remaining}`;
  const tick = setInterval(() => {
    remaining -= 1;
    if (remaining <= 0) {
      clearInterval(tick);
      onZero();
      return;
    }
    el.textContent = `CLOSING IN ${remaining}`;
  }, 1000);
}

function showError(msg) {
  const ring = $("#progress-ring");
  ring.classList.remove("is-spinning");
  ring.style.opacity = "0";
  setStatus(msg, "err");
}

async function finalize() {
  const toolkit = (param("toolkit") || "").toLowerCase();
  const connectedAccountId = param("connectedAccountId") || param("connection_id") || null;

  if (!toolkit) {
    showError("missing toolkit param. close this tab and try again.");
    return;
  }
  renderBrand(toolkit);

  // Composio's connection often goes INITIATED → ACTIVE in the second
  // after the redirect lands. Retry 4× with backoff so the user
  // doesn't see "could not finalize" when they actually did finish.
  const attempts = [0, 800, 1600, 3200];
  let lastErr = "unknown error";
  for (let i = 0; i < attempts.length; i++) {
    if (attempts[i] > 0) await new Promise((r) => setTimeout(r, attempts[i]));
    try {
      const resp = await chrome.runtime.sendMessage({
        type: "klo.composio.callback",
        toolkit,
        connection_id: connectedAccountId,
      });
      if (resp && resp.ok) {
        showSuccess(toolkit);
        startCountdown(3, () => {
          try { window.close(); } catch (_) {}
        });
        return;
      }
      lastErr = (resp && resp.error) || lastErr;
      // Only retry on the inactive race; other errors are terminal.
      if (lastErr && !/inactive|initiated|not.?active|400/i.test(lastErr)) break;
    } catch (e) {
      const stale = e && e.message && e.message.includes("Extension context invalidated");
      if (stale) {
        showError("klo was reloaded. refresh this page.");
        return;
      }
      lastErr = e.message || lastErr;
    }
  }
  showError(`could not finalize: ${lastErr}`);
}

finalize();
