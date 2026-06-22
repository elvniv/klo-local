import AppKit
import Foundation
import Combine

/// Observable account state for hosted klo.
///
/// Owns:
///   • Supabase session (access_token + refresh_token in Keychain)
///   • klo-cloud subscription status (cached, refreshed periodically)
///
/// Paid features gate on `isReady` — true for paid subscribers AND for
/// trial users with remaining free runs. Subscription-only surfaces (the
/// voice path's Realtime API) gate separately via `isPaidSubscriber`.
/// The Mac app surfaces sign-in via the Account tab; sign-in itself
/// happens in the user's default browser through Google OAuth (handled
/// server-side by Supabase). When the OAuth round-trip completes,
/// Supabase redirects to `klo://auth#access_token=...` which the OS
/// hands to AppDelegate, which forwards to `handleDeepLink`. Magic
/// links were the previous path; replaced because Google OAuth is
/// faster and the bounce-through-email loop is dead weight when 95%
/// of users have a Google account.
@MainActor
final class AccountManager: ObservableObject {

    enum Status: Equatable {
        case unknown                                    // not yet checked
        case signedOut                                  // no session
        case awaitingOAuth                              // user clicked "Sign in with Google", waiting for callback
        case signedInUnsubscribed(email: String)        // session valid, no active sub
        case signedInActive(email: String, plan: String)
        case signedInPastDue(email: String)
        case signedInExpired(email: String)             // sub cancelled/lapsed

        var displayLabel: String {
            switch self {
            case .unknown:                              return "Checking…"
            case .signedOut:                            return "Not signed in"
            case .awaitingOAuth:                        return "Finishing sign-in in your browser…"
            case .signedInUnsubscribed(let e):          return "Signed in as \(e) — no subscription"
            case .signedInActive(let e, let plan):      return "\(plan) — \(e)"
            case .signedInPastDue(let e):               return "Payment past due — \(e)"
            case .signedInExpired(let e):               return "Subscription ended — \(e)"
            }
        }
    }

    @Published private(set) var status: Status = .unknown

    /// Last user-facing reason a sign-in attempt failed. Cleared at
    /// the start of the next attempt and on a successful signed-in
    /// transition. Sign-in views render this as a calm inline notice
    /// so silent failures (e.g. cloud unreachable, transient 5xx)
    /// don't leave the user clicking the button into the void.
    @Published private(set) var lastSignInError: String? = nil

    /// Composio toolkits the user has connected. Populated from the
    /// `integrations.composio.connected_toolkits` field returned by
    /// /auth/me, so this stays in sync with klo-cloud on every refresh.
    /// IntegrationsView reads this to render the Settings → Connected
    /// Apps section. Empty = user has connected nothing yet.
    @Published private(set) var connectedToolkits: [String] = []

    /// In-memory snapshot of the Composio catalog so slash-app
    /// autocomplete in TextInputView is instant (no network round-trip
    /// per keystroke). Populated lazily by `ensureComposioCatalog()`
    /// and shared with ConnectionsView. Empty until first fetch.
    @Published private(set) var composioCatalogSnapshot: [ComposioApp] = []

    /// True while `ensureComposioCatalog` has a fetch in flight. Used
    /// by callers to render a small spinner if they care.
    @Published private(set) var composioCatalogLoading: Bool = false

    /// Last error from the catalog fetch (nil = success or never tried).
    /// Surfaced in ConnectionsView's existing error path; TextInputView's
    /// autocomplete just hides itself when this is set.
    @Published private(set) var composioCatalogError: ComposioError? = nil

    /// One-shot "currently connecting" indicator per toolkit, used by
    /// the Settings UI to show a spinner between clicking "Connect" and
    /// the OAuth deep-link returning. Stays set even if the user
    /// abandons the browser tab — IntegrationsView shows a Cancel link
    /// that calls `cancelToolkitConnect(slug)` to clear it.
    @Published private(set) var connectingToolkit: String? = nil

    /// The toolkit slug of the most recent startComposioConnect attempt.
    /// Stays set after `connectingToolkit` clears so IntegrationsView
    /// can attribute a `lastSignInError` to the right tile (so the
    /// inline error string lands under the toolkit the user actually
    /// clicked, not a random other one).
    @Published private(set) var lastConnectAttemptToolkit: String? = nil

    // MARK: - Free-trial state
    //
    // Populated from /auth/me on every refresh. `accessMode` is the
    // single field UI reads to branch: "subscription" (full access),
    // "trial" (budget remaining), "exhausted" (signed in but trial used
    // up, must subscribe), or "unknown" (not yet fetched). Counters
    // are surfaced for the Settings usage strip ("3 of 10 free runs
    // used") and the upgrade modal copy ("10/10 used").

    @Published private(set) var trialRunsUsed: Int = 0
    @Published private(set) var trialRunsLimit: Int = 10
    @Published private(set) var accessMode: String = "unknown"

    // ─── Time-trial state (Path B pricing: 5/day × 7 days) ────────────────
    //
    // Server returns these on every /usage/task_start AND from the new
    // /usage/today endpoint. The TrialStatusIndicator chip in the notch
    // reads them live; the Settings usage strip mirrors them.
    //
    // `currentTier` mirrors derive_tier() on the server: "free", "starter",
    // "pro", or "unknown" before the first /usage/today call lands.
    // `chatsLimit == 0` means unlimited (server returns null for paid tiers;
    // we coerce to 0 here so the chip's "X of N" math degrades cleanly).
    // `daysLeft == 0` means trial ended (chip hides).
    @Published private(set) var currentTier: String = "unknown"
    @Published private(set) var chatsToday: Int = 0
    @Published private(set) var chatsLimit: Int = 5
    @Published private(set) var daysLeft: Int = 0
    @Published private(set) var trialExpiresAt: Date? = nil

    /// True when the chip should render. Free tier with an active
    /// trial window AND any days remaining. Subscribed users and
    /// expired-trial users return false (chip hidden).
    var shouldShowTrialIndicator: Bool {
        currentTier == "free" && trialExpiresAt != nil && daysLeft > 0
    }

    /// True when the trial budget has remaining runs. Convenience for
    /// AccountView's usage strip — show iff trial AND has remaining.
    var trialRunsRemaining: Int {
        max(0, trialRunsLimit - trialRunsUsed)
    }

    /// Push fresh trial counters from a /runs response. Lets the usage
    /// strip in Settings stay in sync immediately after a run starts,
    /// without waiting for the next /auth/me poll. The sidecar's
    /// create_run echoes these in its response after claiming a slot.
    @MainActor
    func updateTrialCounters(used: Int, limit: Int, mode: String) {
        self.trialRunsUsed = used
        self.trialRunsLimit = limit
        self.accessMode = mode
    }

    /// Push the full time-trial snapshot from a /usage/today or
    /// /usage/task_start response. Single entry point so the chip and
    /// Settings strip stay in sync; no view manipulates these fields
    /// directly.
    @MainActor
    func updateTrialState(
        tier: String,
        chatsToday: Int,
        chatsLimit: Int,
        daysLeft: Int,
        trialExpiresAt: Date?
    ) {
        self.currentTier = tier
        self.chatsToday = chatsToday
        self.chatsLimit = chatsLimit
        self.daysLeft = daysLeft
        self.trialExpiresAt = trialExpiresAt
    }

    /// True when the user can run the agent right now — either active
    /// subscription, or signed-in with remaining free-trial budget. Used
    /// by AgentClient, onboarding routing, and the saved-draft auto-
    /// resubmit observer.
    var isReady: Bool {
        if case .signedInActive = status { return true }
        if isSignedIn && accessMode == "trial" { return true }
        return false
    }

    /// True only for paid subscribers. Voice (OpenAI Realtime API) gates
    /// on this because per-minute cost outpaces the trial budget.
    var isPaidSubscriber: Bool {
        if case .signedInActive = status { return true }
        return false
    }

    /// True for any signed-in status (active, unsubscribed, pastDue,
    /// expired). Onboarding step routing uses this — once the user
    /// signs in we advance past the SignIn step even if their
    /// subscription state isn't `.active` yet; the paywall handles
    /// the rest from inside the app.
    var isSignedIn: Bool {
        switch status {
        case .signedInActive, .signedInUnsubscribed,
             .signedInPastDue, .signedInExpired:
            return true
        case .unknown, .signedOut, .awaitingOAuth:
            return false
        }
    }

    /// Hosted cloud URL fallback for public KLO Local builds. Keep this
    /// loopback-only so cloned builds never call KLO-hosted infra unless
    /// the user explicitly sets KLO_CLOUD_URL.
    static let productionCloudURL = "http://127.0.0.1:8789"

    /// Local-dev cloud URL — what `uv run klo-cloud` binds to by default.
    static let localCloudURL = "http://127.0.0.1:8789"

    /// Legacy UserDefaults key the removed Developer-card override used
    /// to write to. Kept as a constant so `migrateLegacyCloudOverride()`
    /// can find and wipe stale values on launch.
    private static let legacyCloudOverrideKey = "klo.debug.cloudURLOverride"

    /// Cloud base URL. Precedence (first non-empty wins):
    ///   1. `KLO_CLOUD_URL` env var (dev workflow — set it in your
    ///      shell or scheme to point at a local klo-cloud; hardcoded
    ///      in source if you want it to persist across builds)
    ///   2. Hosted URL injected by an official/private build
    ///
    /// A previous UserDefaults override (`klo.debug.cloudURLOverride`)
    /// was driven by the now-removed Developer card in Settings. It's
    /// no longer consulted; any stale value gets wiped by
    /// `migrateLegacyCloudOverride()` at init time.
    static var cloudBase: URL {
        let raw = ProcessInfo.processInfo.environment["KLO_CLOUD_URL"]
            ?? productionCloudURL
        return URL(string: raw)!
    }

    /// Wipe the now-defunct `klo.debug.cloudURLOverride` UserDefaults
    /// key on launch. Defends users (and ex-dev machines) whose Defaults
    /// store still carries the local-cloud URL the removed Developer
    /// card used to write — without this they'd hit "Could not connect
    /// to the server" on every auth call because `cloudBase` was
    /// pointed at `localhost:8789` with nothing listening.
    ///
    /// Idempotent. removeObject is a no-op when the key is absent, so
    /// running this on every launch is cheap and safe.
    private static func migrateLegacyCloudOverride() {
        let defaults = UserDefaults.standard
        if let stale = defaults.string(forKey: legacyCloudOverrideKey),
           !stale.isEmpty {
            NSLog("KLO Account: removing stale cloud override '%@' from UserDefaults", stale)
            defaults.removeObject(forKey: legacyCloudOverrideKey)
        }
    }

    /// User-facing error message for a network call that failed against
    /// klo-cloud. Branches on URLError.Code so the user sees something
    /// more actionable than "couldn't reach klo" for every failure
    /// shape. Previously every URLError became the same generic
    /// message, leaving users guessing whether it was their network,
    /// klo-cloud being down, or DNS.
    ///
    /// Use this at every catch site that surfaces a network error to
    /// the UI (sign-in, /auth/me poll, voice ephemeral-key mint, etc.).
    static func cloudErrorMessage(for error: Error) -> String {
        guard let urlErr = error as? URLError else {
            return "Couldn't reach klo right now. Try again."
        }
        switch urlErr.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "You're offline. Reconnect and try again."
        case .timedOut:
            return "klo's cloud is slow right now. Try again in 30 seconds."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "klo's cloud is unreachable. Check status.getklo.com or try again in a minute."
        case .networkConnectionLost:
            return "Connection dropped mid-request. Try again."
        default:
            return "Couldn't reach klo right now. Try again."
        }
    }

    private var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Active during the ~5 min after the user opens Stripe Checkout
    /// or the Customer Portal. Polls /auth/me every 2.5s so we detect
    /// the active subscription within seconds of Stripe firing the
    /// webhook → Supabase update. Auto-cancels itself after 6 min.
    private var postCheckoutCancellable: AnyCancellable?
    private var postCheckoutStarted: Date?

    /// Proactive refresh state. The timer fires ~5 min before the
    /// access token's `exp` claim so the token is never stale at
    /// request time. `pendingRefresh` is the single-flight cache —
    /// concurrent callers await the same in-flight refresh instead of
    /// each posting `/auth/refresh` and burning the rotated refresh
    /// token race.
    private var refreshTimer: Timer?
    private var pendingRefresh: Task<String?, Never>?
    private var wakeObserver: Any?

    /// Timestamp of the last refresh failure. Used as a cooldown so
    /// the proactive timer + reactive 401 retries + WS reconnects
    /// don't all hammer `/auth/refresh` after the refresh token has
    /// already been declared dead (typical cause: password reset
    /// elsewhere invalidates all existing sessions). Cleared on a
    /// successful refresh or a fresh sign-in.
    private var lastRefreshFailureAt: Date?
    private static let refreshCooldownSeconds: TimeInterval = 30

    /// Refresh this many seconds before the access token's `exp` claim.
    /// Far enough out that even with clock skew + a slow `/auth/refresh`
    /// round-trip we never let a request go out with a dead token.
    private static let refreshLeadSeconds: TimeInterval = 300  // 5 min

    /// `withFreshAccessToken()` returns the current token if its `exp`
    /// is more than this many seconds away; otherwise it refreshes.
    /// Smaller than `refreshLeadSeconds` so the proactive timer is the
    /// usual path; this is just the safety net for callers that fire
    /// in the window between the timer expiring and rescheduling.
    private static let freshnessThresholdSeconds: TimeInterval = 60

    init() {
        // Run the migration BEFORE recheck() — recheck reads cloudBase
        // (which used to consult the legacy override) so we want the
        // stale key gone before any network call is dispatched.
        Self.migrateLegacyCloudOverride()
        recheck()
        scheduleProactiveRefresh()
        setupWakeObserver()
    }

    deinit {
        refreshTimer?.invalidate()
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Session token (stored in Keychain)

    private var accessToken: String? {
        KeychainStore.get(account: KeychainStore.Account.supabaseAccessToken)
    }

    private func setAccessToken(_ token: String) {
        try? KeychainStore.set(token, account: KeychainStore.Account.supabaseAccessToken)
        Self.writeSidecarSessionFile(accessToken: token)
        // Re-arm the proactive refresh timer for the new exp claim.
        scheduleProactiveRefresh()
    }

    private func clearTokens() {
        KeychainStore.delete(account: KeychainStore.Account.supabaseAccessToken)
        KeychainStore.delete(account: KeychainStore.Account.supabaseRefreshToken)
        Self.deleteSidecarSessionFile()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Parse the `exp` claim out of a Supabase JWT. Returns nil if the
    /// token isn't a well-formed three-segment JWT or the payload
    /// can't be decoded — callers treat that as "expiry unknown" and
    /// refresh defensively.
    private static func tokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        // base64url → base64 + padding
        payload = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Sidecar session-file bridge
    //
    // The Python sidecar runs as a separate process and can't read our
    // Keychain (different signed binary path → different ACL row). We
    // write the session token to ~/.klo/session.json so the sidecar's
    // cloud_auth.get_session_token() can pick it up. Filesystem-permission
    // scoped to the user account; both processes belong to the same user.

    private static var sidecarSessionPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".klo/session.json")
    }

    private static func writeSidecarSessionFile(accessToken: String) {
        let url = sidecarSessionPath
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Lakshita fix (render logs 2026-06-19): when an orphan
            // sidecar survives a Mac app crash / force-quit, its WS
            // bridge to klo-cloud gets 403 the moment the access token
            // expires (~1h Supabase TTL) and there's nobody left to
            // refresh it — the Mac process is gone. Writing the refresh
            // token here lets the sidecar self-refresh via
            // cloud_auth.refresh_session_token() instead of hammering
            // the cloud with the same dead token at 2s intervals
            // indefinitely. A file lock at ~/.klo/refresh.lock prevents
            // Mac+sidecar from refreshing concurrently and burning each
            // other's rotated refresh_token.
            var payload: [String: String] = ["access_token": accessToken]
            if let rt = KeychainStore.get(account: KeychainStore.Account.supabaseRefreshToken),
               !rt.isEmpty {
                payload["refresh_token"] = rt
            }
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted]
            )
            try data.write(to: url, options: [.atomic])
            // Tighten permissions — only the user can read.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            NSLog("KLO Account: wrote \(url.path)")
        } catch {
            NSLog("KLO Account: failed to write sidecar session file: \(error)")
        }
    }

    private static func deleteSidecarSessionFile() {
        let url = sidecarSessionPath
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Google OAuth sign-in flow

    /// Step 1: user clicked "Sign in with Google".
    /// We POST to klo-cloud's /auth/oauth/start, which returns a
    /// Supabase OAuth kickoff URL. We open that URL in the user's
    /// default browser (NSWorkspace) and flip status to .awaitingOAuth.
    /// The user signs in with Google in the browser; Supabase redirects
    /// back to klo://auth#access_token=... which the OS hands to
    /// AppDelegate → handleDeepLink (Step 2 below).
    /// Timeout after which we forcibly UNHIDE klo if the OAuth deep
    /// link never came back. Covers the "user closed the browser tab,
    /// or Supabase silently failed, or the bridge page didn't redirect"
    /// failure modes — without this the user is stuck staring at a
    /// hidden klo wondering what happened.
    private static let oauthHideSafetyTimeoutSeconds: TimeInterval = 90
    private var oauthSafetyTimer: Timer?

    func startSignInWithGoogle() async {
        await MainActor.run {
            lastSignInError = nil
            status = .awaitingOAuth
        }

        let url = Self.cloudBase.appendingPathComponent("auth/oauth/start")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Route Supabase → klo via an HTTPS bridge page, not directly
        // to the klo:// custom scheme. Browsers (Safari, Chrome
        // especially) block or silently drop SERVER-SIDE redirects
        // from an HTTPS origin to a non-HTTP scheme; the bridge page
        // lands on HTTPS first and JS-redirects from same-origin
        // script — that path browsers allow. The bridge URL must
        // also be in Supabase's redirect-URL allowlist.
        //
        // Bridge lives on the LANDING (getklo.com), not the Render
        // backend, so the URL bar reads getklo.com all the way through
        // sign-in instead of flashing the hosted KLO backend.
        // /auth/desktop-callback on the landing mirrors the klo-cloud
        // /auth/callback bridge but in the landing's design language.
        //
        // dst=klo-desktop makes the bridge hop to klo-desktop://auth,
        // a scheme only this app claims — iOS dev builds squatting on
        // the shared klo:// scheme can't intercept the callback.
        let bridgeURL = "https://getklo.com/auth/desktop-callback?dst=klo-desktop"
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "provider": "google",
            "redirect_to": bridgeURL,
        ])
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("KLO Account: /auth/oauth/start HTTP \(code)")
                await MainActor.run {
                    lastSignInError = "Couldn't reach klo right now. Try again."
                    status = .signedOut
                }
                return
            }
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthURLString = payload["url"] as? String,
                  let oauthURL = URL(string: oauthURLString) else {
                NSLog("KLO Account: /auth/oauth/start returned no url")
                await MainActor.run {
                    lastSignInError = "Sign in didn't go through. Try again."
                    status = .signedOut
                }
                return
            }
            await MainActor.run {
                // Browser handoff: opens the URL, hides klo so its
                // panel doesn't block the OAuth page, and arms the
                // shared 90s safety timer that unhides klo if no
                // klo:// callback arrives. Same helper Composio
                // OAuth uses — keep them on one path so neither
                // surface regresses to "klo blocks the browser".
                self.handoffToBrowserForOAuth(
                    url: oauthURL,
                    timeoutContext: "google-signin",
                ) { [weak self] in
                    // If we're still in .awaitingOAuth after the
                    // timeout, the bridge page never redirected →
                    // flip back to .signedOut with a retry hint so
                    // the island isn't stuck spinning.
                    if case .awaitingOAuth = self?.status {
                        self?.status = .signedOut
                        self?.lastSignInError = "Sign-in took too long. Try again."
                    }
                }
            }
        } catch {
            NSLog("KLO Account: /auth/oauth/start failed: \(error)")
            await MainActor.run {
                lastSignInError = Self.cloudErrorMessage(for: error)
                status = .signedOut
            }
        }
    }

    /// Step 2: user finished Google sign-in; Supabase redirected to
    /// klo://auth#access_token=...&refresh_token=... — AppDelegate
    /// forwards here. Store tokens and verify. Same handler regardless
    /// of which auth flow produced the callback (works for the legacy
    /// magic-link tokens too if any are still in flight).
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "klo" || url.scheme == "klo-desktop" else { return }
        // Always cancel the OAuth-hide safety timer + bring klo back
        // when ANY klo:// URL fires (auth callback, billing callback,
        // composio bounce, etc). The hide was klo's "step aside for
        // the browser" move during OAuth; the deep link is the user's
        // browser handing them back to us, so we materialize again.
        oauthSafetyTimer?.invalidate()
        oauthSafetyTimer = nil
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Stripe success/cancel/portal-return → klo://billing[?ok=1|cancel=1|back=1].
        // No tokens to parse here — just kick a refresh and arm the
        // post-checkout poller so we catch the webhook-driven status
        // flip within a few seconds even if the user immediately
        // re-prompts. Idempotent if the poller was already armed by
        // the paywall path.
        if url.host == "billing" {
            NSLog("KLO Account: klo://billing — refreshing + arming poller")
            beginPostCheckoutPolling()
            Task { await refreshFromCloud() }
            return
        }
        // Composio OAuth return — klo://composio?toolkit=gmail&connection_id=conn_abc
        // The HTML bounce page on klo-cloud's /integrations/composio/oauth_bounce
        // route triggers this URL after the user authorizes in their browser.
        // We finalize on klo-cloud and refresh /auth/me so the connected_toolkits
        // list re-syncs.
        if url.host == "composio" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            let toolkit = items.first(where: { $0.name == "toolkit" })?.value ?? ""
            let connectionId = items.first(where: { $0.name == "connection_id" })?.value ?? ""
            NSLog("KLO Account: klo://composio — toolkit=\(toolkit) connection_id=\(connectionId.prefix(8))…")
            guard !toolkit.isEmpty, !connectionId.isEmpty else {
                NSLog("KLO Account: composio deep link missing required params")
                return
            }
            Task { await finalizeComposioConnect(toolkit: toolkit, connectionId: connectionId) }
            return
        }
        guard url.host == "auth" else { return }
        // Supabase puts tokens in the URL fragment (#access_token=...).
        // Some configs put them in the query string. Try both.
        let raw = url.fragment ?? url.query ?? ""
        var params: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2,
                  let v = kv[1].removingPercentEncoding else { continue }
            params[kv[0]] = v
        }
        guard let access = params["access_token"], !access.isEmpty else {
            NSLog("KLO Account: deep link missing access_token (got keys: \(Array(params.keys)))")
            return
        }
        setAccessToken(access)
        if let refresh = params["refresh_token"], !refresh.isEmpty {
            try? KeychainStore.set(refresh, account: KeychainStore.Account.supabaseRefreshToken)
        }
        NSLog("KLO Account: stored Supabase tokens from deep link")
        Task { await refreshFromCloud() }
    }

    // MARK: - Status refresh

    /// Read tokens from Keychain, ask klo-cloud who we are.
    func recheck() {
        Task { await refreshFromCloud() }
    }

    /// Public wrapper for the internal /auth/me refresh. Used by
    /// the AgentClient gate (when paywall is hit, refresh once in
    /// case cached state is stale) and by the post-checkout poller.
    func refreshNow() async {
        await refreshFromCloud()
    }

    /// Start the post-Stripe-Checkout polling loop. Idempotent —
    /// calling twice resets the timer but doesn't duplicate
    /// subscriptions. Auto-stops after 6 minutes; the ambient state
    /// will catch any later changes via the standard recheck cadence
    /// (currently triggered on app launch).
    func beginPostCheckoutPolling() {
        postCheckoutCancellable?.cancel()
        postCheckoutStarted = Date()
        postCheckoutCancellable = Timer.publish(every: 2.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.refreshFromCloud() }
                if let started = self.postCheckoutStarted,
                   Date().timeIntervalSince(started) > 360 {
                    self.postCheckoutCancellable?.cancel()
                    self.postCheckoutCancellable = nil
                    self.postCheckoutStarted = nil
                }
            }
    }

    /// Public stop — called when the paywall observes `.signedInActive`
    /// (no need to keep polling) or the user dismisses the paywall.
    func endPostCheckoutPolling() {
        postCheckoutCancellable?.cancel()
        postCheckoutCancellable = nil
        postCheckoutStarted = nil
    }

    private func refreshFromCloud() async {
        // Funnel through `withFreshAccessToken` so the proactive +
        // single-flight refresh path is the SAME path used by every
        // other authed call. If we have no token at all → signedOut.
        guard let token = await withFreshAccessToken() else {
            await MainActor.run { status = .signedOut }
            return
        }
        await callAuthMe(token: token, didAttemptRefresh: false)
    }

    /// `/auth/me` with the supplied access token. On 401, try the
    /// refresh-token swap exactly ONCE and retry; only clear the
    /// session + flip to signedOut if the refresh itself fails. The
    /// access-token side effect of a successful refresh is that
    /// `~/.klo/session.json` gets rewritten with the fresh token, so
    /// the next sidecar request to `/api/llm/openai/*` succeeds.
    private func callAuthMe(token: String, didAttemptRefresh: Bool) async {
        let url = Self.cloudBase.appendingPathComponent("auth/me")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                if !didAttemptRefresh, let fresh = await refreshAccessToken() {
                    await callAuthMe(token: fresh, didAttemptRefresh: true)
                    return
                }
                await MainActor.run {
                    self.clearTokens()
                    self.status = .signedOut
                }
                return
            }
            guard (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("KLO Account: /auth/me HTTP \(http.statusCode)")
                return
            }
            let email = (body["email"] as? String) ?? "you"
            let subStatus = (body["subscription_status"] as? String) ?? "none"
            let plan = (body["plan"] as? String) ?? "Pro"
            // Trial counters + derived mode. Older cloud (pre-trial)
            // returns no fields here; defaults keep behaviour identical
            // to the subscription-only era.
            let trialUsed = (body["trial_runs_used"] as? Int) ?? 0
            let trialLimit = (body["trial_runs_limit"] as? Int) ?? 0
            let mode = (body["access_mode"] as? String) ?? "unknown"
            // Pull the integrations blob — currently just composio's
            // connected_toolkits list. /auth/me always includes it (may
            // be empty {}) so a missing key here means an older cloud.
            let integrations = (body["integrations"] as? [String: Any]) ?? [:]
            let composio = (integrations["composio"] as? [String: Any]) ?? [:]
            let toolkits = (composio["connected_toolkits"] as? [String]) ?? []
            await MainActor.run {
                self.connectedToolkits = toolkits.sorted()
                self.trialRunsUsed = trialUsed
                self.trialRunsLimit = trialLimit
                self.accessMode = mode
            }
            await MainActor.run {
                // Successful auth — clear any stale sign-in error from
                // a prior failed attempt so the views don't keep
                // showing it after we land in a signed-in state.
                self.lastSignInError = nil
                switch subStatus {
                case "active", "trialing":
                    self.status = .signedInActive(email: email, plan: plan)
                    // Landed in active — no need to keep hammering
                    // /auth/me. Stops the 2.5s timer before its
                    // 6-minute auto-cap.
                    self.endPostCheckoutPolling()
                case "past_due":
                    self.status = .signedInPastDue(email: email)
                case "canceled", "unpaid", "incomplete_expired":
                    self.status = .signedInExpired(email: email)
                default:
                    self.status = .signedInUnsubscribed(email: email)
                }
            }
            // Pull fresh time-trial state in the background. /auth/me
            // doesn't carry the new chats_today / days_left fields, so
            // /usage/today is the source of truth. Non-blocking.
            Task { await self.refreshUsageToday() }
        } catch {
            NSLog("KLO Account: /auth/me threw \(error)")
        }
    }

    // MARK: - Token refresh
    //
    // Supabase access tokens are short-lived (1 hour by default).
    // Persistent auth needs four pieces, all here:
    //   1. PROACTIVE TIMER — `scheduleProactiveRefresh` re-arms a
    //      Timer that fires `refreshLeadSeconds` before exp, so the
    //      token is never stale at request time.
    //   2. REFRESH-BEFORE-CALL — `withFreshAccessToken` is the single
    //      entry point for "give me a token I can send right now."
    //      Refreshes if exp is within `freshnessThresholdSeconds`.
    //   3. SIDECAR BRIDGE FILE — `setAccessToken` writes
    //      `~/.klo/session.json` so the Python sidecar's per-request
    //      `make_openai_client()` reads the fresh token.
    //   4. SINGLE-FLIGHT — `pendingRefresh` collapses concurrent
    //      refreshes into one Task so we never POST `/auth/refresh`
    //      twice in parallel and burn the rotated refresh token.
    //
    // Wake observer + on-401 fallback (in `callAuthMe`) are belt-and-
    // suspenders for clock skew, sleep, and network blips.

    /// Returns an access token whose `exp` is at least
    /// `freshnessThresholdSeconds` in the future. Refreshes if not.
    /// All authed callers should funnel through this rather than
    /// reading `accessToken` directly — that way the proactive +
    /// reactive paths share one code path.
    func withFreshAccessToken() async -> String? {
        guard let token = accessToken else { return nil }
        if let exp = Self.tokenExpiry(token),
           exp.timeIntervalSinceNow > Self.freshnessThresholdSeconds {
            return token
        }
        return await refreshAccessTokenSingleFlight()
    }

    /// Single-flight wrapper around `refreshAccessToken`. Two concurrent
    /// callers will both await the same in-flight `Task`, so Supabase
    /// only sees one `/auth/refresh` POST. Critical because Supabase
    /// rotates the refresh token on every call — a parallel double-fire
    /// would burn the first response's rotated refresh token before the
    /// second caller could persist it, killing the session.
    private func refreshAccessTokenSingleFlight() async -> String? {
        if let pending = pendingRefresh {
            return await pending.value
        }
        let task = Task<String?, Never> { [weak self] in
            let result = await self?.refreshAccessToken() ?? nil
            await MainActor.run { self?.pendingRefresh = nil }
            return result
        }
        pendingRefresh = task
        return await task.value
    }

    /// Schedule a proactive refresh for `refreshLeadSeconds` before
    /// the current access token's `exp`. Re-arms whenever we get a
    /// new token (`setAccessToken`) and on wake from sleep. Idempotent:
    /// invalidates any prior timer first.
    private func scheduleProactiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let token = accessToken,
              let exp = Self.tokenExpiry(token) else { return }
        let fireAt = exp.addingTimeInterval(-Self.refreshLeadSeconds)
        // 30-second floor instead of 1s. When the access token is
        // already expired (exp in the past), the proactive timer
        // would otherwise tick once per second forever — burning the
        // refresh token's last cycle, hitting Supabase rate limits,
        // and never making forward progress. 30s gives the cooldown
        // in refreshAccessToken room to detect a dead refresh token,
        // clear it, and stop the timer entirely via clearTokens().
        let interval = max(fireAt.timeIntervalSinceNow, 30)
        NSLog("KLO Account: scheduling proactive refresh in \(Int(interval))s (exp at \(exp))")
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                _ = await self?.refreshAccessTokenSingleFlight()
                // Re-arm for the NEW token's exp. The successful
                // refresh path went through setAccessToken, which
                // already calls scheduleProactiveRefresh — so this is
                // belt-and-suspenders for the failure path (where we
                // want to try again at a sensible interval rather than
                // give up forever).
                self?.scheduleProactiveRefresh()
            }
        }
    }

    /// macOS suspends Timers during system sleep. On wake, refresh
    /// immediately if the token expired in our absence and re-arm the
    /// proactive timer for the new exp.
    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSLog("KLO Account: wake notification — refreshing token if needed")
            Task { @MainActor in
                _ = await self?.withFreshAccessToken()
                self?.scheduleProactiveRefresh()
            }
        }
    }

    /// Try to refresh the access token via klo-cloud's /auth/refresh.
    /// Returns the fresh access_token on success; nil on failure
    /// (caller should clear the session in that case).
    private func refreshAccessToken() async -> String? {
        // Cooldown: if we failed to refresh within the last 30s, the
        // refresh token is almost certainly dead. Returning nil
        // without hitting the network stops the storm where the
        // proactive timer + WS reconnect + reactive 401 retries all
        // fire in parallel after a session revoke.
        if let last = lastRefreshFailureAt,
           Date().timeIntervalSince(last) < Self.refreshCooldownSeconds {
            NSLog("KLO Account: refreshAccessToken — within cooldown, returning nil")
            return nil
        }
        let rt = KeychainStore.get(account: KeychainStore.Account.supabaseRefreshToken)
        guard let refreshToken = rt, !refreshToken.isEmpty else {
            return nil
        }
        // NOTE: an earlier guard rejected refresh_tokens under 32 chars
        // as "corrupt" — that was WRONG. Empirically, Supabase OAuth
        // returns 12-character rotating refresh tokens (e.g.
        // "hzgnumggvmq2"), and /auth/refresh HTTP 200's on them. The
        // "uaipxi7efuyi" we previously saw rejected wasn't malformed
        // — it had already been rotated away by a parallel refresh
        // attempt (the storm bug fixed by cooldowns). Length is NOT
        // a signal of validity; only the server can say if the token
        // is alive. Don't gate refresh on shape.
        let url = Self.cloudBase.appendingPathComponent("auth/refresh")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken,
        ])
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = body["access_token"] as? String,
                  !access.isEmpty
            else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("KLO Account: /auth/refresh HTTP \(code)")
                await MainActor.run { self.lastRefreshFailureAt = Date() }
                // 400/401 from klo-cloud => refresh token is genuinely
                // dead (Supabase: "refresh_token_not_found"). Clear
                // the keychain entry NOW so subsequent reads return
                // nil and short-circuit, AND stop the proactive timer
                // so we don't re-fire every second on the stale exp.
                if code == 400 || code == 401 {
                    NSLog("KLO Account: refresh token is dead, clearing keychain + stopping timer")
                    await MainActor.run {
                        self.clearTokens()
                    }
                }
                return nil
            }
            // Supabase rotates refresh tokens — the new one is in the
            // response. Persist it FIRST so `setAccessToken` below
            // writes BOTH the new access_token AND the new refresh_token
            // into ~/.klo/session.json in one atomic write. Reversing
            // these (the old order) left a window where session.json had
            // the new access_token + the now-rotated stale refresh_token
            // — fine for the Mac app (it reads Keychain) but broken for
            // the sidecar's self-refresh path which reads session.json.
            if let newRefresh = body["refresh_token"] as? String, !newRefresh.isEmpty {
                try? KeychainStore.set(
                    newRefresh,
                    account: KeychainStore.Account.supabaseRefreshToken
                )
            }
            // Persist the new access token (Keychain + sidecar bridge file).
            await MainActor.run {
                self.setAccessToken(access)
                self.lastRefreshFailureAt = nil  // cleared on success
            }
            NSLog("KLO Account: refreshed access token via /auth/refresh")
            return access
        } catch {
            NSLog("KLO Account: /auth/refresh threw \(error)")
            await MainActor.run { self.lastRefreshFailureAt = Date() }
            return nil
        }
    }

    // MARK: - Authed POST with reactive 401 retry
    //
    // The proactive refresh timer covers the happy path, but fails when
    // the Mac was asleep through the entire access-token window. On wake
    // we *try* to refresh — but if the user opens Settings → Connected
    // Apps faster than the wake observer fires, the call goes out with
    // an expired token and lands on a stale 401.
    //
    // `authedPOST` is the single seam for "POST something to klo-cloud
    // with auth, recover from a stale token transparently." On 401, it
    // funnels through the same single-flight refresh path the proactive
    // timer uses (so we never burn a rotated refresh token via parallel
    // refresh calls) and retries the request exactly once. If the
    // refresh itself fails, the original 401 is returned and the caller
    // decides what to do (typically: sign out).

    /// POST to `path` (relative to klo-cloud) with a Bearer token and
    /// optional JSON body. Auto-retries once on 401 after a single-flight
    /// refresh. Returns `(data, http)` on any non-transport completion;
    /// throws on network errors so callers can branch on URLError.
    @MainActor
    func authedPOST(path: String, body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard var token = await withFreshAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        let url = Self.cloudBase.appendingPathComponent(path)
        for attempt in 1...2 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 401 && attempt == 1 {
                NSLog("KLO Account: \(path) 401 — refreshing + retrying")
                guard let fresh = await refreshAccessTokenSingleFlight() else {
                    // Refresh failed: surface the 401 so caller can sign
                    // the user out and bounce them to the sign-in island.
                    return (data, http)
                }
                token = fresh
                continue
            }
            return (data, http)
        }
        // Unreachable — the loop returns on attempt 2 either way.
        throw URLError(.badServerResponse)
    }

    /// Authenticated GET to klo-cloud. Same single-flight refresh-on-401
    /// pattern as authedPOST. Used for read-only endpoints like
    /// /usage/today and /auth/me.
    func authedGET(path: String) async throws -> (Data, HTTPURLResponse) {
        guard var token = await withFreshAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        let url = Self.cloudBase.appendingPathComponent(path)
        for attempt in 1...2 {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 401 && attempt == 1 {
                NSLog("KLO Account: GET \(path) 401 — refreshing + retrying")
                guard let fresh = await refreshAccessTokenSingleFlight() else {
                    return (data, http)
                }
                token = fresh
                continue
            }
            return (data, http)
        }
        throw URLError(.badServerResponse)
    }

    // MARK: - Time-trial usage refresh

    /// Pull the user's current tier + today's usage from klo-cloud's
    /// /usage/today endpoint. Updates the time-trial @Published fields
    /// that drive TrialStatusIndicator + AccountView's Settings strip.
    ///
    /// Cheap (one Supabase RPC + one profile read on the server side).
    /// Fails silently — the chip keeps showing last-known values if the
    /// network blips, since stale-by-a-few-seconds is fine for a
    /// non-critical surface.
    ///
    /// Trigger this from:
    ///   - refreshNow() right after /auth/me lands
    ///   - AgentClient on every /runs 200 (keeps the chip live as the
    ///     daily count ticks)
    ///   - app foreground (didBecomeActive)
    ///   - post-Stripe-checkout polling
    func refreshUsageToday() async {
        do {
            let (data, http) = try await authedGET(path: "usage/today")
            guard (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("KLO Account: /usage/today HTTP \(http.statusCode)")
                return
            }
            let tier = (body["tier"] as? String) ?? "unknown"
            let today = (body["today"] as? [String: Any]) ?? [:]
            let chatsUsed = (today["chats_used"] as? Int) ?? 0
            // chats_limit can be null on the server (unlimited for paid tiers);
            // coerce to 0 here — TrialStatusIndicator's shouldShow check
            // already gates on tier == "free", so the limit only renders
            // for trial users.
            let chatsLimitRaw = today["chats_limit"]
            let chatsLimitVal = (chatsLimitRaw as? Int) ?? 0
            // Compute days left from trial_expires_at (top-level field,
            // not nested under today). Null for paid tiers.
            let expiresAtStr = body["trial_expires_at"] as? String
            let expiresAt = expiresAtStr.flatMap { Self.parseISO8601($0) }
            let daysLeft = expiresAt.map { exp -> Int in
                let now = Date()
                if exp <= now { return 0 }
                // Round UP partial days so "ends in 3.5 days" reads as
                // "4 days left" — matches user mental model better than
                // truncation.
                let secs = exp.timeIntervalSince(now)
                return max(0, Int(ceil(secs / 86400.0)))
            } ?? 0
            await MainActor.run {
                self.updateTrialState(
                    tier: tier,
                    chatsToday: chatsUsed,
                    chatsLimit: chatsLimitVal,
                    daysLeft: daysLeft,
                    trialExpiresAt: expiresAt
                )
            }
        } catch {
            NSLog("KLO Account: /usage/today threw \(error)")
        }
    }

    /// Parse the ISO 8601 timestamps Supabase / FastAPI return. Handles
    /// both fractional-seconds and integer-seconds variants since the
    /// server can emit either depending on the column type.
    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - Stripe Checkout / Customer Portal

    /// Returns a fresh Stripe Checkout URL. Pass `tier` to pick which
    /// product to bill ("starter" = $15/mo, "pro" = $30/mo). Omit
    /// `tier` to fall back to the legacy STRIPE_PRICE_ID on the
    /// server, which old Mac builds still rely on.
    ///
    /// Mac app opens the returned URL in the user's browser; Stripe
    /// handles the payment surface; webhook updates the user's row in
    /// Supabase, which trips _apply_subscription and surfaces back
    /// through /auth/me as a status change.
    func startCheckout(tier: String? = nil) async -> URL? {
        do {
            var body: [String: Any]? = nil
            if let tier = tier, !tier.isEmpty {
                body = ["tier": tier]
            }
            let (data, http) = try await authedPOST(path: "billing/checkout", body: body)
            guard (200..<300).contains(http.statusCode),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlStr = parsed["url"] as? String,
                  let u = URL(string: urlStr) else {
                NSLog("KLO Account: checkout HTTP \(http.statusCode)")
                return nil
            }
            return u
        } catch {
            NSLog("KLO Account: checkout threw \(error)")
            return nil
        }
    }

    /// Returns a Stripe Customer Portal URL for managing billing.
    func openBillingPortal() async -> URL? {
        do {
            let (data, http) = try await authedPOST(path: "billing/portal")
            guard (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlStr = body["url"] as? String,
                  let u = URL(string: urlStr) else {
                NSLog("KLO Account: portal HTTP \(http.statusCode)")
                return nil
            }
            return u
        } catch {
            NSLog("KLO Account: portal threw \(error)")
            return nil
        }
    }

    func signOut() {
        clearTokens()
        status = .signedOut
        connectedToolkits = []
        connectingToolkit = nil
        // Reset time-trial state so the chip + Settings strip hide
        // immediately on sign-out. Stale numbers showing for the
        // signed-out state would be a visual bug.
        currentTier = "unknown"
        chatsToday = 0
        chatsLimit = 5
        daysLeft = 0
        trialExpiresAt = nil
        NSLog("KLO Account: signed out")
    }

    // MARK: - Composio integration
    //
    // All four methods follow the same pattern: POST to a
    // /integrations/composio/* endpoint with the user's Supabase JWT
    // as Bearer, decode the response, mutate published state.
    // klo-cloud holds the Composio API key + per-user OAuth tokens;
    // the Mac app never sees either.

    /// Fetch the catalog of available toolkits for the picker UI.
    /// Returns a sorted-by-name list of `{slug, name, icon, description}`.
    /// Server caches this for 24h so it's cheap to call on Settings open.
    /// Populate `composioCatalogSnapshot` from the network if empty.
    /// Idempotent — multiple callers can call this; only the first
    /// triggers an actual fetch. Used by TextInputView's slash-app
    /// autocomplete + ConnectionsView's catalog grid. Errors are
    /// stashed in `composioCatalogError` so callers can decide whether
    /// to surface them (ConnectionsView does; autocomplete just hides).
    @MainActor
    func ensureComposioCatalog() async {
        // Already loaded or in flight? Done.
        if !composioCatalogSnapshot.isEmpty || composioCatalogLoading { return }
        composioCatalogLoading = true
        composioCatalogError = nil
        defer { composioCatalogLoading = false }
        do {
            let apps = try await fetchComposioCatalog()
            self.composioCatalogSnapshot = apps
        } catch let err as ComposioError {
            self.composioCatalogError = err
        } catch {
            self.composioCatalogError = .network
        }
    }

    @MainActor
    func fetchComposioCatalog() async throws -> [ComposioApp] {
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await authedPOST(path: "integrations/composio/list_apps")
        } catch {
            throw ComposioError.network
        }
        if http.statusCode == 401 { throw ComposioError.authExpired }
        if http.statusCode == 402 { throw ComposioError.subscriptionRequired }
        if http.statusCode == 503 { throw ComposioError.notConfigured }
        guard (200..<300).contains(http.statusCode),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appsRaw = body["apps"] as? [[String: Any]] else {
            throw ComposioError.upstream(http.statusCode)
        }
        let apps = appsRaw.compactMap { dict -> ComposioApp? in
            guard let slug = dict["slug"] as? String, !slug.isEmpty else { return nil }
            return ComposioApp(
                slug: slug,
                name: (dict["name"] as? String) ?? slug.capitalized,
                description: (dict["description"] as? String) ?? "",
                iconURL: (dict["icon"] as? String).flatMap { URL(string: $0) },
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        // Mirror into the shared snapshot so the slash-app autocomplete
        // in TextInputView can render suggestions instantly without its
        // own fetch path.
        self.composioCatalogSnapshot = apps
        self.composioCatalogError = nil
        return apps
    }

    /// Kick off the OAuth flow for a toolkit. Posts to klo-cloud to get
    /// the Composio-hosted redirect URL, opens it in the user's default
    /// browser. AppDelegate routes the eventual klo://composio?...
    /// callback back to `finalizeComposioConnect`.
    ///
    /// Reused for "add another account": calling this on a toolkit the
    /// user has already connected creates a fresh connected_account on
    /// Composio's side (their API never dedupes by email — each OAuth
    /// run produces a new account row). The Settings multi-account UI
    /// drives that path via its "+ Add another account" button.
    @MainActor
    func startComposioConnect(toolkit: String) {
        guard !toolkit.isEmpty else { return }
        NSLog("KLO Account: startComposioConnect(\(toolkit))")
        connectingToolkit = toolkit
        lastConnectAttemptToolkit = toolkit
        // Clear any stale error from a prior attempt so the inline
        // error in IntegrationsView doesn't render until this attempt
        // actually fails.
        lastSignInError = nil
        Task {
            do {
                let (data, http) = try await authedPOST(
                    path: "integrations/composio/connect",
                    body: ["toolkit": toolkit],
                )
                if http.statusCode == 401 { throw ComposioError.authExpired }
                if http.statusCode == 402 { throw ComposioError.subscriptionRequired }
                if http.statusCode == 503 { throw ComposioError.notConfigured }
                guard (200..<300).contains(http.statusCode),
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let redirectStr = body["redirect_url"] as? String,
                      let redirect = URL(string: redirectStr) else {
                    throw ComposioError.upstream(http.statusCode)
                }
                await MainActor.run {
                    self.handoffToBrowserForOAuth(
                        url: redirect,
                        timeoutContext: "composio:\(toolkit)",
                    ) { [weak self] in
                        // Clear the in-flight spinner on the toolkit tile so
                        // the user can retry from a Connect button that isn't
                        // stuck mid-spinner. handleDeepLink clears this on
                        // the happy path; the safety timer is the fallback
                        // for "user closed the browser tab".
                        guard let self else { return }
                        if self.connectingToolkit == toolkit {
                            self.connectingToolkit = nil
                            self.lastSignInError = "Connecting took too long. Try again."
                        }
                    }
                }
            } catch {
                NSLog("KLO Account: composio connect failed for \(toolkit): \(error)")
                await MainActor.run {
                    self.connectingToolkit = nil
                    self.lastSignInError = Self.cloudErrorMessage(for: error)
                }
            }
        }
    }

    /// Called from `handleDeepLink` when the OAuth bounce returns. Asks
    /// klo-cloud to verify with Composio that the connection actually
    /// activated, then refreshes /auth/me so connected_toolkits picks
    /// up the new entry.
    @MainActor
    func finalizeComposioConnect(toolkit: String, connectionId: String) async {
        defer {
            // Always clear the in-flight indicator — whether finalize
            // succeeded (toolkit appears in the next /auth/me poll) or
            // failed (user retries from a Connect button that's no
            // longer mid-spinner).
            self.connectingToolkit = nil
        }
        do {
            let (_, http) = try await authedPOST(
                path: "integrations/composio/callback",
                body: ["toolkit": toolkit, "connection_id": connectionId],
            )
            guard (200..<300).contains(http.statusCode) else {
                NSLog("KLO Account: composio callback rejected — HTTP \(http.statusCode)")
                return
            }
            await refreshFromCloud()
        } catch {
            NSLog("KLO Account: composio callback threw — \(error)")
        }
    }

    /// Revoke a toolkit. Triggers a Composio-side disconnect then a
    /// /auth/me refresh so connected_toolkits drops the slug locally.
    @MainActor
    func disconnectComposio(toolkit: String) {
        guard !toolkit.isEmpty else { return }
        Task {
            do {
                _ = try await authedPOST(
                    path: "integrations/composio/disconnect",
                    body: ["toolkit": toolkit],
                )
                await refreshFromCloud()
            } catch {
                NSLog("KLO Account: composio disconnect threw — \(error)")
            }
        }
    }

    /// Open an OAuth URL in the user's default browser and step klo
    /// entirely aside so the OAuth page is interactive.
    ///
    /// Used by every browser-based auth handoff we initiate:
    ///   - Google sign-in (Supabase magic-link flow)
    ///   - Stripe Checkout / Customer Portal
    ///   - Composio toolkit OAuth (every toolkit, every "add another"
    ///     reconnect — all go through this so no Composio flow can
    ///     accidentally regress to "klo's panel blocks the browser")
    ///
    /// Three moves, in this order:
    ///   1. Open the URL with `OpenConfiguration.activates = true` so
    ///      the browser becomes frontmost. NSWorkspace.shared.open(_:)
    ///      without a configuration opens the URL but does NOT
    ///      reactivate the browser, so klo's notch panel stays on top.
    ///   2. After 0.18s, NSApp.hide(nil). klo is LSUIElement (no Dock
    ///      icon, no menu bar item) — the panel is the only window
    ///      and stays floating above other apps. The only way for the
    ///      browser tab to be fully clickable is for klo to hide its
    ///      window list entirely. The tiny delay lets the user see
    ///      the in-flight UI change before we vanish, so it doesn't
    ///      read as "I clicked the button and nothing happened."
    ///   3. Arm `oauthSafetyTimer`. handleDeepLink cancels it the
    ///      moment any klo:// URL fires (auth/billing/composio all
    ///      route through that one handler). If 90s passes with no
    ///      callback — the user closed the tab, denied consent without
    ///      a redirect, lost network — the timer unhides klo and
    ///      invokes onTimeout so the caller can roll back its in-flight
    ///      UI state (spinner, status string, etc.).
    @MainActor
    func handoffToBrowserForOAuth(
        url: URL,
        timeoutContext: String,
        onTimeout: @escaping () -> Void,
    ) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            NSApp.hide(nil)
        }
        oauthSafetyTimer?.invalidate()
        oauthSafetyTimer = Timer.scheduledTimer(
            withTimeInterval: Self.oauthHideSafetyTimeoutSeconds,
            repeats: false,
        ) { [weak self] _ in
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            self?.oauthSafetyTimer = nil
            NSLog("KLO Account: OAuth safety timer fired for \(timeoutContext)")
            onTimeout()
        }
    }

    /// Clear the "currently connecting" spinner if the user abandons
    /// the OAuth tab and clicks Cancel in Settings.
    @MainActor
    func cancelToolkitConnect(_ toolkit: String) {
        if connectingToolkit == toolkit {
            connectingToolkit = nil
        }
    }

    /// Revoke a single connected account for a toolkit. Used by the
    /// multi-account UI when the user wants to drop one of several
    /// Gmail accounts without nuking the rest. If this was the last
    /// remaining account for the toolkit, the backend strips the slug
    /// from connected_toolkits; we refresh /auth/me either way so the
    /// UI converges.
    @MainActor
    func disconnectComposioConnection(toolkit: String, connectionId: String) {
        guard !toolkit.isEmpty, !connectionId.isEmpty else { return }
        Task {
            do {
                _ = try await authedPOST(
                    path: "integrations/composio/disconnect",
                    body: ["toolkit": toolkit, "connection_id": connectionId],
                )
                await refreshFromCloud()
            } catch {
                NSLog("KLO Account: composio disconnect(connection) threw — \(error)")
            }
        }
    }

    /// Fetch the list of individual Composio accounts the user has
    /// connected for a toolkit. Powers the multi-account expansion in
    /// Settings → Integrations: shows "Connected as foo@gmail.com,
    /// bar@gmail.com" with per-account disconnect and an "+ Add another
    /// account" button.
    ///
    /// Returns an empty list when the user has zero connections for
    /// this toolkit. Throws ComposioError on cloud failures so the
    /// caller can render an inline error in the tile.
    @MainActor
    func fetchConnections(toolkit: String) async throws -> [ComposioConnection] {
        guard !toolkit.isEmpty else { return [] }
        let (data, http) = try await authedPOST(
            path: "integrations/composio/list_connections",
            body: ["toolkit": toolkit],
        )
        if http.statusCode == 401 { throw ComposioError.authExpired }
        if http.statusCode == 402 { throw ComposioError.subscriptionRequired }
        if http.statusCode == 503 { throw ComposioError.notConfigured }
        guard (200..<300).contains(http.statusCode),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = body["connections"] as? [[String: Any]] else {
            throw ComposioError.upstream(http.statusCode)
        }
        return raw.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return ComposioConnection(
                id: id,
                label: (item["label"] as? String) ?? "Account",
                status: item["status"] as? String,
                createdAt: item["created_at"] as? String,
            )
        }
    }

}

// MARK: - Composio support types

struct ComposioApp: Identifiable, Hashable {
    var id: String { slug }
    let slug: String
    let name: String
    let description: String
    let iconURL: URL?
}

/// A single Composio-side connected_account row for one toolkit. A user
/// can have multiple of these per toolkit (two Gmail addresses, two
/// Google Calendars, etc.) — `connectedToolkits` collapses them to the
/// slug; this shape gives the UI per-account visibility.
struct ComposioConnection: Identifiable, Hashable {
    let id: String           // Composio's connected_account id (used for disconnect)
    let label: String        // best-effort human label, usually the OAuth email
    let status: String?      // "ACTIVE", "INITIATED", etc., when Composio reports it
    let createdAt: String?   // ISO timestamp from Composio, optional
}

enum ComposioError: LocalizedError {
    case network
    case authExpired
    case subscriptionRequired
    case notConfigured
    case upstream(Int)

    var errorDescription: String? {
        switch self {
        case .network:
            return "Couldn't reach klo's cloud to start the connection."
        case .authExpired:
            // Hit only when the reactive refresh in authedPOST itself
            // failed (refresh token invalid or revoked). Caller should
            // surface a "sign in again" CTA rather than a HTTP code.
            return "Your session expired. Sign in again from Settings."
        case .subscriptionRequired:
            return "Connecting services is a Pro feature. Subscribe in Settings."
        case .notConfigured:
            return "Composio isn't configured on this server yet."
        case .upstream(let code):
            return "Connection failed (HTTP \(code))."
        }
    }
}
