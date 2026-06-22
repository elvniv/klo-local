import AppKit
import AVFoundation
import Combine
import Foundation

/// Single source of truth for "is the SIDECAR's TCC trust live right now?"
///
/// Why this exists: granting "klo" in System Settings → Accessibility
/// trusts the Mac app's binary, but the agent's click/type tools run
/// inside the SIDECAR (a separate PyInstaller binary at
/// `KLO.app/Contents/Resources/klo-sidecar/klo-sidecar` with its own
/// cdhash). The OS attributes Accessibility trust to the binary that
/// posts the CGEvent → so the SIDECAR's `AXIsProcessTrusted()` is
/// what actually gates the agent. Asking the Mac app's own
/// `AXIsProcessTrusted()` is the WRONG question.
///
/// PermissionMonitor solves that by reading the sidecar's `/health`
/// endpoint (which the sidecar already exposes via its own
/// `AXIsProcessTrusted()` call). One @Published `Status` per service
/// — that's the truth source for both onboarding routing and runtime
/// grant detection.
///
/// Replaces the previous `PermissionsManager` whose state was a
/// snapshot of the Mac app's TCC view, durable UserDefaults flags,
/// and cdhash bookkeeping — all four of which could desync from
/// each other AND from the actual gate.
@MainActor
final class PermissionMonitor: ObservableObject {

    enum Status: Equatable {
        case unknown      // never polled, or sidecar unreachable
        case granted
        case notGranted
    }

    /// Mirrors `_permission_denied_payload(service)` in agent2/tools.py
    /// so the Mac app and sidecar agree on the wire format.
    enum Service: String, Equatable, CaseIterable {
        case accessibility   = "accessibility"
        case screenRecording = "screen_recording"
        case appleEvents     = "apple_events"

        /// Display name used in surface copy ("klo needs Accessibility for that").
        var displayName: String {
            switch self {
            case .accessibility:    return "Accessibility"
            case .screenRecording:  return "Screen Recording"
            case .appleEvents:      return "Automation (Apple Events)"
            }
        }

        /// Privacy-pane deep-link URL.
        var settingsURL: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .appleEvents:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
            }
        }
    }

    static let shared = PermissionMonitor()

    @Published private(set) var accessibility:   Status = .unknown
    @Published private(set) var screenRecording: Status = .unknown
    @Published private(set) var appleEvents:     Status = .unknown
    @Published private(set) var microphone:      Status = .unknown

    /// Both required permissions live + confirmed by the sidecar.
    /// Use this in onboarding routing INSTEAD of the old
    /// `requiredEverGranted` durable-flag check — the durable flags
    /// can survive cdhash drift / `tccutil reset`, leading to false
    /// "you've already granted, skip the permissions step" routing.
    var requiredAllLive: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    // ─── Polling ──────────────────────────────────────────────────────

    private let healthURL = URL(string: "http://127.0.0.1:8787/health")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 1.5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private var poller: AnyCancellable?
    /// Fast poller used while a grant flow is active — drops detection
    /// latency from 1.5s to 0.4s. Started by `beginRapidPolling()`,
    /// stopped by `endRapidPolling()`.
    private var rapidPoller: AnyCancellable?

    /// NSWorkspace observer that fires when klo regains frontmost
    /// status. The natural moment after the user finishes in System
    /// Settings — perfect for an immediate refresh that catches the
    /// grant without waiting for the next poll tick.
    private var activationObserver: NSObjectProtocol?

    private init() {
        // Microphone trust is in-process and per-app, not cross-process,
        // so we read it directly here. (It's not on the sidecar's path.)
        microphone = Self.readMicrophoneStatus()
        // Slow poller starts immediately — we want a baseline as soon
        // as the sidecar comes up.
        poller = Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
        // Fire one tick immediately so the UI doesn't sit on .unknown.
        Task { @MainActor in self.tick() }

        // Catch the post-Settings moment: when klo becomes frontmost
        // again, the user just left Settings (probably after toggling).
        // Force a refresh so we see the grant within one runloop tick
        // instead of waiting up to 400ms for the next poll.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == "com.klo.KLO"
            else { return }
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let token = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// Public helper for callers (e.g. PermissionGrantOrchestrator's
    /// pre-flight cdhash-drift check) that need the current cached
    /// status for a service WITHOUT triggering a new poll.
    func statusFor(_ service: Service) -> Status {
        switch service {
        case .accessibility:    return accessibility
        case .screenRecording:  return screenRecording
        case .appleEvents:      return appleEvents
        }
    }

    // MARK: - Refresh + signal hooks

    /// Force an immediate refresh — typically called after a wake-from-
    /// sleep or after we've nudged the user to grant something.
    func refresh() {
        tick()
        microphone = Self.readMicrophoneStatus()
    }

    /// Speed up polling. Called when the orchestrator opens System
    /// Settings, so a grant lands in ~0.4s instead of ~1.5s.
    func beginRapidPolling() {
        guard rapidPoller == nil else { return }
        rapidPoller = Timer.publish(every: 0.4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func endRapidPolling() {
        rapidPoller?.cancel()
        rapidPoller = nil
    }

    /// Called by AgentClient when a `status_change` event carries
    /// `error_code == "permission_denied"`. The sidecar just told us
    /// directly that this service is blocked — no need to wait for
    /// the next poll. Flip the published status immediately so any
    /// observers (the orchestrator's grant-watch publisher) react.
    func noteDenialFromSidecar(_ service: Service) {
        switch service {
        case .accessibility:
            if accessibility != .notGranted { accessibility = .notGranted }
        case .screenRecording:
            if screenRecording != .notGranted { screenRecording = .notGranted }
        case .appleEvents:
            if appleEvents != .notGranted { appleEvents = .notGranted }
        }
    }

    // MARK: - Tick (poll sidecar /health)

    private func tick() {
        Task { [weak self] in
            await self?.poll()
        }
    }

    private func poll() async {
        do {
            let (data, _) = try await session.data(from: healthURL)
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let subsystems = json["subsystems"] as? [String: Any]
            else { return }
            // Sidecar emits "trusted" / "untrusted" / "unknown" for
            // accessibility_api. Anything we can't parse stays as the
            // last value (safer than flipping back to .unknown on a
            // single bad payload).
            if let raw = subsystems["accessibility_api"] as? String {
                let next = Self.statusFromString(raw, trustedKey: "trusted", deniedKey: "untrusted")
                await MainActor.run {
                    if let next = next, self.accessibility != next {
                        self.accessibility = next
                    }
                }
            }
            // Sidecar doesn't currently expose a screen_recording flag
            // in /health; we infer from CGPreflightScreenCaptureAccess
            // here in-process. The sidecar's SR check happens at tool-
            // dispatch time and emits a `permission_denied` event we
            // catch via `noteDenialFromSidecar`. So this Mac-side read
            // is just a baseline / hint, not the gate.
            let srGranted = CGPreflightScreenCaptureAccess()
            let srNext: Status = srGranted ? .granted : .notGranted
            await MainActor.run {
                if self.screenRecording != srNext { self.screenRecording = srNext }
            }
        } catch {
            // Sidecar unreachable — leave statuses alone (stale is
            // better than fluctuating to .unknown on every transient
            // network blip).
        }
    }

    // MARK: - Helpers

    private static func statusFromString(_ raw: String, trustedKey: String, deniedKey: String) -> Status? {
        let s = raw.lowercased()
        if s == trustedKey   { return .granted }
        if s == deniedKey    { return .notGranted }
        return nil
    }

    private static func readMicrophoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:                return .granted
        case .denied, .restricted:       return .notGranted
        case .notDetermined:             return .unknown
        @unknown default:                return .unknown
        }
    }
}


// MARK: - Bridge to legacy KLOState.PermissionService

extension PermissionMonitor.Service {
    /// Map to the legacy state-machine enum the notch UI uses to
    /// render `.permissionRequired`. Keeps the existing notch
    /// surfaces working while we migrate call sites incrementally.
    var kloStateService: KLOState.PermissionService {
        switch self {
        case .accessibility:    return .accessibility
        case .screenRecording:  return .screenRecording
        case .appleEvents:      return .appleEvents
        }
    }

    init?(_ kloState: KLOState.PermissionService) {
        switch kloState {
        case .accessibility:    self = .accessibility
        case .screenRecording:  self = .screenRecording
        case .appleEvents:      self = .appleEvents
        }
    }
}
