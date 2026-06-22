/* klo in-page side panel.
 *
 * Mounts as a content script. Renders a docked side panel on the
 * right edge of any http(s) page that:
 *   1. Pushes the page content over (sets margin-right on <html>),
 *      so the panel doesn't overlap. Like Friday in Gmail, but works
 *      on any website by manipulating documentElement margins.
 *   2. Has a 12px drag handle on its left edge for resize. Width is
 *      persisted in chrome.storage.local across pages and reloads.
 *   3. Hosts the full klo chat surface: Google OAuth sign-in,
 *      chat input + streaming response, status pill.
 *
 * Communication with background.js uses the klo-chat long-lived port,
 * same protocol the side panel + old overlay used.
 *
 * UI lives entirely in a Shadow DOM rooted on a single host div, so
 * the page's CSS can't reach our styles and ours can't bleed back.
 */

(() => {
  // Version-stamped mount guard. When the extension reloads or updates,
  // background.js re-injects this script into every open tab. The OLD
  // content script's `window.__klo_overlay_v` is still set on the page,
  // but its chrome.* listeners are dead. We need to sweep its orphan
  // DOM hosts and re-mount fresh. Same version = same instance, bail.
  const VERSION = (() => {
    try { return chrome.runtime.getManifest().version; } catch (_) { return "unknown"; }
  })();
  if (window.__klo_overlay_v === VERSION) return;
  if (window.__klo_overlay_v) {
    // Sweep all of the prior instance's persistent DOM artefacts so the
    // new instance starts clean. Also strip the klo-shrunk class on
    // <html> in case the prior instance left the page shrunk.
    document.querySelectorAll(
      "#klo-panel-host, #klo-onboard-host, #klo-host-page-style, #klo-page-world-patch"
    ).forEach((el) => {
      try { el.remove(); } catch (_) {}
    });
    try { document.documentElement.classList.remove("klo-shrunk", "klo-dragging"); } catch (_) {}
  }
  window.__klo_overlay_v = VERSION;
  window.__klo_panel_mounted = true;

  const KLO_CLOUD_URL = "http://127.0.0.1:8789"; // Loopback-only fallback for public local builds.
  const DEFAULT_WIDTH = 380;
  const MIN_WIDTH     = 320;
  const MAX_WIDTH_PCT = 0.6;   // 60% of viewport
  const STORAGE_KEY_W = "klo_panel_width";
  // Cross-tab open state: when true, every tab with a content script
  // mounted will auto-open its panel. Closing in any tab closes
  // everywhere. Lets klo's tab navigations stay smooth.
  const STORAGE_KEY_OPEN  = "klo_panel_open";
  // Auth tokens (mirrored from background.js for fast pane decisions).
  const STORAGE_KEY_TOKEN = "klo_access_token";
  // Chat input draft, persisted on every keystroke (debounced) so
  // unfinished prompts survive a klo-driven navigation.
  const STORAGE_KEY_DRAFT = "klo_input_draft";
  // Magic-link state. While truthy, the signin pane shows the "click
  // the email" pending sub-view instead of the form. Cleared when the
  // auth-callback consumes a token, or when the user picks a different
  // email. Shape: { email: string, sentAt: number }
  const STORAGE_KEY_AUTH_PENDING = "klo_auth_pending";
  // First-run gate. While falsy, every host page mounts a one-time
  // "Press ⌘K" cloud in the bottom-right corner that teaches the
  // shortcut. Set to true the first time the user actually presses ⌘K
  // (in any tab) — storage.onChanged broadcasts the dismiss to other
  // open tabs that already have the cloud showing.
  const STORAGE_KEY_ONBOARD = "klo_onboard_seen";

  const WEBMAIL = {
    "gmail.com":      "https://mail.google.com",
    "googlemail.com": "https://mail.google.com",
    "outlook.com":    "https://outlook.live.com/mail/0/inbox",
    "hotmail.com":    "https://outlook.live.com/mail/0/inbox",
    "live.com":       "https://outlook.live.com/mail/0/inbox",
    "msn.com":        "https://outlook.live.com/mail/0/inbox",
    "yahoo.com":      "https://mail.yahoo.com",
    "yahoo.co.uk":    "https://mail.yahoo.com",
    "icloud.com":     "https://www.icloud.com/mail",
    "me.com":         "https://www.icloud.com/mail",
    "mac.com":        "https://www.icloud.com/mail",
    "proton.me":      "https://mail.proton.me/u/0/inbox",
    "protonmail.com": "https://mail.proton.me/u/0/inbox",
    "pm.me":          "https://mail.proton.me/u/0/inbox",
    "aol.com":        "https://mail.aol.com",
    "fastmail.com":   "https://app.fastmail.com",
    "zoho.com":       "https://mail.zoho.com",
  };

  // Panel state
  let host = null;
  let shadow = null;
  let panel = null;
  let isOpen = false;
  let panelWidth = DEFAULT_WIDTH;
  // Track viewport width so we can distinguish "user resized the window"
  // from "we just dispatched a resize event ourselves."
  let lastViewportWidth = window.innerWidth;

  // ─── Auth-host detection ──────────────────────────────────────────────────
  //
  // OAuth / SSO / sign-in pages have specific layout requirements
  // (centered cards, fixed widths, viewport-relative units, mobile
  // media queries). The page-shrink mechanism (klo-shrunk class +
  // window.innerWidth patch) routinely breaks them: cards get clipped,
  // buttons hide off-screen, mobile layouts trigger at desktop sizes.
  //
  // Policy on auth hosts:
  //   - Do NOT auto-open the panel (even if storage says open).
  //   - If user manually opens (Alt+K), mount in float mode: panel
  //     shows but the host page is NOT shrunk and innerWidth is NOT
  //     patched. OAuth UI renders at full width.
  //
  // The list is heuristic — it catches the common providers + obvious
  // path patterns. False positives are cheap (klo just float-overlays
  // instead of pushing; user can still close it). False negatives mean
  // the page might get squished — file a bug and add the pattern.
  function isAuthHost() {
    const h = (location.hostname || "").toLowerCase();
    const p = (location.pathname || "").toLowerCase();
    // Subdomain prefixes: typical hostnames for hosted SSO / sign-in UIs.
    if (/^(accounts|login|auth|signin|sso|id|idp|secure|my)\./.test(h)) return true;
    // Major identity providers (tenant subdomains).
    if (/\.(auth0|okta|onelogin|pingidentity|duosecurity|duo|workos|frontegg|stytch|clerk|descope)\.com$/.test(h)) return true;
    if (/\.okta-emea\.com$/.test(h)) return true;
    if (/\.clerk\.accounts\.dev$/.test(h)) return true;
    // Well-known exact hosts.
    const exact = new Set([
      "appleid.apple.com",
      "login.live.com",
      "login.microsoftonline.com",
      "login.microsoft.com",
      "login.salesforce.com",
      "login.yahoo.com",
      "github.com",     // /login + /sessions + /login/oauth — gated by path below
      "gitlab.com",     // /users/sign_in + /users/auth — gated by path below
      "bitbucket.org",  // /account/signin — gated by path below
    ]);
    if (exact.has(h)) {
      // For these dual-purpose hosts, only consider it an auth context
      // when the path looks auth-y. Avoids breaking the rest of the site.
      return /^\/(login|signin|sign_in|sessions|users\/sign_in|users\/auth|account\/signin|oauth)(\/|$|\?)/.test(p);
    }
    // Path-based fallback for arbitrary domains hosting login at a
    // subpath. Conservative — only the most unambiguous patterns.
    if (/^\/(login|signin|sign-in|sign_in|sessions\/new|oauth\/authorize|sso\/login)(\/|$|\?)/.test(p)) return true;
    return false;
  }

  // Onboarding cloud state — separate Shadow DOM host so the cloud and
  // the panel are visually independent (no z-index wars during the
  // dismiss-then-open transition).
  let onboardHost = null;
  let onboardCard = null;

  // Fixed-bar snapping state — see tagFixedFullWidthElements() below.
  let snapObserver = null;
  let snapDebounceId = 0;

  // ─── Host-page stylesheet ─────────────────────────────────────────────────
  //
  // Injected into the host document (NOT the shadow root), so it can
  // affect the page's own html/body. !important rules + targeting both
  // html and body, with width AND max-width, beats whatever CSS the
  // site has defined. Toggled via the `klo-shrunk` class on <html> so
  // close() reverts cleanly with no inline-style snapshot/restore.
  const HOST_PAGE_CSS = `
    /* Root: just hide horizontal overflow and animate width. The actual
     * width constraint is applied to body and to common SPA app roots
     * below, which is what most sites lay out from. */
    html.klo-shrunk {
      width: var(--klo-shrink-width, 100%) !important;
      max-width: var(--klo-shrink-width, 100%) !important;
      min-width: 0 !important;
      overflow-x: hidden !important;
      box-sizing: border-box !important;
      transition: width 200ms cubic-bezier(0.2, 0.9, 0.3, 1),
                  max-width 200ms cubic-bezier(0.2, 0.9, 0.3, 1) !important;
    }

    /* Hit every layout root we know about. Sites use different mount
     * points, so we shotgun the common patterns:
     *   - body and its first-child div: covers vanilla layouts
     *   - #root: React (Create React App, plain ReactDOM.render)
     *   - #__next, #__next-build-watcher: Next.js
     *   - #__nuxt, #__layout: Nuxt
     *   - #app, #app-mount: Vue, Discord, many other SPAs
     *   - main: semantic HTML
     *   - [data-reactroot]: legacy React
     *   - [id^="root-"]: namespaced React mounts
     * Both width AND max-width because some sites set width:100vw
     * which beats max-width on tie; max-width is the safety net.
     */
    html.klo-shrunk body,
    html.klo-shrunk body > div:first-child,
    html.klo-shrunk body > main:first-child,
    html.klo-shrunk #root,
    html.klo-shrunk #__next,
    html.klo-shrunk #__nuxt,
    html.klo-shrunk #__layout,
    html.klo-shrunk #app,
    html.klo-shrunk #app-mount,
    html.klo-shrunk main,
    html.klo-shrunk [data-reactroot] {
      width: var(--klo-shrink-width, 100%) !important;
      max-width: var(--klo-shrink-width, 100%) !important;
      min-width: 0 !important;
      overflow-x: hidden !important;
      box-sizing: border-box !important;
      transition: width 200ms cubic-bezier(0.2, 0.9, 0.3, 1),
                  max-width 200ms cubic-bezier(0.2, 0.9, 0.3, 1) !important;
    }

    /* During drag we want 1:1 tracking, no easing. */
    html.klo-shrunk.klo-dragging,
    html.klo-shrunk.klo-dragging body,
    html.klo-shrunk.klo-dragging body > div:first-child,
    html.klo-shrunk.klo-dragging #root,
    html.klo-shrunk.klo-dragging #__next,
    html.klo-shrunk.klo-dragging #__nuxt,
    html.klo-shrunk.klo-dragging #__layout,
    html.klo-shrunk.klo-dragging #app,
    html.klo-shrunk.klo-dragging #app-mount,
    html.klo-shrunk.klo-dragging main {
      transition: none !important;
    }

    /* Fixed/sticky bars (top navs, sticky headers, cookie banners,
     * modal scrims) get tagged via JS in tagFixedFullWidthElements()
     * because pure CSS can't query computed position. The rule below
     * pulls every tagged element off the panel by:
     *   - clamping width via 100vw - panel (handles width:100% / 100vw)
     *   - pinning right + inset-inline-end to panel-width (handles
     *     left:0; right:0 anchors and RTL via the logical property)
     * --klo-panel-width is set on <html> in setPanelWidth so drag
     * ticks update every snapped element instantly via calc(). */
    html.klo-shrunk [data-klo-fixed-snap] {
      width: calc(100vw - var(--klo-panel-width, 0px)) !important;
      max-width: calc(100vw - var(--klo-panel-width, 0px)) !important;
      right: var(--klo-panel-width, 0px) !important;
      inset-inline-end: var(--klo-panel-width, 0px) !important;
      box-sizing: border-box !important;
      transition: width 200ms cubic-bezier(0.2, 0.9, 0.3, 1),
                  max-width 200ms cubic-bezier(0.2, 0.9, 0.3, 1),
                  right 200ms cubic-bezier(0.2, 0.9, 0.3, 1) !important;
    }
    html.klo-shrunk.klo-dragging [data-klo-fixed-snap] {
      transition: none !important;
    }
  `;

  // Patch script injected into the *page* world (not our isolated content
  // script world) so it can override the page's window.innerWidth and
  // friends. Many SPAs read these directly to lay out, ignoring CSS.
  // Has to be a string because the page-world doesn't have access to
  // our content-script bindings.
  //
  // We patch:
  //   window.innerWidth          → virtual width
  //   window.outerWidth          → virtual width
  //   document.documentElement.clientWidth → virtual width
  //
  // Restored when the page receives a `klo:viewport-restore` event.
  // The virtual width is communicated via a CSS variable on <html>
  // (--klo-virtual-width) which the page script reads.
  const PAGE_WORLD_PATCH = `
    (function() {
      if (window.__kloViewportPatched) return;
      window.__kloViewportPatched = true;

      function virtualWidth() {
        const v = parseInt(
          getComputedStyle(document.documentElement).getPropertyValue('--klo-virtual-width'),
          10
        );
        return isFinite(v) && v > 0 ? v : null;
      }

      const realInner = Object.getOwnPropertyDescriptor(window, 'innerWidth')
                     || Object.getOwnPropertyDescriptor(Object.getPrototypeOf(window) || Window.prototype, 'innerWidth');
      const realOuter = Object.getOwnPropertyDescriptor(window, 'outerWidth')
                     || Object.getOwnPropertyDescriptor(Object.getPrototypeOf(window) || Window.prototype, 'outerWidth');
      const realClient = Object.getOwnPropertyDescriptor(Element.prototype, 'clientWidth');

      try {
        Object.defineProperty(window, 'innerWidth', {
          configurable: true,
          get() { const v = virtualWidth(); return v != null ? v : (realInner ? realInner.get.call(this) : 0); },
        });
        Object.defineProperty(window, 'outerWidth', {
          configurable: true,
          get() { const v = virtualWidth(); return v != null ? v : (realOuter ? realOuter.get.call(this) : 0); },
        });
        Object.defineProperty(document.documentElement, 'clientWidth', {
          configurable: true,
          get() { const v = virtualWidth(); return v != null ? v : (realClient ? realClient.get.call(document.documentElement) : 0); },
        });
      } catch (e) {
        // Site might've sealed window already; nothing we can do.
        console.warn('[klo] viewport patch failed:', e);
      }
    })();
  `;

  // Chat state
  let port = null;
  let assistantBuffer = "";
  let assistantBubble = null;
  let isWorking = false;

  // Heartbeat watchdog + elapsed-time indicator. Mirror of the
  // side-panel logic (see sidepanel.js for rationale): SW broadcasts
  // agent.heartbeat every 2s; if 5s pass without one we surface a
  // stuck banner with retry. Status pill ticks elapsed seconds so the
  // user always sees progress.
  const HEARTBEAT_TIMEOUT_MS = 5000;
  let lastHeartbeatAt = 0;
  let elapsedTimer = null;
  let watchdogTimer = null;
  let elapsedSeconds = 0;
  let lastUserPrompt = "";
  let stuckBannerShown = false;

  // Cached UI refs (populated in mount())
  let signinPane, chatPane, signinBtn, signinFeedback;
  let signinViewForm, signinViewPending, pendingEmailEl;
  let pendingResendBtn, pendingResendLink;
  let upsellPane, upsellCtaBtn, upsellAlreadyBtn;
  let bodyEl, statusEl, statusTextEl, inputEl, sendBtn, stopBtn, inputRowEl, panelInnerEl;
  let connBannerEl;
  let menuBtn, menuEl, mSignin, mSignout, mNewChat, mHistory, mApps, appsBtn;
  let titlePillEl, titlePillTextEl;
  let historyMenuEl, historyEmptyEl, historyListEl;
  // Cached conversation index from the most recent state.snapshot or
  // conversations.updated broadcast. Used to re-render the History
  // dropdown without round-tripping background.
  let conversationsCache = [];
  let activeConversationId = null;

  const ACTIVE_STATUSES = new Set(["active", "trialing"]);

  // ─── Mount ────────────────────────────────────────────────────────────────

  async function mount() {
    if (host) return;

    // Pre-read persisted state so we can paint the right pane on the
    // first frame, no signin → chat flash. Width, auth token, draft,
    // and any pending magic-link state all read in one round trip.
    let initialSignedIn = false;
    let initialDraft = "";
    let initialPending = null;
    try {
      const stored = await chrome.storage.local.get([
        STORAGE_KEY_W,
        STORAGE_KEY_TOKEN,
        STORAGE_KEY_DRAFT,
        STORAGE_KEY_AUTH_PENDING,
      ]);
      if (stored && typeof stored[STORAGE_KEY_W] === "number") {
        panelWidth = clampWidth(stored[STORAGE_KEY_W]);
      }
      initialSignedIn = !!stored[STORAGE_KEY_TOKEN];
      initialDraft    = stored[STORAGE_KEY_DRAFT] || "";
      initialPending  = stored[STORAGE_KEY_AUTH_PENDING] || null;
    } catch (_) { /* storage may be unavailable on file:// */ }

    injectHostPageStyles();
    injectPageWorldPatch();

    host = document.createElement("div");
    host.id = "klo-panel-host";
    host.style.all = "initial";
    // Pin the host to the viewport. Without this, it sits at the end of
    // the document flow (default position: static) — and when open()
    // focuses an input inside the shadow DOM, the browser scrolls the
    // HOST into view, which jumps the page to its bottom (i.e. the
    // footer). The actual panel inside uses position:fixed too, so the
    // host's own positioning is decorative.
    host.style.position = "fixed";
    host.style.top = "0";
    host.style.left = "0";
    host.style.width = "0";
    host.style.height = "0";
    host.style.zIndex = "2147483646";
    document.documentElement.appendChild(host);
    shadow = host.attachShadow({ mode: "open" });

    // Inject CSS via fetch since content_scripts can't directly use <link>
    // with web_accessible_resources from a Shadow DOM without explicit
    // URL resolution.
    const cssURL = chrome.runtime.getURL("overlay/overlay.css");
    fetch(cssURL).then((r) => r.text()).then((css) => {
      const style = document.createElement("style");
      style.textContent = css;
      shadow.prepend(style);
    });

    panel = document.createElement("div");
    panel.className = "klo-panel";
    panel.hidden = true;
    panel.innerHTML = panelHTML();
    shadow.appendChild(panel);

    // Cache element refs.
    signinPane         = shadow.querySelector("#signin-pane");
    signinViewForm     = shadow.querySelector("#signin-view-form");
    signinViewPending  = shadow.querySelector("#signin-view-pending");
    pendingEmailEl     = shadow.querySelector("#pending-email");
    pendingResendBtn   = shadow.querySelector("#pending-resend-btn");
    pendingResendLink  = shadow.querySelector("#pending-resend-link");
    upsellPane         = shadow.querySelector("#upsell-pane");
    upsellCtaBtn       = shadow.querySelector("#upsell-cta");
    upsellAlreadyBtn   = shadow.querySelector("#upsell-already-subscribed");
    chatPane           = shadow.querySelector("#chat-pane");
    signinBtn          = shadow.querySelector("#signin-btn");
    signinFeedback     = shadow.querySelector("#signin-feedback");
    bodyEl             = shadow.querySelector("#body");
    connBannerEl       = shadow.querySelector("#conn-banner");
    statusEl           = shadow.querySelector("#status");
    statusTextEl       = shadow.querySelector("#status-text");
    inputEl            = shadow.querySelector("#input");
    sendBtn            = shadow.querySelector("#send-btn");
    stopBtn            = shadow.querySelector("#stop-btn");
    inputRowEl         = shadow.querySelector("#input-row");
    panelInnerEl       = shadow.querySelector(".klo-panel-inner");
    menuBtn            = shadow.querySelector("#menu-btn");
    menuEl             = shadow.querySelector("#menu");
    mSignin            = shadow.querySelector("#m-signin");
    mSignout           = shadow.querySelector("#m-signout");
    mNewChat           = shadow.querySelector("#m-new-chat");
    mHistory           = shadow.querySelector("#m-history");
    mApps              = shadow.querySelector("#m-apps");
    appsBtn            = shadow.querySelector("#apps-btn");
    titlePillEl        = shadow.querySelector("#title-pill");
    titlePillTextEl    = shadow.querySelector("#title-pill-text");
    historyMenuEl      = shadow.querySelector("#history-menu");
    historyEmptyEl     = shadow.querySelector("#history-empty");
    historyListEl      = shadow.querySelector("#history-list");

    // Pre-set the right pane based on whatever auth state we read above
    // so the very first frame the panel paints shows the correct UI.
    // refreshAuthGate runs again in open() to confirm with background.
    if (initialSignedIn) {
      chatPane.classList.add("is-visible");
      mSignout.style.display = "block";
      mSignin.style.display  = "none";
    } else {
      signinPane.classList.add("is-visible");
      mSignin.style.display  = "block";
      mSignout.style.display = "none";
      setSigninView(initialPending);
    }

    // Restore the in-progress chat input draft.
    if (initialDraft) {
      inputEl.value = initialDraft;
    }

    wireListeners();
    setPanelWidth(panelWidth);
    startSigninTaglineRotation();
  }

  // ─── Markup ───────────────────────────────────────────────────────────────

  function panelHTML() {
    // Both wordmark variants are shipped + web_accessible. We pick at
    // render time using <picture> so the visible wordmark always
    // contrasts against the panel surface (cream paper in light, klo-
    // black in dark). Browsers re-evaluate the <source> media match
    // when the OS theme flips, so no JS listener is needed.
    const logoBlackURL = chrome.runtime.getURL("overlay/klo-logo-black.png");
    const logoWhiteURL = chrome.runtime.getURL("overlay/klo-logo-white.png");
    // Vector wordmark for the signin watermark, scales crisply at any
    // panel width without pixelation.
    const logoSVGURL = chrome.runtime.getURL("overlay/klo-logo.svg");
    return `
      <div class="klo-resize-handle" aria-label="Resize panel" role="separator" aria-orientation="vertical" tabindex="-1"></div>
      <div class="klo-panel-inner">
        <div class="klo-header">
          <picture>
            <source media="(prefers-color-scheme: dark)" srcset="${logoWhiteURL}">
            <img class="klo-wordmark" src="${logoBlackURL}" alt="klo" draggable="false" />
          </picture>
          <!-- Title pill mirrors the side panel: shows the active conv
               title and toggles the History dropdown anchored under it. -->
          <button class="klo-tag klo-title-pill" id="title-pill" type="button" title="Switch chats">
            <span class="klo-tag-dot"></span>
            <span class="klo-title-pill-text" id="title-pill-text">new chat</span>
          </button>
          <button class="klo-header-apps" id="header-apps" title="Connected apps" aria-label="Connected apps">
            <span class="klo-header-apps-stack" id="header-apps-stack"></span>
            <span class="klo-header-apps-label" id="header-apps-label"></span>
          </button>
          <div class="klo-header-spacer"></div>
          <button class="klo-icon-btn" id="menu-btn" title="Menu">⋯</button>
          <button class="klo-icon-btn" id="close-btn" title="Close (⌥K)">&times;</button>
          <div class="klo-menu" id="menu">
            <div class="klo-menu-section">Chats</div>
            <button id="m-new-chat">New chat</button>
            <button id="m-history">Previous chats</button>
            <div class="klo-menu-divider"></div>
            <div class="klo-menu-section">Apps</div>
            <button id="m-apps">Browse apps</button>
            <div class="klo-menu-divider"></div>
            <div class="klo-menu-section">Account</div>
            <button id="m-signin">Sign in</button>
            <button id="m-signout" style="display:none">Sign out</button>
          </div>
          <!-- History dropdown anchored under the title pill. Same
               shadow-DOM treatment as the .klo-menu so click-outside
               handling is consistent. -->
          <div class="klo-history-menu" id="history-menu">
            <div class="klo-history-empty" id="history-empty">No previous chats yet.</div>
            <div class="klo-history-list" id="history-list"></div>
          </div>
        </div>

        <div class="klo-signin" id="signin-pane">
          <!-- Soft olive bloom — the CSS echo of MiniFireView. -->
          <div class="klo-signin-bg" aria-hidden="true"></div>

          <!-- Mirrors iOS SignInScreen: cream wordmark + rotating
               tagline with olive rules + outline-only capsule with
               Google-G cream disc + monospace legal. -->
          <div class="klo-signin-view" id="signin-view-form">
            <img class="klo-signin-glyph" src="${logoWhiteURL}" alt="klo" draggable="false" />
            <div class="klo-signin-tagline" aria-hidden="true">
              <span class="klo-signin-tagline-rule"></span>
              <span class="klo-signin-tagline-text" id="signin-tagline-text">drive your chrome with klo</span>
              <span class="klo-signin-tagline-rule"></span>
            </div>
            <div class="klo-signin-cta-wrap" id="signin-cta-wrap">
              <button class="klo-btn-primary" id="signin-btn" type="button">
                <span class="klo-g-disc" aria-hidden="true">
                  <svg viewBox="0 0 18 18">
                    <path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.7-1.57 2.68-3.88 2.68-6.62z"/>
                    <path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.81.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.32A9 9 0 0 0 9 18z"/>
                    <path fill="#FBBC05" d="M3.97 10.72A5.4 5.4 0 0 1 3.68 9c0-.6.1-1.18.29-1.72V4.96H.96A9 9 0 0 0 0 9c0 1.45.35 2.82.96 4.04l3.01-2.32z"/>
                    <path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58C13.46.89 11.43 0 9 0A9 9 0 0 0 .96 4.96l3.01 2.32C4.68 5.16 6.66 3.58 9 3.58z"/>
                  </svg>
                </span>
                <span class="klo-g-label" id="signin-btn-label">continue with google</span>
              </button>
              <span class="klo-signin-cta-glow" aria-hidden="true"></span>
            </div>

            <div class="klo-signin-feedback" id="signin-feedback"></div>

            <div class="klo-terms">
              by continuing you agree to our <a href="https://getklo.com/terms" target="_blank">terms</a> and <a href="https://getklo.com/privacy" target="_blank">privacy policy</a>
            </div>
          </div>
        </div>

        <div class="klo-upsell" id="upsell-pane">
          <img class="klo-upsell-glyph" src="${logoWhiteURL}" alt="klo" draggable="false" />
          <div class="klo-upsell-tag" aria-hidden="true">
            <span class="klo-upsell-tag-rule"></span>
            <span class="klo-upsell-tag-text">SUBSCRIBE TO KLO</span>
            <span class="klo-upsell-tag-rule"></span>
          </div>
          <h2>Tell it<br/>what to do.</h2>
          <p class="klo-upsell-lede">$20/mo &middot; cancel anytime</p>
          <div class="klo-upsell-cta-wrap" id="upsell-cta-wrap">
            <button type="button" class="klo-upsell-cta" id="upsell-cta">
              <span class="klo-lock-disc" aria-hidden="true">
                <svg viewBox="0 0 16 16" fill="none">
                  <path d="M4.5 7V5.25A3.5 3.5 0 0 1 8 1.75a3.5 3.5 0 0 1 3.5 3.5V7M3.5 7h9v6.5a.75.75 0 0 1-.75.75h-7.5a.75.75 0 0 1-.75-.75V7z" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
              </span>
              <span class="klo-upsell-cta-label" id="upsell-cta-label">subscribe with stripe</span>
            </button>
            <span class="klo-upsell-cta-glow" aria-hidden="true"></span>
          </div>
          <button type="button" class="klo-upsell-already" id="upsell-already-subscribed">i already subscribed</button>
          <p class="klo-upsell-fineprint">stripe &middot; secure checkout</p>
        </div>

        <div class="klo-chat" id="chat-pane">
          <div class="klo-body" id="body"></div>
          <div class="klo-conn-banner" id="conn-banner"></div>
          <div class="klo-status" id="status">
            <span class="klo-pulse"></span>
            <span class="klo-status-text" id="status-text">working</span>
          </div>
          <div class="klo-input-row" id="input-row">
            <div class="klo-slash-popover" id="slash-popover" role="listbox" aria-label="Slash command suggestions"></div>
            <textarea class="klo-input" id="input" rows="1" placeholder="tell klo what to do, or /app to scope it" autofocus></textarea>
            <span class="klo-send-btn-wrap">
              <button class="klo-send-btn" id="send-btn" title="Send" aria-label="Send">
                <svg width="11" height="11" viewBox="0 0 12 12" fill="none" aria-hidden="true">
                  <path d="M6 10V2M6 2L2.5 5.5M6 2L9.5 5.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
              </button>
              <span class="klo-send-btn-glow" aria-hidden="true"></span>
            </span>
            <button class="klo-stop-btn" id="stop-btn" title="Stop klo (esc)" aria-label="Stop klo">
              <svg width="10" height="10" viewBox="0 0 10 10" fill="currentColor" aria-hidden="true">
                <rect x="1.5" y="1.5" width="7" height="7" rx="1.2" />
              </svg>
            </button>
          </div>
          <div class="klo-footer-hint">
            <kbd>&#8997;K</kbd> toggles klo
          </div>
        </div>
      </div>
    `;
  }

  // ─── Listener wiring ──────────────────────────────────────────────────────

  function wireListeners() {
    shadow.querySelector("#close-btn").addEventListener("click", close);
    menuBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      historyMenuEl.classList.remove("is-visible");
      menuEl.classList.toggle("is-visible");
    });
    titlePillEl.addEventListener("click", (e) => {
      e.stopPropagation();
      menuEl.classList.remove("is-visible");
      historyMenuEl.classList.toggle("is-visible");
    });
    shadow.addEventListener("click", (e) => {
      if (!menuEl.contains(e.target) && e.target !== menuBtn) menuEl.classList.remove("is-visible");
      if (
        !historyMenuEl.contains(e.target)
        && e.target !== titlePillEl
        && !titlePillEl.contains(e.target)
      ) historyMenuEl.classList.remove("is-visible");
    });

    mNewChat.addEventListener("click", () => {
      menuEl.classList.remove("is-visible");
      ensurePort();
      port.postMessage({ type: "conversation.new" });
    });
    mHistory.addEventListener("click", () => {
      menuEl.classList.remove("is-visible");
      historyMenuEl.classList.add("is-visible");
    });

    // ─── Empty-state quick-connect chips ────────────────────────────
    // Mirrors sidepanel: when body has no real msgs, show a small
    // "START WITH AN APP" panel with brand chips above the placeholder.
    const EMPTY_HINT_SLUGS = ["gmail", "notion", "slack"];
    function renderEmptyHint() {
      if (!bodyEl || bodyEl.querySelector(".klo-empty-hint")) return;
      const hint = document.createElement("div");
      hint.className = "klo-empty-hint";
      const chipsHTML = EMPTY_HINT_SLUGS.map((slug) => {
        if (!window.Composio?.BUNDLED_SLUGS.has(slug)) return "";
        const name = window.Composio.displayName(slug);
        const url = window.Composio.iconURL(slug);
        const color = window.Composio.color(slug);
        return `
          <button class="klo-empty-hint-chip" data-slug="${slug}"
                  style="--brand-color:${color};--brand-edge:${color}55;--brand-tint:${color}10">
            ${url ? `<img src="${url}" alt="">` : ""}
            <span>${name}</span>
          </button>`;
      }).join("");
      hint.innerHTML = `
        <span class="klo-empty-hint-eyebrow">START WITH AN APP</span>
        <div class="klo-empty-hint-chips">${chipsHTML}</div>
        <span class="klo-empty-hint-trailer">or just tell klo what to do.</span>
      `;
      hint.querySelectorAll(".klo-empty-hint-chip").forEach((btn) => {
        btn.addEventListener("click", () => {
          const slug = btn.dataset.slug;
          inputEl.focus();
          inputEl.value = `/${slug} `;
          autoResizeInput();
          updateSlashPopover();
        });
      });
      bodyEl.appendChild(hint);
    }
    function updateEmptyState() {
      if (!bodyEl) return;
      const hasMessages = !!bodyEl.querySelector(".klo-msg");
      bodyEl.classList.toggle("is-empty", !hasMessages);
      if (!hasMessages) renderEmptyHint();
      else {
        const hint = bodyEl.querySelector(".klo-empty-hint");
        if (hint) hint.remove();
      }
    }
    if (typeof MutationObserver !== "undefined" && bodyEl) {
      const obs = new MutationObserver(() => updateEmptyState());
      obs.observe(bodyEl, { childList: true });
      updateEmptyState();
    }

    // "Apps" menu entry — open the toolkit picker by inserting "/"
    // and triggering the slash popover. No dedicated input-bar button
    // (the "+" version cluttered the input); slash typing is the
    // iOS-parity affordance.
    function openAppsPicker() {
      inputEl.focus();
      if (inputEl.value && !inputEl.value.startsWith("/")) {
        inputEl.value = "/" + inputEl.value;
      } else if (!inputEl.value) {
        inputEl.value = "/";
      }
      autoResizeInput();
      updateSlashPopover();
    }
    mApps?.addEventListener("click", () => {
      menuEl.classList.remove("is-visible");
      openAppsPicker();
    });

    signinBtn?.addEventListener("click", startSignIn);

    // Upsell pane CTAs.
    upsellCtaBtn?.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      startCheckoutFlow();
    });
    upsellAlreadyBtn?.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      refreshAuthGate({ force: true });
    });

    mSignin.addEventListener("click", () => {
      menuEl.classList.remove("is-visible");
      chatPane.classList.remove("is-visible");
      upsellPane?.classList.remove("is-visible");
      signinPane.classList.add("is-visible");
      signinBtn?.focus();
    });

    mSignout.addEventListener("click", async () => {
      menuEl.classList.remove("is-visible");
      await chrome.runtime.sendMessage({ type: "klo.sign_out" });
      if (signinBtn) signinBtn.disabled = false;
      hideSigninFeedback();
      refreshAuthGate();
    });

    let draftTimer = null;
    inputEl.addEventListener("input", () => {
      autoResizeInput();
      updateSlashPopover();
      // Persist the draft so a klo-driven navigation doesn't drop
      // what the user typed. Debounce to avoid hammering storage.
      clearTimeout(draftTimer);
      draftTimer = setTimeout(() => {
        try {
          if (inputEl.value) chrome.storage.local.set({ [STORAGE_KEY_DRAFT]: inputEl.value });
          else chrome.storage.local.remove(STORAGE_KEY_DRAFT);
        } catch (_) {}
      }, 250);
    });
    inputEl.addEventListener("keydown", (e) => {
      if (handleSlashKeydown(e)) return;
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        submit();
      } else if (e.key === "Escape" && isWorking) {
        // Esc inside the textarea cancels a running turn — keyboard
        // parity with the visible Stop button. Stops at the input so
        // we don't fight host-page Esc handlers.
        e.preventDefault();
        e.stopPropagation();
        requestCancel();
      }
    });
    inputEl.addEventListener("blur", () => {
      // Defer so click on a popover row registers before we hide it.
      setTimeout(closeSlashPopover, 120);
    });

    // ─── Slash-command popover wiring ──────────────────────────────
    // Mirrors sidepanel.js — when the user types "/<prefix>" we show
    // a popover with matching Composio toolkits. Arrow/Tab/Enter pick.
    let slashState = { active: false, items: [], index: 0 };
    let connectedToolkits = new Set();
    const slashPopoverEl = shadow.querySelector("#slash-popover");

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
      } catch (_) {}
      renderHeaderAppsStack();
    }
    function renderHeaderAppsStack() {
      const stack = shadow.querySelector("#header-apps-stack");
      const label = shadow.querySelector("#header-apps-label");
      const wrap = shadow.querySelector("#header-apps");
      if (!stack || !wrap || !label) return;
      const slugs = Array.from(connectedToolkits).filter((s) =>
        window.Composio?.BUNDLED_SLUGS.has(s)
      );
      if (!slugs.length) { wrap.classList.remove("is-visible"); return; }
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
    shadow.querySelector("#header-apps")?.addEventListener("click", () => openAppsPicker());

    function currentSlashPrefix() {
      const v = inputEl.value;
      if (!v.startsWith("/")) return null;
      const rest = v.slice(1);
      if (rest.includes(" ") || rest.includes("\n")) return null;
      return rest;
    }
    function renderSlashPopover() {
      if (!slashPopoverEl) return;
      slashPopoverEl.innerHTML = "";
      slashState.items.forEach((slug, idx) => {
        const row = document.createElement("div");
        const isConnected = connectedToolkits.has(slug);
        row.className = "klo-slash-row"
          + (idx === slashState.index ? " is-active" : "")
          + (isConnected ? " is-connected" : "");
        row.setAttribute("role", "option");
        row.dataset.slug = slug;
        const icon = document.createElement("span");
        icon.className = "klo-slash-row-icon";
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
        name.className = "klo-slash-row-name";
        name.textContent = window.Composio.displayName(slug);
        const slugEl = document.createElement("span");
        slugEl.className = "klo-slash-row-slug";
        slugEl.textContent = `/${slug}`;
        const enter = document.createElement("span");
        enter.className = "klo-slash-row-enter";
        enter.textContent = "↩";
        // Connected badge doubles as a disconnect affordance —
        // mirrors sidepanel.js: click arms "disconnect?", second
        // click fires klo.composio.disconnect.
        const status = document.createElement("button");
        status.type = "button";
        status.className = "klo-slash-row-status";
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
          e.preventDefault();
          acceptSlash(slug);
        });
        slashPopoverEl.appendChild(row);
      });
    }
    function updateSlashPopover() {
      if (!window.Composio || !slashPopoverEl) return;
      const prefix = currentSlashPrefix();
      if (prefix === null) { closeSlashPopover(); return; }
      const matches = prefix === ""
        ? Array.from(window.Composio.BUNDLED_SLUGS).sort().slice(0, 6)
        : window.Composio.matchPrefix(prefix).slice(0, 6);
      if (!matches.length) { closeSlashPopover(); return; }
      const wasActive = slashState.active;
      slashState.active = true;
      slashState.items = matches;
      if (slashState.index >= matches.length) slashState.index = 0;
      inputRowEl?.classList.add("has-slash");
      renderSlashPopover();
      if (!wasActive) refreshConnectedToolkits().then(renderSlashPopover);
    }
    function closeSlashPopover() {
      slashState = { active: false, items: [], index: 0 };
      inputRowEl?.classList.remove("has-slash");
      if (slashPopoverEl) slashPopoverEl.innerHTML = "";
    }
    function acceptSlash(slug) {
      inputEl.value = `/${slug} `;
      closeSlashPopover();
      autoResizeInput();
      inputEl.focus();
      const end = inputEl.value.length;
      inputEl.setSelectionRange(end, end);
    }
    function handleSlashKeydown(e) {
      if (!slashState.active || !slashState.items.length) return false;
      if (e.key === "ArrowDown") { e.preventDefault(); slashState.index = (slashState.index + 1) % slashState.items.length; renderSlashPopover(); return true; }
      if (e.key === "ArrowUp")   { e.preventDefault(); slashState.index = (slashState.index - 1 + slashState.items.length) % slashState.items.length; renderSlashPopover(); return true; }
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); acceptSlash(slashState.items[slashState.index]); return true; }
      if (e.key === "Tab")    { e.preventDefault(); acceptSlash(slashState.items[slashState.index]); return true; }
      if (e.key === "Escape") { e.preventDefault(); closeSlashPopover(); return true; }
      return false;
    }
    sendBtn.addEventListener("click", submit);
    stopBtn.addEventListener("click", requestCancel);

    // Resize handle.
    const handle = shadow.querySelector(".klo-resize-handle");
    let dragging = false;
    let startX = 0;
    let startW = panelWidth;

    handle.addEventListener("pointerdown", (e) => {
      dragging = true;
      startX = e.clientX;
      startW = panelWidth;
      handle.setPointerCapture(e.pointerId);
      document.documentElement.style.userSelect = "none";
      if (document.body) document.body.style.cursor = "ew-resize";
      // klo-dragging is a stylesheet rule that disables the transition
      // for both <html> and <body> while the user is dragging, so the
      // page tracks the handle 1:1 with no easing-induced lag.
      document.documentElement.classList.add("klo-dragging");
      panel.classList.add("is-dragging");
      e.preventDefault();
    });
    handle.addEventListener("pointermove", (e) => {
      if (!dragging) return;
      const dx = startX - e.clientX;   // dragging left = wider
      const next = clampWidth(startW + dx);
      setPanelWidth(next);
    });
    function endDrag(e) {
      if (!dragging) return;
      dragging = false;
      try { handle.releasePointerCapture(e.pointerId); } catch (_) {}
      document.documentElement.style.userSelect = "";
      if (document.body) document.body.style.cursor = "";
      document.documentElement.classList.remove("klo-dragging");
      panel.classList.remove("is-dragging");
      // Persist width.
      try { chrome.storage.local.set({ [STORAGE_KEY_W]: panelWidth }); } catch (_) {}
    }
    handle.addEventListener("pointerup", endDrag);
    handle.addEventListener("pointercancel", endDrag);

    // Cross-tab state sync via chrome.storage. Auth, open-state, and
    // input-draft all flow here so a klo-driven navigation preserves
    // every piece of UI state.
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== "local") return;
      if ((changes.klo_access_token || changes.klo_refresh_token) && isOpen) {
        refreshAuthGate();
      }
      if (changes[STORAGE_KEY_OPEN]) {
        const wantOpen = !!changes[STORAGE_KEY_OPEN].newValue;
        if (wantOpen && !isOpen)  open({ propagate: false });
        if (!wantOpen && isOpen)  close({ propagate: false });
      }
      if (changes[STORAGE_KEY_DRAFT] && inputEl) {
        // Don't stomp on the user mid-keystroke. Only sync when the
        // input isn't focused (i.e., another tab is actively typing).
        const focused = shadow.activeElement === inputEl;
        if (!focused) {
          inputEl.value = changes[STORAGE_KEY_DRAFT].newValue || "";
          autoResizeInput();
        }
      }
      if (changes.bridge) {
        renderBridgeBanner(!!(changes.bridge.newValue || {}).connected);
      }
      // Magic-link state changed: another tab either started a magic
      // link or chose a different email. Mirror locally if the signin
      // pane is currently visible.
      if (changes[STORAGE_KEY_AUTH_PENDING]) {
        const newPending = changes[STORAGE_KEY_AUTH_PENDING].newValue || null;
        if (signinPane && signinPane.classList.contains("is-visible")) {
          setSigninView(newPending);
        }
      }
    });

    // ─── Focus shield ─────────────────────────────────────────────────────
    //
    // Many sites bind keyboard shortcuts at the document/body level
    // (Gmail's j/k, GitHub's s, Twitter's g+h, Notion's /, etc.). When
    // the user types in our input, those events bubble through the
    // shadow boundary and trigger the page handlers, which can steal
    // focus or run unwanted commands.
    //
    // We attach a bubble-phase stopPropagation on the host element. By
    // the time keyboard events reach the host, the input has already
    // received them; further propagation to body/html/document/window
    // is blocked.
    //
    // We deliberately let ⌥K and Esc pass through so our document-level
    // toggle/close handlers still see them.
    const SHIELDED_EVENTS = ["keydown", "keyup", "keypress", "input", "beforeinput"];
    for (const evt of SHIELDED_EVENTS) {
      host.addEventListener(evt, (e) => {
        // Allow ⌥K through so our document-level toggle handler can
        // close the panel even when focus is in our input.
        if (e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey
            && (e.key === "k" || e.key === "K" || e.key === "˚" || e.code === "KeyK")) return;
        // Esc is also a panel-level command.
        if (e.key === "Escape") return;
        e.stopPropagation();
      });
    }
  }

  function autoResizeInput() {
    inputEl.style.height = "auto";
    inputEl.style.height = Math.min(140, inputEl.scrollHeight) + "px";
  }

  // ─── Open / close / size ──────────────────────────────────────────────────

  function clampWidth(w) {
    const max = Math.floor(window.innerWidth * MAX_WIDTH_PCT);
    return Math.max(MIN_WIDTH, Math.min(max, Math.round(w)));
  }

  // Inject the host-page stylesheet once. Idempotent: a second call is
  // a no-op so re-mounting (extension reload, SPA navigation) is safe.
  function injectHostPageStyles() {
    if (document.getElementById("klo-host-page-style")) return;
    const style = document.createElement("style");
    style.id = "klo-host-page-style";
    style.textContent = HOST_PAGE_CSS;
    (document.head || document.documentElement).appendChild(style);
  }

  // Inject the viewport patch into the *page world*. Content scripts
  // run in an isolated world so we can't patch window globals from
  // here, the script tag is the only way. Some sites with strict CSP
  // may block this; we fall back to CSS-only behavior in that case.
  function injectPageWorldPatch() {
    if (document.getElementById("klo-page-world-patch")) return;
    try {
      const script = document.createElement("script");
      script.id = "klo-page-world-patch";
      script.textContent = PAGE_WORLD_PATCH;
      (document.head || document.documentElement).appendChild(script);
      // We can remove the script element; the IIFE has already executed.
      script.remove();
    } catch (e) {
      // CSP block, ignore.
    }
  }

  // Update the panel width and the two CSS variables on <html>:
  //
  //   --klo-shrink-width:  the page's available width (viewport - panel)
  //                        used by the !important CSS rules to constrain
  //                        html/body/SPA roots.
  //   --klo-virtual-width: same value, exposed to the page-world patched
  //                        getters for innerWidth/outerWidth/clientWidth.
  //
  // The class on <html> is added in open() and removed in close(); this
  // function only drives the width.
  function setPanelWidth(w) {
    panelWidth = w;
    if (panel) panel.style.width = w + "px";

    const viewportW = window.innerWidth;
    const pageW = Math.max(0, viewportW - w);
    const html = document.documentElement;
    html.style.setProperty("--klo-shrink-width", pageW + "px");
    html.style.setProperty("--klo-virtual-width", pageW);
    // Panel width as px — read by the [data-klo-fixed-snap] CSS rule
    // so every tagged top/bottom bar tracks drag instantly via calc().
    html.style.setProperty("--klo-panel-width", w + "px");

    lastViewportWidth = viewportW;
    // Multi-tier nudge so JS-driven layouts notice the shrink:
    //   1) window 'resize' wakes matchMedia + libraries that listen on
    //      window-level events.
    //   2) pingResizeObservers() forces ResizeObserver(body) to fire by
    //      briefly perturbing body's box.
    //   3) Repeat the resize 100ms and 220ms in so debounced/throttled
    //      handlers catch up after the CSS transition completes.
    fireResize();
    setTimeout(fireResize, 100);
    setTimeout(fireResize, 220);
  }

  function fireResize() {
    window.dispatchEvent(new Event("resize"));
    pingResizeObservers();
  }

  // Force-fire body-level ResizeObservers. Many modern apps (Gmail,
  // Linear, Notion) hang their layout off this primitive, so simulating
  // a body resize is more reliable than the legacy window.resize event.
  function pingResizeObservers() {
    if (!document.body) return;
    const prev = document.body.style.minHeight;
    document.body.style.minHeight = (document.body.clientHeight + 1) + "px";
    requestAnimationFrame(() => {
      if (document.body) document.body.style.minHeight = prev;
    });
  }

  // ─── Fixed-bar snapping ───────────────────────────────────────────────────
  //
  // The CSS shrink mechanism above clamps html/body/SPA roots, but
  // anything `position: fixed` (top nav bars, sticky headers, cookie
  // banners, modal scrims) is positioned against the initial containing
  // block (the viewport) and stays full-width — bleeding under the
  // panel. We can't detect "full-width fixed bar" in pure CSS, so we
  // walk the DOM, tag the matching elements with [data-klo-fixed-snap],
  // and let the corresponding rule in HOST_PAGE_CSS pull them off the
  // panel via `width: calc(100vw - --klo-panel-width)` + `right`.
  //
  // CSS variable handles live width updates during drag; we never
  // re-walk on drag.
  //
  // Limitation: closed shadow roots are unreachable. Open shadow roots
  // (YouTube ytd-masthead, Reddit shell) are recursed into.
  //
  // ──────────────────────────────────────────────────────────────────────────
  const SNAP_LEFT_TOLERANCE = 0.05;   // anchored within 5% of the left edge
  const SNAP_WIDTH_THRESHOLD = 0.85;  // spans ≥ 85% of viewport
  const SNAP_SKIP_SELECTOR = "#klo-panel-host, #klo-onboard-host";

  function isSnapCandidate(el, viewportW, panelW) {
    if (!(el instanceof Element)) return false;
    if (el.closest && el.closest(SNAP_SKIP_SELECTOR)) return false;
    // Already tagged — keep it tagged on re-scan (cheap path).
    if (el.hasAttribute("data-klo-fixed-snap")) return true;

    const cs = getComputedStyle(el);
    if (cs.position !== "fixed" && cs.position !== "sticky") return false;
    if (cs.display === "none" || cs.visibility === "hidden") return false;

    const rect = el.getBoundingClientRect();
    // Containing-block check by measurement: if the element is already
    // narrower than the available page width (e.g. parent has
    // `transform: translateZ(0)` and acts as the containing block),
    // it'll shrink for free with the body — skip.
    if (rect.width <= viewportW - panelW + 2) return false;
    if (rect.width < viewportW * SNAP_WIDTH_THRESHOLD) return false;
    if (rect.left > viewportW * SNAP_LEFT_TOLERANCE) return false;
    return true;
  }

  // Walk an element tree (TreeWalker for SHOW_ELEMENT only) and tag
  // every match. Recurses into open shadow roots so nav bars in
  // shadow-DOM-rooted apps (YouTube, modern Reddit) get caught.
  function tagFixedFullWidthElements(root) {
    if (!isOpen) return;
    const viewportW = window.innerWidth;
    const panelW = panelWidth;
    const scope = root || document.body;
    if (!scope) return;

    // Tag the scope itself if it qualifies (TreeWalker starts at the
    // first child by default, missing the root).
    if (scope.nodeType === Node.ELEMENT_NODE && isSnapCandidate(scope, viewportW, panelW)) {
      scope.setAttribute("data-klo-fixed-snap", "1");
    }

    const walker = document.createTreeWalker(scope, NodeFilter.SHOW_ELEMENT);
    let n = walker.nextNode();
    while (n) {
      if (isSnapCandidate(n, viewportW, panelW)) {
        n.setAttribute("data-klo-fixed-snap", "1");
      }
      // Recurse into open shadow roots.
      if (n.shadowRoot) tagFixedFullWidthElements(n.shadowRoot);
      n = walker.nextNode();
    }
  }

  function revertFixedElements() {
    document
      .querySelectorAll("[data-klo-fixed-snap]")
      .forEach((el) => el.removeAttribute("data-klo-fixed-snap"));
  }

  // Debounced wrapper. Multiple mutations within 250ms collapse into
  // one pass, so SPAs that re-render constantly (Gmail, Notion) don't
  // thrash. requestIdleCallback if available, setTimeout fallback.
  function scheduleTagPass(root) {
    if (snapDebounceId) return;
    const run = () => {
      snapDebounceId = 0;
      tagFixedFullWidthElements(root);
    };
    if (typeof window.requestIdleCallback === "function") {
      snapDebounceId = window.requestIdleCallback(run, { timeout: 250 });
    } else {
      snapDebounceId = setTimeout(run, 200);
    }
  }

  function startSnapObserver() {
    if (snapObserver) return;
    snapObserver = new MutationObserver((records) => {
      for (const r of records) {
        // We only care about new elements appearing — attribute and
        // text mutations don't change which fixed bars exist. Filter
        // tightens the hot path on chatty pages.
        if (r.type !== "childList" || r.addedNodes.length === 0) continue;
        scheduleTagPass();
        return;
      }
    });
    snapObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
  }

  function stopSnapObserver() {
    if (snapObserver) {
      snapObserver.disconnect();
      snapObserver = null;
    }
    if (snapDebounceId) {
      if (typeof window.cancelIdleCallback === "function") {
        window.cancelIdleCallback(snapDebounceId);
      } else {
        clearTimeout(snapDebounceId);
      }
      snapDebounceId = 0;
    }
  }

  // open()/close() take a `propagate` flag: true (default) writes the
  // new state to chrome.storage.local so other tabs follow; false is
  // used when WE are reacting to a storage change from another tab and
  // don't want to loop.
  async function open(opts = {}) {
    if (isOpen) return;
    if (!host) await mount();
    injectHostPageStyles();   // idempotent

    // Float mode on auth pages: keep the panel visible but don't push
    // the host page or lie about innerWidth. OAuth/SSO/sign-in UIs are
    // brittle to viewport changes — the page-shrink mechanism
    // routinely hides buttons and triggers mobile media queries.
    const floatMode = isAuthHost();

    if (!floatMode) {
      injectPageWorldPatch();   // idempotent
      // Add the class first; the injected stylesheet's transition will
      // animate the resulting width change. Then set the width var.
      document.documentElement.classList.add("klo-shrunk");
      setPanelWidth(panelWidth);
    } else {
      // In float mode setPanelWidth's CSS-var writes are no-ops (no
      // klo-shrunk class to consume them, no innerWidth patch, no
      // fixed-bar snapper). We still need to set panel.style.width so
      // the panel renders at the user's preferred width.
      if (panel) panel.style.width = panelWidth + "px";
    }

    panel.hidden = false;
    void panel.offsetWidth;   // force reflow so the slide-in animates
    panel.classList.add("is-open");
    if (floatMode) {
      panel.classList.add("klo-float-mode");
    }

    isOpen = true;

    if (!floatMode) {
      // Tag every full-width fixed/sticky bar so the host-page CSS pulls
      // it off the panel. First pass immediately; re-runs at +100ms and
      // +240ms catch navs that mount after the initial paint (matches
      // the existing setPanelWidth nudge cadence). MutationObserver
      // catches anything later. Skipped in float mode — the page isn't
      // shrunk so there's nothing to pull off of.
      tagFixedFullWidthElements();
      startSnapObserver();
      setTimeout(tagFixedFullWidthElements, 100);
      setTimeout(tagFixedFullWidthElements, 240);
    }

    if (opts.propagate !== false) {
      try { chrome.storage.local.set({ [STORAGE_KEY_OPEN]: true }); } catch (_) {}
    }

    await refreshAuthGate();
    refreshBridgeBanner();

    // Subscribe to the chat broadcast as soon as we open, so this tab
    // receives every event (including ones triggered by another tab)
    // and gets a state.snapshot to render whatever's already happened.
    if (chatPane.classList.contains("is-visible")) ensurePort();

    setTimeout(() => {
      if (signinPane.classList.contains("is-visible")) signinBtn?.focus();
      else inputEl?.focus();
    }, 50);
  }

  function close(opts = {}) {
    if (!isOpen) return;
    isOpen = false;
    panel.classList.remove("is-open");
    panel.classList.remove("klo-float-mode");

    // Drop the class, the !important rules go away and the page reverts
    // to whatever its natural width was. The transition declared in
    // HOST_PAGE_CSS animates the change. Removing --klo-virtual-width
    // makes the patched window.innerWidth getters fall back to real
    // values immediately. All of these are no-ops if open() ran in
    // float mode (the class wasn't added, the CSS vars weren't set).
    document.documentElement.classList.remove("klo-shrunk");
    document.documentElement.style.removeProperty("--klo-shrink-width");
    document.documentElement.style.removeProperty("--klo-virtual-width");
    document.documentElement.style.removeProperty("--klo-panel-width");

    // Untag every fixed/sticky bar we snapped + tear down the
    // observer/idle-callback so a late mutation can't re-tag after
    // the page is supposed to be back to normal.
    stopSnapObserver();
    revertFixedElements();

    lastViewportWidth = window.innerWidth;
    fireResize();
    setTimeout(fireResize, 100);
    setTimeout(fireResize, 240);

    setTimeout(() => {
      if (!isOpen) panel.hidden = true;
    }, 240);

    if (port) { try { port.disconnect(); } catch (_) {} port = null; }
    menuEl?.classList.remove("is-visible");

    if (opts.propagate !== false) {
      try { chrome.storage.local.set({ [STORAGE_KEY_OPEN]: false }); } catch (_) {}
    }
  }

  // Keep the page-push correct when the user resizes the browser window.
  // We compare against lastViewportWidth (which we update ourselves
  // whenever WE dispatch resize) so we don't ping-pong with our own
  // events. Float mode (auth host) skips this entirely — there's no
  // page-push to keep correct, and firing resize events on auth pages
  // can re-trigger their mobile media queries.
  window.addEventListener("resize", () => {
    if (!isOpen) return;
    if (panel && panel.classList.contains("klo-float-mode")) return;
    const viewportW = window.innerWidth;
    if (viewportW === lastViewportWidth) return;   // self-triggered
    lastViewportWidth = viewportW;
    const clamped = clampWidth(panelWidth);
    setPanelWidth(clamped);
  });

  function toggle() { isOpen ? close() : open(); }

  // ─── Bridge (Mac app) health ──────────────────────────────────────────────
  //
  // background.js publishes {connected, ...} to chrome.storage.local
  // under "bridge" (runtime.sendMessage doesn't reach content scripts,
  // so storage is the reliable channel here). We surface an inline
  // banner only for the regression case — the Mac app was connected
  // this session and went away — so users without the Mac app never
  // see it.
  let bridgeWasConnected = false;

  function renderBridgeBanner(connected) {
    if (connected) bridgeWasConnected = true;
    if (!connBannerEl) return;
    const show = !connected && bridgeWasConnected;
    connBannerEl.classList.toggle("is-visible", show);
    if (show) {
      connBannerEl.textContent = "Mac app not connected — open klo on your Mac.";
    }
  }

  async function refreshBridgeBanner() {
    try {
      const v = await chrome.storage.local.get("bridge");
      renderBridgeBanner(!!(v.bridge && v.bridge.connected));
    } catch (_) { /* storage unavailable */ }
  }

  // ─── Auth gate ────────────────────────────────────────────────────────────

  async function refreshAuthGate({ force = false } = {}) {
    let status = { signed_in: false };
    let pending = null;
    try {
      status = await chrome.runtime.sendMessage({ type: "klo.auth_status", force });
    } catch (_) { /* background asleep */ }
    try {
      const v = await chrome.storage.local.get(STORAGE_KEY_AUTH_PENDING);
      pending = v[STORAGE_KEY_AUTH_PENDING] || null;
    } catch (_) {}

    const signedIn = !!(status && status.signed_in);
    const active   = signedIn && ACTIVE_STATUSES.has(status.subscription_status);
    const unknown  = signedIn && status.subscription_status === "unknown";

    // Three panes: signin → upsell → chat. "unknown" treats as active
    // so a transient backend hiccup doesn't bounce the user.
    if (signinPane) signinPane.classList.toggle("is-visible", !signedIn);
    if (upsellPane) upsellPane.classList.toggle("is-visible", signedIn && !active && !unknown);
    if (chatPane)   chatPane.classList.toggle("is-visible", signedIn && (active || unknown));

    mSignin.style.display  = signedIn ? "none"  : "block";
    mSignout.style.display = signedIn ? "block" : "none";

    if (!signedIn) {
      setSigninView(pending);
      connectedToolkits = new Set();
      renderHeaderAppsStack();
    } else {
      // Pull the connected-toolkit list whenever auth flips to signed-in
      // so the header stack + picker badges paint without waiting for
      // the user to open the picker for the first time.
      refreshConnectedToolkits();
      if (active || unknown) ensurePort();
    }
  }

  // Background broadcasts auth.status_changed when Stripe Checkout
  // closes and /auth/me reports a fresh subscription_status. Refresh
  // the panes so the upsell card fades to chat without manual action.
  chrome.runtime.onMessage.addListener((msg) => {
    if (!msg) return;
    if (msg.type === "auth.status_changed") refreshAuthGate();
    if (msg.type === "composio.connected") {
      refreshConnectedToolkits();
      const slug = String(msg.toolkit || "").toLowerCase();
      if (pendingComposioPrompt && pendingComposioPrompt.slug === slug) {
        const prompt = pendingComposioPrompt.prompt;
        dismissAuthGateWithSuccess(slug).then(() => sendPrompt(prompt));
      } else if (activeAuthGateEl) {
        dismissAuthGateWithSuccess(slug);
      } else {
        appendConnectedNote(slug);
      }
    }
    if (msg.type === "composio.disconnected") {
      refreshConnectedToolkits();
    }
  });

  function appendConnectedNote(slug) {
    if (!bodyEl || !window.Composio?.BUNDLED_SLUGS.has(slug)) return;
    const name = window.Composio.displayName(slug);
    const iconURL = window.Composio.iconURL(slug);
    const tileStyle = iconURL ? "" :
      ` style="--brand-color:${window.Composio.color(slug)};--brand-tint:${window.Composio.color(slug)}33"`;
    const tileInner = iconURL
      ? `<img src="${iconURL}" alt="">`
      : window.Composio.monogram(slug);
    const el = document.createElement("div");
    el.className = "klo-msg klo-msg-auth-card";
    el.innerHTML = `
      <span class="klo-msg-auth-tile${iconURL ? "" : " monogram"}"${tileStyle}>${tileInner}</span>
      <div class="klo-msg-auth-body">
        <span class="klo-msg-auth-title">${name} connected.</span>
        <span class="klo-msg-auth-sub">ask klo to use it — your earlier message can be retried.</span>
      </div>
    `;
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  // "Subscribe" → ask background to open Stripe Checkout in a new
  // tab. Same loading vocabulary as SignInScreen: label flips, glow
  // pauses, button disables; the cream lock-disc stays so the
  // affordance reads continuously.
  async function startCheckoutFlow() {
    const btn = upsellCtaBtn;
    const wrap = shadow.querySelector("#upsell-cta-wrap");
    const label = shadow.querySelector("#upsell-cta-label");
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
        const errMsg = stale
          ? "klo was reloaded — refresh this page to reconnect."
          : `Couldn't start checkout: ${(resp && resp.error) || "unknown error"}`;
        restore();
        console.warn("[klo]", errMsg);
        return;
      }
    } catch (_) {
      restore();
      return;
    }
    setTimeout(restore, 1500);
  }

  // Legacy no-op. Used to flip between an email form and a
  // "check your email" pending state; the Google OAuth flow has a
  // single view so there's nothing to toggle. Kept so the signature
  // matches old call sites without thrashing the diff.
  function setSigninView(_pending) {
    if (signinBtn) signinBtn.disabled = false;
  }

  // ─── Sign-in (inline + auto-open webmail) ────────────────────────────────

  function showSigninFeedback(text, kind = "info") {
    signinFeedback.className = `klo-signin-feedback is-visible ${kind}`;
    signinFeedback.textContent = text;
  }
  function hideSigninFeedback() {
    signinFeedback.className = "klo-signin-feedback";
    signinFeedback.textContent = "";
  }

  // Mirror iOS SignInScreen.awaitingOAuth: label flips to
  // "opening google", the breathing glow pauses, and the button is
  // disabled. Wrap is the parent for .is-loading.
  function setSigninLoading(loading) {
    if (!signinBtn) return;
    signinBtn.disabled = loading;
    const wrap = shadow.querySelector("#signin-cta-wrap");
    wrap?.classList.toggle("is-loading", loading);
    const label = shadow.querySelector("#signin-btn-label");
    if (label) label.textContent = loading ? "opening google" : "continue with google";
  }

  // Google OAuth, same flow as the side panel. We POST to klo-cloud's
  // /auth/oauth/start with the chrome-extension callback URL, get the
  // Supabase OAuth URL back, and open it in a new tab. The callback
  // page (auth-callback.html) parses tokens out of the URL fragment
  // and hands them to background.js via klo.set_tokens. When that
  // lands, background broadcasts auth.status_changed and this pane
  // flips to chat without any further user action.
  async function startSignIn() {
    hideSigninFeedback();
    if (!signinBtn) return;
    setSigninLoading(true);
    try {
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
      // Content scripts can't open tabs; ask background to do it.
      try {
        await chrome.runtime.sendMessage({ type: "klo.open_webmail", url });
      } catch (_) {
        // Background asleep or message dropped — fall back to window.open
        // which Chrome allows because this is a direct user gesture.
        window.open(url, "_blank", "noopener");
      }
      showSigninFeedback("pick your Google account in the new tab.", "ok");
    } catch (e) {
      const stale = e && e.message && e.message.includes("Extension context invalidated");
      const msg = stale
        ? "klo was reloaded. refresh this page to reconnect."
        : `couldn't reach klo-cloud: ${e.message}`;
      showSigninFeedback(msg, "err");
      setSigninLoading(false);
    }
  }

  // Rotating tagline — mirrors iOS SignInScreen.startTaglineRotation
  // (3.6s cadence, same phrases). The fade-out / fade-in is driven by
  // the .is-fading class on the text node.
  const SIGNIN_TAGLINES = [
    "drive your chrome with klo",
    "ask. klo runs.",
    "your browser, on autopilot",
    "your agent on call",
  ];
  let signinTaglineIdx = 0;
  let signinTaglineTimer = null;
  function startSigninTaglineRotation() {
    if (signinTaglineTimer) return;
    const node = shadow.querySelector("#signin-tagline-text");
    if (!node) return;
    signinTaglineTimer = setInterval(() => {
      if (!signinPane?.classList.contains("is-visible")) return;
      node.classList.add("is-fading");
      setTimeout(() => {
        signinTaglineIdx = (signinTaglineIdx + 1) % SIGNIN_TAGLINES.length;
        node.textContent = SIGNIN_TAGLINES[signinTaglineIdx];
        node.classList.remove("is-fading");
      }, 400);
    }, 3600);
  }

  function clearPendingAndShowForm() {
    // Legacy no-op — magic-link pending state no longer exists, but
    // older callers (cross-tab storage observers, menu wiring) may
    // still invoke this. Keep the symbol so we don't break callsites.
    try { chrome.storage.local.remove(STORAGE_KEY_AUTH_PENDING); } catch (_) {}
  }

  // ─── Chat orchestration ──────────────────────────────────────────────────

  // Inline Composio auth gate state — mirrors sidepanel.js. Holds
  // the pending prompt while the user completes OAuth in a new tab.
  let pendingComposioPrompt = null;
  let activeAuthGateEl = null;

  function parseComposioPrefix(text) {
    if (!text.startsWith("/")) return null;
    const m = text.slice(1).match(/^([a-z0-9_-]+)\b/i);
    return m ? m[1].toLowerCase() : null;
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
      // retryable connect card instead of a silent tool failure later.
      return false;
    }
  }

  function renderAuthGate(slug, prompt) {
    if (activeAuthGateEl) { activeAuthGateEl.remove(); activeAuthGateEl = null; }
    pendingComposioPrompt = { slug, prompt };
    const name = window.Composio?.displayName(slug) || slug;
    const iconURL = window.Composio?.iconURL(slug);
    const brandColor = window.Composio?.color(slug) || "#A8C152";
    const tileInner = iconURL
      ? `<img src="${iconURL}" alt="">`
      : (window.Composio?.monogram(slug) || "");
    const el = document.createElement("div");
    el.className = "klo-msg klo-msg-auth-card";
    el.style.setProperty("--brand-color", brandColor);
    el.style.setProperty("--brand-edge", brandColor + "55");
    el.style.setProperty("--brand-tint", brandColor + "14");
    el.innerHTML = `
      <span class="klo-msg-auth-tile${iconURL ? "" : " monogram"}">${tileInner}</span>
      <div class="klo-msg-auth-body">
        <span class="klo-msg-auth-title">Connect ${name}</span>
        <span class="klo-msg-auth-sub">opens in a new tab. you'll come right back.</span>
      </div>
      <button type="button" class="klo-msg-auth-cta">connect</button>
      <span class="klo-msg-auth-spinner" aria-hidden="true"></span>
      <span class="klo-msg-auth-check" aria-hidden="true"></span>
    `;
    const cta = el.querySelector(".klo-msg-auth-cta");
    const sub = el.querySelector(".klo-msg-auth-sub");
    cta.addEventListener("click", async () => {
      cta.disabled = true;
      el.classList.add("is-connecting");
      sub.textContent = `opening ${name.toLowerCase()} in a new tab.`;
      try {
        const resp = await chrome.runtime.sendMessage({
          type: "klo.composio.connect", toolkit: slug,
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
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
    activeAuthGateEl = el;
  }

  function dismissAuthGateWithSuccess(slug) {
    if (!activeAuthGateEl) return Promise.resolve();
    const el = activeAuthGateEl;
    activeAuthGateEl = null;
    pendingComposioPrompt = null;
    const name = window.Composio?.displayName(slug) || slug;
    const sub = el.querySelector(".klo-msg-auth-sub");
    const title = el.querySelector(".klo-msg-auth-title");
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
    if (activeAuthGateEl) { activeAuthGateEl.remove(); activeAuthGateEl = null; }
    pendingComposioPrompt = null;
  }

  async function submit() {
    const text = inputEl.value.trim();
    if (!text || isWorking) return;

    // Preflight Composio gate — see sidepanel.js for the rationale.
    const slug = parseComposioPrefix(text);
    if (slug && window.Composio?.BUNDLED_SLUGS.has(slug)) {
      const connected = await isToolkitConnected(slug);
      if (!connected) {
        inputEl.value = "";
        autoResizeInput();
        try { chrome.storage.local.remove(STORAGE_KEY_DRAFT); } catch (_) {}
        renderAuthGate(slug, text);
        return;
      }
    }

    inputEl.value = "";
    autoResizeInput();
    try { chrome.storage.local.remove(STORAGE_KEY_DRAFT); } catch (_) {}
    sendPrompt(text);
  }

  // Connect the chat port up front so this tab receives every event,
  // even ones triggered from a different tab. Background broadcasts to
  // all open klo-chat ports + serves a state.snapshot on connect so we
  // can render the conversation that's already in progress.
  function ensurePort() {
    if (port) return;
    port = chrome.runtime.connect({ name: "klo-chat" });
    port.onMessage.addListener(onAgentMessage);
    port.onDisconnect.addListener(() => {
      port = null;
      if (isWorking) {
        finishWorking();
        // Service-worker port drops are normal background-page eviction,
        // not a hard failure — show a calm notice rather than alarm-red.
        appendNoticeBubble("connection dropped. try again");
      }
    });
  }

  function sendPrompt(text) {
    // Don't paint locally, the user bubble arrives via log.append
    // broadcast in a few ms. That keeps every tab consistent with no
    // optimistic-then-dedupe gymnastics.
    lastUserPrompt = text;
    startWorkingState();
    ensurePort();
    port.postMessage({ type: "user.prompt", text, tabId: -1 });
  }

  function startWorkingState() {
    showStatus("thinking · 0s");
    assistantBuffer = "";
    assistantBubble = null;
    isWorking = true;
    sendBtn.disabled = true;
    setWorkingChrome(true);
    elapsedSeconds = 0;
    lastHeartbeatAt = Date.now();
    stuckBannerShown = false;
    if (elapsedTimer) clearInterval(elapsedTimer);
    elapsedTimer = setInterval(() => {
      elapsedSeconds += 1;
      refreshStatusElapsed();
    }, 1000);
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
    const el = document.createElement("div");
    el.className = "klo-msg-stuck";
    el.innerHTML = `
      <span class="klo-msg-stuck-text"></span>
      <button type="button" class="klo-msg-stuck-retry">Retry</button>
    `;
    el.querySelector(".klo-msg-stuck-text").textContent = text;
    el.querySelector(".klo-msg-stuck-retry").addEventListener("click", () => {
      el.remove();
      if (lastUserPrompt) sendPrompt(lastUserPrompt);
    });
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
    finishWorking();
  }

  function finishWorking() {
    isWorking = false;
    sendBtn.disabled = false;
    setWorkingChrome(false);
    hideStatus();
    if (elapsedTimer) { clearInterval(elapsedTimer); elapsedTimer = null; }
    if (watchdogTimer) { clearInterval(watchdogTimer); watchdogTimer = null; }
    elapsedSeconds = 0;
    stuckBannerShown = false;
  }

  // Toggle the working chrome (fiery glow on the panel card, stop btn
  // visible, send btn hidden) without touching agent state.
  function setWorkingChrome(on) {
    panelInnerEl?.classList.toggle("is-working", !!on);
    inputRowEl?.classList.toggle("is-working", !!on);
  }

  // Cancel a running turn. Background flips its cancelRequested flag
  // and aborts the in-flight LLM stream; the loop emits "_(stopped)_"
  // on its way out.
  function requestCancel() {
    if (!isWorking) return;
    ensurePort();
    try { port.postMessage({ type: "agent.cancel" }); } catch (_) {}
  }

  function onAgentMessage(msg) {
    if (!msg || !msg.type) return;
    // Any broadcast counts as a sign-of-life from the SW. Resets the
    // watchdog so the user doesn't hit the stuck banner during a
    // legitimately slow tool execution. agent.heartbeat is the
    // explicit ping when nothing else is happening.
    lastHeartbeatAt = Date.now();
    switch (msg.type) {
      case "agent.heartbeat":
        // Liveness ping; lastHeartbeatAt already updated above.
        break;
      // Initial sync from background. Cleans the body and renders the
      // entire conversation that's already in flight.
      case "state.snapshot":
        renderSnapshot(msg);
        break;
      case "log.append":
        renderLogEntry(msg.message);
        break;
      case "log.cleared":
        bodyEl.innerHTML = "";
        assistantBuffer = "";
        assistantBubble = null;
        finishWorking();
        break;
      case "conversations.updated":
        // Light index-only broadcast emitted after a turn finalizes
        // (so the row's preview/updatedAt move) without re-rendering
        // the whole conversation.
        conversationsCache = Array.isArray(msg.conversations) ? msg.conversations : [];
        renderConversationsList();
        break;
      case "agent.text_delta":     appendAssistantDelta(msg.text); break;
      case "agent.tool_use_start":
        isWorking = true;
        sendBtn.disabled = true;
        setWorkingChrome(true);
        showStatus(humanizeTool(msg.name));
        break;
      case "agent.tool_call":
        // Visible activity entry — user sees klo working step by step.
        appendToolActivity(msg);
        showStatus(msg.summary || humanizeTool(msg.name));
        break;
      case "agent.tool_result":
        updateToolActivity(msg);
        showStatus(msg.ok ? "thinking" : `${humanizeTool(msg.name)} failed`);
        break;
      case "agent.message":        finalizeAssistantBubble(msg.text); break;
      case "agent.done":           finishWorking(); break;
      case "agent.error":
        finishWorking();
        if (msg.code === "cloud_timeout" || msg.code === "cloud_unreachable") {
          // Cold-start / connectivity — recoverable. Retry banner so
          // the user can re-issue the prompt in one click.
          showStuckBanner(msg.message || "klo cloud is unreachable. Retry?");
        } else {
          renderErrorEntry(msg);
        }
        break;
    }
  }

  // Render the background's full state into the panel. Wipes whatever
  // bubbles the body currently has and replays them from the log, so
  // every tab eventually has the same DOM. Also refreshes the title
  // pill and History dropdown.
  function renderSnapshot(snap) {
    activeConversationId = snap.conversationId || null;
    conversationsCache = Array.isArray(snap.conversations) ? snap.conversations : [];
    setTitlePill(snap.title);
    renderConversationsList();

    bodyEl.innerHTML = "";
    assistantBuffer = "";
    assistantBubble = null;
    for (const entry of (snap.log || [])) {
      renderLogEntry(entry, /*isFinal=*/true);
    }
    // Mid-stream catch-up: if a turn is in flight, replay the partial
    // assistant text into a live bubble so subsequent text_delta events
    // append to it.
    if (snap.partialAssistant) {
      assistantBubble = document.createElement("div");
      assistantBubble.className = "klo-msg is-assistant";
      assistantBubble.innerHTML = `<div class="klo-msg-role">klo</div><div class="klo-msg-text"></div>`;
      assistantBuffer = snap.partialAssistant;
      assistantBubble.querySelector(".klo-msg-text").textContent = assistantBuffer;
      bodyEl.appendChild(assistantBubble);
    }
    // Restore the working indicator if the agent is mid-turn.
    if (snap.working) {
      isWorking = true;
      sendBtn.disabled = true;
      setWorkingChrome(true);
      if (snap.status && snap.status.name) showStatus(humanizeTool(snap.status.name));
      else showStatus("thinking");
    } else {
      finishWorking();
    }
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  function renderLogEntry(entry, isFinal = false) {
    if (!entry || !entry.role) return;
    console.log("[klo overlay] renderLogEntry", { role: entry.role, hasText: !!entry.text, len: (entry.text || "").length });
    if (entry.role === "user") {
      appendUserBubble(entry.text);
    } else if (entry.role === "assistant") {
      // No text? The agent ran tools but didn't summarize. The activity
      // entries above already show what happened — drop the empty
      // bubble silently rather than rendering a void or apologetic
      // placeholder.
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
        const target = assistantBubble.querySelector(".klo-msg-text");
        target.innerHTML = renderMarkdown(text);
        assistantBubble = null;
        assistantBuffer = "";
      } else {
        const el = document.createElement("div");
        el.className = "klo-msg is-assistant";
        el.innerHTML = `<div class="klo-msg-role">klo</div><div class="klo-msg-text"></div>`;
        el.querySelector(".klo-msg-text").innerHTML = renderMarkdown(text);
        bodyEl.appendChild(el);
      }
    } else if (entry.role === "error") {
      if (
        (entry.code === "cloud_timeout" || entry.code === "cloud_unreachable")
        && bodyEl.querySelector(".klo-msg-stuck")
      ) {
        // Live cloud errors already rendered as the retry banner —
        // don't double up. (Snapshot replays wiped the body first, so
        // history still shows the message.)
        return;
      }
      // Use the same severity router as live events. Legacy entries
      // missing `severity` get classified by their code (paywall /
      // hard error / notice).
      renderErrorEntry({
        severity: entry.severity,
        code: entry.code,
        message: entry.text,
        detail: entry.detail,
      });
    }
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  // Track in-flight tool-activity entries by tool_use_id so we can
  // flip them from pending → done/failed when the result arrives.
  const toolActivityById = new Map();

  function appendToolActivity(call) {
    const el = document.createElement("div");
    el.className = "klo-msg-tool is-pending";
    el.innerHTML = `<span class="klo-msg-tool-arrow">→</span><span class="klo-msg-tool-text"></span>`;
    el.querySelector(".klo-msg-tool-text").textContent = call.summary || call.name;
    bodyEl.appendChild(el);
    if (call.id) toolActivityById.set(call.id, el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  function updateToolActivity(result) {
    const el = result.id ? toolActivityById.get(result.id) : null;
    if (!el) return;
    el.classList.remove("is-pending");
    el.classList.toggle("is-error", !result.ok);
    el.classList.toggle("is-done", result.ok);
    const textEl = el.querySelector(".klo-msg-tool-text");
    const baseText = textEl.textContent;
    const sep = result.ok ? " · " : " — ";
    textEl.textContent = `${baseText}${sep}${result.summary || (result.ok ? "done" : "failed")}`;
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  function showStatus(text) {
    if (text == null) { statusEl.classList.remove("is-visible"); return; }
    statusEl.classList.add("is-visible");
    statusTextEl.textContent = text;
  }
  function hideStatus() { showStatus(null); }

  function appendUserBubble(text) {
    const el = document.createElement("div");
    el.className = "klo-msg is-user";
    el.innerHTML = `<div class="klo-msg-role">you</div><div class="klo-msg-text"></div>`;
    el.querySelector(".klo-msg-text").textContent = text;
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  function appendAssistantDelta(delta) {
    // Don't create an empty bubble for an empty/whitespace delta — wait
    // for actual content. Without this guard, a content_block of type
    // "text" with no body produces a visible "klo" bubble with no text.
    if (!assistantBubble && (!delta || !delta.trim())) return;
    if (!assistantBubble) {
      assistantBubble = document.createElement("div");
      assistantBubble.className = "klo-msg is-assistant";
      assistantBubble.innerHTML = `<div class="klo-msg-role">klo</div><div class="klo-msg-text"></div>`;
      bodyEl.appendChild(assistantBubble);
    }
    assistantBuffer += delta;
    assistantBubble.querySelector(".klo-msg-text").textContent = assistantBuffer;
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  function finalizeAssistantBubble(finalText) {
    if (!assistantBubble) {
      assistantBuffer = finalText;
      appendAssistantDelta("");
    }
    const target = assistantBubble.querySelector(".klo-msg-text");
    target.innerHTML = renderMarkdown(assistantBuffer || finalText);
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  function appendErrorBubble(text) {
    const el = document.createElement("div");
    el.className = "klo-msg is-error";
    el.innerHTML = `<div class="klo-msg-role">klo</div><div class="klo-msg-text"></div>`;
    el.querySelector(".klo-msg-text").textContent = text;
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  // Calm inline grey muttering — for transient/recoverable issues that
  // the user should know about but shouldn't be alarmed by (timeouts,
  // network blips, "klo is still working" pushback, max-rounds-without-
  // synthesis fallback). No role label, italic, indented — sits in the
  // log like a system aside, not a chat bubble.
  function appendNoticeBubble(text) {
    const el = document.createElement("div");
    el.className = "klo-msg is-notice";
    el.innerHTML = `<div class="klo-msg-text"></div>`;
    el.querySelector(".klo-msg-text").textContent = text;
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
  }

  // Pick the right bubble for an error event based on its severity.
  // Defaults to "notice" when severity is missing — both unknown new
  // codes and replayed entries from before this change get the calm
  // treatment instead of red.
  function renderErrorEntry({ severity, code, message, detail }) {
    const sev = severity || (code === "subscription_required"
      ? "paywall"
      : (code === "not_signed_in" || code === "session_expired") ? "error" : "notice");
    if (sev === "paywall") {
      appendPaywallBubble(message || (detail && detail.message));
    } else if (sev === "error") {
      appendErrorBubble(message || code || "something went wrong");
    } else {
      appendNoticeBubble(message || code || "something went wrong");
    }
  }

  // ─── Title pill + History dropdown ─────────────────────────────────

  function setTitlePill(title) {
    if (!titlePillTextEl) return;
    const t = (title || "").trim();
    titlePillTextEl.textContent = t || "new chat";
    titlePillEl.title = t || "Start a new chat";
  }

  function bucketForTimestamp(ms, now = Date.now()) {
    const day = 24 * 60 * 60 * 1000;
    const today = new Date(now); today.setHours(0, 0, 0, 0);
    const startOfToday = today.getTime();
    const startOfYesterday = startOfToday - day;
    const startOfWeek = startOfToday - 6 * day;
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
    if (!historyListEl) return;
    historyListEl.innerHTML = "";
    const list = conversationsCache;
    if (!list || list.length === 0) {
      historyEmptyEl.classList.remove("is-hidden");
      return;
    }
    historyEmptyEl.classList.add("is-hidden");

    const buckets = ["Today", "Yesterday", "This week", "Older"];
    const grouped = { Today: [], Yesterday: [], "This week": [], Older: [] };
    for (const entry of list) grouped[bucketForTimestamp(entry.updatedAt)].push(entry);

    for (const name of buckets) {
      const rows = grouped[name];
      if (!rows.length) continue;
      const heading = document.createElement("div");
      heading.className = "klo-history-group-heading";
      heading.textContent = name;
      historyListEl.appendChild(heading);
      for (const entry of rows) historyListEl.appendChild(buildHistoryRow(entry));
    }
  }

  function buildHistoryRow(entry) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "klo-history-row";
    if (entry.id === activeConversationId) row.classList.add("is-active");
    row.dataset.convId = entry.id;
    row.innerHTML = `
      <span class="klo-history-row-title"></span>
      <span class="klo-history-row-meta">
        <span class="klo-history-row-preview"></span>
        <span class="klo-history-row-time"></span>
      </span>
      <button class="klo-history-row-delete" type="button" aria-label="Delete chat">×</button>
    `;
    row.querySelector(".klo-history-row-title").textContent = entry.title || "Untitled chat";
    row.querySelector(".klo-history-row-preview").textContent = entry.preview || "";
    row.querySelector(".klo-history-row-time").textContent = relativeTime(entry.updatedAt);
    row.addEventListener("click", (e) => {
      if (e.target.closest(".klo-history-row-delete")) return;
      ensurePort();
      port.postMessage({ type: "conversation.switch", id: entry.id });
      historyMenuEl.classList.remove("is-visible");
    });
    row.querySelector(".klo-history-row-delete").addEventListener("click", (e) => {
      e.stopPropagation();
      ensurePort();
      port.postMessage({ type: "conversation.delete", id: entry.id });
    });
    return row;
  }

  // Inline paywall card — shown when /chat/llm-turn returns 402
  // mid-session. Looks like a chat bubble (sits in conversation flow)
  // but with the orange-tinted paywall surface and an embedded
  // Upgrade button that runs the same Stripe Checkout flow as the
  // upsell pane.
  function appendPaywallBubble(message) {
    const el = document.createElement("div");
    el.className = "klo-msg is-error is-paywall";
    el.innerHTML = `
      <div class="klo-msg-role">klo</div>
      <div class="klo-msg-text"></div>
      <button type="button" class="klo-msg-cta">
        Subscribe — $20/mo
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
          <path d="M3 8H13M13 8L8.5 3.5M13 8L8.5 12.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </button>
    `;
    el.querySelector(".klo-msg-text").textContent = message || "Your subscription's inactive.";
    const cta = el.querySelector(".klo-msg-cta");
    cta.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      startCheckoutFlow();
    });
    bodyEl.appendChild(el);
    bodyEl.scrollTop = bodyEl.scrollHeight;
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
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  // ─── First-run onboarding cloud ───────────────────────────────────────────
  //
  // A semi-transparent floating card in the bottom-right corner that
  // teaches ⌘K. Renders on every host page until the user presses ⌘K
  // for the first time (in any tab); after that, never again. Lives in
  // its own Shadow DOM host so it can fade out independently of the
  // panel sliding in.

  function mountOnboard() {
    if (onboardHost) return;
    onboardHost = document.createElement("div");
    onboardHost.id = "klo-onboard-host";
    onboardHost.style.all = "initial";
    // Same fix as the panel host: pin to viewport so any focus movement
    // inside the shadow DOM doesn't drag the host page's scroll.
    onboardHost.style.position = "fixed";
    onboardHost.style.top = "0";
    onboardHost.style.left = "0";
    onboardHost.style.width = "0";
    onboardHost.style.height = "0";
    onboardHost.style.zIndex = "2147483645";
    document.documentElement.appendChild(onboardHost);
    const onboardShadow = onboardHost.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = `
      /* Tokens — dark mode flips the surface, keeps the orange glow.
         Triggers off the OS preference, not the host page's theme. */
      :host {
        all: initial;
        color-scheme: light dark;
        --klo-card-bg:     rgba(255, 255, 255, 0.85);
        --klo-card-border: rgba(10, 10, 10, 0.12);
        --klo-card-fg:     #0A0A0A;
        --klo-card-fg-60:  rgba(10, 10, 10, 0.60);
        --klo-card-shadow: 0 16px 40px -10px rgba(10, 10, 10, 0.22);
        --klo-keycap-bg:     rgba(10, 10, 10, 0.04);
        --klo-keycap-border: rgba(10, 10, 10, 0.12);
        --klo-keycap-shadow: 0 4px 10px rgba(10, 10, 10, 0.10);
      }
      @media (prefers-color-scheme: dark) {
        :host {
          --klo-card-bg:     rgba(20, 20, 20, 0.92);
          --klo-card-border: rgba(255, 255, 255, 0.10);
          --klo-card-fg:     #FBF8F2;
          --klo-card-fg-60:  rgba(255, 255, 255, 0.60);
          --klo-card-shadow: 0 16px 40px -10px rgba(0, 0, 0, 0.55);
          --klo-keycap-bg:     rgba(255, 255, 255, 0.04);
          --klo-keycap-border: rgba(255, 255, 255, 0.10);
          --klo-keycap-shadow: 0 4px 10px rgba(0, 0, 0, 0.40);
        }
      }
      .klo-onboard-root {
        position: fixed;
        bottom: 24px;
        right: 24px;
        z-index: 2147483646;
        font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
        -webkit-font-smoothing: antialiased;
        pointer-events: none;
      }
      .klo-onboard-card {
        width: 280px;
        padding: 18px 20px 20px;
        border-radius: 20px;
        background: var(--klo-card-bg);
        -webkit-backdrop-filter: blur(14px);
        backdrop-filter: blur(14px);
        border: 1px solid var(--klo-card-border);
        box-shadow:
          var(--klo-card-shadow),
          0 0 0 1px rgba(168, 193, 82, 0.16),
          0 0 36px rgba(168, 193, 82, 0.18);
        color: var(--klo-card-fg);
        opacity: 0;
        transform: translateY(12px) scale(0.96);
        transition:
          opacity 280ms ease-out,
          transform 320ms cubic-bezier(0.2, 0.9, 0.3, 1);
        pointer-events: auto;
      }
      .klo-onboard-card.is-shown {
        opacity: 1;
        transform: translateY(0) scale(1);
      }
      .klo-onboard-card.is-leaving {
        opacity: 0;
        transform: translateY(8px) scale(0.98);
        pointer-events: none;
      }
      .klo-onboard-keys {
        display: flex;
        gap: 8px;
        justify-content: center;
        margin: 0 0 14px;
      }
      .klo-onboard-keycap {
        width: 44px;
        height: 44px;
        border-radius: 12px;
        background: var(--klo-keycap-bg);
        border: 1px solid var(--klo-keycap-border);
        box-shadow:
          var(--klo-keycap-shadow),
          0 0 0 1px rgba(168, 193, 82, 0.18),
          0 0 14px rgba(168, 193, 82, 0.18);
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 22px;
        font-weight: 500;
        color: var(--klo-card-fg);
        line-height: 1;
      }
      .klo-onboard-headline {
        margin: 0 0 4px;
        font-size: 16px;
        font-weight: 500;
        color: var(--klo-card-fg);
        text-align: center;
        letter-spacing: -0.005em;
      }
      .klo-onboard-tagline {
        margin: 0;
        font-size: 13px;
        color: var(--klo-card-fg-60);
        text-align: center;
        line-height: 1.4;
      }
    `;
    onboardShadow.appendChild(style);

    const root = document.createElement("div");
    root.className = "klo-onboard-root";
    root.innerHTML = `
      <div class="klo-onboard-card" id="klo-onboard-card">
        <div class="klo-onboard-keys">
          <div class="klo-onboard-keycap">⌥</div>
          <div class="klo-onboard-keycap">K</div>
        </div>
        <p class="klo-onboard-headline">Press ⌥K</p>
        <p class="klo-onboard-tagline">to talk to klo, your browser agent</p>
      </div>
    `;
    onboardShadow.appendChild(root);
    onboardCard = onboardShadow.getElementById("klo-onboard-card");

    // Force reflow then add the is-shown class so the entrance animates.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        if (onboardCard) onboardCard.classList.add("is-shown");
      });
    });
  }

  function dismissOnboard({ persist = true } = {}) {
    if (!onboardHost) return;
    if (onboardCard) {
      onboardCard.classList.add("is-leaving");
    }
    const hostRef = onboardHost;
    onboardHost = null;
    onboardCard = null;
    setTimeout(() => {
      try { hostRef.remove(); } catch (_) {}
    }, 320);
    if (persist) {
      try { chrome.storage.local.set({ [STORAGE_KEY_ONBOARD]: true }); } catch (_) {}
    }
  }

  async function maybeShowOnboard() {
    try {
      const stored = await chrome.storage.local.get(STORAGE_KEY_ONBOARD);
      if (stored && stored[STORAGE_KEY_ONBOARD]) return;
      mountOnboard();
    } catch (_) { /* storage unavailable, skip silently */ }
  }

  // Cross-tab sync: when one tab dismisses the cloud (by pressing ⌘K),
  // every other tab with the cloud showing fades it out too.
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes[STORAGE_KEY_ONBOARD] && changes[STORAGE_KEY_ONBOARD].newValue) {
      dismissOnboard({ persist: false });
    }
  });

  // ─── External triggers (background → content) ─────────────────────────────

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || !msg.type) return false;
    if (msg.type === "klo.toggle_overlay") {
      dismissOnboard();
      toggle();
      sendResponse({ ok: true, isOpen });
      return true;
    }
    if (msg.type === "klo.open_overlay") {
      dismissOnboard();
      open();
      sendResponse({ ok: true });
      return true;
    }
    if (msg.type === "klo.close_overlay") {
      close();
      sendResponse({ ok: true });
      return true;
    }
    return false;
  });

  // Local ⌥K fallback. The chrome.commands binding goes through background
  // and that's the primary path. This catches the case where Chrome failed
  // to register the command for whatever reason. ⌥K is also the published
  // hotkey because ⌘K is already owned by the Mac notch app at the OS level.
  // On macOS, Option+K natively types "˚" — we check both `key === "k"`
  // (some browsers / layouts) and `key === "˚"` (default US layout with
  // Option held) so we catch it either way.
  document.addEventListener("keydown", (e) => {
    const isAltK = e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey
                   && (e.key === "k" || e.key === "K" || e.key === "˚" || e.code === "KeyK");
    if (isAltK) {
      // Don't intercept ⌥K when user is typing in a page input — except
      // inside our own panel (where input lives in shadow DOM, so the host
      // page sees focus on body).
      const ae = document.activeElement;
      const inHostField = ae && ae !== document.body && ae !== document.documentElement
                          && (ae.tagName === "INPUT" || ae.tagName === "TEXTAREA" || ae.isContentEditable);
      if (inHostField && !isOpen) return;
      e.preventDefault();
      e.stopPropagation();
      dismissOnboard();
      toggle();
    } else if (e.key === "Escape" && isOpen) {
      // Esc only closes if the panel is open AND focus is in our shadow.
      // Otherwise leave Esc to the host page.
      const inShadow = e.composedPath().some((n) => n === host);
      if (inShadow) {
        e.preventDefault();
        e.stopPropagation();
        close();
      }
    }
  }, true);

  // Auto-open on content-script load if klo was open in another tab.
  // This is what makes klo "follow" the user when they switch tabs or
  // when klo navigates programmatically (chrome.tabs.create / update),
  // including the magic-link webmail navigation where klo's pending
  // state is the whole point of staying open.
  //
  // EXCEPT on auth/OAuth pages — we never auto-open there because
  // even float mode (panel as overlay, no page-push) covers content.
  // OAuth flows are short-lived; the user goes back to a normal page
  // after auth completes and the panel auto-opens there. If they need
  // klo on an auth page specifically, Alt+K still works.
  (async () => {
    try {
      if (isAuthHost()) return;
      const stored = await chrome.storage.local.get(STORAGE_KEY_OPEN);
      if (stored && stored[STORAGE_KEY_OPEN]) {
        open({ propagate: false });
      }
    } catch (_) { /* storage unavailable */ }
  })();

  // First-run cloud. Runs in parallel with the auto-open above; if the
  // user has already dismissed the cloud (storage flag set), this is a
  // no-op. Otherwise it mounts the floating "Press ⌘K" hint.
  maybeShowOnboard();
})();
