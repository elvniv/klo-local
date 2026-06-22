import SwiftUI

// Root SwiftUI view inside the KLOPanel. Uses the canonical
// NotchShape — a single black-filled shape positioned at the top
// of the screen so it visually merges with the hardware notch and
// extends downward. As the shape grows wider/taller, the bottom
// corners curve outward, producing the "expanding notch" look.
//
// Two corner-radius pairs:
//   - compact (idle): top=6, bottom=14
//   - expanded (any non-idle): top=15, bottom=20
//
// Width must always be ≥ notchSize.width + 2*topCornerRadius so the
// top of the shape covers the entire hardware notch.
struct KLOOverlayView: View {
    @EnvironmentObject var state: KLOState
    @EnvironmentObject var detector: NotchDetector
    @EnvironmentObject var agentClient: AgentClient
    @EnvironmentObject var realtimeBridge: RealtimeBridge
    @EnvironmentObject var account: AccountManager
    @EnvironmentObject var systemDialog: SystemDialogObserver

    /// One-shot intro pulse — set true when the cloud onboarding
    /// finishes and the notch panel first appears. Strong KloFireGlow
    /// on the notch silhouette for ~2.4s, then fades to the normal
    /// idle state. Triggered via NotificationCenter from
    /// `KLOWindowController.show(withIntroPulse: true)`.
    @State private var introPulseActive: Bool = false

    /// Saved query the user fired before being interrupted by a TCC
    /// denial. Re-submitted automatically the next time the user
    /// summons the notch with a working permission set. Cleared on
    /// dismiss / successful retry.
    // Runtime permission grant state (pendingRetryQuery / Watcher /
    // pendingRetryService) all moved to PermissionGrantOrchestrator.
    // This view just renders .permissionRequired and forwards the
    // Grant click to the orchestrator with the right retry closure.

    /// Saved draft prompt from a sign-in island. Lives on KLOOverlayView
    /// because the island itself auto-collapses to .idle after a brief
    /// moment (so the OAuth browser becomes clickable) — but we still
    /// need to retry once account.status flips signed-in. Cleared on
    /// dismiss / successful retry.
    @State private var pendingSignInDraft: String?

    /// Sparkle status feed. When `updater.updateAvailable` flips non-nil
    /// the dormant pill grows a small olive arrow overlay; tapping it
    /// fires a user-initiated check (which routes through Sparkle's
    /// stock install/restart sheet). See UpdaterManager.swift.
    @ObservedObject private var updater = UpdaterManager.shared
    @State private var updateArrowBreath: Bool = false

    /// Sidecar health feed. While the local agent process is down the
    /// notch grows a small status pill below the silhouette — "klo
    /// agent is starting…" during boot/restart, "klo agent unavailable
    /// — Retry" once the watchdog gives up. See SidecarLauncher.
    @ObservedObject private var sidecar = SidecarLauncher.shared

    /// Live extension/bridge status (same object MissingExtensionPanel
    /// reads). Drives the degraded-web caption while working and the
    /// one-time "klo works in Chrome too" idle nudge.
    @EnvironmentObject private var bridge: BridgeStatusManager

    /// One-time idle nudge flag. Existing users finished onboarding
    /// before the extension step existed, so the only path to the
    /// install card was a web-task failure. Dismissed (or connected)
    /// once → never shows again.
    @AppStorage("klo.extensionNudgeDismissed")
    private var extensionNudgeDismissed = false

    var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed clear backdrop. Marked non-hit-testable so
            // clicks on the panel's transparent margins (everything
            // outside the notch silhouette + chat panel) pass through
            // to whatever's underneath — other apps, the desktop, etc.
            // Without this, the 1000×700pt panel silently captures
            // every click that lands "near" the notch, which:
            //   - prevents the user from dragging another window
            //   - silently dismisses no .collapseToIdle, so the panel
            //     feels modal even when it shouldn't
            // The click-away monitor in KLOWindowController completes
            // the loop: when a passed-through click reaches another
            // window, that monitor fires and collapses the notch.
            Color.clear.allowsHitTesting(false)

            if detector.geometry.hasNotch {
                notchSurface
            } else {
                fallbackPanel
            }
        }
        .ignoresSafeArea()
        // Yield visually to Apple's TCC consent dialogs. When the OS
        // pops "klo would like to access files in your Documents folder"
        // (or the AppleEvents/Automation prompt), SystemDialogObserver
        // flips and we fade the entire notch content to ~0.18 alpha so
        // the system dialog is readable + the Allow / Don't Allow
        // buttons are visible. Click pass-through is handled separately
        // in KLOWindowController.applyModeToPanel — together they make
        // the notch a near-invisible bystander until the dialog closes.
        .opacity(systemDialog.systemDialogVisible ? 0.18 : 1)
        .animation(.easeOut(duration: 0.18), value: systemDialog.systemDialogVisible)
        .onReceive(NotificationCenter.default.publisher(for: .kloNotchIntroPulse)) { _ in
            // Brief one-shot pulse: enable a strong fire-glow on the
            // notch silhouette for ~2.4s, then revert to the normal
            // subtle outline.
            withAnimation(.easeOut(duration: 0.35)) {
                introPulseActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                withAnimation(.easeIn(duration: 0.6)) {
                    introPulseActive = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kloShowWebPane)) { _ in
            // MacOpsServer posts this when the model calls web.open.
            // Carry the current working query through so the pane's
            // dismiss can return to .working without losing context.
            // If we're not in a working state (shouldn't happen but
            // defensive), fall back to a generic label.
            let query: String
            if case .working(let q) = state.mode { query = q }
            else if case .webPane(let q) = state.mode { query = q }
            else { query = "" }
            state.showWebPane(query: query)
        }
        .onChange(of: account.status) { newStatus in
            // Auto-recovery + auto-resubmit on auth-state flips.
            // Two paths:
            //   1. Big paywall card (subscription gates) — existing flow.
            //   2. Small sign-in island — new flow.
            // Both: when account.isReady flips true, fire the saved
            // draft prompt the user typed before being gated.
            let signedInNow: Bool = {
                if case .signedInActive = newStatus { return true }
                return false
            }()
            if signedInNow,
               case .paywallRequired(_, let draftPrompt) = state.mode {
                NSLog("KLO: paywall cleared — auto-resubmitting draft prompt")
                HapticEngine.success()
                account.endPostCheckoutPolling()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if !draftPrompt.isEmpty {
                        agentClient.submitQuery(draftPrompt)
                    } else {
                        state.collapseToIdle()
                    }
                }
                return
            }
            // Sign-in island path: user OAuth'd, status flipped to
            // signed-in. The island has typically auto-collapsed by
            // now (to free the browser tab from klo's click-trap), so
            // we drive the retry off `pendingSignInDraft` rather than
            // off state.mode.
            let authDone: Bool = {
                switch newStatus {
                case .signedInActive, .signedInUnsubscribed,
                     .signedInPastDue, .signedInExpired: return true
                default: return false
                }
            }()
            if authDone, let draft = pendingSignInDraft {
                NSLog("KLO: sign-in completed — auto-resubmitting saved draft")
                HapticEngine.success()
                let toFire = draft
                pendingSignInDraft = nil
                // If island is still visible, dismiss it first.
                if case .signInRequired = state.mode {
                    state.collapseToIdle()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if !toFire.isEmpty {
                        agentClient.submitQuery(toFire)
                    }
                }
            }
        }
        .onChange(of: state.mode) { newMode in
            // Empty-state whisper — when the user opens the notch
            // into an empty thread, compute one quiet starter line.
            // The whisper is cleared on first keystroke (TextInputView)
            // and on collapse to idle (KLOState.setMode). One line, not
            // a list — see KLOState.IdleWhisper for the design rationale.
            if case .textExpanded = newMode, state.messages.isEmpty {
                Task { @MainActor in
                    state.idleWhisper = await IdleWhisperProvider.compute()
                }
            }
            // Sign-in island: save draft so the auth-completion observer
            // can resubmit once OAuth lands. Don't auto-collapse on a
            // raw timer; that produced the "I saw it flash and couldn't
            // click anything" bug. User has no time to read what's
            // happening, especially when the OAuth browser tab hasn't
            // surfaced yet. Instead, collapse only once account.status
            // actually transitions out of .signedOut (OAuth tab opened,
            // user is mid-flow) so the island gets out of the way at
            // the right time. Esc still dismisses immediately, and the
            // safety timer below at 60s is a backstop for users who
            // gave up halfway.
            if case .signInRequired(let draft) = newMode {
                pendingSignInDraft = draft
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    if case .signInRequired = state.mode {
                        state.collapseToIdle()
                    }
                }
                return
            }

            // The runtime permission grant flow (Open Settings + drag
            // island + grant detection + auto-retry) lives entirely in
            // PermissionGrantOrchestrator now. The notch only renders
            // .permissionRequired and forwards the Grant click to the
            // orchestrator — no local timers, no local poll, no local
            // pending-retry state to manage here.
        }
    }

    /// True when the notch silhouette itself should be filled with fire
    /// instead of black. Voice mode only — text-mode `.working` now
    /// renders the chat panel (with a thinking indicator) just like
    /// `.completed`, so the fire would visually compete with it. The
    /// "klo is doing something" signal during text mode comes from
    /// the orange action chip below the notch + the ThinkingDots in
    /// the chat panel.
    private var isFireMode: Bool {
        switch state.mode {
        case .voiceExpanded: return true
        default: return false
        }
    }

    /// Fire opacity. In voice mode the fire is DIM (~0.45) until Vapi
    /// reports `inCall` — that's the moment the WebRTC handshake
    /// completes and the OS mic actually opens. Visually mirrors the
    /// macOS top-right mic indicator. Outside voice mode the fire is
    /// invisible.
    private var fireOpacity: Double {
        switch state.mode {
        case .voiceExpanded:
            return realtimeBridge.inCall ? 1.0 : 0.42
        default:
            return 0.0
        }
    }

    // The copper hue-shift trust signal was removed in 2.1.1. Given
    // the AX pre-flight redirect and the SOM canonical workflow shipped
    // in 2.1.0, `.vision` almost never fires in practice — the signal
    // was loud about an event the user couldn't act on and the user
    // couldn't predict. KLOState.currentTargetingMethod is still
    // tracked for diagnostics; we just don't render it as a visible
    // change to the fire. See the wow-moments framework's honesty
    // check: a trust signal that almost never fires is noise.

    // MARK: - Notched display path

    private var notchSurface: some View {
        let g = detector.geometry
        let dims = surfaceDimensions
        let topR = topCornerRadius
        let bottomR = bottomCornerRadius
        // Overlap into the hardware notch by 4pt at the top so there's
        // never a seam-gap between the shape's black fill and the physical
        // notch — even on Retina displays where 0.5pt rounding could
        // otherwise expose a sliver of menu-bar background. Both are
        // black, so the overlap itself is invisible. 4pt covers @1x, @2x,
        // and @3x scale factors with margin.
        let topOverlap: CGFloat = 4
        let totalH = dims.height + g.height + topOverlap

        // BOTH layers always mounted — visibility is opacity-driven.
        // Conditional `if/else` rendering would tear down and recreate
        // the fire view on every transition (with its many @State
        // animations), causing the hitchiness. Opacity-driven keeps view
        // identity stable so the spring animates one continuous value.
        return ZStack(alignment: .top) {
            // FIRE LAYER — always mounted, fades in/out via opacity.
            // Identical 940×440 frame for both working and voice so the
            // fire visual is the same signal in both modes. No notch
            // shape, no outline, no panel — the flame is the entire UI.
            // Tap-to-stop is wired ONLY when voice mode is the active
            // fire. The 160pt hotspot inside MiniFireView becomes
            // tap-eligible iff onStop is non-nil — and we want it
            // tap-eligible only when the user is actually in voice
            // mode (not when fire is being shown for other reasons).
            MiniFireView(
                onStop: isFireMode ? {
                    NSLog("KLO Voice: tap-to-stop hotspot fired")
                    _ = agentClient.stopVoiceCapture()
                    state.collapseToIdle()
                } : nil
            )
                .frame(width: 940, height: 440)
                .offset(y: -topOverlap)
                .allowsHitTesting(false)
                .help(fireTooltip)
                // Voice mode: fire is dim until Vapi's mic is actually
                // live (handshake done, OS mic indicator on). Brightens
                // when realtimeBridge.inCall flips true.
                .opacity(fireOpacity)
                .scaleEffect(isFireMode ? 1.0 : 0.96, anchor: .top)
                .animation(.easeInOut(duration: 0.18), value: realtimeBridge.inCall)


            // NOTCH SILHOUETTE — always mounted, fades out in fire modes.
            // Idle: thin notch line. Text/Completed/Failed: full panel.
            notchSilhouette(
                g: g,
                dims: dims,
                topR: topR,
                bottomR: bottomR,
                totalH: totalH,
                topOverlap: topOverlap
            )
            .opacity(isFireMode ? 0 : 1)
            // SwiftUI opacity == 0 does NOT turn off hit-testing. In
            // fire modes the silhouette is invisible but its contoured
            // shape still consumes clicks, so a click on the "fire"
            // would actually land on the invisible silhouette underneath
            // and never reach the global monitor. allowsHitTesting
            // gated on !isFireMode so the silhouette only catches
            // clicks in modes where it's visible.
            .allowsHitTesting(!isFireMode)
            // Brief intro flourish on app launch — radius 36 for a
            // bigger one-shot pulse than the steady-state.
            .modifier(KloFireGlow(active: introPulseActive, radius: 36))

            // DORMANT BREATHING PULSE — copies the cinematic
            // NotchSilhouette (CeremonyView.swift:164-179) verbatim,
            // overlaid at the hardware-notch position. Same
            // dimensions, same fill, same KloFireGlow radius 24, same
            // breathing cadence. Black-on-black against the actual
            // macOS notch is invisible; only the olive halo radiates,
            // giving the dormant state the "alive at rest" look the
            // user asked for. Only shown when state.mode == .idle so
            // we don't draw two halos during active states.
            if state.mode == .idle {
                // Glow radius 8 — much smaller than cinematic (24)
                // but still visibly breathing. "A lot smaller but
                // still noticeable" per the user's spec.
                NotchSilhouette(geometry: g, glowRadius: 8)
                    .allowsHitTesting(false)

                // klo 2.1.1 — "klo has something for you" dot.
                // Surfaces when a background scheduled run finished
                // while the user was elsewhere (no tap correlated, so
                // we don't auto-open the notch). Persistent until the
                // user opens klo. Anchored to the lower-right of the
                // notch silhouette so it reads as part of the hardware
                // glyph, not a separate overlay.
                if state.notchHardwareDotShouldPulse {
                    NotchHardwareDot()
                        .offset(
                            x: g.width / 2 + 4,
                            y: g.height - 6 - topOverlap,
                        )
                        .allowsHitTesting(false)
                }
            }

            // SIDECAR HEALTH — small status pill below the notch while
            // the local agent process is down. Idle-only so it never
            // competes with an active surface (failures there already
            // get their own copy via AgentClient).
            if state.mode == .idle && sidecar.health != .healthy {
                sidecarHealthBanner
                    .offset(y: g.height + topOverlap + 12)
                    .transition(.opacity)
            }

            // EXTENSION NUDGE — one-time idle pill for users who
            // finished onboarding before the Chrome-extension step
            // existed and have never connected it. Auto-retires when
            // the extension connects or on dismiss.
            if showsExtensionNudge {
                extensionNudgePill
                    .offset(y: g.height + topOverlap + 12)
                    .transition(.opacity)
            }

            // DEGRADED WEB RUN — while working, if a web tool fired
            // but the extension isn't connected, caption the run so
            // the user learns in the moment why klo can only open
            // pages instead of reading them.
            if isWorkingMode && state.sawWebActivity && !bridge.extensionConnected {
                statusCapsule(dotColor: KloColors.orange, pulsing: true) {
                    Text("working without the Chrome extension")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .allowsHitTesting(false)
                .offset(y: g.height + topOverlap + dims.height + 14)
                .transition(.opacity)
            }

            // TRANSIENT NOTICE — brief auto-dismissing toast for
            // failures that need acknowledgement but no panel (e.g.
            // a pause/cancel POST that didn't reach the sidecar).
            if let notice = state.transientNotice {
                transientNoticeToast(notice)
                    .offset(y: g.height + topOverlap + dims.height + 14)
                    .transition(.opacity)
            }

            // ACTION READOUT — orange-dot pill that appears ONLY when
            // klo is actively running a tool (computer.click,
            // computer.screenshot, etc). Mid-reasoning moments where
            // no tool is in flight don't pop this — those land in the
            // chat panel as ThinkingDots instead. Sits floating
            // BELOW the chat panel so it doesn't compete with the
            // panel content.
            // WorkingActivityOverlay (the chip ticker) + the floating
            // STOP pill are intentionally NOT rendered in .working
            // anymore — the new WorkingPillView shown INSIDE the notch
            // carries both the verb and the stop affordance. The
            // ticker showed truncated chips like "scannin…tive app"
            // which read as chrome noise. The pill is the single
            // source of running-state status.
        }
        .compositingGroup()
        .animation(KLOState.modeTransition, value: state.mode)
        // The history overlay and the thread peek strip both grow the
        // textExpanded surface without a mode change, so each needs
        // its own animation trigger — same morph spring as mode
        // transitions for one continuous feel.
        .animation(KLOState.morphSpring, value: state.showingHistory)
        .animation(KLOState.morphSpring, value: state.messages.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Static subtle shadow instead of animating the shadow opacity
        // alongside the spring — animating shadows is GPU-expensive and
        // was the main source of the wake-up hitch on ⌘K. The shadow is
        // mostly invisible behind the notch anyway, so a constant low
        // opacity reads the same without per-frame shadow recompute.
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    /// The notch silhouette: masked content + outline + menu-bar handles.
    /// Extracted so the main `notchSurface` body can keep both this and
    /// the fire layer mounted side-by-side, each opacity-driven, for
    /// stable view identity across transitions.
    ///
    /// WORKING-MODE EXCEPTION: when klo is doing work (`.working` /
    /// `.resuming`), the notch chrome is fully stripped — no NotchShape
    /// mask, no black background, no orange outline. The FireBubblesView
    /// renders directly below the hardware notch as a free-floating
    /// composition (small green fire + activity bubbles), matching the
    /// onboarding "no rectangle, no chrome" design language.
    @ViewBuilder
    private func notchSilhouette(
        g: NotchGeometry,
        dims: CGSize,
        topR: CGFloat,
        bottomR: CGFloat,
        totalH: CGFloat,
        topOverlap: CGFloat
    ) -> some View {
        let isWorking: Bool = {
            switch state.mode {
            case .working, .resuming: return true
            default: return false
            }
        }()

        ZStack(alignment: .top) {
            if isWorking {
                // Working mode: content (FireBubblesView) PINNED TO
                // THE TOP — fire glow emerges from BEHIND the notch
                // hardware and hangs downward (the user's
                // "upside-down dormant pulse" spec); the bubbles sit
                // right under the notch hardware bottom edge. No
                // padding-pushdown below the notch (the previous
                // version had `.padding(.top, g.height + topOverlap)`
                // which made everything start at the notch BOTTOM
                // instead of the notch TOP — user feedback called
                // that out as wrong).
                //
                // The -topOverlap offset still applies so the fire
                // bleeds 4pt into the menu bar (same trick voice
                // fire uses); FireBubblesView internally pads the
                // bubble row down by ~g.height so the bubbles land
                // right under the notch.
                content
                    .frame(width: dims.width, height: dims.height, alignment: .top)
                    .frame(width: dims.width, height: totalH, alignment: .top)
                    .offset(y: -topOverlap)
            } else {
                content
                    .frame(width: dims.width, height: dims.height, alignment: .top)
                    .padding(.top, g.height + topOverlap)
                    .background(Color.black)
                    .mask {
                        NotchShape(
                            topCornerRadius: topR,
                            bottomCornerRadius: bottomR
                        )
                        .frame(width: dims.width, height: totalH)
                    }
                    .frame(width: dims.width, height: totalH, alignment: .top)
                    // Hit-test the VISIBLE silhouette, not the bounding
                    // rect. The `.mask` only clips drawing — without this
                    // the transparent rounded corners of the dims.width ×
                    // totalH rectangle still swallow clicks. contentShape
                    // restricts the panel's hit region to the notch
                    // contour, so clicks just outside it pass through.
                    .contentShape(
                        NotchShape(topCornerRadius: topR, bottomCornerRadius: bottomR)
                    )
                    .offset(y: -topOverlap)

                // Uniform orange outline — wraps the FULL silhouette
                // including top corners (where the shape meets the
                // hardware notch's bottom curves). Skipped in working
                // mode (see above) so the bubble surface stays clean.
                ZStack {
                    NotchShape(topCornerRadius: topR, bottomCornerRadius: bottomR)
                        .stroke(accentStroke.opacity(0.55),
                                style: StrokeStyle(lineWidth: outlineHaloWidth,
                                                   lineCap: .round, lineJoin: .round))
                        .blur(radius: 1.2)

                    NotchShape(topCornerRadius: topR, bottomCornerRadius: bottomR)
                        .stroke(accentStroke,
                                style: StrokeStyle(lineWidth: outlineCoreWidth,
                                                   lineCap: .round, lineJoin: .round))
                }
                .frame(width: dims.width, height: totalH)
                .drawingGroup()
                .offset(y: -topOverlap)
            }
        }
    }

    /// Tooltip text shown on hover over the fire — exposes the in-flight
    /// query during working mode. Empty in voice mode (nothing to show).
    private var fireTooltip: String {
        if case .working(let q) = state.mode { return q }
        return ""
    }


    // MARK: - Stop button (working state only)

    /// Outlined-orange Stop pill rendered below the notch while a turn
    /// is running. Mirrors the extension's stop affordance — same
    /// glyph, same orange ring, same "press me to interrupt" cue.
    /// Cancels the run via AgentClient and pops the panel back to idle.
    private var stopButton: some View {
        Button {
            agentClient.cancelCurrentRun()
            state.collapseToIdle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("stop")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .textCase(.uppercase)
            }
            .foregroundStyle(KloColors.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(KloColors.orange.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(KloColors.orange, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Stop klo (Esc)")
    }

    // MARK: - Fallback (no-notch) path

    /// Dormant breathing pill for external monitors / no-notch displays.
    /// Pure rounded rectangle (no fake notch indent) — the entire "klo
    /// is alive on this monitor" signal at rest. Mirrors the MBP path's
    /// overlaid NotchSilhouette: black ink fill + breathing olive
    /// KloFireGlow at radius 8. Sized slightly smaller than a real
    /// notch (180×28 vs ~200×32) so it reads as "klo's own pill" rather
    /// than imitation hardware.
    private var dormantPill: some View {
        let width: CGFloat = 180
        let height: CGFloat = 28
        return ZStack {
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(KloColors.ink)
                .frame(width: width, height: height)
                .modifier(KloFireGlow(active: true, radius: 8))
                .allowsHitTesting(false)
            updateArrowOverlay
        }
    }

    /// Floats above the dormant pill when Sparkle has found a newer
    /// version on a scheduled background check. Tap fires a user-
    /// initiated check via Sparkle, which opens its stock install
    /// sheet. Hidden when no update is pending (~99% of the time).
    @ViewBuilder
    private var updateArrowOverlay: some View {
        if updater.updateAvailable != nil {
            Button(action: { updater.checkForUpdates() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KloColors.olive)
                    .modifier(KloFireGlow(active: true, radius: 3))
            }
            .buttonStyle(.plain)
            .help(updateAvailableTooltip)
            .offset(y: -22)
            .scaleEffect(updateArrowBreath ? 1.18 : 1.0)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: updateArrowBreath
            )
            .onAppear { updateArrowBreath = true }
        }
    }

    private var updateAvailableTooltip: String {
        if let v = updater.availableVersionString {
            return "klo \(v) available. Click to update."
        }
        return "An update is available"
    }

    // MARK: - Sidecar health banner + transient notice

    /// Small capsule below the notch carrying sidecar health while the
    /// local agent is down. Starting/restarting renders a pulsing olive
    /// dot + "klo agent is starting…" (non-interactive); failed renders
    /// an orange dot + Retry affordance. Same pill vocabulary as the
    /// stop pill / WorkingStatusPill.
    @ViewBuilder
    private var sidecarHealthBanner: some View {
        switch sidecar.health {
        case .healthy:
            EmptyView()
        case .starting, .restarting:
            statusCapsule(dotColor: KloColors.olive, pulsing: true) {
                Text("klo agent is starting…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            .allowsHitTesting(false)
        case .failed:
            statusCapsule(dotColor: KloColors.orange, pulsing: false) {
                Text("klo agent unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                Button {
                    sidecar.retry()
                } label: {
                    Text("Retry")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KloColors.orange)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Restart klo's agent")
            }
        }
    }

    /// True while the agent runs (any .working state).
    private var isWorkingMode: Bool {
        if case .working = state.mode { return true }
        return false
    }

    /// Gate for the one-time extension nudge: idle, healthy sidecar
    /// (no pill stacking), onboarding done, never connected, never
    /// dismissed.
    private var showsExtensionNudge: Bool {
        state.mode == .idle
            && sidecar.health == .healthy
            && CloudOnboardingCard.hasCompleted
            && !bridge.extensionConnected
            && !extensionNudgeDismissed
    }

    private var extensionNudgePill: some View {
        statusCapsule(dotColor: KloColors.olive, pulsing: false) {
            Text("klo works in Chrome too")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
            Button {
                extensionNudgeDismissed = true
                bridge.openInstall()
            } label: {
                Text("Get extension")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KloColors.olive)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Let klo read and click pages inside your browser")
            Button {
                extensionNudgeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .onChange(of: bridge.extensionConnected) { connected in
            // Connected = nudge served its purpose; retire it forever.
            if connected { extensionNudgeDismissed = true }
        }
    }

    private func statusCapsule<Content: View>(
        dotColor: Color,
        pulsing: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: dotColor.opacity(0.55), radius: 4)
                .modifier(KloFireGlow(active: pulsing, radius: 3))
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    /// Auto-dismissing toast below the current surface — content comes
    /// from `state.transientNotice` (set via showTransientNotice).
    private func transientNoticeToast(_ text: String) -> some View {
        statusCapsule(dotColor: KloColors.orange, pulsing: false) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .allowsHitTesting(false)
    }

    private var fallbackPanel: some View {
        let dims = surfaceDimensions
        // Working state liberates itself from the panel chrome: no
        // black background, no border, no card shadow. The
        // FireBubblesView renders its own soft atmospheric cloud
        // (radial gradients fading to transparent at the edges —
        // matches the onboarding CeremonyBackdrop composition
        // language) so a rectangle wrapper would fight the design.
        // Every other expanded mode keeps the existing card chrome.
        let isWorking: Bool = {
            switch state.mode {
            case .working, .resuming: return true
            default: return false
            }
        }()
        return ZStack(alignment: .top) {
            // Expanded-state content (text bar, voice fire, working
            // pill, completed panel, paywall, etc.). Hidden at idle —
            // the dormant pill below carries the at-rest signal.
            content
                .frame(width: dims.width, height: dims.height)
                .background(isWorking ? Color.clear : Color.black)
                .clipShape(RoundedRectangle(cornerRadius: state.mode == .idle ? 4 : 18))
                .overlay(
                    RoundedRectangle(cornerRadius: state.mode == .idle ? 4 : 18)
                        .stroke(state.mode == .idle || isWorking
                                ? Color.clear
                                : Color.white.opacity(0.18),
                                lineWidth: state.mode == .idle ? 1 : 0.5)
                )
                .opacity(state.mode == .idle ? 0 : 1)
                .shadow(color: .black.opacity((state.isExpanded && !isWorking) ? 0.22 : 0), radius: 22, x: 0, y: 10)

            // Dormant pill — only at idle. Mirrors the cinematic
            // NotchSilhouette overlay used in the MBP path.
            if state.mode == .idle {
                dormantPill
            }

            // Sidecar health + transient notice — same surfaces as the
            // notched path, anchored below the pill / panel content.
            if state.mode == .idle && sidecar.health != .healthy {
                sidecarHealthBanner
                    .offset(y: 42)
                    .transition(.opacity)
            }
            if let notice = state.transientNotice {
                // max() keeps the toast clear of the 28pt dormant pill
                // when idle (where dims.height is a few points).
                transientNoticeToast(notice)
                    .offset(y: max(dims.height, 28) + 14)
                    .transition(.opacity)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Mode-driven dimensions

    /// Total dimensions of the notch surface BELOW the notch (the part
    /// that visibly extends downward). Width must be ≥ notch width +
    /// 2*topCornerRadius for the shape to fully cover the notch.
    private var surfaceDimensions: CGSize {
        let g = detector.geometry
        let baseExtra = topCornerRadius * 2
        switch state.mode {
        case .idle:
            // Idle: notch + a barely-there wisp below — only the tapered
            // outline is visually noticeable. Restored to the original
            // 3-6pt sliver; the dormant "alive" look comes from a
            // separate overlay that mirrors the cinematic NotchSilhouette,
            // NOT from inflating these layout dimensions (which had
            // cascading effects on positioning).
            return CGSize(width: g.width + baseExtra,
                          height: max(3, bottomCornerRadius * 0.45))
        case .textExpanded:
            // Spotlight bar — taller for breath around the input row +
            // baseline + caps hint. The 760pt width gives the field
            // ~620pt of usable text area which reads comfortably on
            // both 13" and 15" screens.
            //
            // When the proactive-pills row is populated (it almost
            // always is — connector pills are computed synchronously
            // on appear), the surface grows by ~46pt to house the
            // pill row + its top/bottom padding.
            // Height grows in three independent steps:
            //   * Proactive pills below the input: +46pt
            //   * Cross-surface mirror pickup above the input: +38pt
            //   * Thread peek strip above the input: +54pt (44pt strip
            //     + its top padding). Peek and pickup never coexist —
            //     the pickup row is gated on messages.isEmpty, the
            //     peek strip on !messages.isEmpty.
            // The history overlay replaces the whole stack with a
            // fixed taller surface: filter header + up to ~8 rows +
            // footer hints.
            do {
                if state.showingHistory {
                    return CGSize(width: 760, height: 420)
                }
                var h: CGFloat = 100
                if !state.messages.isEmpty { h += 54 }
                if !state.proactiveCards.isEmpty { h += 46 }
                if !state.mirrorPickup.isEmpty && state.messages.isEmpty { h += 38 }
                return CGSize(width: 760, height: h)
            }
        case .voiceExpanded:
            // Voice mode keeps its own dimensions — voice has a
            // different state machine (RealtimeBridge, mic gating) and
            // its own affordances. Not part of the fire-bubble redesign.
            return CGSize(width: 760, height: 100)
        case .working, .resuming:
            // Working surface: 60%-scaled green fire (~376×176, per
            // the user's "60% smaller than voice fire" spec) hanging
            // upside-down from the hardware notch like a transparent
            // dormant pulse, with friendly activity bubbles right
            // under the notch hardware. ALL chrome stripped — no
            // NotchShape mask, no background, no orange outline.
            //
            // Height = 220pt: fire (~176pt at top) + bubble row
            // overlapping the fire's mid-section (bubbles sit right
            // under notch hardware, fire glows around/behind them).
            // Pinned to the top of the panel (no notch-bottom
            // pushdown — see notchSilhouette working branch).
            return CGSize(width: 720, height: 220)
        case .completed:
            // Golden-ratio chat surface for the final answer (φ ≈ 1.618).
            // Bumped 40pt wider + 36pt taller from the prior compact /
            // transcript pair to add breathing room around the result.
            return state.transcriptExpanded
                ? CGSize(width: 920, height: 580)
                : CGSize(width: 760, height: 480)
        case .failed, .failedExtensionMissing:
            // Error variant uses the chat shell — match compact
            // dimensions so the surface doesn't pop sideways on a
            // failure.
            return CGSize(width: 760, height: 480)
        case .paywallRequired:
            // Auth/billing card. Widened to track the chat panel for
            // a consistent reading width across all expanded modes.
            return CGSize(width: 760, height: 420)
        case .permissionRequired:
            // Small island, not a full result panel. The point of the
            // permission UI is to *not* hog the screen so the user can
            // click in System Settings underneath. Bumped slightly so
            // the body copy doesn't crowd the buttons.
            return CGSize(width: 600, height: 232)
        case .signInRequired:
            // Same island vocabulary as the permission island —
            // small, focused, dismissable. User can keep clicking
            // around the OS while sign-in is in flight.
            return CGSize(width: 600, height: 252)
        case .confirmingAction:
            // Inline confirm bar. Wider than the permission island
            // because the summary line can run long ("Send 'meeting
            // moved to 4pm and please RSVP by EOD' to john@x.com").
            return CGSize(width: 680, height: 252)
        case .webPane:
            // Klo's embedded web view. Dimensions are constrained by
            // the underlying NSPanel canvas (1000×700 — see KLO
            // WindowController.windowWidth/Height) so that the panel
            // doesn't overflow off-screen and get re-positioned by
            // AppKit, which would move the notch silhouette away from
            // the hardware notch. We leave ~30pt below the bottom and
            // ~20pt on either side for breathing room around the
            // WKWebView. 960×620 is right at the cusp of "real
            // desktop" web rendering (above mobile-breakpoint 768,
            // below desktop-breakpoint 1024) — fits the pane shape
            // klo's overlay supports today.
            //
            // Future polish: dynamically expand the panel canvas
            // itself during .webPane mode, then `.webPane` could
            // return a larger size and Cursor-like 1100+pt pane is
            // achievable. KLOWindowController.windowWidth would need
            // to become mode-aware.
            return CGSize(width: 960, height: 620)
        case .offerSaveCredential:
            // "Save sign-in for {host} to klo?" island. Same vocabulary
            // as the permission / sign-in islands — small, focused,
            // dismissable. Body copy is short (host + username), CTAs
            // are two buttons. 600×196 keeps it the same width as the
            // sign-in island so the visual rhythm matches.
            return CGSize(width: 600, height: 196)
        case .scheduleConfirm:
            // 2.0.0 always-confirm card. Same width as the chat
            // surface so the modal swap doesn't pop dimensions.
            // Height accommodates step list scroll for routines.
            return CGSize(width: 760, height: 480)
        case .workspaceInitiated:
            // Init moment — matches textExpanded chat ratio. 760pt wide
            // so the card reads as continuous with klo's input panel.
            // Compact height; the focal brief gets generous whitespace.
            return CGSize(width: 760, height: 220)
        case .workspaceApproval:
            // Approval gate — same chat ratio. Slightly taller for the
            // ask + internally-scrollable payload + action row. The
            // card height is FIXED — long payloads scroll inside the
            // payload block so the notch geometry stays intentional.
            return CGSize(width: 760, height: 320)
        case .connections:
            // Inline Composio connections browser — Raycast/Arc-Spaces
            // style. Width 760 matches Completed-compact and is the
            // proven baseline that doesn't bleed past 13" MBP edges.
            //
            // Featured row is now a 2×4 grid (was 1×8). The single-row
            // variant overflowed on real-world panels because the
            // surface mask + insets shave usable width below the
            // nominal 760pt. 4 tiles × 76pt fits with comfortable
            // margin under any reasonable display.
            //
            // Height bumped to 580pt so the doubled featured section
            // (~210pt incl. labels) still leaves the all-apps grid
            // ~200pt of breathing room.
            return CGSize(width: 760, height: 580)
        }
    }

    // Golden-ratio corner radii: bottom / top = φ ≈ 1.618. Both pairs are
    // also Fibonacci adjacents (8/13 compact, 13/21 expanded), which gives
    // the silhouette a continuous, mathematically-satisfying curve flow as
    // the shape morphs between modes.
    private var topCornerRadius: CGFloat {
        switch state.mode {
        case .idle: return 8
        default: return 13
        }
    }
    private var bottomCornerRadius: CGFloat {
        switch state.mode {
        case .idle: return 13
        // Working/resuming uses a true pill silhouette: bottom corners
        // at half the surface height (42 → 21pt) so the side curves run
        // continuously all the way across, eliminating any "rectangle
        // with rounded corners" feel. Borrowed from Open iOS's
        // horizontal-pill CTA shape.
        case .working, .resuming: return 21
        // All other expanded modes get a deeper bottom curve than
        // before (was 21pt) so the silhouette reads as horizontal-
        // dominant rather than chunky-square.
        default: return 32
        }
    }

    // MARK: - Accent stroke

    private var accentStroke: Color {
        switch state.mode {
        // Idle: no stroke at all — the breathing olive halo from
        // the overlaid cinematic NotchSilhouette is the entire
        // signal of "klo is alive." A stroke on top would just be
        // a line drawn on the halo's edge, fighting the soft glow.
        case .idle: return .clear
        case .failed: return Color.red.opacity(0.55)
        case .working: return KloColors.olive.opacity(0.18)
        default: return .clear
        }
    }
    /// Core border — crisp uniform stroke that wraps the entire
    /// silhouette including the small top corners (where the shape
    /// meets the hardware notch). Bumped up from the previous tapered
    /// design so the outline is always perfectly visible regardless of
    /// background contrast.
    private var outlineCoreWidth: CGFloat {
        switch state.mode {
        case .idle: return 1.4
        default: return 1.2
        }
    }

    /// Soft outer halo behind the core border — gives the outline
    /// presence against varying backgrounds (light wallpapers, busy
    /// app windows) and contributes the "pan with handles" feel by
    /// pushing the silhouette visually outward at the corners.
    private var outlineHaloWidth: CGFloat {
        switch state.mode {
        case .idle: return 3.0
        default: return 2.6
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .idle:
            EmptyView()
        case .textExpanded:
            // ProactiveTextHost wraps TextInputView with the proactive
            // cards row that sits above the input. The host owns the
            // signal-snapshot lifecycle so this view stays declarative.
            // Falls back to a bare input when the snapshot returns
            // nothing — same visual surface as before in that case.
            ProactiveTextHost(onSubmit: handleSubmit)
                .transition(.opacity.animation(.easeInOut(duration: 0.18)))
        case .voiceExpanded:
            VoiceInputView(onSubmitTranscript: handleSubmit, onSwitchToText: { state.toggleText() })
                .transition(.opacity.animation(.easeInOut(duration: 0.18)))
        case .working, .resuming:
            // Fire-bubble surface — replaces the legacy pill (which
            // surfaced raw tool args as "ASKING TELL"). Friendly
            // first-person bubbles stack above a small green-fire
            // glow. New activity pulses the fire + adds a bubble; old
            // bubbles fade out the top. WispPresenter still fires for
            // the wisp orb's per-click flash, but the notch's primary
            // status surface is now the bubbles + fire.
            //
            // 2.1.1 — the QueryPhraser opener bubble ("on it") used to
            // fire on submit, even for chitchat that never used a tool.
            // It's now deferred to the FIRST tool activity (see
            // noteToolActivity). So this view renders an empty fire
            // panel for chitchat (no bubble shouted), and only starts
            // accumulating bubbles once klo is actually doing screen /
            // shell / connector work. Fire-only surface for a brief
            // window is calmer than a "what's up" bubble for a hello.
            FireBubblesView(
                state: state,
                onCancel: {
                    // klo 2.1.1: routine previews + scheduled run-now
                    // are cloud-dispatched on the sidecar — the local
                    // cancelCurrentRun path is a no-op for them. Route
                    // to the cloud's /schedules/{id}/cancel-active
                    // endpoint first so the in-flight agent run on the
                    // sidecar actually aborts. Then collapse local
                    // state.
                    if let suggestionId = state.pendingPreviewSuggestionId {
                        Task {
                            _ = await SchedulesManager.shared.cancelActiveRun(suggestionId)
                        }
                        state.clearPreviewMarker()
                        state.showTransientNotice("preview cancelled")
                        state.collapseToIdle()
                    } else if let taskId = state.pendingRunNowTaskId {
                        Task {
                            _ = await SchedulesManager.shared.cancelActiveRun(taskId)
                        }
                        state.pendingRunNowTaskId = nil
                        state.showTransientNotice("run cancelled")
                        state.collapseToIdle()
                    } else {
                        agentClient.cancelCurrentRun()
                    }
                }
            )
            .transition(.opacity.animation(.easeInOut(duration: 0.20)))
        case .completed(let query, let response):
            ResultPanelView(
                query: query, responseText: response,
                isError: false,
                onDismiss: { state.collapseToIdle() },
                onSubmit: handleSubmit
            )
            // Same surface as .working — content swap, not a panel
            // resize. Tiny delay so the prior view's removal commits
            // before the new one builds.
            .transition(
                .opacity.animation(.easeOut(duration: 0.18))
            )
        case .failed(let query, let error):
            ResultPanelView(
                query: query, responseText: error,
                isError: true, onDismiss: { state.collapseToIdle() }
            )
            .transition(
                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.22))
            )
        case .failedExtensionMissing(let query, let response):
            // Branded "klo needs the Chrome extension for that." card
            // — Install + Retry buttons, lifts the user out of the
            // dead-end the previous salmon RuntimeError text dropped
            // them into.
            MissingExtensionPanel(query: query, response: response) {
                state.collapseToIdle()
            } onRetry: { retryQuery in
                agentClient.submitQuery(retryQuery)
            }
            .transition(
                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.22))
            )
        case .paywallRequired(let reason, let draftPrompt):
            // Auth + subscription gate. Reads coordinator/account from
            // environment to route to SignIn / Stripe Checkout / Customer
            // Portal as appropriate for the reason.
            PaywallPanelView(reason: reason, draftPrompt: draftPrompt)
                .transition(
                    .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.22))
                )
        case .permissionRequired(let query, let service):
            // Small island: "klo needs <X> — Grant". Grant collapses
            // the panel to idle so the user can actually click in
            // System Settings without klo's notch eating the clicks.
            // Auto-retry on next ⌘K is handled below via onChange.
            PermissionRequiredView(
                query: query,
                service: service,
                onGrant: {
                    handleGrantPermission(query: query, service: service)
                },
                onDismiss: {
                    state.collapseToIdle()
                }
            )
            .transition(
                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.10))
            )
        case .signInRequired(let draftPrompt):
            // Small "Sign in with Google" island. Visible for ~1.4s
            // (see onChange(state.mode) handler) then auto-collapses
            // so the OAuth browser tab is fully clickable. The saved
            // draft prompt lives in pendingSignInDraft until OAuth
            // completes; onChange(account.status) handles the retry.
            SignInIslandView(
                draftPrompt: draftPrompt,
                status: account.status,
                onSignIn: {
                    Task { await account.startSignInWithGoogle() }
                },
                onDismiss: {
                    pendingSignInDraft = nil
                    state.collapseToIdle()
                }
            )
            .transition(
                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.10))
            )
        case .confirmingAction(let payload):
            // Inline confirm bar emitted when the agent calls the
            // `confirm_action` tool for a destructive / sending /
            // money / system-changes action. Accept (⌘+Enter) routes
            // the user's approval back to the sidecar via
            // AgentClient.submitConfirm; the global ESC handler in
            // KLOWindowController handles cancellation.
            ConfirmActionView(
                payload: payload,
                onAccept: { agentClient.submitConfirm(approved: true) },
                onCancel: { agentClient.submitConfirm(approved: false) }
            )
            .transition(
                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.10))
            )
        case .webPane:
            // Klo's embedded web view. WebPaneView wraps the persistent
            // WKWebView owned by WebViewManager.shared. The pane stays
            // open for the lifetime of the .webPane mode; dismissing it
            // returns the state to .working so the underlying agent run
            // continues (the model can still web.click / web.text in
            // the background — we just stop showing the page).
            WebPaneView(
                manager: WebViewManager.shared,
                onDismiss: { state.dismissWebPane() }
            )
            .transition(.opacity.animation(.easeInOut(duration: 0.18)))
        case .offerSaveCredential(let host, let username, let pendingId):
            SaveCredentialIslandView(
                host: host,
                username: username,
                onAccept: {
                    NotificationCenter.default.post(
                        name: .kloCredentialSaveAccepted,
                        object: nil,
                        userInfo: ["pendingId": pendingId],
                    )
                    state.dismissSaveCredential()
                },
                onDecline: {
                    NotificationCenter.default.post(
                        name: .kloCredentialSaveDeclined,
                        object: nil,
                    )
                    state.dismissSaveCredential()
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        case .connections(let previousDraft):
            // Inline Composio connections panel — Raycast / Arc Spaces
            // style. Search + featured row + all-apps grid + footer
            // hints. ConnectionsView consumes account directly for the
            // catalog fetch + connect/disconnect dispatch.
            ConnectionsView(
                account: account,
                initialQuery: extractConnectionsInitialQuery(previousDraft),
                onDismiss: { state.dismissConnections() }
            )
            .transition(
                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    .animation(.spring(response: 0.42, dampingFraction: 0.86))
            )
        case .scheduleConfirm(let pending):
            // 2.0.0 always-confirm gate. Pending row promoted into
            // scheduled_tasks only after the user taps Confirm. After
            // resolve, KLOState chains through any other pending rows
            // in the queue (SchedulesManager.pending).
            ScheduleConfirmCard(pending: pending, state: state)
                .transition(
                    .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        .animation(.spring(response: 0.42, dampingFraction: 0.86))
                )
        case .workspaceInitiated(let snapshot):
            // Long-horizon harness: klo recognized a multi-day ask and
            // called workspace_init. Hero card surfaces the brief +
            // workspace path + init summary; user taps Open or Got it.
            WorkspaceInitiatedCard(snapshot: snapshot, state: state)
                .transition(
                    .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        .animation(.spring(response: 0.42, dampingFraction: 0.86))
                )
        case .workspaceApproval(let approval):
            // Long-horizon harness: a Worker queued an external action
            // via workspace_request_human. Gate stays up until Approve
            // or Reject is tapped.
            WorkspaceApprovalCard(approval: approval, state: state)
                .transition(
                    .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        .animation(.spring(response: 0.42, dampingFraction: 0.86))
                )
        }
    }

    /// If the user invoked /apps via a slash command (handleSubmit
    /// passes the trailing token through previousDraft as the query),
    /// pre-fill the search field. Otherwise no pre-fill.
    private func extractConnectionsInitialQuery(_ draft: String?) -> String {
        guard let draft else { return "" }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Convention: when handleSubmit detects `/apps <query>` it
        // stores the query portion (no slash prefix) here so the
        // ConnectionsView search field opens already filtered. A bare
        // /apps with nothing after returns "".
        return trimmed
    }

    /// Forward the Grant button click on the runtime permission
    /// island to `PermissionGrantOrchestrator`. The orchestrator owns
    /// the entire flow: open Settings, show the drag island, watch
    /// for the grant via PermissionMonitor, auto-retry the query,
    /// dismiss the island, bring klo to the front. The notch UI just
    /// collapses to idle so the user can interact with Settings.
    private func handleGrantPermission(query: String, service: KLOState.PermissionService) {
        guard let monitorService = PermissionMonitor.Service(service) else {
            // .appleEvents path — orchestrator still handles it (just
            // opens Settings without the drag island), so still call.
            // Defensive guard: this shouldn't fail since the bridge
            // covers all cases.
            return
        }
        // Collapse the notch first so System Settings is fully
        // clickable. The orchestrator's drag island lives in its own
        // panel; it does not need the notch to be open.
        state.collapseToIdle()

        // Hand off — closure captures `query` for retry.
        let queryToRetry = query
        let client = agentClient
        PermissionGrantOrchestrator.shared.request(service: monitorService) {
            client.submitQuery(queryToRetry)
        }
    }

    private func handleSubmit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Slash-command intercept — `/apps`, `/connect`, `/connections`,
        // `/integrations` all open the connections panel. Optional
        // trailing text becomes the initial search query
        // (e.g., `/apps gmail` opens connections filtered to gmail).
        let connectionsCommands: Set<String> = [
            "/apps", "/connect", "/connections", "/integrations",
        ]
        let lowered = trimmed.lowercased()
        let firstToken = lowered.split(separator: " ", maxSplits: 1).first.map(String.init) ?? lowered
        if connectionsCommands.contains(firstToken) {
            // Strip the slash command + a single space — what remains
            // is the initial filter for ConnectionsView's search.
            let query: String
            if let spaceIdx = trimmed.firstIndex(of: " ") {
                query = String(trimmed[trimmed.index(after: spaceIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                query = ""
            }
            state.showConnections(previousDraft: query.isEmpty ? nil : query)
            return
        }
        // Slash-app scope — `/notion list my pages` etc. If the leading
        // token matches a real Composio toolkit slug, strip the prefix
        // and pass the slug as a soft scope hint to the agent. Falls
        // through to the unscoped path if no slug match.
        if firstToken.hasPrefix("/"),
           let scoped = parseAppScope(trimmed) {
            agentClient.submitQuery(scoped.query, scopedService: scoped.slug)
            return
        }
        agentClient.submitQuery(trimmed)
    }

    /// Parse `/<slug> <rest>` and return (slug, rest) iff `<slug>` is
    /// present in the Composio catalog snapshot. Returns nil otherwise
    /// so an unknown `/<word>` falls through to the unscoped submit
    /// path (the user typed something that LOOKS like a command but
    /// isn't an app — let the model see it raw and figure it out).
    private func parseAppScope(_ text: String) -> (slug: String, query: String)? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let tokenChars = body.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !tokenChars.isEmpty else { return nil }
        let token = String(tokenChars).lowercased()
        // Must match a real catalog slug — otherwise treat as message.
        guard account.composioCatalogSnapshot.contains(where: { $0.slug.lowercased() == token }) else {
            return nil
        }
        let afterToken = body.dropFirst(tokenChars.count)
        let query = afterToken.drop(while: { $0 == " " }).trimmingCharacters(in: .whitespacesAndNewlines)
        return (slug: token, query: String(query))
    }
}


/// klo 2.1.1 — tiny pulsing olive dot anchored to the notch hardware
/// when an unacknowledged background scheduled run has finished and
/// posted its result to chat. The dot is a passive "klo has something
/// for you" affordance; tapping the notch reveals the chat surface
/// AND clears the dot via the KLOOverlayView mode-change observer.
///
/// Animation: 1.4s ease in/out alternating between 0.55 and 1.0 alpha
/// + 0.85 and 1.0 scale. Slow enough to feel ambient, fast enough to
/// catch peripheral attention without nagging.
private struct NotchHardwareDot: View {
    @State private var animating: Bool = false

    var body: some View {
        Circle()
            .fill(KloColors.olive)
            .frame(width: 6, height: 6)
            .shadow(color: KloColors.olive.opacity(0.7), radius: 4)
            .opacity(animating ? 1.0 : 0.55)
            .scaleEffect(animating ? 1.0 : 0.85)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: animating,
            )
            .onAppear { animating = true }
    }
}

