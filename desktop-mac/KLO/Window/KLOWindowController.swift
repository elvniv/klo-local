import AppKit
import Combine
import SwiftUI

/// Fired by `KLOWindowController.show(withIntroPulse: true)` after the
/// cloud onboarding completes. KLOOverlayView listens and applies a
/// brief, strong KloFireGlow to the notch silhouette so the post-
/// onboarding moment reads as "klo just moved into your notch."
extension Notification.Name {
    static let kloNotchIntroPulse = Notification.Name("klo.notchIntroPulse")
    // Posted by MacOpsServer when the model calls web.open. KLOState
    // listens for this to transition into the .webPane mode so the
    // user sees klo's embedded browser pane mount.
    static let kloShowWebPane = Notification.Name("klo.showWebPane")
    // Posted by AgentClient when the sidecar acknowledges a mid-run
    // inject_message frame. WebPaneView listens to show the brief
    // "↪ steered" / "↳ injected" toast over the input row.
    // userInfo: ["kind": "steer" | "inject", "text": String]
    static let kloInjectionAcknowledged = Notification.Name("klo.injection.acknowledged")
    // Posted by CredCaptureCoordinator when the user submits a login
    // form and klo wants to ask "Save sign-in to klo?". KLOState
    // listens to flip into the .offerSaveCredential mode.
    // userInfo: ["host": String, "username": String, "pendingId": String]
    static let kloOfferSaveCredential = Notification.Name("klo.cred.offerSave")
    // User accepted the "Save sign-in?" island. CredCaptureCoordinator
    // listens and persists to KloKeychain.
    // userInfo: ["pendingId": String]
    static let kloCredentialSaveAccepted = Notification.Name("klo.cred.saveAccepted")
    // User declined (or the island timed out) — coordinator flushes
    // the in-memory password hold without persisting.
    static let kloCredentialSaveDeclined = Notification.Name("klo.cred.saveDeclined")
    // Posted by Settings' recent-conversations list when the user
    // clicks a row. AppDelegate routes it to KLOState.resumeConversation
    // (Settings has no direct KLOState reference — same pattern as the
    // other cross-surface notifications above).
    // userInfo: ["id": UUID]
    static let kloResumeConversation = Notification.Name("klo.resumeConversation")
}

// Owns the singleton KLOPanel + hosts the SwiftUI overlay inside it.
// Repositions the panel whenever notch geometry changes (display swap,
// lid open/close), and toggles ignoresMouseEvents + canBecomeKey based
// on the current KLOState mode.
@MainActor
final class KLOWindowController {

    private let panel: KLOPanel
    private let state: KLOState
    private let detector: NotchDetector
    private let agentClient: AgentClient
    private let realtimeBridge: RealtimeBridge
    private let bridgeStatus: BridgeStatusManager
    private let account: AccountManager
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceObserver: NSObjectProtocol?
    private var clickAwayMonitor: Any?
    private var localClickAwayMonitor: Any?
    private var localEscMonitor: Any?
    private var globalEscMonitor: Any?
    private var keyWindowObserver: NSObjectProtocol?

    // Window canvas size — wide enough for the 560pt expanded panel
    // plus generous below-notch buffer for the working pill detail
    // view to grow into without re-laying out the window.
    // Window canvas is intentionally larger than any expanded panel
    // (currently max 600pt wide) so content never overflows and SwiftUI
    // centering math always reduces to "center the dims.width content
    // within the window's full bounds." A previous shift-right artifact
    // came from 600pt content overflowing a 560pt window.
    private static let windowWidth: CGFloat = 1000
    /// Tall enough that the voice-mode fire overlay (drops down from the
    /// notch panel) plus the result panel (340pt tall) both fit without
    /// being clipped by the window bounds.
    private static let windowHeight: CGFloat = 700

    init(state: KLOState,
         detector: NotchDetector,
         agentClient: AgentClient,
         realtimeBridge: RealtimeBridge,
         bridgeStatus: BridgeStatusManager,
         account: AccountManager) {
        self.state = state
        self.detector = detector
        self.agentClient = agentClient
        self.realtimeBridge = realtimeBridge
        self.bridgeStatus = bridgeStatus
        self.account = account

        let initialFrame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        self.panel = KLOPanel(contentRect: initialFrame)

        let rootView = KLOOverlayView()
            .environmentObject(state)
            .environmentObject(detector)
            .environmentObject(agentClient)
            .environmentObject(realtimeBridge)
            .environmentObject(bridgeStatus)
            .environmentObject(account)
            .environmentObject(SystemDialogObserver.shared)

        // PassthroughHostingView (not plain NSHostingView): clicks over
        // any transparent / non-interactive region fall through to the app
        // underneath, so the 1000×700 panel never turns the screen's
        // top-middle into a dead zone. Only klo's actual controls capture.
        let host = PassthroughHostingView(rootView: rootView)
        host.activeHitTestRegions = { [weak state, weak detector, weak bridgeStatus] bounds in
            guard let state, let detector, let bridgeStatus else { return [] }
            return Self.activeHitTestRegions(
                state: state,
                detector: detector,
                bridgeStatus: bridgeStatus,
                bounds: bounds,
            )
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        bindStateChanges()
        bindDetectorChanges()
        bindActiveAppChanges()
        bindSystemDialogVisibility()
        bindGrantPhase()
        bindSidecarHealth()
        installClickAwayMonitor()
        installEscapeMonitors()
        installKeyWindowObserver()
    }

    /// Dismiss the notch on outside-clicks via two complementary
    /// monitors. The right mental model is "SwiftUI is the ground truth
    /// for what counts as 'on the notch'" — KLOOverlayView marks
    /// transparent regions of the panel as `.allowsHitTesting(false)`,
    /// so clicks land on the notch's visible silhouette OR pass straight
    /// through to whatever's underneath (other apps, the desktop,
    /// another klo window). These monitors react to the pass-throughs:
    ///
    ///   - **Global monitor:** fires for any click delivered to ANOTHER
    ///     app. If the notch is expanded, that means the user clicked
    ///     outside klo — collapse.
    ///   - **Local monitor:** fires for any click delivered to klo. If
    ///     the event went to a klo window OTHER than the notch panel
    ///     (e.g. Settings), the user is moving focus there — collapse.
    ///     Events on the panel itself are SwiftUI-consumed visible
    ///     content; leave them alone.
    ///
    /// `dismissOnOutsideClickIfAppropriate()` gates on `isExpanded` and
    /// carves out modes that require an explicit answer (sign-in,
    /// paywall, permission, confirm, web pane) — a stray click can't
    /// accidentally cancel those.
    private func installClickAwayMonitor() {
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissOnOutsideClickIfAppropriate() }
        }
        localClickAwayMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // Never consume — let SwiftUI / responder chain handle the
            // event normally. We just observe.
            guard let self else { return event }
            // Only react if the event landed on a different klo window.
            // Events for `self.panel` were consumed by visible notch UI
            // (transparent regions don't deliver to the panel — they
            // pass through, in which case the event's `window` is the
            // window beneath, handled by `event.window !== self.panel`
            // naturally).
            if event.window !== self.panel {
                Task { @MainActor in self.dismissOnOutsideClickIfAppropriate() }
            }
            return event
        }
    }

    /// Collapse the notch whenever a different klo window becomes key —
    /// most importantly the Settings window, but also any future
    /// auxiliary window we add. This sidesteps the z-order trap: the
    /// notch panel is at `.statusBar` (above Settings's `.normal`), so
    /// when both are visible the notch sits ON TOP and intercepts
    /// clicks on Settings UI that overlaps the notch's visible chat
    /// silhouette (the textExpanded panel is 760×100+, completed is
    /// 760×480 — easily large enough to cover Settings's X button).
    /// Auto-collapsing the notch the moment Settings becomes key means
    /// the user can always interact with Settings, and they re-summon
    /// the notch with ⌘K when done.
    ///
    /// Carve-outs still apply via dismissOnOutsideClickIfAppropriate —
    /// e.g., sign-in island stays put even if another klo window becomes
    /// key, because the user needs to complete OAuth.
    private func installKeyWindowObserver() {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let win = notification.object as? NSWindow else { return }
            guard let self else { return }

            // Settings became key: demote the panel level out from
            // under it. Without this, the panel (at .statusBar = 25)
            // sits above Settings (.normal = 0) and intercepts clicks
            // on Settings UI that overlaps the panel's visible chat
            // silhouette — most painfully, the red close button when
            // the notch is expanded in a carve-out mode (signInRequired,
            // webPane, etc.) where dismissOnOutsideClickIfAppropriate
            // can't collapse. Demoting to .normal puts Settings on top
            // visually + click-wise; restored when the panel becomes
            // key again below.
            if win === SettingsWindowController.shared.currentWindow {
                self.panel.level = .normal
            }

            // Notch panel became key: restore its float-above-everything
            // level. (Also catches the case where the user clicked the
            // notch after Settings was open — they want the notch on
            // top again.)
            if win === self.panel {
                self.panel.level = .statusBar
                return  // panel becoming key is not "external surface stole focus"
            }

            Task { @MainActor in self.dismissOnOutsideClickIfAppropriate() }
        }
    }

    /// Collapse the notch when the user clicks outside its visible UI,
    /// unless the current mode requires an explicit answer. Modes in
    /// the carve-out below stay open on outside-click:
    ///
    ///   - `.signInRequired` — user has a draft prompt held against
    ///     the OAuth callback; dismissing would lose it.
    ///   - `.paywallRequired` — same, plus Stripe checkout is the path
    ///     forward and we don't want to vanish on the way out the door.
    ///   - `.permissionRequired` — paired with the grant orchestrator;
    ///     the user must accept/deny the macOS Privacy pane.
    ///   - `.confirmingAction` — the agent is blocked on a yes/no
    ///     decision; auto-dismissing would re-pose the question.
    ///   - `.webPane` — the user is watching klo work in a browser;
    ///     stray clicks to focus their editor shouldn't yank the pane.
    ///     The X button in the chrome dismisses; Esc hard-stops.
    ///   - `.completed` / `.failed`, `.failedExtensionMissing` — the
    ///     panel just landed the run's result and the user needs to
    ///     read / copy / act on it. Auto-dismissing on the very next
    ///     click anywhere on screen silently destroys the result. The
    ///     user closes with Esc or by re-tapping ⌘K to clear.
    @MainActor
    private func dismissOnOutsideClickIfAppropriate() {
        guard state.isExpanded else { return }
        switch state.mode {
        case .signInRequired, .paywallRequired, .permissionRequired,
             .confirmingAction, .webPane,
             .completed, .failed, .failedExtensionMissing:
            return
        default:
            state.collapseToIdle()
        }
    }

    deinit {
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let monitor = clickAwayMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localClickAwayMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = localEscMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEscMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Global ESC handling
    //
    // Pre-this-change, ESC only fired when a `.keyboardShortcut(.escape)`
    // button was in the responder chain — which excluded `.working` /
    // `.resuming` (panel.allowsKey is false there) and any state where
    // no button was focused. Users hit ESC during a run, nothing
    // happened. Fix: two monitors with complementary coverage.
    //
    //   - localEscMonitor:  fires when klo's own panel is key (text
    //                       input, completed, paywall, permission,
    //                       sign-in islands). Swallows the event so
    //                       any redundant `.keyboardShortcut(.escape)`
    //                       doesn't double-fire.
    //   - globalEscMonitor: fires when ANOTHER app is active. Acts
    //                       ONLY when klo has a cancellable run in
    //                       flight (.working / .resuming) so we don't
    //                       hijack ESC from the user's typing flow.
    //
    // Both funnel into `handleEscape()` which routes by mode.
    private func installEscapeMonitors() {
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }    // ESC
            // Never steal ESC while a system TCC dialog is up — the
            // user is interacting with it.
            if SystemDialogObserver.shared.systemDialogVisible { return event }
            // Idle: don't swallow. ESC should fall through to whatever
            // (rare) responder might want it (e.g. menu close).
            if case .idle = self.state.mode { return event }
            Task { @MainActor in self.handleEscape() }
            return nil
        }
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self else { return }
                if SystemDialogObserver.shared.systemDialogVisible { return }
                // Global monitor catches ESC from ANY foreground app
                // — only act when klo has a cancellable run in flight.
                // Otherwise the user is just hitting ESC in their
                // editor / browser and shouldn't trigger klo at all.
                switch self.state.mode {
                case .working, .resuming:
                    self.handleEscape()
                default:
                    break
                }
            }
        }
    }

    @MainActor
    private func handleEscape() {
        guard panel.isVisible else { return }
        switch state.mode {
        case .idle:
            return
        case .working, .resuming:
            // Cancels the WS, POSTs /runs/<id>/cancel, and collapses
            // to idle via state.collapseToIdle inside cancelCurrentRun.
            agentClient.cancelCurrentRun()
        case .confirmingAction:
            // Reject the agent's confirm_action — the run continues
            // on the sidecar side and reports cancellation cleanly.
            // Drop to .working so the user sees the run resume instead
            // of the panel snapping shut.
            agentClient.submitConfirm(approved: false)
        case .textExpanded:
            // The history overlay layers over the text input without a
            // mode of its own, so Esc has to peel it off here BEFORE
            // the default collapse — otherwise closing the list would
            // also slam the whole panel shut.
            if state.showingHistory {
                state.showingHistory = false
            } else {
                state.collapseToIdle()
            }
        case .voiceExpanded,
             .completed, .failed, .failedExtensionMissing,
             .paywallRequired, .permissionRequired, .signInRequired:
            state.collapseToIdle()
        case .webPane:
            // Esc inside the web pane is the HARD STOP — kills the run,
            // collapses to idle. The "dismiss pane but keep run going"
            // affordance is the X button in the chrome bar (which calls
            // state.dismissWebPane()). We make Esc the bigger gesture
            // because the user is actively watching klo work; if they
            // hit Esc, they want to abort, not just hide.
            agentClient.cancelCurrentRun()
        case .offerSaveCredential:
            // Decline the save prompt — the in-memory password hold
            // expires on its own after ~30s, but dismissing the island
            // signals "no, don't save" cleanly.
            NotificationCenter.default.post(name: .kloCredentialSaveDeclined, object: nil)
            state.dismissSaveCredential()
        case .connections:
            // Dismiss the inline connections browser. If the user had
            // a draft typed in .textExpanded before opening connections,
            // state.dismissConnections() restores it.
            state.dismissConnections()
        case .scheduleConfirm(let pending):
            // Esc on the confirm card is the same as tapping Cancel —
            // dismiss the pending schedule without activating it.
            Task { await state.rejectPendingSchedule(pending) }
        case .workspaceInitiated:
            // Esc on the init hero is the same as tapping "Got it" —
            // dismiss without opening Finder. The workspace was already
            // created on disk by the Python sidecar; this is just the
            // acknowledgement.
            state.dismissWorkspaceInitiated()
        case .workspaceApproval(let approval):
            // Esc on the approval gate is "Reject" — block the worker's
            // pending external action.
            Task { await state.resolveWorkspaceApproval(approval, approved: false) }
        }
    }

    func show(withIntroPulse: Bool = false) {
        repositionForCurrentScreen(animated: false)
        panel.orderFrontRegardless()
        if withIntroPulse {
            // Brief one-shot fire-glow on the notch silhouette so the
            // user reads the post-onboarding notch panel as "klo is
            // now living in your notch." KLOOverlayView observes via
            // NotificationCenter and animates the glow.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NotificationCenter.default.post(
                    name: .kloNotchIntroPulse,
                    object: nil
                )
            }
        }
    }

    // MARK: - Bindings

    private func bindStateChanges() {
        state.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.applyModeToPanel(mode)
                self?.syncWebViewParenting(for: mode)
            }
            .store(in: &cancellables)
    }

    /// Belt-and-suspenders companion to WebViewContainer.dismantleNSView.
    /// Synchronous reparent on mode change ensures the WKWebView's
    /// window pointer is correct BEFORE the next tool call (which is
    /// dispatched through MacOpsServer's main-actor queue).
    ///
    /// dismantleNSView gets called by SwiftUI's view-removal path which
    /// can be delayed by transition animations (.opacity, .move, etc.).
    /// Tool dispatch may arrive in that gap and hit a window-less
    /// webView. This hook eliminates the race by reparenting the moment
    /// state.mode flips away from .webPane.
    private func syncWebViewParenting(for mode: KLOState.Mode) {
        guard case .webPane = mode else {
            WebViewManager.shared.reparentToHolder()
            return
        }
        // Mode IS .webPane — let SwiftUI's WebViewContainer claim the
        // webView on mount. No-op here.
    }

    private func bindDetectorChanges() {
        detector.$geometry
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repositionForCurrentScreen(animated: true)
            }
            .store(in: &cancellables)
    }

    /// Multi-display follow. When the user switches focus to an app on a
    /// different display, recompute notch geometry for THAT display so
    /// the panel jumps to the correct notch within the 250ms spring.
    private func bindActiveAppChanges() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDetectorForFocusedApp() }
        }
    }

    private func refreshDetectorForFocusedApp() {
        // Use the screen containing the focused app's main window, falling
        // back to NSScreen.main if we can't read the app's window frame.
        let candidate: NSScreen?
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let screen = screenForApp(pid: frontApp.processIdentifier) {
            candidate = screen
        } else {
            candidate = NSScreen.main
        }
        guard let target = candidate else { return }
        if target == detector.screen { return }
        detector.refresh(on: target)
    }

    /// Find the screen containing the largest portion of any of the
    /// app's on-screen windows. Uses CGWindowList — no AX permission
    /// required for reading window bounds.
    private func screenForApp(pid: pid_t) -> NSScreen? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Find the first on-screen window owned by this PID.
        for info in windowList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t, ownerPid == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0
            else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            // CGWindowList uses top-left-origin display coords (Quartz).
            // NSScreen.frame uses bottom-left-origin AppKit coords.
            // For "which screen contains this window?" we just need to
            // check intersection — convert via flipping.
            if let screen = NSScreen.screens.first(where: { screen in
                let screenFrame = screen.frame
                let primaryScreen = NSScreen.screens.first ?? screen
                let primaryHeight = primaryScreen.frame.height
                let flippedY = primaryHeight - bounds.maxY
                let appKitBounds = CGRect(x: bounds.minX, y: flippedY, width: bounds.width, height: bounds.height)
                return screenFrame.intersects(appKitBounds)
            }) {
                return screen
            }
        }
        return nil
    }

    // Idle: mouse enabled only over explicit hit regions, no key.
    // Expanded: mouse enabled over the visible KLO surface, can become key.
    // Working: mouse enabled only over the cancel target, no key.
    private func applyModeToPanel(_ mode: KLOState.Mode) {
        let allowsKey: Bool
        var ignoresMouse: Bool
        switch mode {
        case .idle:
            allowsKey = false
            // Idle must not create a browser dead zone under the notch.
            // Only suspend mouse passthrough while an actual idle CTA is
            // visible (sidecar retry / extension nudge). The dormant notch
            // itself opens via the global hotkey, not by eating clicks.
            let hasIdleCTA = SidecarLauncher.shared.health == .failed
                || Self.extensionNudgeVisible(bridgeStatus: bridgeStatus)
            ignoresMouse = !hasIdleCTA
        case .textExpanded, .voiceExpanded, .completed, .failed, .failedExtensionMissing, .paywallRequired, .permissionRequired, .signInRequired, .confirmingAction, .webPane, .offerSaveCredential, .connections, .scheduleConfirm, .workspaceInitiated, .workspaceApproval:
            // Result/failed/paywall/permission/confirm/web/connections/
            // scheduleConfirm panels need to be key so Escape collapses
            // them and CTAs receive input.
            allowsKey = true
            ignoresMouse = false
        case .working, .resuming:
            // Working = klo is thinking. Resuming = "Continuing your
            // request…" pill shown right after a permission grant. Both
            // render the free-floating fire + activity bubbles (no chrome),
            // which hang from the notch over a large slice of the
            // top-middle. We keep mouse events ENABLED here and let
            // PassthroughHostingView decide per-pixel: the fire + bubbles
            // are `.allowsHitTesting(false)` so every click over them falls
            // through to the app the user is working in, while the small
            // Cancel ✕ stays clickable. (Esc still hard-stops the run.)
            // This is what fixes the "can't click the top-middle while klo
            // works" report — the old `ignoresMouse = true` relied on the
            // window-level flag being honored, which it wasn't reliably.
            allowsKey = false
            ignoresMouse = false
        }
        // OVERRIDE: while an Apple TCC consent dialog is visible, force
        // mouse pass-through regardless of mode. Otherwise clicks on
        // "Allow" / "Don't Allow" that fall within the notch panel's
        // 1000×700 frame get eaten by klo. The SwiftUI overlay dims
        // its content separately (via SystemDialogObserver env object)
        // so the user can actually see the system dialog.
        if SystemDialogObserver.shared.systemDialogVisible {
            ignoresMouse = true
        }
        panel.allowsKey = allowsKey
        panel.ignoresMouseEvents = ignoresMouse
        if allowsKey && !SystemDialogObserver.shared.systemDialogVisible {
            panel.makeKey()
        }
    }

    private static func activeHitTestRegions(
        state: KLOState,
        detector: NotchDetector,
        bridgeStatus: BridgeStatusManager,
        bounds: NSRect,
    ) -> [NSRect] {
        let mode = state.mode
        let hasNotch = detector.geometry.hasNotch
        let dims = surfaceDimensions(state: state, detector: detector)

        switch mode {
        case .idle:
            var regions: [NSRect] = []
            // Idle banners live below the notch surface. Keep these
            // approximate but intentionally tight; the visual pills are
            // centered and under 340pt wide.
            if SidecarLauncher.shared.health == .failed || extensionNudgeVisible(bridgeStatus: bridgeStatus) {
                let topInset = hasNotch ? detector.geometry.height + 4 + 12 : 42
                regions.append(topAnchoredRect(width: 360, height: 48, topInset: topInset, bounds: bounds))
            }
            return regions
        case .working, .resuming:
            // Only the cancel X in FireBubblesView should catch clicks.
            // Fire and activity bubbles remain click-through.
            let surface = surfaceHitRegion(dims: dims, detector: detector, bounds: bounds)
            return [
                NSRect(
                    x: surface.maxX - 76,
                    y: surface.maxY - 48,
                    width: 76,
                    height: 48,
                ),
            ]
        default:
            return [surfaceHitRegion(dims: dims, detector: detector, bounds: bounds)]
        }
    }

    private static func surfaceHitRegion(
        dims: CGSize,
        detector: NotchDetector,
        bounds: NSRect,
    ) -> NSRect {
        if detector.geometry.hasNotch {
            return topAnchoredRect(
                width: dims.width,
                height: detector.geometry.height + 4 + dims.height,
                topInset: 0,
                bounds: bounds,
            )
        }
        return topAnchoredRect(width: dims.width, height: dims.height, topInset: 16, bounds: bounds)
    }

    private static func topAnchoredRect(
        width: CGFloat,
        height: CGFloat,
        topInset: CGFloat,
        bounds: NSRect,
    ) -> NSRect {
        let clampedWidth = min(width, bounds.width)
        let clampedHeight = min(height, bounds.height)
        return NSRect(
            x: bounds.midX - clampedWidth / 2,
            y: bounds.maxY - topInset - clampedHeight,
            width: clampedWidth,
            height: clampedHeight,
        )
    }

    private static func surfaceDimensions(state: KLOState, detector: NotchDetector) -> CGSize {
        let g = detector.geometry
        let baseExtra: CGFloat = 16
        switch state.mode {
        case .idle:
            return CGSize(width: g.width + baseExtra, height: max(3, CGFloat(13) * 0.45))
        case .textExpanded:
            if state.showingHistory {
                return CGSize(width: 760, height: 420)
            }
            var height: CGFloat = 100
            if !state.messages.isEmpty { height += 54 }
            if !state.proactiveCards.isEmpty { height += 46 }
            if !state.mirrorPickup.isEmpty && state.messages.isEmpty { height += 38 }
            return CGSize(width: 760, height: height)
        case .voiceExpanded:
            return CGSize(width: 760, height: 100)
        case .working, .resuming:
            return CGSize(width: 720, height: 220)
        case .completed:
            return state.transcriptExpanded
                ? CGSize(width: 920, height: 580)
                : CGSize(width: 760, height: 480)
        case .failed, .failedExtensionMissing:
            return CGSize(width: 760, height: 480)
        case .paywallRequired:
            return CGSize(width: 760, height: 420)
        case .permissionRequired:
            return CGSize(width: 600, height: 232)
        case .signInRequired:
            return CGSize(width: 600, height: 252)
        case .confirmingAction:
            return CGSize(width: 680, height: 252)
        case .webPane:
            return CGSize(width: 960, height: 620)
        case .offerSaveCredential:
            return CGSize(width: 600, height: 196)
        case .scheduleConfirm:
            return CGSize(width: 760, height: 480)
        case .workspaceInitiated:
            return CGSize(width: 760, height: 220)
        case .workspaceApproval:
            return CGSize(width: 760, height: 320)
        case .connections:
            return CGSize(width: 760, height: 580)
        }
    }

    /// Mirror of KLOOverlayView.showsExtensionNudge — the idle nudge
    /// pill carries clickable controls (Get extension, dismiss), so
    /// the hit-region list must include the pill while it's visible.
    /// Keep this condition in sync with the SwiftUI view.
    private static func extensionNudgeVisible(bridgeStatus: BridgeStatusManager) -> Bool {
        SidecarLauncher.shared.health == .healthy
            && CloudOnboardingCard.hasCompleted
            && !bridgeStatus.extensionConnected
            && !UserDefaults.standard.bool(forKey: "klo.extensionNudgeDismissed")
    }

    /// Re-apply mode-derived panel attributes whenever the observer
    /// flips. This is what enforces the "force-passthrough while a
    /// system dialog is up" override above — when the dialog dismisses,
    /// the next call reverts to the mode's normal value.
    /// Re-apply mode-derived panel attributes when sidecar health
    /// flips — the idle case's mouse pass-through depends on whether
    /// the "klo agent unavailable — Retry" banner is up.
    private func bindSidecarHealth() {
        SidecarLauncher.shared.$health
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.applyModeToPanel(self.state.mode)
            }
            .store(in: &cancellables)
        // Extension nudge visibility inputs: bridge connection status
        // and the dismissed flag (UserDefaults — flips when the user
        // clicks Get extension or the X). Both must restore idle
        // pass-through the moment the pill disappears.
        bridgeStatus.$extensionConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.applyModeToPanel(self.state.mode)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.applyModeToPanel(self.state.mode)
            }
            .store(in: &cancellables)
    }

    private func bindSystemDialogVisibility() {
        SystemDialogObserver.shared.$systemDialogVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.applyModeToPanel(self.state.mode)
            }
            .store(in: &cancellables)
    }

    /// Hide the notch panel completely while the orchestrator is
    /// awaiting a TCC grant in System Settings. Stronger than the
    /// SystemDialogObserver fade — that was for transient Apple
    /// dialogs (a few seconds); this is for a multi-second user
    /// interaction with the Settings window where the notch's
    /// 1000×700pt frame would otherwise eat clicks on the toggle
    /// in the Accessibility / Screen Recording pane.
    ///
    /// Restore on `.idle` (user cancelled) or `.granted` (success).
    /// The orchestrator's `handleGranted` calls `state.noteAutoRetry`
    /// before firing its retry closure, so the panel reappears
    /// carrying the "Continuing your request…" pill instead of an
    /// empty surface.
    private func bindGrantPhase() {
        PermissionGrantOrchestrator.shared.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self = self else { return }
                switch phase {
                case .awaiting:
                    self.panel.orderOut(nil)
                case .idle, .granted:
                    // Reposition first so the panel comes back at the
                    // correct notch geometry (covers display swap, lid
                    // changes during the grant flow).
                    self.repositionForCurrentScreen(animated: false)
                    self.panel.orderFrontRegardless()
                    // Re-apply mode-derived attrs now that the panel
                    // is visible again — the mode may have flipped to
                    // .resuming while it was hidden.
                    self.applyModeToPanel(self.state.mode)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Positioning

    /// Anchor the panel to the notch (or top-center on no-notch displays).
    /// Window x is centered on the screen's horizontal midpoint — the
    /// hardware notch on every built-in MacBook display is centered on
    /// that midpoint, so this is exact and avoids rounding error from
    /// deriving the notch position via auxiliaryTopLeftArea.maxX (which
    /// can include a sub-point margin for the rounded screen corner).
    /// Window y is anchored so the top of the window aligns with the top
    /// of the screen, putting the notch line at exactly
    /// safeAreaInsets.top from the top.
    private func repositionForCurrentScreen(animated: Bool) {
        guard let screen = detector.screen ?? NSScreen.main else { return }
        let screenFrame = screen.frame   // origin: bottom-left of display

        // The built-in MacBook display centers the hardware notch on the
        // screen's midX. Using midX directly is more reliable than
        // computing notchOriginX + notchWidth/2 from auxiliary areas.
        let anchorCenterX = screenFrame.midX

        let originX = anchorCenterX - Self.windowWidth / 2
        // AppKit's NSWindow.setFrame uses bottom-left origin. We want the
        // top of the window flush with the top of the screen so SwiftUI
        // can lay out everything DOWN from y=windowHeight (which sits at
        // the screen's top edge).
        let originY = screenFrame.maxY - Self.windowHeight

        let frame = NSRect(x: originX, y: originY, width: Self.windowWidth, height: Self.windowHeight)
        NSLog("KLO: repositioning panel — screen=\(Int(screenFrame.width))×\(Int(screenFrame.height)) midX=\(anchorCenterX) windowOriginX=\(originX) windowWidth=\(Self.windowWidth)")
        if animated {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
