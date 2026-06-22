import AppKit
import Combine
import SwiftUI

/// Drives the persistent cloud panel's phase + handoff state.
///
/// **Phases** (`HostPhase`) are the cinematic / demo-tour / onboarding /
/// returning-welcome cross-fades inside the cloud. Owned here so views
/// observing `phase` get a clean SwiftUI transition.
///
/// **Handoffs** (`Handoff`) are the moments when the user must leave klo
/// to do something elsewhere — toggle a TCC permission in System
/// Settings, install the Chrome extension. All handoffs share the same
/// shape:
///   1. Cloud `orderOut`s. Floating reminder pill takes over (and, for
///      permission handoffs, a drag island docks to System Settings).
///   2. Coordinator deep-links the user to the right destination.
///   3. Coordinator polls a kind-specific completion signal (TCC for
///      permissions, `BridgeStatusManager.extensionConnected` for chrome).
///   4. On detection: 3-stage celebration choreography (haptic → toast →
///      restore cloud). Permissions chain to the next ungranted one if
///      there is one; chrome is one-shot.
///   5. On manual return (pill's `Return` button): cloud restores
///      immediately; user lands on the same step (chrome step's
///      fallback view shows; permissions step stays).
///
/// `CeremonyWindowController` observes `activeHandoff` to drive the
/// AppKit-level panel/reminder lifecycle.
@MainActor
final class OnboardingFocusCoordinator: ObservableObject {

    enum HostPhase: Equatable {
        case cinematic
        case demoTour
        case onboarding
        /// Brief "Welcome back." flourish for returning users on
        /// relaunch (after onboarding has completed in a prior
        /// session). Auto-dismisses after ~2.2s.
        case returningWelcome
    }

    @Published private(set) var phase: HostPhase = .cinematic

    /// The single source of truth for "is klo currently stepped aside
    /// for a user-driven handoff?" `nil` means the cloud owns the
    /// screen. Anything else means a reminder pill should be on screen
    /// pointing the user at the kind-specific destination.
    @Published private(set) var activeHandoff: Handoff?

    /// Brief celebratory beat between "completion detected" and
    /// "panel restored." The reminder pill reads "Done!" during this
    /// window; the host view applies a fire-glow burst to the matching
    /// surface.
    @Published private(set) var lastCompletedHandoff: Handoff?

    /// True while we're in the 1.6s grace period before auto-relaunching
    /// for an in-session SR grant. The cloud's permissions step shows a
    /// "restarting klo" toast bound to this flag. Permission-only;
    /// chrome / google sign-in don't trigger relaunches.
    @Published private(set) var screenRecordingRestartPending: Bool = false

    private weak var permissions: PermissionsManager?
    private weak var bridge: BridgeStatusManager?
    private weak var sidecar: SidecarLauncher?
    private weak var account: AccountManager?
    private var completionSubscription: AnyCancellable?
    private var srRelaunchSubscription: AnyCancellable?

    func bind(permissions: PermissionsManager,
              bridge: BridgeStatusManager? = nil,
              sidecar: SidecarLauncher? = nil,
              account: AccountManager? = nil) {
        self.permissions = permissions
        self.bridge = bridge
        self.sidecar = sidecar
        self.account = account
        observeScreenRecordingRelaunch(permissions: permissions)
    }

    /// Watch Screen Recording. macOS requires a process restart for a
    /// fresh SR grant to take effect — the toggle flips green
    /// immediately in Settings but the running process is still
    /// blocked. We snapshot SR's launch-time state on the
    /// PermissionsManager itself (`wasScreenRecordingGrantedAtLaunch`)
    /// and, if SR flips to `.granted` mid-session, persist a resume
    /// step + relaunch after a 1.6s grace so the user reads the toast.
    private func observeScreenRecordingRelaunch(permissions: PermissionsManager) {
        // DISABLED. Auto-relaunching when SR flips to .granted mid-flow
        // is a destructive UX — the user toggles SR while also trying
        // to toggle Accessibility, klo restarts under them, they lose
        // their place in System Settings, and they have to start over.
        // The "SR doesn't take effect for a running process" caveat
        // still applies, but we let the user trigger the relaunch
        // themselves (next manual launch, or a banner button) instead
        // of yanking the rug. Body intentionally left empty.
        _ = permissions
    }

    // MARK: - Phase

    /// Cinematic finished — flip to the demo tour. The tour itself
    /// transitions to onboarding when its last scene auto-advances.
    func transitionToDemoTour() {
        guard phase == .cinematic else { return }
        withAnimation(.easeOut(duration: 0.55)) { phase = .demoTour }
    }

    /// Set the initial phase to the returning-user welcome flourish.
    /// Bypasses the .cinematic guard since this path skips the full
    /// cinematic. Call from the controller right after mounting the
    /// panel for a returning user.
    func enterReturningWelcome() {
        withAnimation(.easeOut(duration: 0.55)) { phase = .returningWelcome }
    }

    /// Demo tour finished (or user skipped) — flip to onboarding.
    func transitionToOnboarding() {
        guard phase != .onboarding else { return }
        withAnimation(.easeOut(duration: 0.55)) { phase = .onboarding }
    }

    // MARK: - Handoff: request

    /// Step aside for `kind`. The whole choreography (cloud `orderOut`,
    /// reminder pill, deep-link, completion observer) fans out from
    /// here. Idempotent: requesting the same handoff twice is a no-op.
    func requestHandoff(_ kind: Handoff) {
        guard activeHandoff != kind else { return }

        // Per-kind pre-work that has to happen BEFORE the cloud
        // orderOuts. Permissions need rapid TCC polling so detection
        // latency drops from 1.5s → ~0.4s. Chrome pre-warms the sidecar
        // (the WebSocket backend the extension connects to). OAuth has
        // none — the kick is the deep-link action itself.
        if kind.isPermission {
            permissions?.beginRapidPolling()
        } else if kind == .chromeExtension {
            sidecar?.startIfNeeded()
        }

        withAnimation(.easeOut(duration: 0.25)) {
            activeHandoff = kind
        }

        // Open the deep-link / kick off the kind-specific action. For
        // permissions we route through System Settings.app explicitly
        // via `withApplicationAt:` so it activates atomically. For
        // chrome we just open the Web Store URL. For Google sign-in we
        // call AccountManager.startSignInWithGoogle() which does a
        // network round-trip to Supabase to mint the OAuth URL, then
        // opens it in the default browser.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            switch kind {
            case .accessibility, .screenRecording:
                guard let url = kind.deepLinkURL else { return }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                cfg.addsToRecentItems = false
                let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: settingsApp,
                    configuration: cfg
                ) { _, _ in }
            case .chromeExtension:
                if let url = kind.deepLinkURL { NSWorkspace.shared.open(url) }
            case .googleSignIn:
                if let account = self.account {
                    Task { await account.startSignInWithGoogle() }
                }
            }
        }

        observeForCompletion(kind)
    }

    // MARK: - Handoff: return paths

    /// Manual escape — pill's `Return` button OR Dock-icon click during
    /// a permissions handoff. Refresh state, drop the completion
    /// subscription, restore the cloud regardless of whether the user
    /// actually completed the handoff (they explicitly asked to come
    /// back).
    func forceReturnFromHandoff() {
        guard activeHandoff != nil else { return }
        permissions?.refresh()
        completionSubscription?.cancel()
        completionSubscription = nil
        permissions?.endRapidPolling()
        PermissionTransitionToastWindowController.shared.dismiss()
        withAnimation(.easeOut(duration: 0.4)) {
            activeHandoff = nil
            lastCompletedHandoff = nil
        }
        bringKloForward()
    }

    /// Used by external listeners (e.g. the NSWorkspace activation
    /// observer that restores the cloud when klo regains focus during
    /// a chrome handoff). Same effect as `forceReturnFromHandoff` but
    /// no celebration toast/haptic — the user already got their
    /// celebration cue from completing the install.
    func endHandoff() {
        guard activeHandoff != nil else { return }
        completionSubscription?.cancel()
        completionSubscription = nil
        permissions?.endRapidPolling()
        withAnimation(.easeOut(duration: 0.4)) {
            activeHandoff = nil
            lastCompletedHandoff = nil
        }
    }

    // MARK: - Completion observer (kind-specific signal source)

    private func observeForCompletion(_ kind: Handoff) {
        completionSubscription?.cancel()

        let donePublisher: AnyPublisher<Void, Never>
        switch kind {
        case .accessibility:
            guard let p = permissions else { return }
            donePublisher = p.$accessibility
                .filter { $0 == .granted }
                .map { _ in () }
                .eraseToAnyPublisher()
        case .screenRecording:
            guard let p = permissions else { return }
            donePublisher = p.$screenRecording
                .filter { $0 == .granted }
                .map { _ in () }
                .eraseToAnyPublisher()
        case .chromeExtension:
            guard let b = bridge else { return }
            donePublisher = b.$extensionConnected
                .filter { $0 }
                .map { _ in () }
                .eraseToAnyPublisher()
        case .googleSignIn:
            guard let a = account else { return }
            donePublisher = a.$status
                .filter { status in
                    switch status {
                    case .signedInActive, .signedInUnsubscribed,
                         .signedInPastDue, .signedInExpired:
                        return true
                    default:
                        return false
                    }
                }
                .map { _ in () }
                .eraseToAnyPublisher()
        }

        completionSubscription = donePublisher
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.celebrateAndRestore(kind)
            }
    }

    // MARK: - Celebration choreography

    /// Permission handoffs run the full 3-stage choreography (pill
    /// flash → transition toast → restore-or-chain) ending with
    /// `bringKloForward()` so the user sees the success beat — they're
    /// mid-Settings-toggle and need the visible confirmation.
    ///
    /// Browser handoffs (`.chromeExtension`, `.googleSignIn`) DELIBERATELY
    /// do not pull klo forward. The user might still be finishing the
    /// extension's own auth flow, dealing with an OAuth redirect tab,
    /// or otherwise mid-task in their browser. Stealing focus on a
    /// WebSocket-connected / token-stored signal is premature. Instead
    /// we persist the durable flag + flash the pill to its celebratory
    /// state ("Done — come back when ready") and let the user return
    /// to klo of their own volition. The NSWorkspace activation
    /// listener restores the cloud when they do.
    private func celebrateAndRestore(_ kind: Handoff) {
        if kind.isPermission {
            celebrateAndRestorePermission(kind)
        } else {
            celebrateBrowserCompletion(kind)
        }
    }

    /// Browser handoff completion.
    ///
    /// `.chromeExtension` — auto-restore klo to the foreground after a
    /// short celebratory beat. The user just installed the extension
    /// inside their browser; with no on-screen affordance back to klo
    /// (the reminder pill is small and easy to miss), waiting for them
    /// to find their own way back is a dead end. The pill's
    /// celebratory state still gets a moment to register before the
    /// cloud animates back in.
    ///
    /// `.googleSignIn` — stays non-interrupting. The OAuth callback
    /// URL handler delivers its own focus + token-store side effects;
    /// auto-restoring on `account.status` flip would race that path
    /// and risk tearing down the cloud before the URL handler can
    /// finish wiring the session.
    private func celebrateBrowserCompletion(_ kind: Handoff) {
        // Chrome durable flag — set here when the bridge detects the
        // extension. Same flag the user's "I'm done" click sets, so
        // the derived currentStep advances past Chrome whenever the
        // cloud restores.
        if kind == .chromeExtension {
            UserDefaults.standard.set(true, forKey: CloudChromeExtensionStep.didInstallKey)
        }
        // OAuth has no flag — account.isSignedIn IS the signal for
        // derived currentStep routing.

        withAnimation(.easeOut(duration: 0.25)) {
            lastCompletedHandoff = kind
        }
        HapticEngine.tap(.alignment)
        CeremonyAudio.shared.playSuccessPing()
        NSLog("KLO Coordinator: browser-handoff \(kind) complete — pill flipped")

        guard kind == .chromeExtension else { return }

        // Cancel the completion subscription now that we're driving the
        // restore ourselves — leaving it live would let a subsequent
        // bridge-state flicker re-fire the celebration.
        completionSubscription?.cancel()
        completionSubscription = nil

        // 0.4s delay matches the post-toast cadence permission handoffs
        // use, so the pill's celebratory state registers before the
        // cloud panel animates back in. The CeremonyWindowController
        // observer for `$activeHandoff` handles the actual orderFront
        // + NSApp.activate when we nil it out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                self.activeHandoff = nil
                self.lastCompletedHandoff = nil
            }
            self.bringKloForward()
        }
    }

    /// Permission handoff completion — the full 3-stage choreography.
    /// Unchanged behavior; the user is mid-Settings-toggle and wants
    /// the visible success beat.
    private func celebrateAndRestorePermission(_ kind: Handoff) {
        withAnimation(.easeOut(duration: 0.25)) {
            lastCompletedHandoff = kind
        }
        HapticEngine.success()
        CeremonyAudio.shared.playSuccessPing()

        let nextKind = nextUngrantedPermission(after: kind)
        NSLog("KLO Coordinator: stage1 done=\(kind) next=\(String(describing: nextKind))")

        // Stage 2 — transition toast at 0.4s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            PermissionTransitionToastWindowController.shared.show(
                current: kind,
                next: nextKind
            )
        }

        // Stage 3 at 2.0s — chain to next OR restore cloud.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            PermissionTransitionToastWindowController.shared.dismiss()
            HapticEngine.tap(.alignment)

            if let next = nextKind {
                NSLog("KLO Coordinator: stage3 → chaining to \(next)")
                self.lastCompletedHandoff = nil
                self.activeHandoff = nil
                DispatchQueue.main.async {
                    self.requestHandoff(next)
                }
                return
            }

            NSLog("KLO Coordinator: stage3 → restoring cloud")
            withAnimation(.easeOut(duration: 0.4)) {
                self.activeHandoff = nil
                self.lastCompletedHandoff = nil
            }
            self.permissions?.endRapidPolling()
            self.bringKloForward()
        }
    }

    /// Next required permission still in `.notRequested` / `.denied`
    /// after `current`, in fixed Accessibility → Screen Recording
    /// order. Nil if all required permissions are granted.
    private func nextUngrantedPermission(after current: Handoff) -> Handoff? {
        guard let permissions = permissions else { return nil }
        let order: [Handoff] = [.accessibility, .screenRecording]
        for kind in order where kind != current {
            let status: PermissionsManager.Status
            switch kind {
            case .accessibility:    status = permissions.accessibility
            case .screenRecording:  status = permissions.screenRecording
            case .chromeExtension, .googleSignIn:  continue
            }
            if status != .granted { return kind }
        }
        return nil
    }

    // MARK: - Bring klo forward

    /// Multi-pronged activation. `NSApp.activate` alone isn't always
    /// enough when System Settings (or Chrome) is the active app — the
    /// cloud can stay technically frontmost (it's at `.screenSaver`
    /// level) but klo isn't the active app from macOS's perspective.
    /// `NSRunningApplication` activation is more authoritative.
    private func bringKloForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}


// ─────────────────────────────────────────────────────────────────────
// One Handoff enum to rule them all. Carries kind-specific data via
// computed properties so consumers don't need to switch on it for
// every detail.
// ─────────────────────────────────────────────────────────────────────

enum Handoff: Equatable {
    case accessibility
    case screenRecording
    case chromeExtension
    case googleSignIn

    /// Short label shown in the reminder pill / transition toast.
    var label: String {
        switch self {
        case .accessibility:   return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .chromeExtension: return "Chrome extension"
        case .googleSignIn:    return "Google sign-in"
        }
    }

    /// Full pane name shown in transition-toast copy: "Toggle klo on in
    /// {paneLabel}." Permission-only.
    var paneLabel: String? {
        switch self {
        case .accessibility:   return "Accessibility"
        case .screenRecording: return "Screen & System Audio Recording"
        case .chromeExtension: return nil
        case .googleSignIn:    return nil
        }
    }

    /// Where the user gets sent. System Settings deep-link for permissions,
    /// Chrome Web Store URL for the extension. Nil for Google sign-in
    /// because the URL is dynamic (Supabase generates it per request)
    /// and the coordinator triggers AccountManager.startSignInWithGoogle()
    /// instead of NSWorkspace.open on a fixed URL.
    var deepLinkURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .chromeExtension:
            return URL(string: "https://github.com/klo-local/klo-local/blob/main/docs/extension.md")
        case .googleSignIn:
            return nil
        }
    }

    /// True for the macOS TCC handoffs that need rapid polling, drag
    /// island, transition toast, and chaining-to-next behavior.
    var isPermission: Bool {
        switch self {
        case .accessibility, .screenRecording: return true
        case .chromeExtension, .googleSignIn:  return false
        }
    }
}
