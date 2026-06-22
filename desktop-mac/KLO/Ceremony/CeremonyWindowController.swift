import AppKit
import Combine
import SwiftUI

/// Owns the persistent cloud panel that hosts BOTH the cinematic
/// intro AND the onboarding cards. The panel is created once with a
/// single stable `NSHostingController(rootView: CeremonyHostView)`;
/// the host crossfades cinematic ↔ onboarding internally via SwiftUI
/// state so the entire view tree stays alive across the transition
/// (no remount, no flicker, no blank frame).
///
/// The controller observes the host's `OnboardingFocusCoordinator`
/// for two AppKit-side changes:
///   - `phase`: when it flips to .onboarding, enable mouse events +
///     bring the panel to key for text input.
///   - `handoff`: when it flips to .dimmedAwaiting, drop the panel
///     level from .screenSaver to .floating + flip ignoresMouseEvents
///     so System Settings can come forward and receive clicks. When
///     it flips back to .full, restore.
///
/// Returning users (signed out, hasSeenCeremony = true) skip this
/// path entirely and use the standalone `OnboardingWindowController`.
@MainActor
final class CeremonyWindowController: NSObject, NSWindowDelegate {

    static let shared = CeremonyWindowController()

    /// Has the user ever seen the launch ceremony? Separate from
    /// `CloudOnboardingCard.hasCompleted` so onboarding can
    /// re-enter (e.g. after sign-out) without replaying the ceremony.
    static var hasSeenCeremony: Bool {
        get { UserDefaults.standard.bool(forKey: "klo.hasSeenLaunchCeremony") }
        set { UserDefaults.standard.set(newValue, forKey: "klo.hasSeenLaunchCeremony") }
    }

    private var panel: CeremonyPanel?
    private var permissions: PermissionsManager?
    private var bridge: BridgeStatusManager?
    private var account: AccountManager?
    private var coordinator: OnboardingFocusCoordinator?
    /// One reminder pill across all handoff kinds. Kind-aware body is
    /// in `HandoffReminderView`. Created once, reused via `show(handoff:)`.
    private var reminder: HandoffReminderWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingOnComplete: (() -> Void)?

    /// Read-only accessor so AppDelegate can route Dock-icon clicks
    /// to `forceReturnToCloud()` during a handoff. Nil when no cloud
    /// experience is active.
    var currentCoordinator: OnboardingFocusCoordinator? { coordinator }

    /// First-launch entry point (and post-SR-restart resume entry).
    /// Builds the panel + host once. When `skipCinematic` is false
    /// (first launch), plays the cinematic then hands off to onboarding.
    /// When `skipCinematic` is true (post-restart resume), the host
    /// boots directly into onboarding mode — preserving the cloud
    /// surface so the user reads the restart as continuous instead of
    /// jarring.
    func playCloudExperience(
        account: AccountManager,
        bridge: BridgeStatusManager,
        sidecar: SidecarLauncher,
        notchGeometry: NotchGeometry,
        skipCinematic: Bool = false,
        skipDemoTour: Bool = false,
        onComplete: @escaping () -> Void
    ) {
        guard panel == nil else {
            onComplete()
            return
        }

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = CeremonyPanel(contentRect: frame)
        self.panel = panel
        self.pendingOnComplete = onComplete

        let permissions = PermissionsManager()
        self.permissions = permissions
        self.bridge = bridge
        self.account = account

        let coordinator = OnboardingFocusCoordinator()
        // Coordinator owns completion polling for both kinds — bind
        // the bridge (chrome signal source) + sidecar (so chrome
        // handoff pre-warms the WebSocket backend) here so the
        // controller doesn't need to wire its own subscriptions.
        coordinator.bind(permissions: permissions,
                         bridge: bridge,
                         sidecar: sidecar,
                         account: account)
        self.coordinator = coordinator

        // One reminder pill, used across all handoff kinds.
        let reminder = HandoffReminderWindowController()
        self.reminder = reminder

        // Single stable hosting controller. Never replaced — phase
        // changes happen inside the host.
        let host = CeremonyHostView(
            coordinator: coordinator,
            account: account,
            permissions: permissions,
            bridge: bridge,
            notchGeometry: notchGeometry,
            onCinematicComplete: { [weak self] in
                Self.hasSeenCeremony = true
                self?.handleCinematicComplete(account: account)
            },
            onOnboardingDone: { [weak self] in
                CloudOnboardingCard.hasCompleted = true
                self?.dismissPanel()
            },
            onEscape: { [weak self] in
                // User clicked × or hit ⌘W / ⌘Q during onboarding.
                // Dismiss the cloud WITHOUT marking onboarding
                // completed — they can re-enter on the next launch
                // (or via the standalone SignIn window if they
                // signed in before escaping).
                NSLog("KLO Ceremony: user escaped cloud onboarding")
                self?.dismissPanel()
            }
        )
        panel.contentViewController = NSHostingController(rootView: host)

        // CRITICAL: explicit setFrame AFTER assigning the
        // contentViewController. Without this, NSHostingController
        // collapses the panel to the SwiftUI root's intrinsic size.
        panel.setFrame(frame, display: false)

        // Observe coordinator → flip AppKit-side panel state. The
        // coordinator owns the completion polling for all handoff
        // kinds (permissions, chrome, google sign-in) — the controller
        // only does the AppKit-level work (orderOut/orderFront,
        // show/dismiss reminder + island).
        observeCoordinator(coordinator, panel: panel)

        panel.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSLog("KLO Ceremony: panel mounted at frame \(panel.frame), skipCinematic=\(skipCinematic)")

        // Post-restart / mid-flow resume: jump straight to onboarding
        // (skipping cinematic and optionally the demo tour). Mark
        // hasSeenCeremony=true defensively (it should already be true
        // if we got here via the resume path, but no harm in being
        // explicit).
        if skipCinematic {
            Self.hasSeenCeremony = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.handleCinematicComplete(account: account, skipDemoTour: skipDemoTour)
            }
        }
    }

    /// Called when the cinematic timeline finishes. If onboarding is
    /// needed, flip into the demo tour (or directly into onboarding
    /// when `skipDemoTour` is true — for users who already saw the
    /// tour in a prior session and just need to finish remaining steps).
    /// If not, just dismiss.
    private func handleCinematicComplete(account: AccountManager, skipDemoTour: Bool = false) {
        guard let coordinator = coordinator, let panel = panel else { return }

        let needsOnboarding = !CloudOnboardingCard.hasCompleted
            || !account.isReady
        guard needsOnboarding else {
            dismissPanel()
            return
        }

        // Resume case: skip the demo tour entirely and go straight
        // into the onboarding card. CloudOnboardingCard.onAppear
        // detects which step is next (permissions / ready / signIn)
        // based on what's already done, so the user lands on exactly
        // the right card.
        if skipDemoTour {
            coordinator.transitionToOnboarding()
        } else {
            coordinator.transitionToDemoTour()
        }

        // Re-pin the panel frame in case AppKit re-laid the host
        // controller during the SwiftUI phase change.
        let frame = NSScreen.main?.frame ?? panel.frame
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSLog("KLO Ceremony: transitioned to \(skipDemoTour ? "onboarding (skip demo)" : "demo tour")")
    }

    /// Wires up the coordinator's `@Published` values to AppKit:
    ///   - `phase`: enables mouse events on the cloud after the
    ///     cinematic finishes.
    ///   - `activeHandoff`: orderOut's the cloud + shows the reminder
    ///     pill (and drag island, for permissions) while non-nil;
    ///     reverses when nil. One observer for both kinds — the
    ///     reminder view branches on `Handoff` for kind-specific copy.
    private func observeCoordinator(_ coordinator: OnboardingFocusCoordinator,
                                    panel: CeremonyPanel) {
        coordinator.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] phase in
                guard let panel = panel else { return }
                switch phase {
                case .cinematic, .returningWelcome:
                    panel.ignoresMouseEvents = true
                case .demoTour, .onboarding:
                    panel.ignoresMouseEvents = false
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            .store(in: &cancellables)

        coordinator.$activeHandoff
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak panel] handoff in
                guard let self = self, let panel = panel else { return }
                if let handoff = handoff {
                    NSLog("KLO Controller: activeHandoff=\(handoff), hiding cloud + showing reminder")
                    panel.orderOut(nil)

                    // Reminder pill — same primitive for all kinds.
                    if let permissions = self.permissions,
                       let account = self.account {
                        self.reminder?.show(
                            handoff: handoff,
                            permissions: permissions,
                            bridge: self.bridge,
                            account: account,
                            coordinator: coordinator
                        )
                    }

                    // Drag island only for permission handoffs (literal
                    // "drag the .app onto the TCC list" UX). Chrome
                    // install + Google sign-in live entirely inside the
                    // browser.
                    if handoff.isPermission, let permissions = self.permissions {
                        let step: Int
                        switch handoff {
                        case .accessibility:    step = 1
                        case .screenRecording:
                            step = (permissions.accessibility == .granted) ? 2 : 1
                        case .chromeExtension, .googleSignIn:
                            step = 1 // unreachable: guarded by isPermission
                        }
                        AppDragIslandWindowController.shared.show(
                            for: handoff,
                            stepNumber: step,
                            totalSteps: 2
                        )
                    } else {
                        AppDragIslandWindowController.shared.dismiss()
                    }

                    // Activation listener: browser handoffs only (chrome
                    // + google sign-in). The kind-specific poll is the
                    // primary completion signal but can lag — if klo
                    // regains focus (user came back after finishing),
                    // end the handoff as a fast-path. Permission
                    // handoffs never auto-end on activation; the user
                    // may be mid-toggle and just checking on klo.
                    if handoff == .chromeExtension || handoff == .googleSignIn {
                        self.installKloActivationListener()
                    } else {
                        self.tearDownKloActivationListener()
                    }
                } else {
                    NSLog("KLO Controller: activeHandoff=nil, restoring cloud")
                    self.permissions?.endRapidPolling()
                    self.reminder?.dismiss()
                    AppDragIslandWindowController.shared.dismiss()
                    PermissionTransitionToastWindowController.shared.dismiss()
                    self.tearDownKloActivationListener()
                    panel.orderFrontRegardless()
                    panel.ignoresMouseEvents = false
                    NSApp.activate(ignoringOtherApps: true)
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    panel.makeKey()
                    // Final refresh so any @Published-driven UI updates
                    // as soon as the cloud is visible again.
                    self.permissions?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Klo activation listener (chrome handoff fast-return)

    /// NSWorkspace observer that ends the chrome handoff when klo
    /// regains focus. Permission handoffs intentionally do NOT install
    /// this — the user may be mid-toggle and just checking on klo.
    private var kloActivationObserver: Any?

    private func installKloActivationListener() {
        guard kloActivationObserver == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        kloActivationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let activatedApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleId = activatedApp?.bundleIdentifier else { return }
            if bundleId == Bundle.main.bundleIdentifier {
                NSLog("KLO Controller: klo regained focus during chrome handoff — ending")
                self.coordinator?.endHandoff()
            }
        }
    }

    private func tearDownKloActivationListener() {
        if let obs = kloActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            kloActivationObserver = nil
        }
    }

    /// Returning-user entry point — called on relaunch when onboarding
    /// is already complete and the user is signed in. Mounts the cloud
    /// panel directly into `.returningWelcome` phase for a brief
    /// (~2.4s) "Welcome back." flourish, then dismisses. Gives the
    /// relaunch the same visual continuity as first launch instead of
    /// dropping the user straight into the notch with no flourish.
    ///
    /// Intentionally simpler than `playCloudExperience`: no
    /// PermissionsManager, no reminder, no handoff observer — the cloud
    /// is purely decorative here. After dismissal the existing
    /// keyboard tutorial sink (in AppDelegate) fires naturally if the
    /// tutorial hasn't been seen, which is the "pick up where you left
    /// off" beat.
    func playReturningExperience(
        notchGeometry: NotchGeometry,
        account: AccountManager,
        bridge: BridgeStatusManager,
        onComplete: @escaping () -> Void
    ) {
        guard panel == nil else {
            onComplete()
            return
        }

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = CeremonyPanel(contentRect: frame)
        self.panel = panel
        self.pendingOnComplete = onComplete

        // Lightweight stand-ins: the welcome flourish needs neither a
        // PermissionsManager nor a coordinator-driven handoff. We still
        // build a coordinator so the host's phase enum is observable.
        let permissions = PermissionsManager()
        self.permissions = permissions

        let coordinator = OnboardingFocusCoordinator()
        coordinator.bind(permissions: permissions)
        self.coordinator = coordinator

        let host = CeremonyHostView(
            coordinator: coordinator,
            account: account,
            permissions: permissions,
            bridge: bridge,
            notchGeometry: notchGeometry,
            onCinematicComplete: { [weak self] in
                // Welcome flourish ended → tear down the cloud and let
                // the rest of the app boot.
                self?.dismissPanel()
            },
            onOnboardingDone: { [weak self] in
                self?.dismissPanel()
            },
            onEscape: { [weak self] in
                self?.dismissPanel()
            }
        )
        panel.contentViewController = NSHostingController(rootView: host)
        panel.setFrame(frame, display: false)

        // Welcome panel never drops to handoff mode; we only need the
        // phase observer so the host updates when we flip to
        // .returningWelcome below.
        observeCoordinator(coordinator, panel: panel)

        panel.delegate = self
        // Activate so the cloud is visibly frontmost. ignoresMouseEvents
        // stays true via the .cinematic-style phase observer until we
        // flip phase below — but the welcome content has no interactive
        // affordances anyway, so it doesn't matter much here.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSLog("KLO Ceremony: returning welcome panel mounted")

        // Flip phase next tick so the host's transition animation
        // actually runs (going from initial .cinematic to
        // .returningWelcome with `withAnimation` produces a clean
        // crossfade-in).
        DispatchQueue.main.async {
            coordinator.enterReturningWelcome()
        }
    }

    private func dismissPanel() {
        // Fade the ethereal ambient bed before tearing down the cloud.
        CeremonyAudio.shared.stopAmbient(fadeOut: 1.0)
        reminder?.dismiss()
        reminder = nil
        AppDragIslandWindowController.shared.dismiss()
        tearDownKloActivationListener()
        panel?.orderOut(nil)
        panel = nil
        permissions = nil
        bridge = nil
        account = nil
        coordinator = nil
        cancellables.removeAll()
        let onComplete = pendingOnComplete
        pendingOnComplete = nil
        onComplete?()
    }
}
