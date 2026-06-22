import AppKit
import AVFoundation
import Combine

// Owns the lifetime of the singleton window controller, notch detector,
// hotkey manager, agent client, and Vapi bridge. Created once at launch,
// torn down at terminate. Everything else in the app borrows references
// from here.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var notchDetector: NotchDetector?
    private var windowController: KLOWindowController?
    private var hotKeyManager: HotKeyManager?
    private var wispOverlay: WispOverlayWindowController?
    private var state: KLOState?
    private var agentClient: AgentClient?
    private var realtimeBridge: RealtimeBridge?
    private var accountManager: AccountManager?
    private var sidecarLauncher: SidecarLauncher?
    private var bridgeStatus: BridgeStatusManager?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("KLO: applicationDidFinishLaunching")

        // Offer the move to /Applications FIRST — before the ceremony,
        // onboarding, or any TCC prompt. Sequoia only persists grants
        // for apps in /Applications; prompting mid-permission was too
        // late. Skippable, and a decline is remembered.
        if MoveToApplicationsPrompt.promptIfNeeded() {
            // Moving + relaunching from the new path — abort this
            // launch, the relaunch helper takes it from here.
            return
        }

        // Pre-warm klo-cloud. Render free/starter tiers can spin down
        // after 15min idle → ~30s cold start on next request. That cold
        // start lands on the user's first voice/text query, which feels
        // like klo is broken. Fire a fire-and-forget /health hit at
        // launch so the container is warm by the time the user types
        // their first prompt (~2-5s window typical). Failures here are
        // silent on purpose — pre-warm is best-effort, not a gate.
        let healthURL = AccountManager.cloudBase.appendingPathComponent("health")
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 5
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error {
                NSLog("KLO: cloud pre-warm failed — \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                NSLog("KLO: cloud pre-warm OK (HTTP \(http.statusCode))")
            }
        }.resume()

        // Bootstrap Sparkle. Touching the singleton constructs
        // SPUStandardUpdaterController which starts the scheduled
        // check loop. Without this call the framework is dead weight,
        // the situation klo shipped in through 1.1.5. From 1.1.6
        // onward, scheduled checks fire per SUScheduledCheckInterval
        // and surface as an olive arrow above the dormant notch pill
        // (see UpdaterManager + KLOOverlayView). User-initiated
        // checks go through Settings, Check for Updates.
        _ = UpdaterManager.shared

        // Phase A — cheap, no-prompt setup. Only things that won't
        // raise an OS dialog. We need these available before the
        // ceremony so the onboarding-after callback has the account
        // gate to consult and the keyboard-tutorial sink to fire on.
        setupCheapState()

        // Phase B — launch experience. The cloud owns ALL onboarding +
        // sign-in moments; the standalone OnboardingWindow was deleted.
        // `needsCloud` is true for:
        //   1. First launch (cinematic + demo tour + onboarding)
        //   2. Post-SR-restart resume (resume key set; skipCinematic so
        //      we drop into the right card on the same dark cloud)
        //   3. Returning user who quit BEFORE finishing onboarding
        //   4. Signed-out returning user (lands on the cloud sign-in step)
        // Otherwise: a brief "Welcome back." flourish then bootHeavyState.
        guard let accountManager = self.accountManager,
              let bridgeStatus = self.bridgeStatus else {
            return  // setupCheapState always creates them.
        }
        let hasResumeStep = UserDefaults.standard.string(forKey: "klo.onboardingResumeStep") != nil
        // Onboarding "complete" now just means the user finished the
        // first-run ceremony + chrome card. Sign-in moved to a small
        // in-notch island fired from AgentClient.submitQuery when the
        // user actually tries to use klo; permissions moved to a
        // separate inline island fired by the agent's tool-error
        // detector. Neither is a launch gate any more.
        let onboardingComplete = CloudOnboardingCard.hasCompleted
        let needsCloud = !CeremonyWindowController.hasSeenCeremony
            || hasResumeStep
            || !onboardingComplete

        if needsCloud {
            // Consume the resume key so we don't re-enter the cloud
            // on every subsequent launch just because this flag was
            // never cleared. The standalone OnboardingView used to
            // consume it; now the cloud owns the flow, so the cloud
            // entry-point clears it.
            UserDefaults.standard.removeObject(forKey: "klo.onboardingResumeStep")

            // Capture notch geometry once before the cloud experience
            // — we render it inside the cloud at the hardware notch
            // position. Detector itself will be wired into the notch
            // panel later in bootHeavyState.
            let detector = NotchDetector()
            detector.refresh()
            let notchGeometry = detector.geometry

            // skipCinematic: any returning user (already saw the
            // ceremony) skips the cinematic.
            // skipDemoTour: returning user mid-flow ALSO skips the
            // demo tour — they've already seen it and just need to
            // finish remaining onboarding steps. The cloud card
            // picks the correct step on appear.
            let skipCinematic = CeremonyWindowController.hasSeenCeremony
            let skipDemoTour = skipCinematic && !onboardingComplete

            // Eager SidecarLauncher allocation (no startIfNeeded() yet
            // — that happens when the coordinator transitions to the
            // chrome handoff). Allocating just the object is dialog-free;
            // it's the first .startIfNeeded() that triggers Gatekeeper.
            let sidecar = self.sidecarLauncher ?? SidecarLauncher.shared
            self.sidecarLauncher = sidecar

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                CeremonyWindowController.shared.playCloudExperience(
                    account: accountManager,
                    bridge: bridgeStatus,
                    sidecar: sidecar,
                    notchGeometry: notchGeometry,
                    skipCinematic: skipCinematic,
                    skipDemoTour: skipDemoTour
                ) { [weak self] in
                    // Cloud experience fully done — including sign-in
                    // (cloud owns it as a step). Boot the rest of the
                    // app: sidecar, Vapi, notch panel, hotkeys.
                    // No standalone-window fallback: if the user
                    // closed the cloud before signin, the next launch
                    // sees account.isReady == false and re-enters the
                    // cloud at the signin step (gate condition above).
                    self?.bootHeavyState()
                }
            }
        } else {
            // Returning user, onboarding fully complete + signed in.
            // Play the brief "Welcome back." flourish for visual
            // continuity, then boot. The standalone OnboardingWindow
            // is no longer opened from any launch path — signed-out
            // returning users went through the cloud branch above
            // (because !accountManager.isReady forces needsCloud=true).
            let detector = NotchDetector()
            detector.refresh()
            let notchGeometry = detector.geometry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                CeremonyWindowController.shared.playReturningExperience(
                    notchGeometry: notchGeometry,
                    account: accountManager,
                    bridge: bridgeStatus
                ) { [weak self] in
                    self?.bootHeavyState()
                }
            }
        }
    }

    /// Phase A: cheap setup. No OS prompts, no expensive subprocesses.
    /// Safe to run before the ceremony — nothing here will pop a
    /// dialog over the cinematic.
    @MainActor
    private func setupCheapState() {
        // Mic permission status — read-only query, no UI.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("KLO: mic auth status = \(micStatus.rawValue)")

        // MacOps loopback HTTP server. Started here (not in
        // bootHeavyState) so it's reachable as soon as the sidecar
        // boots — including during onboarding when the sidecar
        // pre-warms for chrome-install detection. Just opens a port,
        // no TCC prompts.
        MacOpsServer.shared.start()

        // BridgeStatusManager — pure async URLSession polling.
        let bridgeStatus = BridgeStatusManager()
        self.bridgeStatus = bridgeStatus

        // 2.0.0: poll klo-cloud for pending schedule confirmations and
        // the user's active schedule list. Surfaces confirm cards in
        // the notch and feeds Settings → Schedules.
        SchedulesManager.shared.start()

        // Sidecar pre-warm. The bundled Python binary takes ~5-15s on a
        // cold first run (Gatekeeper signature check + interpreter spin-
        // up + FastAPI startup + bridge_server bind). If we wait until
        // the user clicks "Install klo for Chrome" to launch it — the
        // path we used through 1.4.8 — the user can finish installing
        // the extension before our bridge is reachable. The extension's
        // service worker tries to connect, fails, then idles out after
        // ~30s (Chrome MV3 SW lifecycle). The chrome.alarms wake fires
        // every 30s, so the user can sit on a stalled "extension not
        // detected" card for up to a minute even though they did
        // everything right.
        //
        // Booting the sidecar here, at app launch, gives the bridge a
        // ~10-15s head start over the moment of extension install — so
        // the extension's first WS connect almost always succeeds.
        // `startIfNeeded` is idempotent (port-check first, no-op if
        // someone else already bound :8787 — the dev-workflow case), so
        // calling it again in `bootHeavyState` after onboarding finishes
        // is harmless.
        let sidecarLauncher = self.sidecarLauncher ?? SidecarLauncher.shared
        sidecarLauncher.startIfNeeded()
        self.sidecarLauncher = sidecarLauncher

        // AccountManager — async network + Keychain read; init returns
        // immediately, the network call happens on a background task.
        let accountManager = AccountManager()
        self.accountManager = accountManager

        // 2.0.0: hand the account into SchedulesManager so its polling
        // loop (already started in setupCheapState) can authenticate.
        SchedulesManager.shared.attach(account: accountManager)

        // Configure the settings window controller so it's ready when
        // the user wants to show it.
        SettingsWindowController.shared.configure(account: accountManager)

        // Keyboard-tutorial trigger. Sink registered eagerly so we
        // catch the FIRST status flip to .signedInActive — even if
        // it happens during the ceremony or before bootHeavyState
        // creates the KLOState (we resolve state lazily inside the
        // callback so it's fine if state isn't there yet).
        //
        // 1.5s deferral when fired post-cloud onboarding: the notch
        // panel just appeared with its intro fire-glow pulse; if the
        // tutorial appears at the same moment they compete for
        // attention. The delay sequences pulse → tutorial.
    }

    /// Phase C: heavy boot. EVERY initialization in here can plausibly
    /// trigger an OS dialog on a clean install — Gatekeeper for the
    /// sidecar binary, Accessibility for the global hotkey, network /
    /// mic for the Vapi SDK loading. Deferring all three until after
    /// the ceremony is what stops dialogs from interrupting it.
    @MainActor
    private func bootHeavyState() {
        // setupCheapState always creates accountManager. If it didn't
        // run for some reason (defensive), bail rather than crash.
        guard let accountManager = self.accountManager else {
            NSLog("KLO: bootHeavyState called before setupCheapState")
            return
        }

        // MacOps server is started in setupCheapState — already up by now.

        // Sidecar — bundled Python binary. First run on a new Mac
        // triggers Gatekeeper signature check. Already pre-warmed in
        // `setupCheapState` so the Chrome extension can connect to the
        // bridge the moment the user installs it; this call is
        // idempotent (port-check no-op if the sidecar is already up).
        let sidecarLauncher = self.sidecarLauncher ?? SidecarLauncher.shared
        sidecarLauncher.startIfNeeded()
        self.sidecarLauncher = sidecarLauncher

        // KLOState + agent client. AgentClient gets the AccountManager
        // so submitQuery / handleVoiceTranscript can gate on
        // account.isReady before running the agent.
        let state = KLOState()
        let agentClient = AgentClient(state: state, account: accountManager)

        // 2.0.0 always-confirm: when SchedulesManager picks up a new
        // pending row in its poll cycle, ask state to surface the
        // confirm card (it'll only do so if the notch is in a non-
        // disruptive mode like .idle / .textExpanded / .completed).
        SchedulesManager.shared.$pending
            .receive(on: DispatchQueue.main)
            .sink { _ in
                state.presentNextPendingConfirmIfNeeded()
            }
            .store(in: &cancellables)

        // Mirror iPhone-initiated runs into the notch panel: when the
        // sidecar's cloud_bridge accepts a remote run, it posts
        // `klo.bridge.run.start` (DistributedNotificationCenter); we flip
        // KLOState into .working so the fire activates. On `.run.end` we
        // collapse back to idle. The Mac panel then visually narrates
        // whatever the phone is dispatching, with the same notch fire
        // the user sees for local runs.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("klo.bridge.run.start"),
            object: nil,
            queue: .main
        ) { [weak state] note in
            let prompt = (note.userInfo?["prompt"] as? String) ?? "from your iPhone"
            state?.startWorking(query: prompt)
        }
        // Settings' recent-conversations list → resume in the notch.
        // Settings has no KLOState reference (it only knows
        // AccountManager), so it posts and we route — same shape as
        // the web-pane / credential notifications.
        NotificationCenter.default.addObserver(
            forName: .kloResumeConversation,
            object: nil,
            queue: .main
        ) { [weak state] note in
            guard let id = note.userInfo?["id"] as? UUID else { return }
            Task { @MainActor in
                state?.resumeConversation(id)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("klo.bridge.run.end"),
            object: nil,
            queue: .main
        ) { [weak state] _ in
            // Only collapse if we're still in .working — don't yank the
            // user out of a different surface (settings, voice, etc.) if
            // they switched while the phone run was in flight.
            if case .working = state?.mode {
                state?.collapseToIdle()
            }
            state?.clearToolActivity()
        }

        // klo 2.1.1: cloud-dispatched scheduled run (preview, fire, or
        // run-now) just completed and the cloud pushed its stitched
        // markdown result. cloud_bridge.py forwards the WS frame as
        // this distributed notification. Without this observer, the
        // user would see "Checking on that…" for ~5s and then never
        // hear about the result — the exact silent dropoff the user
        // hit on "Check disk space weekly."
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("klo.cloud.mirror"),
            object: nil,
            queue: .main
        ) { [weak state] note in
            guard let state else { return }
            let info = note.userInfo ?? [:]
            handleScheduledMirror(payload: info, state: state)
        }

        // klo 2.1.1: live step_progress events from a cloud-dispatched
        // run. Lets the working-state activity bubbles update during a
        // preview / scheduled fire instead of going dark right after
        // the opener.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("klo.cloud.run.event"),
            object: nil,
            queue: .main
        ) { [weak state] note in
            guard let state else { return }
            let info = note.userInfo ?? [:]
            handleScheduledRunEvent(payload: info, state: state)
        }

        // OpenAI Realtime API bridge — native WebRTC for direct
        // STT + LLM + TTS in one connection. The only voice transport
        // klo uses; Vapi+Haiku+ElevenLabs was removed once Realtime
        // proved out.
        let realtimeBridge = RealtimeBridge(account: accountManager)
        agentClient.attach(realtimeBridge: realtimeBridge)

        // NotchDetector + KLOWindowController — passive AppKit calls.
        // Showing the notch panel HERE (after the ceremony) means the
        // notch idle line never briefly flashes behind the cloud at
        // launch.
        let detector = NotchDetector()
        detector.refresh()
        let windowController = KLOWindowController(
            state: state,
            detector: detector,
            agentClient: agentClient,
            realtimeBridge: realtimeBridge,
            bridgeStatus: bridgeStatus!,
            account: accountManager
        )
        // First-launch (post-cloud-onboarding) gets a brief one-shot
        // fire-glow pulse on the notch silhouette — confirms "klo
        // just moved into your notch." Returning launches don't pulse.
        let isFirstLaunchPostCloud = !UserDefaults.standard
            .bool(forKey: "klo.didShowNotchIntroPulse")
        windowController.show(withIntroPulse: isFirstLaunchPostCloud)
        if isFirstLaunchPostCloud {
            UserDefaults.standard.set(true, forKey: "klo.didShowNotchIntroPulse")
        }

        // First-prompt demo island — only shown once per install AND
        // only to signed-in users. Sits below the notch and teaches:
        //   Stage A: "Press ⌘K to summon klo" (while state.mode == .idle)
        //   Stage B: "Tell klo what to do." (after user presses ⌘K)
        // Auto-dismisses on first prompt submission. Replaces the
        // older KeyboardTutorialWindowController.
        //
        // Deferred ~2.4s so it lands after the notch's intro pulse
        // fades — otherwise the two flares would compete for attention.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            FirstPromptIslandWindowController.shared.showIfNeeded(
                state: state,
                account: accountManager
            )
        }

        // Global hotkeys — ⌘K = chat, ⌘⇧, = settings. May trigger
        // Accessibility on first run depending on macOS version.
        // cancelRun closure: when the user presses ⌘K / ⌘⇧K during an
        // active run, the hotkey ROUTES to cancel instead of toggling
        // the panel. Same logic the ESC handler in KLOWindowController
        // uses — single source of truth so we never have a state where
        // pressing the hotkey doesn't stop the agent.
        let hotKeyManager = HotKeyManager(
            state: state,
            openSettings: { SettingsWindowController.shared.show() },
            cancelRun: { [weak agentClient] in
                agentClient?.cancelCurrentRun()
            }
        )
        hotKeyManager.register()

        // Wisp overlay — a borderless, click-through panel that hosts
        // the glowing orange presence which travels across the screen
        // during a run. Lives outside the notch panel so it can render
        // anywhere klo is acting, not just at the top of the display.
        // Visibility is driven entirely by WispPresenter; the window
        // stays alive but orders out when isActive flips false.
        let wispOverlay = WispOverlayWindowController()
        wispOverlay.show()

        self.state = state
        self.agentClient = agentClient
        self.realtimeBridge = realtimeBridge
        self.notchDetector = detector
        self.windowController = windowController
        self.hotKeyManager = hotKeyManager
        self.wispOverlay = wispOverlay
    }

    // MARK: - klo:// deep link (Supabase magic-link callback)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "klo" || url.scheme == "klo-desktop" {
            // Long-horizon harness preview paths for visual QA without
            // wiring the Python sidecar bridge yet:
            //   open klo-desktop://preview/workspace-init
            //   open klo-desktop://preview/workspace-approval
            // The cards surface in the notch with fake data so the design
            // can be inspected end-to-end. Production paths fall through
            // to the auth/deeplink handler below.
            if url.host == "preview", let kloState = state {
                let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let wc = windowController
                Task { @MainActor in
                    // Force the panel forward so the preview is visible
                    // even when the panel is dismissed or the sidecar
                    // failed banner is up in the idle state.
                    wc?.show()
                    NSApp.activate(ignoringOtherApps: true)
                    KLOWorkspacePreview.fire(action: action, state: kloState)
                }
                continue
            }
            accountManager?.handleDeepLink(url)
        }
    }

    /// Dock icon click. Two cases we care about:
    ///   1. User is mid-handoff (granting a permission in System
    ///      Settings) — Dock click means "I'm back." Force the cloud
    ///      to return + re-check permissions.
    ///   2. Otherwise — let macOS handle it (default behavior brings
    ///      whatever window forward).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let coordinator = CeremonyWindowController.shared.currentCoordinator,
           coordinator.activeHandoff?.isPermission == true {
            coordinator.forceReturnFromHandoff()
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregister()
        // Hard-stop the Realtime call so the WebRTC connection releases
        // the mic before the process dies (otherwise the menu-bar mic
        // indicator can linger for a second or two after quit).
        realtimeBridge?.stop()
        // Stop MacOps server BEFORE the sidecar so any in-flight
        // sidecar→Mac-app calls don't hang on a dying server.
        MacOpsServer.shared.stop()
        // Graceful sidecar shutdown — FastAPI runs lifespan handlers,
        // bridge closes, etc. Falls back to SIGKILL after 2s if needed.
        sidecarLauncher?.stop()
        NSLog("KLO: applicationWillTerminate")
    }

    // klo never auto-quits when "all windows" close — the panel itself is
    // the entire UI and we want it persistent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}


// MARK: - klo 2.1.1 — cloud-dispatched run notification handlers

/// Handle the `klo.cloud.mirror` distributed notification — a scheduled
/// run on the cloud just produced a stitched-markdown result. The Mac
/// sidecar's cloud_bridge.py forwards the WS frame here so we can:
///   1. Append the message to state.messages so the chat surface shows it.
///   2. Route via the smart completion policy: user-initiated runs
///      (recent tap, pending preview marker, pending run-now task) auto-
///      open the notch into .completed with a one-line summary; background
///      fires (cadence ticks) surface as a transient toast + a persistent
///      olive dot on the notch hardware until acknowledged.
@MainActor
private func handleScheduledMirror(payload: [AnyHashable: Any], state: KLOState) {
    let content = (payload["content"] as? String) ?? ""
    let metadata = payload["metadata"] as? [String: Any] ?? [:]
    let routineName = (metadata["routine_name"] as? String) ?? "your routine"
    let kind = (metadata["kind"] as? String) ?? ""
    let scheduledTaskId = (metadata["scheduled_task_id"] as? String)
        ?? (metadata["suggestion_id"] as? String)
        ?? ""

    // Append into the chat transcript so the .completed panel + the
    // history overlay both see it. The mirror frame is the authoritative
    // copy — the cloud already wrote it into /messages.
    state.appendScheduledMessage(content: content, metadata: metadata)

    // User-initiated? Three signals:
    //   - state.pendingPreviewSuggestionId matches the suggestion id
    //   - state.pendingRunNowTaskId matches the scheduled_task_id
    //   - the user tapped SOMETHING in the last 5 seconds (run-now,
    //     suggestion, etc.) — broad heuristic that catches edge paths
    let suggestionId = (metadata["suggestion_id"] as? String) ?? ""
    let isPreviewMatch = state.pendingPreviewSuggestionId != nil
        && state.pendingPreviewSuggestionId == suggestionId
    let isRunNowMatch = state.pendingRunNowTaskId != nil
        && state.pendingRunNowTaskId == scheduledTaskId
    let recentTap = Date().timeIntervalSince(state.lastUserTap) < 5
    let isUserInitiated = isPreviewMatch || isRunNowMatch || recentTap

    if isUserInitiated {
        // Auto-open into the chat surface with a one-line summary. The
        // full stitched content lives in state.messages and is reachable
        // via the result panel's transcript scrollback.
        let summary = extractOneLineSummary(content)
        let headline = kind == "routine_preview"
            ? "Preview: \(routineName)"
            : routineName
        state.showCompleted(query: headline, response: summary)
        state.clearPreviewMarker()
        state.pendingRunNowTaskId = nil
    } else {
        // Background fire while user was elsewhere. Quiet toast +
        // persistent olive dot on the notch hardware. The dot stays
        // until the user opens the notch (KLOOverlayView clears it
        // on .idle → any-other-mode transition).
        state.showTransientNotice("routine finished: \(routineName) — tap to see")
        state.notchHardwareDotShouldPulse = true
    }
}

/// Handle the `klo.cloud.run.event` distributed notification. A
/// cloud-dispatched run emitted a step_progress event the Mac would
/// otherwise miss. Route into KLOState.noteToolActivity so the working-
/// state activity bubbles update live during preview / scheduled runs
/// instead of going silent right after the opener.
@MainActor
private func handleScheduledRunEvent(payload: [AnyHashable: Any], state: KLOState) {
    let event = payload["event"] as? [String: Any] ?? [:]
    let eventPayload = event["payload"] as? [String: Any] ?? [:]
    let name = eventPayload["tool"] as? String
        ?? eventPayload["name"] as? String
        ?? ""
    let action = eventPayload["action"] as? String
    let detail = eventPayload["detail"] as? String
        ?? eventPayload["text"] as? String
    if !name.isEmpty {
        state.noteToolActivity(name: name, action: action, detail: detail)
    }
}

/// Pull a short headline from a scheduled run's stitched markdown
/// summary. Cloud's stitched format is:
///   ## <Routine name>
///   ### Step 1
///   <output text>
///   ### Step 2
///   <output text>
///   ...
/// We want the first non-header, non-italic line — typically the first
/// sentence of the first step's output. Falls back to the leading 120
/// chars of the full content for safety.
@MainActor
private func extractOneLineSummary(_ content: String) -> String {
    let lines = content.split(whereSeparator: { $0.isNewline })
    let candidates = lines.compactMap { l -> String? in
        let s = l.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("##") || s.hasPrefix("###") { return nil }
        if s.hasPrefix("_") && s.hasSuffix("_") { return nil }  // italic notes
        return s
    }
    let first = candidates.first ?? String(content.prefix(120))
    return String(first.prefix(140))
}
