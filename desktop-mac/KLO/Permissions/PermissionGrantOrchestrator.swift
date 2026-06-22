import AppKit
import Combine
import Foundation

/// Single grant flow used by BOTH onboarding and runtime denials.
///
/// Replaces:
///   - `KLOOverlayView.handleGrantPermission` + `isPermissionLive` +
///     `handoffForService` + `startRuntimePermissionWatcher` +
///     `permissionWatcher` Timer + the runtime `onChange(state.mode)`
///     auto-retry branches.
///   - The permission half of `OnboardingFocusCoordinator.requestHandoff`
///     + `observeForCompletion(.accessibility/.screenRecording)`.
///
/// Both paths used to run their own poll loop, both raced against the
/// same shared `AppDragIslandWindowController.shared`. Now there's
/// one orchestrator — caller passes a `retry` closure that knows what
/// to do once the grant lands. Runtime passes
/// `{ agentClient.submitQuery(query) }`; onboarding passes the next-
/// step advance.
@MainActor
final class PermissionGrantOrchestrator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case awaiting(PermissionMonitor.Service)
        case granted(PermissionMonitor.Service)
    }

    static let shared = PermissionGrantOrchestrator()

    @Published private(set) var phase: Phase = .idle

    /// The retry closure isn't part of `Phase` (closures aren't
    /// Equatable) — kept as a sibling. Cleared whenever phase ends.
    private var pendingRetry: (() -> Void)?

    private var grantSubscription: AnyCancellable?
    private var timeoutTask: Task<Void, Never>?

    /// Cap the watch so we don't poll forever if the user wanders off.
    private static let timeoutSeconds: TimeInterval = 300  // 5 min

    /// Services we've already called the native `*RequestAccess` /
    /// `AXIsProcessTrustedWithOptions(prompt:true)` API for since the
    /// process started. These APIs show macOS's consent dialog ONLY on
    /// the first call per process — subsequent calls return silently.
    /// So we branch:
    ///   • First request per service: call the native API alone. Apple's
    ///     dialog appears with an "Open System Settings" button that
    ///     both REGISTERS klo in the Privacy list AND opens Settings
    ///     to the right pane. We don't open Settings ourselves — that
    ///     would race the user's interaction with Apple's dialog and
    ///     they'd land on an empty Privacy list (the bug we just hit).
    ///   • Subsequent requests: native API is silent, so we open
    ///     Settings via the URL deep-link directly as a self-service
    ///     fallback. By this point klo IS in the Privacy list (added
    ///     by the first request's user interaction), so the user
    ///     sees a row they can toggle.
    private var requestedThisProcess: Set<PermissionMonitor.Service> = []

    private init() {}

    // MARK: - Public API

    /// Open Settings + show the drag island for `service`. When the
    /// PermissionMonitor reports the service granted, dismiss the
    /// island, bring klo to the front, and fire `retry`. Caller pre-
    /// fires whatever it wants to retry (e.g. `submitQuery(query)`).
    ///
    /// Idempotent: requesting the same service while already awaiting
    /// it just refreshes the retry closure. Requesting a different
    /// service hands off cleanly to the new flow.
    func request(service: PermissionMonitor.Service, retry: (() -> Void)? = nil) {
        // If we're already awaiting this exact service, just refresh
        // the retry closure (e.g. user clicked Grant a second time).
        if case .awaiting(service) = phase {
            pendingRetry = retry
            return
        }

        // Pre-flight cdhash-drift / stale-cache recovery. The sidecar
        // can momentarily see `permission_denied` for a service that
        // IS actually granted live — usually a TCC cache flake right
        // after a previous grant, or cdhash drift on a freshly-built
        // binary. Force a fresh poll and check; if the monitor reports
        // the service as `.granted`, the denial was a fluke. Skip the
        // entire Settings round-trip and fire the retry directly — the
        // second attempt will see live trust and succeed.
        //
        // If the second attempt ALSO denies, that's a real denial and
        // we'll be re-entered here with a refreshed cache, which falls
        // through to the normal Settings flow below.
        PermissionMonitor.shared.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            // Guard against a competing flow that already entered the
            // .awaiting state between dispatch and now.
            if case .awaiting = self.phase { return }
            if PermissionMonitor.shared.statusFor(service) == .granted {
                NSLog("KLO: pre-flight skipped Settings — \(service.displayName) is already granted live (was a sidecar cache flake)")
                retry?()
                return
            }
            self.startGrantFlow(service: service, retry: retry)
        }
    }

    /// The body of `request()` after the pre-flight has confirmed
    /// we genuinely need to send the user to System Settings.
    private func startGrantFlow(service: PermissionMonitor.Service, retry: (() -> Void)?) {
        // Different service or fresh request — tear down any prior
        // subscription and start a new one.
        cancel()

        pendingRetry = retry
        phase = .awaiting(service)

        // ONE path to grant, not three. This used to call the native
        // API AND open Settings AND show an instruction card — three
        // competing UIs racing each other. The user saw an empty
        // Privacy list (we opened Settings before the native dialog
        // had registered klo) with a redundant "Toggle klo on" card
        // floating on top of Apple's own consent dialog. Stripped to
        // one path per case:
        //
        //   First request per service this process:
        //     Call the native registration API. macOS shows its
        //     consent dialog with an "Open System Settings" button.
        //     Clicking that button does BOTH: registers klo in the
        //     Privacy list and opens Settings to the right pane. We
        //     don't lift a finger — Apple's flow is the flow.
        //
        //   Subsequent requests (native API is silent on repeat):
        //     Open Settings via URL deep-link. By this point klo IS
        //     in the Privacy list (added by the first request), so
        //     the user sees a row they can toggle.
        //
        //   AppleEvents: no native registration API exists (Automation
        //     is per-target-app, granted lazily by tccd on first AE
        //     attempt). Always open Settings via URL.
        let isFirstRequest = !requestedThisProcess.contains(service)
        requestedThisProcess.insert(service)
        switch service {
        case .accessibility:
            if isFirstRequest {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            } else {
                Self.openSettingsAt(service.settingsURL)
            }
        case .screenRecording:
            if isFirstRequest {
                CGRequestScreenCaptureAccess()
            } else {
                Self.openSettingsAt(service.settingsURL)
            }
        case .appleEvents:
            Self.openSettingsAt(service.settingsURL)
        }

        // Speed up PermissionMonitor's polling so the grant lands
        // in ~0.4s instead of ~1.5s. The instruction card / drag
        // island is GONE from this path — Apple's native dialog and
        // the Privacy pane are sufficient guidance.
        PermissionMonitor.shared.beginRapidPolling()

        // 4. Subscribe to the relevant service's status. The moment
        //    it flips .granted, fire celebrate-and-retry.
        let publisher: AnyPublisher<PermissionMonitor.Status, Never>
        switch service {
        case .accessibility:
            publisher = PermissionMonitor.shared.$accessibility.eraseToAnyPublisher()
        case .screenRecording:
            publisher = PermissionMonitor.shared.$screenRecording.eraseToAnyPublisher()
        case .appleEvents:
            publisher = PermissionMonitor.shared.$appleEvents.eraseToAnyPublisher()
        }
        grantSubscription = publisher
            .filter { $0 == .granted }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleGranted(service)
            }

        // 5. Cap the wait so we don't poll forever.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
            await MainActor.run { self?.cancel() }
        }
    }

    /// User-driven cancel — clears the watch and dismisses the island.
    /// Does NOT fire the retry closure.
    func cancel() {
        grantSubscription?.cancel()
        grantSubscription = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        PermissionMonitor.shared.endRapidPolling()
        pendingRetry = nil
        if phase != .idle { phase = .idle }
    }

    // MARK: - Private

    private func handleGranted(_ service: PermissionMonitor.Service) {
        grantSubscription?.cancel()
        grantSubscription = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        PermissionMonitor.shared.endRapidPolling()

        let retry = pendingRetry
        pendingRetry = nil
        phase = .granted(service)

        // Bring klo to the front so the user sees the auto-retry's
        // response materialize without having to ⌘K back in.
        NSApp.activate(ignoringOtherApps: true)

        // Fire the caller's retry closure.
        retry?()

        // Brief celebratory beat then back to idle so subsequent
        // grants can be requested cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if case .granted = self.phase { self.phase = .idle }
        }
    }

    /// Open System Settings at a specific Privacy-pane URL. Uses the
    /// explicit `withApplicationAt:configuration:` form so Settings is
    /// reliably activated AND lands on the right pane even when it was
    /// cold-launched (the bare `NSWorkspace.shared.open(url)` races on
    /// macOS Sequoia and parks at the Privacy & Security root).
    private static func openSettingsAt(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.addsToRecentItems = false
        let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: settingsApp,
            configuration: cfg
        ) { _, _ in }
    }
}
