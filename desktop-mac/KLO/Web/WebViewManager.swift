import AppKit
import WebKit
import Combine

/// Klo's embedded web layer. One WKWebView, one persistent
/// WKWebsiteDataStore, lives inside klo's process. Replaces the
/// previously-planned bundled Chromium subprocess approach.
///
/// Why WKWebView (verified empirically — see /tmp/wkwebview-trust-test/):
///   - `NSEvent.mouseEvent` dispatched via `webView.mouseDown(with:)`
///     produces DOM events with `isTrusted=true` — the gate that
///     Instagram/Gmail/YouTube React handlers check. No Chromium needed.
///   - `NSEvent.keyEvent` via `webView.keyDown(with:)` does the same for
///     keystrokes (both keydown/keyup events AND the resulting `input`
///     events fire trusted).
///   - `WKWebsiteDataStore(forIdentifier:)` gives durable per-app cookie
///     + localStorage persistence that survives process restart.
///   - It's WebKit, not Chromium — saves ~344MB on the .app size and
///     gets free integration with macOS keychain, energy-optimised
///     rendering, and AppKit event flow.
///
/// All operations go through this singleton so the Python sidecar has
/// one well-known place to call into via `MacOpsServer`'s HTTP API.
@MainActor
final class WebViewManager: NSObject, ObservableObject {
    static let shared = WebViewManager()

    /// The web view itself. Held by reference here even when the
    /// embedding view (WebPaneView) isn't mounted — page state +
    /// scripts persist across panel mount/unmount cycles so the model
    /// can `web.open` and then later `web.click` without losing the
    /// page in between.
    private(set) var webView: WKWebView!

    /// Notifies observers when the WKWebView's loading state, URL, or
    /// title changes. WebPaneView observes this to repaint the
    /// minimal chrome (URL pill + close X).
    @Published private(set) var currentURL: URL? = nil
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isLoading: Bool = false

    /// Fixed identifier for the persistent data store. Same UUID across
    /// process restarts → same cookies, same localStorage, same logged-
    /// in sessions. The user signs into Gmail once in klo, klo stays
    /// signed into Gmail forever.
    private static let storeID = UUID(uuidString: "B72E1F4A-3D24-4F60-9C71-7D8B2A5E0C13")!

    /// Persistent offscreen NSWindow that holds the WKWebView whenever
    /// SwiftUI's WebPaneView isn't mounting it. This is the fix for the
    /// "WKWebView is not mounted in a window" trace bug:
    ///   - SwiftUI tears down WebPaneView on any mode flip away from
    ///     `.webPane` (offerSaveCredential prompt, panel collapse,
    ///     mid-run state change, etc.).
    ///   - Without this holder, webView.window becomes nil → mouseDown/
    ///     keyDown/makeFirstResponder all fail.
    ///   - The webView ALWAYS lives in this holder by default. When
    ///     SwiftUI mounts WebViewContainer, the webView is re-parented
    ///     into the SwiftUI host. When SwiftUI dismantles it, we move
    ///     it back here. NSEvent dispatch works in either parent.
    ///
    /// The window is borderless, sized to the canonical web-pane
    /// dimensions (so layout matches what the user sees), positioned
    /// far offscreen, and never ordered front. AppKit treats it as a
    /// live window for event-dispatch purposes regardless.
    private var hiddenHolder: NSWindow!

    /// Continuation slots that bridge async/await with WKNavigation
    /// callbacks. A single in-flight navigation at a time is enough
    /// for klo's model-driven access pattern.
    private var pendingNavigation: CheckedContinuation<Void, Error>? = nil

    private override init() {
        super.init()
        let cfg = WKWebViewConfiguration()
        if #available(macOS 14.0, *) {
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        } else {
            cfg.websiteDataStore = .default()
        }
        // Match the user agent shape Chrome uses so sites don't serve
        // mobile / lite variants. Some apps treat raw WebKit as Safari
        // and lock features.
        cfg.applicationNameForUserAgent = "Klo/1.0"

        // Install the credential-capture user script in every frame.
        // Fires on form submissions and posts to the kloCredCapture
        // message handler so klo can ask "Save sign-in to klo?"
        // See CredCaptureCoordinator for the full flow.
        let captureScript = WKUserScript(
            source: CredCaptureCoordinator.captureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
        )
        cfg.userContentController.addUserScript(captureScript)
        cfg.userContentController.add(CredCaptureCoordinator.shared, name: "kloCredCapture")

        // Construct with a substantial default size — the actual size
        // is set by WebPaneView when mounted, but a non-zero frame here
        // lets the page lay out reasonably during the open-before-mount
        // window (which DOES happen — model calls web.open seconds
        // before the user's panel transitions to .webPane mode).
        let webFrame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        webView = WKWebView(frame: webFrame, configuration: cfg)
        // Disable the back/forward swipe — the model drives navigation
        // explicitly via web.open. The user doesn't get a gesture-based
        // way to mess with klo's understanding of the current page.
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Observe load state + URL + title for the chrome bar.
        webView.addObserver(self, forKeyPath: "URL",      options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "title",    options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "loading",  options: .new, context: nil)

        // Build the persistent offscreen holder. -10000pt is well off
        // every monitor; the window exists for AppKit's bookkeeping
        // (so webView.window is non-nil and NSEvent dispatch works)
        // but the user never sees it. We orderOut to keep it
        // explicitly hidden — but `windowNumber` stays valid as long
        // as the window object lives, which is what NSEvent.mouseEvent
        // needs.
        let holderFrame = NSRect(x: -20000, y: -20000, width: webFrame.width, height: webFrame.height)
        let holder = NSWindow(
            contentRect: holderFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,
        )
        holder.isReleasedWhenClosed = false
        holder.hasShadow = false
        holder.level = .normal
        holder.ignoresMouseEvents = true
        let host = NSView(frame: NSRect(origin: .zero, size: webFrame.size))
        holder.contentView = host
        host.addSubview(webView)
        webView.frame = NSRect(origin: .zero, size: webFrame.size)
        // orderFrontRegardless then orderOut: we need the window to
        // have ever been brought online (so windowNumber assigned),
        // then hide it. Without this dance, some macOS versions
        // assign windowNumber=-1 until first display.
        holder.orderFrontRegardless()
        holder.orderOut(nil)
        hiddenHolder = holder
    }

    /// Called by `WebViewContainer.dismantleNSView` when SwiftUI tears
    /// down the visible WebPaneView (mode change, panel collapse, etc.).
    /// Re-parents the WKWebView back into the hidden holder so it
    /// retains a window for NSEvent dispatch.
    ///
    /// Without this, agent runs that span mode changes (e.g. the
    /// CredCaptureCoordinator flips into .offerSaveCredential, then
    /// back) lose the WKWebView's window and every subsequent click /
    /// type errors out with "WKWebView is not mounted in a window."
    func reparentToHolder() {
        guard let host = hiddenHolder?.contentView else { return }
        if webView.superview === host { return }
        webView.removeFromSuperview()
        host.addSubview(webView)
        webView.frame = NSRect(origin: .zero, size: host.bounds.size)
        NSLog("KLO Web: re-parented WKWebView to hidden holder")
    }

    // MARK: - Public operations (called by MacOpsServer)

    /// Navigate to `url`. Returns after the page reports
    /// didFinish (or didFail) so callers can read state without
    /// racing the renderer.
    func open(url: URL, timeout: TimeInterval = 12.0) async throws {
        // Cancel any prior in-flight navigation.
        pendingNavigation?.resume(throwing: WebError.cancelled)
        pendingNavigation = nil

        webView.load(URLRequest(url: url))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingNavigation = cont
            // Watchdog — never let the model block indefinitely.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    guard let self else { return }
                    if let c = self.pendingNavigation {
                        self.pendingNavigation = nil
                        c.resume(throwing: WebError.timeout)
                    }
                }
            }
        }
    }

    /// Evaluate a JS expression in the page's main world. Returns the
    /// JSON-serialisable result value (or nil if undefined).
    func evaluate(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(js) { value, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: value)
                }
            }
        }
    }

    /// Dispatch a trusted mouse click at the given DOM point. Coordinates
    /// are in CSS pixels (the same space `getBoundingClientRect()` returns);
    /// we convert to AppKit window coords before posting.
    func clickAt(domX: CGFloat, domY: CGFloat) async throws {
        guard let window = webView.window else { throw WebError.notMounted }
        // WKWebView's internal coords are top-left like the DOM (despite
        // AppKit's bottom-left convention) — the view does the flip
        // internally. So passing DOM coords directly works.
        let viewPoint = NSPoint(x: domX, y: domY)
        let windowPoint = webView.convert(viewPoint, to: nil)
        let ts = ProcessInfo.processInfo.systemUptime

        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [],
            timestamp: ts, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0
        ),
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint, modifierFlags: [],
            timestamp: ts + 0.05, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ) else {
            throw WebError.eventConstructionFailed
        }

        webView.mouseDown(with: down)
        webView.mouseUp(with: up)
    }

    /// Click an element found via JS. Returns the element's tag/label
    /// plus before/after URL+title so the caller can detect state
    /// changes. `selector` is a CSS selector; `text` is a fallback that
    /// matches innerText/aria-label.
    func clickElement(selector: String?, text: String?, nth: Int) async throws -> [String: Any] {
        let finderJS = Self.buildFinderJS(selector: selector, text: text, nth: nth)
        let beforeURL = currentURL?.absoluteString
        let beforeTitle = currentTitle

        let result = try await evaluate(finderJS)
        guard let coords = result as? [String: Any],
              let x = (coords["x"] as? NSNumber)?.doubleValue,
              let y = (coords["y"] as? NSNumber)?.doubleValue else {
            return [
                "ok": false, "error": "selector_not_found",
                "selector": selector as Any, "text_query": text as Any,
                "before_url": beforeURL as Any,
            ]
        }

        try await clickAt(domX: CGFloat(x), domY: CGFloat(y))
        // Let the click's onClick fire + any nav settle.
        try? await Task.sleep(nanoseconds: 350_000_000)

        let afterURL = currentURL?.absoluteString
        let afterTitle = currentTitle
        let stateChanged = (beforeURL != afterURL) || (beforeTitle != afterTitle)

        return [
            "ok": true,
            "match": [
                "tag": coords["tag"] as? String ?? "",
                "label": coords["label"] as? String ?? "",
                "href": coords["href"] as Any,
            ],
            "coords": ["x": x, "y": y],
            "before_url": beforeURL as Any,
            "after_url": afterURL as Any,
            "before_title": beforeTitle,
            "after_title": afterTitle,
            "state_changed": stateChanged,
        ]
    }

    /// Focus an input matching `selector`, optionally clear it, then
    /// type `text`. Uses webView.insertText for bulk text (one trusted
    /// input event), or per-key NSEvent dispatch if needed for sites
    /// that listen specifically for keydown events.
    func typeText(selector: String, text: String, submit: Bool, clearFirst: Bool) async throws -> [String: Any] {
        guard let window = webView.window else { throw WebError.notMounted }

        // Focus the element via JS, then make webView the first responder
        // so the next mouse/key events are routed to it.
        let focusJS = """
        (() => {
            const el = document.querySelector(\(jsString(selector)));
            if (!el) return false;
            try { el.scrollIntoView({behavior: 'instant', block: 'center'}); } catch(_) {}
            try { el.focus({preventScroll: true}); } catch(_) { el.focus(); }
            return document.activeElement === el;
        })()
        """
        let focusedAny = try await evaluate(focusJS)
        let focused = (focusedAny as? Bool) ?? false
        if !focused {
            return ["ok": false, "error": "selector_not_found", "selector": selector]
        }
        window.makeFirstResponder(webView)

        // Clear via Cmd+A → Delete.
        if clearFirst {
            try await sendKeyCombo("a", keyCode: 0x00, modifiers: .command)
            try await sendKey(.delete, keyCode: 0x33, char: "\u{0008}")
        }

        // Bulk insert — fires a single trusted input event with
        // inputType:"insertText", data:text. React + Vue + most
        // frameworks listen for input not keydown for text changes.
        if !text.isEmpty {
            webView.insertText(text)
        }

        if submit {
            try await sendKey(.return, keyCode: 0x24, char: "\r")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        return ["ok": true, "selector": selector, "chars": text.count, "submitted": submit]
    }

    enum SpecialKey { case `return`, delete }

    private func sendKey(_ kind: SpecialKey, keyCode: UInt16, char: String) async throws {
        try await dispatchKey(keyCode: keyCode, char: char, modifiers: [])
    }

    private func sendKeyCombo(_ char: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) async throws {
        try await dispatchKey(keyCode: keyCode, char: char, modifiers: modifiers)
    }

    private func dispatchKey(keyCode: UInt16, char: String, modifiers: NSEvent.ModifierFlags) async throws {
        guard let window = webView.window else { throw WebError.notMounted }
        let ts = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ts, windowNumber: window.windowNumber, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode
        ),
        let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: modifiers,
            timestamp: ts + 0.02, windowNumber: window.windowNumber, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode
        ) else {
            throw WebError.eventConstructionFailed
        }
        webView.keyDown(with: down)
        webView.keyUp(with: up)
    }

    /// Read inner text. If `selector` is nil, returns document.body.innerText.
    func readText(selector: String?, max: Int) async throws -> [String: Any] {
        let expr: String
        if let s = selector {
            expr = "(() => { const el = document.querySelector(\(jsString(s))); return el ? (el.innerText || el.textContent || '') : null; })()"
        } else {
            expr = "document.body && (document.body.innerText || document.body.textContent || '')"
        }
        let value = try await evaluate(expr)
        guard let s = value as? String else {
            return ["ok": false, "error": "no_text", "selector": selector as Any]
        }
        let truncated = s.count > max
        let out = truncated ? String(s.prefix(max)) : s
        return ["ok": true, "text": out, "truncated": truncated, "length": s.count]
    }

    /// Poll until `selector` is present or `timeout` elapses.
    func waitFor(selector: String, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.5), 30.0))
        let expr = "!!document.querySelector(\(jsString(selector)))"
        let start = Date()
        while Date() < deadline {
            let present = (try? await evaluate(expr)) as? Bool ?? false
            if present {
                return [
                    "ok": true, "selector": selector,
                    "elapsed_s": Date().timeIntervalSince(start),
                ]
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return ["ok": false, "error": "timeout", "selector": selector, "timeout_s": timeout]
    }

    /// JS that walks the live DOM, computes ARIA role + accessible
    /// name (W3C ANC 1.1 subset), filters to visible interactive
    /// elements, tags each with `data-klo-idx`, and returns a compact
    /// indexed list. This is the FAR-superior alternative to
    /// `web.click(text=...)` — Playwright's `getByRole(role, name)` is
    /// built on the same algorithm.
    ///
    /// Why this is the right pattern (confirmed against WebGames
    /// benchmark winner @ 85% success):
    ///   - The model gets the SAME semantic view a screen reader gets:
    ///     role + accessible name + state. No HTML, no CSS, no
    ///     framework noise.
    ///   - Indexed click means the model says "press(idx=1)" instead
    ///     of guessing CSS selectors or text patterns. No selector
    ///     reverse-engineering, no innerText collisions.
    ///   - data-klo-idx tags survive scroll, resize, and most
    ///     re-layouts — the snapshot stays usable for ~30s until the
    ///     model takes a fresh one.
    ///
    /// Implementation notes:
    ///   - Name computation follows W3C's Accessible Name and
    ///     Description Computation 1.1, simplified:
    ///       1. aria-labelledby (resolve IDREFs, join with space)
    ///       2. aria-label
    ///       3. native HTML semantics (label[for], wrapping label,
    ///          placeholder for inputs; alt for img; etc.)
    ///       4. subtree innerText (trimmed)
    ///       5. title attribute
    ///   - Role: explicit `role` attr first, then a small lookup of
    ///     native HTML elements. Anything we can't classify gets
    ///     "generic" (and excluded unless it has an explicit role or
    ///     onclick or tabindex>=0).
    ///   - Capped at 300 items — most pages have 30-80. Beyond 300,
    ///     the model is going to truncate anyway. We sort by document
    ///     order so adjacent items in the list are spatially nearby.
    private static let snapshotScript: String = """
    (function() {
      const NAME_MAX = 80;
      const VALUE_MAX = 60;
      const ITEM_CAP = 300;

      function visible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return false;
        const cs = window.getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden') return false;
        if (parseFloat(cs.opacity || '1') < 0.05) return false;
        // aria-hidden anywhere in ancestor chain
        let cur = el;
        while (cur) {
          if (cur.getAttribute && cur.getAttribute('aria-hidden') === 'true') return false;
          cur = cur.parentElement;
        }
        return true;
      }

      // Map HTML element to its implicit ARIA role. Not exhaustive but
      // covers ~95% of real-world interactive elements. Anything not
      // listed returns null and the explicit role attr takes over.
      function implicitRole(el) {
        const t = el.tagName.toLowerCase();
        switch (t) {
          case 'a':        return el.hasAttribute('href') ? 'link' : null;
          case 'button':   return 'button';
          case 'select':   return el.hasAttribute('multiple') ? 'listbox' : 'combobox';
          case 'textarea': return 'textbox';
          case 'details':  return 'group';
          case 'summary':  return 'button';
          case 'option':   return 'option';
          case 'input': {
            const type = (el.type || 'text').toLowerCase();
            const inputMap = {
              text: 'textbox', email: 'textbox', search: 'searchbox',
              tel: 'textbox', url: 'textbox', password: 'textbox',
              number: 'spinbutton', range: 'slider',
              checkbox: 'checkbox', radio: 'radio',
              button: 'button', submit: 'button', reset: 'button',
              image: 'button', file: 'button',
              date: 'textbox', 'datetime-local': 'textbox',
              month: 'textbox', time: 'textbox', week: 'textbox',
              color: 'textbox',
            };
            return inputMap[type] || 'textbox';
          }
          case 'h1': case 'h2': case 'h3':
          case 'h4': case 'h5': case 'h6': return 'heading';
          case 'nav':     return 'navigation';
          case 'main':    return 'main';
          case 'aside':   return 'complementary';
          case 'header':  return 'banner';
          case 'footer':  return 'contentinfo';
          case 'form':    return 'form';
          case 'img':     return el.hasAttribute('alt') && el.getAttribute('alt') === '' ? null : 'img';
          default:        return null;
        }
      }

      function role(el) {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.trim().toLowerCase();
        return implicitRole(el);
      }

      // W3C ANC 1.1, simplified.
      function accName(el, depth) {
        depth = depth || 0;
        if (depth > 3) return '';
        // 1. aria-labelledby
        const lblBy = el.getAttribute && el.getAttribute('aria-labelledby');
        if (lblBy) {
          const parts = lblBy.split(/\\s+/).map(id => {
            const ref = document.getElementById(id);
            return ref ? (ref.innerText || ref.textContent || '').trim() : '';
          }).filter(Boolean);
          if (parts.length) return parts.join(' ').trim();
        }
        // 2. aria-label
        const lbl = el.getAttribute && el.getAttribute('aria-label');
        if (lbl && lbl.trim()) return lbl.trim();

        // 3. Native HTML semantics
        const tag = el.tagName ? el.tagName.toLowerCase() : '';
        if (tag === 'input' || tag === 'select' || tag === 'textarea') {
          // label[for=id]
          if (el.id) {
            const lblEl = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
            if (lblEl) {
              const t = (lblEl.innerText || lblEl.textContent || '').trim();
              if (t) return t;
            }
          }
          // wrapping <label>
          let p = el.parentElement;
          while (p && p !== document.body) {
            if (p.tagName === 'LABEL') {
              const t = (p.innerText || p.textContent || '').trim();
              if (t) return t;
              break;
            }
            p = p.parentElement;
          }
          // For buttons: value attribute
          if (tag === 'input') {
            const it = (el.type || '').toLowerCase();
            if (it === 'button' || it === 'submit' || it === 'reset') {
              const v = (el.value || '').trim();
              if (v) return v;
            }
          }
          // Placeholder (last-resort hint, even though ANC ranks it lower)
          const ph = el.getAttribute('placeholder');
          if (ph && ph.trim()) return ph.trim();
        }
        if (tag === 'img') {
          const alt = el.getAttribute('alt');
          if (alt && alt.trim()) return alt.trim();
        }

        // 4. Subtree content (innerText is the most reliable)
        const inner = (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
        if (inner) return inner;

        // 5. title
        const ti = el.getAttribute && el.getAttribute('title');
        if (ti && ti.trim()) return ti.trim();
        return '';
      }

      // What value (if any) does this element carry? For combo/text-
      // input/select we report current value. For checkbox/radio we
      // report checked state via separate field. Skip for buttons/links.
      function valueOf(el) {
        const tag = el.tagName.toLowerCase();
        if (tag === 'input') {
          const t = (el.type || '').toLowerCase();
          if (t === 'checkbox' || t === 'radio') return undefined;
          if (t === 'button' || t === 'submit' || t === 'reset' || t === 'file' || t === 'image') return undefined;
          return el.value || '';
        }
        if (tag === 'select') {
          const opt = el.options[el.selectedIndex];
          return opt ? (opt.text || opt.value) : '';
        }
        if (tag === 'textarea') return el.value || '';
        if (el.isContentEditable) return (el.textContent || '').trim();
        return undefined;
      }

      function isInteractive(el, r) {
        if (!r) return false;
        if (el.disabled) return false;
        const cs = window.getComputedStyle(el);
        if (cs.pointerEvents === 'none') return false;
        // Explicit role that's interactive
        const explicitRole = (el.getAttribute('role') || '').toLowerCase();
        const interactiveRoles = new Set([
          'button','link','tab','menuitem','menuitemradio','menuitemcheckbox',
          'option','radio','checkbox','switch','slider','spinbutton',
          'textbox','combobox','listbox','searchbox','treeitem','gridcell',
        ]);
        if (interactiveRoles.has(explicitRole)) return true;
        // Native interactive tags
        const t = el.tagName.toLowerCase();
        if (t === 'a' && el.hasAttribute('href')) return true;
        if (t === 'button' || t === 'select' || t === 'textarea' || t === 'summary') return true;
        if (t === 'input') {
          const it = (el.type || 'text').toLowerCase();
          if (it === 'hidden') return false;
          return true;
        }
        if (el.isContentEditable) return true;
        if (el.tabIndex >= 0) return true;
        // onclick handler (heuristic — only catches inline handlers,
        // not addEventListener. Better than nothing.)
        if (el.hasAttribute('onclick')) return true;
        return false;
      }

      // Clear stale tags from previous snapshot
      document.querySelectorAll('[data-klo-idx]').forEach(el => {
        el.removeAttribute('data-klo-idx');
      });

      const all = document.querySelectorAll('*');
      const items = [];
      let idx = 0;
      for (const el of all) {
        if (idx >= ITEM_CAP) break;
        if (!visible(el)) continue;
        const r = el.getBoundingClientRect();
        if (!isInteractive(el, r)) continue;
        // Compute role; if generic, only include if it has tabindex/onclick/explicit role
        const er = role(el);
        if (!er || er === 'generic') {
          if (!el.hasAttribute('role') && !el.hasAttribute('onclick') && el.tabIndex < 0) continue;
        }
        const n = accName(el).slice(0, NAME_MAX);
        // Skip unnamed elements unless they're text inputs that carry a value
        const v = valueOf(el);
        if (!n && !v && er !== 'textbox' && er !== 'searchbox' && er !== 'combobox') continue;
        el.setAttribute('data-klo-idx', String(idx));
        const item = {
          idx,
          role: er || 'generic',
          name: n,
          x: Math.round(r.left + r.width / 2),
          y: Math.round(r.top + r.height / 2),
        };
        if (v !== undefined) item.value = String(v).slice(0, VALUE_MAX);
        if (el.checked) item.checked = true;
        const sel = el.getAttribute('aria-selected');
        if (sel === 'true') item.selected = true;
        const exp = el.getAttribute('aria-expanded');
        if (exp === 'true') item.expanded = true;
        if (exp === 'false') item.expanded = false;
        items.push(item);
        idx++;
      }

      return {
        snapshot_id: 'snap_' + Math.random().toString(36).slice(2, 10),
        url: location.href,
        title: document.title,
        viewport: {w: window.innerWidth, h: window.innerHeight},
        scroll: {x: window.scrollX, y: window.scrollY},
        items,
      };
    })();
    """

    /// The most-recent snapshot id we handed out. Used for stale-snapshot
    /// detection in press/fill — if the model passes a snapshot_id that
    /// doesn't match the live tags, we error with a clear "take a new
    /// snapshot" message instead of clicking the wrong element.
    private(set) var lastSnapshotId: String? = nil
    private(set) var lastSnapshotURL: String? = nil

    /// Capture the page's interactive-element tree as a flat indexed
    /// list. Auto-settles the DOM first. Returns a `[String: Any]`
    /// matching the contract documented above. Used by `web.snapshot`
    /// and by `web.press/fill` (which look up by `data-klo-idx`).
    func snapshot() async throws -> [String: Any] {
        await waitForSettled(timeout: 3.0)
        let raw = try await evaluate(Self.snapshotScript)
        guard var dict = raw as? [String: Any] else {
            return ["ok": false, "error": "snapshot returned non-dict"]
        }
        dict["ok"] = true
        lastSnapshotId = dict["snapshot_id"] as? String
        lastSnapshotURL = dict["url"] as? String
        return dict
    }

    /// Click the element tagged with `data-klo-idx=idx` in the current
    /// page. Uses the existing NSEvent trusted-click pipeline. If the
    /// snapshot is stale (no element with that idx exists anymore),
    /// returns ok=false with a typed reason so the model knows to take
    /// a fresh snapshot.
    func pressIdx(_ idx: Int, snapshotId: String? = nil) async throws -> [String: Any] {
        if let sid = snapshotId, let last = lastSnapshotId, sid != last {
            return [
                "ok": false,
                "error": "stale snapshot — snapshot_id \(sid) is older than current \(last); call web.snapshot() again",
                "stale": true,
            ]
        }
        let lookup = """
        (() => {
          const el = document.querySelector('[data-klo-idx="\(idx)"]');
          if (!el) return null;
          try { el.scrollIntoView({behavior: 'instant', block: 'center', inline: 'center'}); } catch(_){}
          const r = el.getBoundingClientRect();
          if (!r || (r.width === 0 && r.height === 0)) return null;
          return {
            x: r.left + r.width / 2,
            y: r.top + r.height / 2,
            tag: el.tagName.toLowerCase(),
            role: el.getAttribute('role') || '',
            label: ((el.innerText || el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 120)),
            href: el.getAttribute('href') || null,
          };
        })()
        """
        let beforeURL = currentURL?.absoluteString
        let beforeTitle = currentTitle
        let result = try await evaluate(lookup)
        guard let coords = result as? [String: Any],
              let x = (coords["x"] as? NSNumber)?.doubleValue,
              let y = (coords["y"] as? NSNumber)?.doubleValue else {
            return [
                "ok": false,
                "error": "idx \(idx) not found in current page — snapshot is stale, take a new web.snapshot()",
                "stale": true,
            ]
        }
        try await clickAt(domX: CGFloat(x), domY: CGFloat(y))
        try? await Task.sleep(nanoseconds: 350_000_000)
        let afterURL = currentURL?.absoluteString
        let afterTitle = currentTitle
        let stateChanged = (beforeURL != afterURL) || (beforeTitle != afterTitle)
        return [
            "ok": true,
            "idx": idx,
            "match": [
                "tag": coords["tag"] as? String ?? "",
                "role": coords["role"] as? String ?? "",
                "label": coords["label"] as? String ?? "",
                "href": coords["href"] as Any,
            ],
            "before_url": beforeURL as Any,
            "after_url": afterURL as Any,
            "before_title": beforeTitle,
            "after_title": afterTitle,
            "state_changed": stateChanged,
        ]
    }

    /// Focus the element tagged `data-klo-idx=idx` and type `text`.
    /// Same trusted-keystroke pipeline as `typeText(selector:)`.
    func fillIdx(_ idx: Int, text: String, submit: Bool, clearFirst: Bool, snapshotId: String? = nil) async throws -> [String: Any] {
        if let sid = snapshotId, let last = lastSnapshotId, sid != last {
            return [
                "ok": false,
                "error": "stale snapshot — snapshot_id \(sid) is older than current \(last); call web.snapshot() again",
                "stale": true,
            ]
        }
        guard let window = webView.window else { throw WebError.notMounted }

        let focusJS = """
        (() => {
          const el = document.querySelector('[data-klo-idx="\(idx)"]');
          if (!el) return false;
          try { el.scrollIntoView({behavior: 'instant', block: 'center'}); } catch(_){}
          try { el.focus({preventScroll: true}); } catch(_) { el.focus(); }
          return document.activeElement === el;
        })()
        """
        let focusedAny = try await evaluate(focusJS)
        let focused = (focusedAny as? Bool) ?? false
        if !focused {
            return [
                "ok": false,
                "error": "idx \(idx) not found or not focusable — take a new web.snapshot()",
                "stale": true,
            ]
        }
        window.makeFirstResponder(webView)

        if clearFirst {
            try await sendKeyCombo("a", keyCode: 0x00, modifiers: .command)
            try await sendKey(.delete, keyCode: 0x33, char: "\u{0008}")
        }
        if !text.isEmpty {
            webView.insertText(text)
        }
        if submit {
            try await sendKey(.return, keyCode: 0x24, char: "\r")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return ["ok": true, "idx": idx, "chars": text.count, "submitted": submit]
    }

    /// Capture the WKWebView's visible content as a PNG. Used by
    /// `web.screenshot` so the model gets visual grounding on heavy
    /// SPAs (Google Flights, Booking, Notion, etc.) where the text-
    /// only `web.text` is unusable.
    ///
    /// Implementation notes:
    ///   - `takeSnapshot(with:completionHandler:)` is the right API —
    ///     it composites with the page's actual paint state (not a
    ///     screen-capture, which would fail in the background or with
    ///     no SR permission). Works whether or not the panel is
    ///     visible because WKWebView keeps a paint context.
    ///   - We constrain to `rect: .zero` which means "the visible
    ///     viewport." That matches what the user sees, which is the
    ///     mental model the model already has.
    ///   - We render `afterScreenUpdates: true` so any pending layout
    ///     flushes before we capture — eliminates the "captured mid-
    ///     paint" footgun that produces blank screenshots on freshly-
    ///     loaded pages.
    ///   - Output is PNG (lossless, easy to send as base64). Anthropic
    ///     supports PNG natively; the model gets a real image block.
    func screenshot(maxWidth: CGFloat = 1280) async throws -> [String: Any] {
        let config = WKSnapshotConfiguration()
        config.rect = .zero  // full visible viewport
        config.afterScreenUpdates = true
        // Cap width — Anthropic image blocks tokenize per pixel, so
        // 1280px is a good ceiling (matches typical laptop CSS width).
        // The shrink happens server-side after capture.
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: config) { img, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let img = img else {
                    cont.resume(throwing: WebError.eventConstructionFailed)
                    return
                }
                cont.resume(returning: img)
            }
        }

        // Convert NSImage → PNG Data. We downscale if wider than maxWidth.
        let sourceSize = image.size
        let scale: CGFloat = (sourceSize.width > maxWidth)
            ? maxWidth / sourceSize.width
            : 1.0
        let targetSize = NSSize(width: sourceSize.width * scale,
                                height: sourceSize.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        )
        guard let rep = rep else {
            throw WebError.eventConstructionFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw WebError.eventConstructionFailed
        }
        let b64 = pngData.base64EncodedString()
        return [
            "ok": true,
            "media_type": "image/png",
            "data": b64,
            "width": Int(targetSize.width),
            "height": Int(targetSize.height),
            "source_width": Int(sourceSize.width),
            "source_height": Int(sourceSize.height),
            "url": currentURL?.absoluteString as Any,
        ]
    }

    /// Wait for the WKWebView's main-document `readyState === 'complete'`
    /// and for in-flight fetches/XHRs to drain, OR for `timeout` to
    /// elapse. Used by callers that need "page is settled" before
    /// reading text / clicking. Polls every 200ms.
    ///
    /// We instrument fetch + XHR via a one-shot user-script (idempotent
    /// — checks `window.__kloNetTracker`). If the tracker reports 0
    /// in-flight requests for 2 consecutive polls AND readyState is
    /// complete, we consider the page settled. Pages without fetch
    /// activity (static HTML) settle immediately on readyState alone.
    func waitForSettled(timeout: TimeInterval = 4.0) async {
        let installTracker = """
        (function() {
          if (window.__kloNetTracker) return;
          window.__kloNetTracker = { inflight: 0 };
          const origFetch = window.fetch;
          window.fetch = function() {
            window.__kloNetTracker.inflight++;
            return origFetch.apply(this, arguments).finally(() => {
              window.__kloNetTracker.inflight--;
            });
          };
          const origOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function() {
            this.addEventListener('loadstart', () => window.__kloNetTracker.inflight++);
            const done = () => window.__kloNetTracker.inflight--;
            this.addEventListener('loadend', done);
            return origOpen.apply(this, arguments);
          };
        })();
        """
        _ = try? await evaluate(installTracker)
        let deadline = Date().addingTimeInterval(min(max(timeout, 0.5), 10.0))
        var idleStreak = 0
        while Date() < deadline {
            let stateAny = (try? await evaluate("document.readyState")) as? String ?? ""
            let inflightAny = (try? await evaluate("(window.__kloNetTracker && window.__kloNetTracker.inflight) || 0")) as? NSNumber
            let inflight = inflightAny?.intValue ?? 0
            if stateAny == "complete" && inflight == 0 {
                idleStreak += 1
                if idleStreak >= 2 { return }
            } else {
                idleStreak = 0
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Try to autofill a sign-in form on the current page using klo's
    /// own credential store (KloKeychain). Triggers Touch ID if a
    /// matching item exists. Returns:
    ///   - ok=true,  filled=true,  username=<u> on success
    ///   - ok=true,  filled=false, reason="no_credential" if nothing saved
    ///   - ok=true,  filled=false, reason="no_form" if no login form on page
    ///   - ok=false, error="biometry_cancelled" / "biometry_failed:<msg>"
    ///
    /// Klo never auto-submits — the form is filled and the password
    /// field is focused so the user can review + press Enter. This
    /// matches Safari's actual behavior and keeps the user in the loop.
    func autofill(host: String) async -> [String: Any] {
        let lookupHost = host.isEmpty
            ? (currentURL?.host ?? "")
            : host
        let outcome = KloKeychain.lookup(host: lookupHost,
                                         reason: "Use saved sign-in for \(lookupHost)")
        switch outcome {
        case .noMatch:
            return ["ok": true, "filled": false, "reason": "no_credential", "host": lookupHost]
        case .biometryCancelled:
            return ["ok": false, "error": "biometry_cancelled", "host": lookupHost]
        case .biometryFailed(let msg):
            return ["ok": false, "error": "biometry_failed: \(msg)", "host": lookupHost]
        case .found(let username, let password):
            let userJSON = Self.jsStringStatic(username)
            let pwdJSON = Self.jsStringStatic(password)
            // Use the native value setter so React-controlled inputs
            // accept the value. Setting .value directly doesn't fire
            // React's onChange because React monkeypatches the property
            // descriptor on its synthetic-event system. We bypass that
            // by calling the cached native descriptor's setter.
            let js = """
            (() => {
              const userSel = [
                'input[type=email]',
                'input[autocomplete="username"]',
                'input[autocomplete="email"]',
                'input[name*=user i]',
                'input[name*=login i]',
                'input[name*=email i]',
                'input[id*=user i]',
                'input[id*=login i]',
                'input[id*=email i]',
              ];
              let userEl = null;
              for (const s of userSel) {
                const el = document.querySelector(s);
                if (el) { userEl = el; break; }
              }
              const pwdEl = document.querySelector('input[type=password]');
              if (!pwdEl) return { filled: false, reason: 'no_form' };
              const nativeSet = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
              ).set;
              if (userEl) {
                nativeSet.call(userEl, \(userJSON));
                userEl.dispatchEvent(new Event('input', { bubbles: true }));
                userEl.dispatchEvent(new Event('change', { bubbles: true }));
              }
              nativeSet.call(pwdEl, \(pwdJSON));
              pwdEl.dispatchEvent(new Event('input', { bubbles: true }));
              pwdEl.dispatchEvent(new Event('change', { bubbles: true }));
              pwdEl.focus();
              return { filled: true };
            })()
            """
            do {
                let res = try await evaluate(js)
                if let dict = res as? [String: Any],
                   let filled = dict["filled"] as? Bool, filled {
                    return ["ok": true, "filled": true, "host": lookupHost, "username": username]
                }
                let reason = (res as? [String: Any])?["reason"] as? String ?? "no_form"
                return ["ok": true, "filled": false, "reason": reason, "host": lookupHost]
            } catch {
                return ["ok": false, "error": "js_failed: \(error.localizedDescription)", "host": lookupHost]
            }
        }
    }

    /// Current URL + title summary.
    func urlSummary() -> [String: Any] {
        return [
            "ok": true,
            "url": currentURL?.absoluteString as Any,
            "title": currentTitle,
        ]
    }

    // MARK: - JS helpers

    private static func buildFinderJS(selector: String?, text: String?, nth: Int) -> String {
        let n = String(max(0, nth))
        if let s = selector {
            return """
            (() => {
                const els = document.querySelectorAll(\(jsStringStatic(s)));
                const el = els[\(n)];
                if (!el) return null;
                try { el.scrollIntoView({behavior: 'instant', block: 'center', inline: 'center'}); } catch(_){}
                const r = el.getBoundingClientRect();
                if (!r || (r.width === 0 && r.height === 0)) return null;
                return {
                    x: r.left + r.width / 2,
                    y: r.top + r.height / 2,
                    tag: el.tagName.toLowerCase(),
                    label: ((el.innerText || el.textContent || el.getAttribute('aria-label') || el.getAttribute('title') || '').trim().slice(0, 120)),
                    href: el.getAttribute('href') || null
                };
            })()
            """
        } else if let t = text {
            return """
            (() => {
                const q = \(jsStringStatic(t)).toLowerCase().trim();
                if (!q) return null;
                // Selector that catches every clickable role + tag we
                // know about, INCLUDING MUI / Material idioms (tab, menu
                // item, option, radio, checkbox, switch). The text query
                // may match a CHILD of one of these; we walk up to the
                // nearest clickable ancestor before clicking.
                const clickableSel = 'button, a, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"], [role="option"], [role="radio"], [role="checkbox"], [role="switch"], input[type="submit"], input[type="button"], input[type="radio"], input[type="checkbox"], summary, label[for]';
                const isClickable = (el) => {
                    if (!el || el.nodeType !== 1) return false;
                    if (el.disabled) return false;
                    return el.matches && el.matches(clickableSel);
                };
                const climbToClickable = (el) => {
                    let cur = el;
                    for (let i = 0; i < 6 && cur; i++) {
                        if (isClickable(cur)) return cur;
                        cur = cur.parentElement;
                    }
                    return el;  // fall back to original if nothing matches
                };
                // Score candidates so exact matches beat substring matches.
                // Higher score = better. We collect all candidates, sort,
                // then pick the first one that's actually visible.
                const score = (el, label) => {
                    const norm = (label || '').toLowerCase().trim();
                    if (!norm) return 0;
                    if (norm === q) return 100;
                    if (norm.startsWith(q + ' ') || norm.startsWith(q + ':')) return 80;
                    if (norm.endsWith(' ' + q)) return 70;
                    // Word-boundary contains beats raw contains by a lot.
                    const re = new RegExp('\\\\b' + q.replace(/[.*+?^${}()|[\\\\]\\\\\\\\]/g, '\\\\\\\\$&') + '\\\\b');
                    if (re.test(norm)) return 60;
                    if (norm.includes(q)) return 40;
                    return 0;
                };

                // Walk everything; a heavy SPA might have the text in a span deep
                // inside a tab-roled li. The candidate ALSO covers the case where
                // the clickable element itself carries the text.
                const all = Array.from(document.querySelectorAll('*'));
                const scored = [];
                const seen = new Set();
                for (const el of all) {
                    if (!el.getAttribute) continue;
                    const t  = (el.innerText || el.textContent || '').slice(0, 200);
                    const a  = el.getAttribute('aria-label') || '';
                    const ti = el.getAttribute('title') || '';
                    const tid = el.getAttribute('data-testid') || '';
                    const place = el.getAttribute('placeholder') || '';
                    const best = Math.max(score(el, t), score(el, a), score(el, ti), score(el, tid), score(el, place));
                    if (!best) continue;
                    const target = climbToClickable(el);
                    if (seen.has(target)) continue;
                    seen.add(target);
                    scored.push({ target, src: el, best });
                }
                scored.sort((a, b) => b.best - a.best);

                for (const { target, src, best } of scored) {
                    try { target.scrollIntoView({behavior: 'instant', block: 'center', inline: 'center'}); } catch(_){}
                    // Visibility — getBoundingClientRect AFTER scrollIntoView
                    // so off-screen elements get their position resolved.
                    const r = target.getBoundingClientRect();
                    if (!r || (r.width === 0 && r.height === 0)) continue;
                    // Computed style — skip pointer-events:none and display:none.
                    // Some SPAs render hidden buttons for ghost-state animations.
                    const cs = window.getComputedStyle(target);
                    if (cs.pointerEvents === 'none') continue;
                    if (cs.display === 'none' || cs.visibility === 'hidden') continue;
                    const label = (src.innerText || src.textContent || src.getAttribute('aria-label') || src.getAttribute('title') || '').trim().slice(0, 120);
                    return {
                        x: r.left + r.width / 2,
                        y: r.top + r.height / 2,
                        tag: target.tagName.toLowerCase(),
                        label,
                        score: best,
                        href: target.getAttribute('href') || null
                    };
                }
                return null;
            })()
            """
        } else {
            return "null"
        }
    }

    /// JSON.stringify-equivalent for a single string, for inlining into
    /// a JS expression. We don't use JSONSerialization because it wraps
    /// the string in an array. Manual escaping handles all the cases
    /// the model's selectors will contain.
    private func jsString(_ s: String) -> String {
        return Self.jsStringStatic(s)
    }
    private static func jsStringStatic(_ s: String) -> String {
        var escaped = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":  escaped += "\\\\"
            case "\"":  escaped += "\\\""
            case "\n":  escaped += "\\n"
            case "\r":  escaped += "\\r"
            case "\t":  escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    // MARK: - KVO

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { return }
        Task { @MainActor in
            switch keyPath {
            case "URL":     self.currentURL = self.webView.url
            case "title":   self.currentTitle = self.webView.title ?? ""
            case "loading": self.isLoading = self.webView.isLoading
            default: break
            }
        }
    }
}

// MARK: - Navigation delegate

extension WebViewManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingNavigation?.resume()
        pendingNavigation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingNavigation?.resume(throwing: error)
        pendingNavigation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingNavigation?.resume(throwing: error)
        pendingNavigation = nil
    }
}

// MARK: - UI delegate (popups / new windows)

extension WebViewManager: WKUIDelegate {
    /// Route target=_blank links into the same view rather than opening
    /// a popup. Klo's flow assumes a single navigated page; if a site
    /// tries to open a new window, we hijack it into the current view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - Errors

enum WebError: Error, LocalizedError {
    case notMounted
    case eventConstructionFailed
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notMounted:             return "WKWebView is not mounted in a window."
        case .eventConstructionFailed: return "Failed to construct NSEvent."
        case .timeout:                return "Operation timed out."
        case .cancelled:              return "Operation was cancelled."
        }
    }
}
