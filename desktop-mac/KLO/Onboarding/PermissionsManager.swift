import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Security

/// Tracks the four macOS permissions klo needs and lets the user
/// trigger the OS prompts from the onboarding UI:
///
///   - Accessibility: drive the cursor and synthesise key events
///   - Screen Recording: capture the screen for the model to see
///   - AppleEvents: drive scriptable apps (Notes, Calendar, Music, …)
///   - Microphone: voice mode (optional — user can skip)
///
/// macOS doesn't surface a callback for any of these except the
/// microphone — for the others we re-poll on a 1.5s timer so the UI
/// can update without the user having to leave the app and come back.
@MainActor
final class PermissionsManager: ObservableObject {

    enum Status: Equatable {
        case notRequested  // never prompted (or we can't tell)
        case granted
        case denied
    }

    @Published private(set) var accessibility: Status = .notRequested
    @Published private(set) var screenRecording: Status = .notRequested
    @Published private(set) var appleEvents: Status = .notRequested
    @Published private(set) var microphone: Status = .notRequested

    /// Snapshotted in init(): was Screen Recording already granted at
    /// app launch? macOS requires a process restart for a fresh SR
    /// grant to take effect — but only when the grant happened
    /// in-session. If it was already granted at launch, no restart is
    /// needed. The coordinator reads this to decide whether to relaunch
    /// after observing SR flip to .granted.
    let wasScreenRecordingGrantedAtLaunch: Bool

    /// Convenience: are BOTH required permissions granted? Apple Events,
    /// Microphone, and the Chrome extension are all optional today —
    /// the agent's only hard dependencies are Accessibility (cursor +
    /// key synthesis) and Screen Recording (screenshots). Apple Events
    /// is read-only osascript queries and fails gracefully; Microphone
    /// is voice-mode opt-in.
    var requiredAllGranted: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    /// Durable "we have seen these granted at least once on this Mac"
    /// signal — persisted to UserDefaults the moment a permission
    /// flips to `.granted`, never unset. Used by the cloud's initial-
    /// step picker so a brief TCC propagation race after relaunch
    /// (common after the SR auto-relaunch, and after Debug rebuilds
    /// where cdhash drift can lose trust) doesn't drop the user back
    /// on the Permissions card despite having just granted everything.
    ///
    /// If TCC then disagrees at runtime (cdhash drift, user revoked),
    /// `CloudPermissionsStep`'s stale-grant hint surfaces immediately
    /// — diagnostic instead of a confused "fresh prompt."
    static let hasGrantedAccessibilityKey  = "klo.hasGrantedAccessibility"
    static let hasGrantedScreenRecordingKey = "klo.hasGrantedScreenRecording"

    var hasEverGrantedAccessibility: Bool {
        UserDefaults.standard.bool(forKey: Self.hasGrantedAccessibilityKey)
    }

    var hasEverGrantedScreenRecording: Bool {
        UserDefaults.standard.bool(forKey: Self.hasGrantedScreenRecordingKey)
    }

    var requiredEverGranted: Bool {
        hasEverGrantedAccessibility && hasEverGrantedScreenRecording
    }

    /// "We've granted before, but live TCC says no right now." The
    /// canonical stale-grant state on dev builds (ad-hoc Debug signing
    /// produces a new cdhash on every xcodebuild; macOS TCC binds
    /// grants to cdhash + designated requirement, so the new binary
    /// reads as untrusted even though System Settings UI may still
    /// list klo as enabled). Surfaced to the onboarding card to
    /// trigger a one-click `resetAndReprompt()` instead of the
    /// generic "grant me permissions" step the user has already
    /// completed once.
    var requiredStaleGrant: Bool {
        requiredEverGranted && !requiredAllGranted
    }

    // MARK: - cdhash tracking (Debug-build drift detection)

    /// SHA-256 cdhash of the currently running binary, hex-encoded.
    /// Read once at init via Security.framework. Compared against the
    /// cdhash that was last persisted when both required permissions
    /// landed `.granted` — if they differ, we know the user's prior
    /// grant doesn't apply to this build and surface the stale-hint
    /// + re-bind path immediately on the permissions card.
    private(set) var currentCDHash: String?

    static let lastGrantedCDHashKey = "klo.lastGrantedCDHash"

    var lastGrantedCDHash: String? {
        UserDefaults.standard.string(forKey: Self.lastGrantedCDHashKey)
    }

    /// True when we've previously persisted a cdhash at grant-time and
    /// the current binary's cdhash differs from it. Used to skip the
    /// 12s timeout in CloudPermissionsStep and surface the stale-hint
    /// immediately on launch.
    var hasCDHashDrifted: Bool {
        guard let last = lastGrantedCDHash, let curr = currentCDHash else { return false }
        return last != curr
    }

    private static func readCurrentCDHash() -> String? {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        guard copyStatus == errSecSuccess, let code = code else {
            NSLog("KLO Permissions: SecCodeCopySelf failed status=\(copyStatus)")
            return nil
        }
        // SecCode and SecStaticCode are toll-free bridged CF types; the
        // Swift signature for SecCodeCopySigningInformation wants the
        // static variant. Bridge via unsafeBitCast — same memory, no
        // retain dance, no Unmanaged ceremony.
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard infoStatus == errSecSuccess,
              let dict = info as? [String: Any],
              let data = dict[kSecCodeInfoUnique as String] as? Data else {
            NSLog("KLO Permissions: SecCodeCopySigningInformation failed status=\(infoStatus)")
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private var poller: AnyCancellable?

    /// Higher-frequency poller, only active during a handoff
    /// (coordinator's .dimmedAwaiting state). Bumps detection latency
    /// from 1.5s → ~0.4s so the user toggles a permission and the
    /// reminder pill flips to "Granted!" almost immediately.
    private var rapidPoller: AnyCancellable?

    init() {
        // Snapshot SR's launch-time state before the first refresh.
        // The coordinator observes our @Published $screenRecording and
        // compares against this flag to decide whether to fire a
        // relaunch — if SR was already granted at launch, the running
        // process has a working grant and no transition is happening,
        // so no relaunch is needed.
        wasScreenRecordingGrantedAtLaunch = CGPreflightScreenCaptureAccess()
        currentCDHash = Self.readCurrentCDHash()
        if let cd = currentCDHash {
            let prev = UserDefaults.standard.string(forKey: Self.lastGrantedCDHashKey)
            NSLog("KLO Permissions: currentCDHash=\(cd.prefix(16))… lastGranted=\(prev?.prefix(16).description ?? "nil") drifted=\(prev != nil && prev != cd)")
        }
        refresh()
        // Poll every 1.5s while the manager is alive so the cards
        // update once the user grants something via System Settings.
        poller = Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    deinit {
        poller?.cancel()
        rapidPoller?.cancel()
    }

    /// Start the high-frequency poller. Called by the coordinator when
    /// a handoff begins. Idempotent — calling twice is safe; only one
    /// rapid poller runs at a time.
    func beginRapidPolling() {
        guard rapidPoller == nil else { return }
        rapidPoller = Timer.publish(every: 0.4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Stop the high-frequency poller. Called when the handoff ends
    /// (cloud restored). Idempotent.
    func endRapidPolling() {
        rapidPoller?.cancel()
        rapidPoller = nil
    }

    // MARK: - Refresh (read current state)

    func refresh() {
        accessibility   = currentAccessibility()
        screenRecording = currentScreenRecording()
        appleEvents     = currentAppleEvents()
        microphone      = currentMicrophone()

        // Durably flag any granted permission so the next launch can
        // route correctly even if TCC propagation is briefly racy. Set-
        // only, never cleared — see `hasEverGrantedAccessibility`.
        if accessibility == .granted,
           !UserDefaults.standard.bool(forKey: Self.hasGrantedAccessibilityKey) {
            UserDefaults.standard.set(true, forKey: Self.hasGrantedAccessibilityKey)
        }
        if screenRecording == .granted,
           !UserDefaults.standard.bool(forKey: Self.hasGrantedScreenRecordingKey) {
            UserDefaults.standard.set(true, forKey: Self.hasGrantedScreenRecordingKey)
        }
        // Persist the cdhash at the moment both required permissions
        // land granted — that's the "working binding" snapshot. On the
        // next launch we compare current cdhash to this; a mismatch
        // means we know the prior grant is stale (Debug rebuild,
        // tccutil reset, etc.) and the onboarding step can surface
        // the re-bind UI immediately rather than waiting on a timer.
        if requiredAllGranted, let cd = currentCDHash {
            let prev = UserDefaults.standard.string(forKey: Self.lastGrantedCDHashKey)
            if prev != cd {
                UserDefaults.standard.set(cd, forKey: Self.lastGrantedCDHashKey)
                NSLog("KLO Permissions: persisted lastGrantedCDHash=\(cd.prefix(16))…")
            }
        }
    }

    /// User-triggered explicit recheck — same as `refresh()` but logs
    /// the actual OS return values verbosely so we can debug stale
    /// grants from Console.app. Common cause of "klo can't see my
    /// grant": Debug rebuilds change klo's cdhash and macOS doesn't
    /// transfer the trust grant to the new binary identity. The user
    /// has to toggle the permission off then back on in System
    /// Settings to re-bind the grant to the new identity.
    func forceRecheck() {
        let ax = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        )
        let sr = CGPreflightScreenCaptureAccess()
        NSLog("KLO Permissions: forceRecheck — AX=\(ax) SR=\(sr) (was AX=\(accessibility) SR=\(screenRecording))")
        refresh()
        NSLog("KLO Permissions: after refresh — accessibility=\(accessibility) screenRecording=\(screenRecording) requiredAllGranted=\(requiredAllGranted)")
    }

    // MARK: - Stale-grant recovery

    /// Reset klo's TCC entries for Accessibility + Screen Recording,
    /// clear the durable "ever granted" flags, then re-prompt so the
    /// user sees the system AX modal again and System Settings shows
    /// klo as an un-toggled (or freshly-added) row. The canonical
    /// recovery from the Debug-build cdhash-drift state where macOS
    /// thinks klo is trusted-for-an-old-binary but not the running one.
    ///
    /// `/usr/bin/tccutil reset <service> <bundleID>` works without
    /// sudo in user context for system-domain services (we verified
    /// earlier this session: returned "Successfully reset"). Synchronous
    /// + fast; we still run it off the main actor to avoid stalling the
    /// SwiftUI body even briefly.
    func resetAndReprompt() async {
        NSLog("KLO Permissions: resetAndReprompt — starting")
        let result = await Task.detached(priority: .userInitiated) {
            (
                Self.runTCCResetSync(service: "Accessibility"),
                Self.runTCCResetSync(service: "ScreenCapture")
            )
        }.value
        NSLog("KLO Permissions: tccutil reset done — Accessibility=\(result.0) ScreenCapture=\(result.1)")

        // Back on @MainActor (we never left, the detached task ran off-actor
        // but its `.value` re-enters our actor context).
        // Wipe the durable signals that say "we've been granted before"
        // — they were telling the truth about a different cdhash.
        UserDefaults.standard.removeObject(forKey: Self.hasGrantedAccessibilityKey)
        UserDefaults.standard.removeObject(forKey: Self.hasGrantedScreenRecordingKey)
        UserDefaults.standard.removeObject(forKey: Self.didShowAXPromptKey)
        UserDefaults.standard.removeObject(forKey: Self.lastGrantedCDHashKey)

        // Re-register klo with TCC. requestAccessibility() pops the OS
        // modal once (because we just cleared didShowAXPromptKey).
        // requestScreenRecording() is silent but ensures klo appears as
        // a row in System Settings → Screen Recording.
        requestAccessibility()
        requestScreenRecording()
        forceRecheck()
    }

    // nonisolated so the Task.detached call site can invoke it without
    // hopping back to @MainActor (the static would otherwise inherit
    // the class's @MainActor isolation). Touches no instance state.
    private nonisolated static func runTCCResetSync(service: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, "com.klo.KLO"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            NSLog("KLO Permissions: tccutil reset \(service) → status=\(p.terminationStatus) out=\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            return p.terminationStatus == 0
        } catch {
            NSLog("KLO Permissions: tccutil reset \(service) failed to spawn: \(error)")
            return false
        }
    }

    private func currentAccessibility() -> Status {
        // Check WITHOUT prompting (prompt happens in requestAccessibility).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts) ? .granted : .notRequested
    }

    private func currentScreenRecording() -> Status {
        // CGPreflightScreenCaptureAccess returns true only after the
        // OS has been prompted at least once AND the user granted.
        return CGPreflightScreenCaptureAccess() ? .granted : .notRequested
    }

    private func currentAppleEvents() -> Status {
        // Probing AppleEvents permission cleanly is tricky — the OS
        // only records "granted/denied" per scriptable target. For the
        // onboarding flow we treat "not yet probed" as not requested
        // and leave it to the request flow to flip the state.
        // (We could fall back to NSWorkspace.shared.runningApplications
        // and request System Events specifically — that's what
        // requestAppleEvents() does.)
        return appleEvents == .granted ? .granted : .notRequested
    }

    private func currentMicrophone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .notRequested
        }
    }

    // MARK: - Request flows

    /// Registers klo in the Accessibility privacy list so the user
    /// can find + toggle the klo row when they open System Settings.
    /// Calling `AXIsProcessTrustedWithOptions(prompt: true)` is
    /// REQUIRED on the first run — without it, klo never appears in
    /// the list and the user opens Settings to find nothing to toggle.
    ///
    /// HOWEVER: `prompt: true` ALSO pops a generic OS-level alert
    /// ("klo would like to control this computer using accessibility
    /// features") which is redundant on top of our custom cloud UI
    /// and reads as noise to the user. After the first call has
    /// registered klo in the TCC list, subsequent calls should use
    /// `prompt: false` (silent check). We persist a flag the first
    /// time we prompt and never prompt again from this code path.
    ///
    /// Does NOT open System Settings here — the coordinator handles
    /// URL opening + app activation in one atomic call to avoid the
    /// race conditions we hit before (multiple competing open
    /// requests landing System Settings behind our window).
    static let didShowAXPromptKey = "klo.didShowAccessibilityPrompt"
    func requestAccessibility() {
        let alreadyPrompted = UserDefaults.standard.bool(forKey: Self.didShowAXPromptKey)
        // If we've prompted before (or AX is already granted), use the
        // silent check. Only the first ever call gets prompt=true.
        let shouldPrompt = !alreadyPrompted && accessibility != .granted
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): shouldPrompt] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if shouldPrompt {
            UserDefaults.standard.set(true, forKey: Self.didShowAXPromptKey)
        }
    }

    /// Registers klo in the Screen Recording privacy list. Silent — no
    /// dialog shown for SR (unlike Accessibility). Required first call
    /// before klo appears as an entry the user can toggle.
    ///
    /// Does NOT open System Settings here (see `requestAccessibility`
    /// rationale).
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Probes AppleEvents permission against System Events — a benign
    /// scriptable app every Mac has installed. The first call shows
    /// the system prompt; subsequent calls just return the recorded
    /// state.
    func requestAppleEvents() {
        let target = NSAppleEventDescriptor(
            bundleIdentifier: "com.apple.systemevents"
        )
        let result = AEDeterminePermissionToAutomateTarget(
            target.aeDesc!,
            typeWildCard,
            typeWildCard,
            true  // askUserIfNeeded
        )
        if result == noErr {
            appleEvents = .granted
        } else if result == errAEEventNotPermitted {
            appleEvents = .denied
        } else {
            // -1744 is "user has not been asked" — leave as notRequested.
            appleEvents = .notRequested
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.microphone = granted ? .granted : .denied
            }
        }
    }
}
