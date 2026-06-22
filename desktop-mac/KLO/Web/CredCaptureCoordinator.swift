import Foundation
import WebKit

/// WKScriptMessageHandler that bridges the in-page credstore-capture.js
/// (injected as a WKUserScript) to klo's native save-credential flow.
///
/// Flow:
///   1. User types creds + clicks submit inside the embedded WKWebView.
///   2. credstore-capture.js fires on `submit` (capture phase), reads
///      the form's username + password input values, posts a message
///      to `webkit.messageHandlers.kloCredCapture`.
///   3. This handler receives the message, stores the password in an
///      in-memory map keyed by a fresh UUID, posts the kloOfferSave
///      Credential notification with (host, username, pendingId).
///   4. KLOState picks up the notification → flips into
///      .offerSaveCredential mode → notch shows the "Save?" island.
///   5. User taps Save → KLOOverlayView posts kloCredentialSaveAccepted
///      with the pendingId → this coordinator resolves the pendingId
///      into the stored password and writes to KloKeychain.
///   6. User taps Not Now (or 30s elapses) → kloCredentialSaveDeclined
///      → coordinator drops the pending entry without writing.
///
/// The 30-second hold limit is hygiene: keep raw passwords in memory
/// only as long as needed for the user to make a decision. The Swift
/// String holding the value is freed normally on `pendingHolds
/// .removeValue` — there's no zero-overwriting helper for `String`,
/// but Swift's allocator returns memory to the system promptly. Apple's
/// official advice for password handling matches this — `String` is
/// fine for short-lived holds.
@MainActor
final class CredCaptureCoordinator: NSObject, WKScriptMessageHandler {

    static let shared = CredCaptureCoordinator()

    /// Pending password holds, keyed by pendingId. Each is cleared
    /// when the user accepts (and we write to keychain), declines, or
    /// the 30-second TTL expires.
    private var pendingHolds: [String: PendingHold] = [:]

    private struct PendingHold {
        let host: String
        let username: String
        let password: String
        let createdAt: Date
    }

    /// JS we inject as a WKUserScript at documentEnd in every frame.
    /// Listens for form submissions (in capture phase so we see them
    /// before the form actually submits), extracts the username and
    /// password values, posts to `kloCredCapture`. The handler decides
    /// what to do with them.
    ///
    /// Choices in the heuristics:
    ///   - We match the username field by trying `input[type=email]`
    ///     first (most explicit), then text/username/login/email-named
    ///     inputs (older forms), then any visible text input adjacent
    ///     to the password field (catches the rest).
    ///   - We only fire if a `<input type=password>` exists in the
    ///     submitting form. Forms without a password field aren't
    ///     credentials.
    ///   - Capture-phase listener (`useCapture: true`) so we run before
    ///     any framework's submit handler that might cancel propagation.
    ///   - Listen on `document` not `window` so we catch forms that get
    ///     dynamically inserted post-load (common on React sites).
    static let captureScript: String = """
    (function() {
      if (window.__kloCapInstalled) return;
      window.__kloCapInstalled = true;

      function findUsername(form, pwd) {
        // Heuristic ladder. Bail out as soon as something hits.
        const sel = [
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
        for (const s of sel) {
          const el = form.querySelector(s);
          if (el && el.value) return el.value;
        }
        // Fallback: scan all text-ish inputs in the same form, pick
        // the one immediately before the password field.
        const inputs = Array.from(form.querySelectorAll('input'));
        const pwdIdx = inputs.indexOf(pwd);
        for (let i = pwdIdx - 1; i >= 0; i--) {
          const t = (inputs[i].type || '').toLowerCase();
          if (t === 'text' || t === 'email' || t === '' || t === 'tel') {
            return inputs[i].value || '';
          }
        }
        return '';
      }

      document.addEventListener('submit', function(ev) {
        try {
          const form = ev.target;
          if (!form || form.tagName !== 'FORM') return;
          const pwd = form.querySelector('input[type=password]');
          if (!pwd || !pwd.value) return;
          const user = findUsername(form, pwd);
          window.webkit.messageHandlers.kloCredCapture.postMessage({
            host: location.host,
            username: user,
            password: pwd.value,
            url: location.href,
          });
        } catch (e) { /* swallow — bad submission shouldn't break the page */ }
      }, true /* capture */);
    })();
    """

    private override init() {
        super.init()
        // Wire the accept/decline notifications. KLOOverlayView posts
        // these when the user taps a button on the save-cred island.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccept(_:)),
            name: .kloCredentialSaveAccepted,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDecline),
            name: .kloCredentialSaveDeclined,
            object: nil,
        )
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Marshal to main actor — the JS message arrives on
        // WKWebKit's internal queue.
        guard let dict = message.body as? [String: Any] else { return }
        let host = (dict["host"] as? String) ?? ""
        let username = (dict["username"] as? String) ?? ""
        let password = (dict["password"] as? String) ?? ""
        Task { @MainActor in
            self.handleCaptured(host: host, username: username, password: password)
        }
    }

    private func handleCaptured(host: String, username: String, password: String) {
        let cleanHost = KloKeychain.normalizeHost(host)
        guard !cleanHost.isEmpty, !password.isEmpty else { return }

        // De-dupe — if there's already an item in keychain that matches
        // host+username AND has the same password, no point re-prompting.
        // We can't read the password without Touch ID though, so we
        // proceed anyway and let the user decide. The keychain write
        // is idempotent (save() deletes-then-adds), so re-confirming
        // an unchanged password is harmless.

        // Drop stale holds while we're here — pure hygiene.
        purgeExpiredHolds()

        let pendingId = UUID().uuidString
        pendingHolds[pendingId] = PendingHold(
            host: cleanHost,
            username: username,
            password: password,
            createdAt: Date()
        )

        // Schedule TTL expiry — 30 seconds is enough for the user to
        // glance at the notch and decide, short enough that an
        // unattended Mac doesn't keep the password in RAM forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await MainActor.run {
                if let hold = self?.pendingHolds.removeValue(forKey: pendingId) {
                    NSLog("KloCredCapture: TTL expired for \(hold.host) — dropping in-memory hold")
                }
            }
        }

        NotificationCenter.default.post(
            name: .kloOfferSaveCredential,
            object: nil,
            userInfo: [
                "host": cleanHost,
                "username": username,
                "pendingId": pendingId,
            ],
        )
    }

    @objc private func handleAccept(_ note: Notification) {
        guard let info = note.userInfo,
              let pendingId = info["pendingId"] as? String else { return }
        Task { @MainActor in
            guard let hold = pendingHolds.removeValue(forKey: pendingId) else {
                NSLog("KloCredCapture: accept for unknown pendingId \(pendingId) — already expired?")
                return
            }
            let ok = KloKeychain.save(
                host: hold.host,
                username: hold.username,
                password: hold.password
            )
            if ok {
                NSLog("KloCredCapture: saved \(hold.host) / \(hold.username) to keychain")
            } else {
                NSLog("KloCredCapture: KloKeychain.save failed for \(hold.host)")
            }
        }
    }

    @objc private func handleDecline() {
        Task { @MainActor in
            // Drop all pending holds — there's no per-island id passed
            // with the decline notification, and there's typically only
            // one hold pending at a time anyway. Conservative.
            if !pendingHolds.isEmpty {
                NSLog("KloCredCapture: declined — dropping \(pendingHolds.count) pending hold(s)")
                pendingHolds.removeAll()
            }
        }
    }

    private func purgeExpiredHolds() {
        let now = Date()
        let stale = pendingHolds.filter { now.timeIntervalSince($0.value.createdAt) > 30 }
        for (k, _) in stale {
            pendingHolds.removeValue(forKey: k)
        }
    }
}
