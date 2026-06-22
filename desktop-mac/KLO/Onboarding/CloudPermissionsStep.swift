import SwiftUI

/// Permissions step tuned for the cloud-hosted onboarding card.
/// Compared to the standalone `PermissionsStep`:
///   - No inline animated mockup (it bloats each card by ~90pt and the
///     full-size mockup belongs in the handoff reminder panel where
///     it has space and serves real guidance value).
///   - Compact cards (~76pt each, vs the standalone's ~150pt with
///     mockup) so all 5 cards + headline + Continue button fit in a
///     ~720pt-tall card with breathing room.
///   - Tuned for the cloud surface (lighter eyebrow, slightly tighter
///     hero typography).
struct CloudPermissionsStep: View {
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var bridge: BridgeStatusManager

    /// Required: the cloud-hosted version always has a focus
    /// coordinator (Open Settings goes through the orderOut/reminder
    /// flow). Standalone `PermissionsStep` is the one with the
    /// optional coordinator.
    let focusCoordinator: OnboardingFocusCoordinator

    /// Set by the parent when we ended up on this step *despite* the
    /// durable "ever granted" flag saying we should have skipped it
    /// — i.e. TCC says not-granted but we know the user did grant.
    /// Surfaces the stale-hint immediately (otherwise it waits 12s
    /// after the user clicks Open Settings). Diagnostic, not a fresh
    /// first-time ask.
    let forceShowStaleHint: Bool

    /// Set when the user clicks Open Settings on a required card.
    /// If we're still waiting >12s after that, we surface a stale-grant
    /// hint ("klo can't see your grant — try toggling off then on") so
    /// the user isn't stuck wondering why their toggle isn't being
    /// detected. The most common cause in dev builds: klo's cdhash
    /// changed between rebuilds and macOS doesn't transfer the trust
    /// grant to the new binary identity.
    @State private var requestedAt: Date?
    @State private var showStaleHint: Bool = false
    @State private var isReBinding: Bool = false

    /// True when the OS-native AX prompt has fired at least once on
    /// this install (durable across launches) AND klo's permissions
    /// still aren't live. Means the user has clicked through the
    /// prompt + System Settings flow at least once without success —
    /// usually cdhash drift where macOS shows klo as enabled but
    /// doesn't honor the grant for this binary's identity.
    private var hasPromptedAndStuck: Bool {
        UserDefaults.standard.bool(forKey: PermissionsManager.didShowAXPromptKey)
            && !permissions.requiredAllGranted
    }

    var body: some View {
        OnboardingStepShell(
            eyebrowLabel: "permissions",
            title: heroText,
            subtitle: "klo needs 2 things from macOS to do the rest. Three more are optional (voice, Notes/Calendar, Chrome).",
            animateTitle: true,
            contentTopPadding: 14
        ) {
            // Progress pips first — sit tight under the subtitle.
            HStack(spacing: 6) {
                progressPip(granted: permissions.accessibility == .granted,
                            active: !permissions.requiredAllGranted &&
                                    permissions.accessibility != .granted)
                progressPip(granted: permissions.screenRecording == .granted,
                            active: permissions.accessibility == .granted &&
                                    permissions.screenRecording != .granted)
            }

            // Required tier — 2 cards, compact, no inline mockups.
            VStack(spacing: 8) {
                permissionRow(
                    icon: "keyboard",
                    title: "Accessibility",
                    description: "Move the cursor and press keys for you.",
                    status: permissions.accessibility,
                    previouslyGranted: permissions.hasEverGrantedAccessibility,
                    onAction: {
                        // If we know this was granted before, prefer
                        // a silent recheck before re-opening Settings —
                        // covers the cdhash-drift case where TCC just
                        // needs to be re-read after the new process boots.
                        if permissions.hasEverGrantedAccessibility
                            && permissions.accessibility != .granted {
                            permissions.forceRecheck()
                        } else {
                            requestedAt = Date()
                            showStaleHint = false
                            focusCoordinator.requestHandoff(.accessibility)
                        }
                    }
                )
                permissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    description: "See your screen so klo can answer questions about it.",
                    status: permissions.screenRecording,
                    previouslyGranted: permissions.hasEverGrantedScreenRecording,
                    onAction: {
                        if permissions.hasEverGrantedScreenRecording
                            && permissions.screenRecording != .granted {
                            permissions.forceRecheck()
                        } else {
                            requestedAt = Date()
                            showStaleHint = false
                            focusCoordinator.requestHandoff(.screenRecording)
                        }
                    }
                )
            }
            .padding(.top, 22)

            // Stale-grant hint — appears under any of these conditions:
            //   - 12s after the user clicked Open Settings (the timer
            //     fallback for "I clicked the button and nothing happened")
            //   - immediately if `forceShowStaleHint` is set (parent
            //     routed us here despite a durable prior-grant flag)
            //   - immediately if `hasCDHashDrifted` (current cdhash
            //     differs from the one persisted at last live grant)
            //   - immediately if we've already shown the AX prompt at
            //     least once (`didShowAXPromptKey` set) AND the user
            //     is still stuck on this step. Catches the common dev
            //     case where the user toggled in System Settings but
            //     TCC didn't bind the grant to this build's cdhash —
            //     the durable flag never flipped because the live API
            //     never returned .granted. Re-bind is the recovery.
            if (showStaleHint || forceShowStaleHint || permissions.hasCDHashDrifted || hasPromptedAndStuck) && !permissions.requiredAllGranted {
                staleGrantHint
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Optional band — divider + heading + 3 slimmer cards.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(KloColors.borderFaint)
                        .frame(height: 1)
                    Text("optional")
                        .kloEyebrow()
                    Rectangle()
                        .fill(KloColors.borderFaint)
                        .frame(height: 1)
                }

                permissionRow(
                    icon: "appclip",
                    title: "Apple Events",
                    description: "Read state from scriptable apps like Notes, Calendar, and Music.",
                    status: permissions.appleEvents,
                    optional: true,
                    onAction: permissions.requestAppleEvents
                )
                permissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Voice mode. Hold ⌘⇧K to talk.",
                    status: permissions.microphone,
                    optional: true,
                    onAction: permissions.requestMicrophone
                )
                // Chrome-extension card REMOVED. klo drives every
                // browser (Safari + every Chromium-family browser)
                // via the universal accessibility surface now —
                // AXManualAccessibility auto-enable on Chromium
                // populates the full rendered DOM as AX nodes, no
                // extension required. BridgeStatusManager + bridge
                // server keep running silently for back-compat.
            }
            .padding(.top, 16)

            Spacer(minLength: 16)

            // Restart toast — visible during the coordinator-owned
            // 1.6s grace before auto-relaunch. The coordinator
            // observes SR + persists the resume step + fires the
            // relaunch (see OnboardingFocusCoordinator.observeScreenRecordingRelaunch).
            if focusCoordinator.screenRecordingRestartPending {
                restartingToast
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // No Continue button — the parent's derived currentStep
            // auto-advances when both permissions land granted (durable
            // flag flips). The cloud's top-right × is the escape valve
            // for users who want to bail without finishing.
        }
        .animation(.easeOut(duration: 0.25), value: focusCoordinator.screenRecordingRestartPending)
        .animation(.easeOut(duration: 0.25), value: showStaleHint)
        // Stale-grant hint timer — wait 12s after user clicked Open
        // Settings; if still not granted, show the hint.
        .task(id: requestedAt) {
            guard requestedAt != nil else { return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if !permissions.requiredAllGranted {
                showStaleHint = true
            }
        }
        // Re-check on appear (returning to the step from handoff).
        // Also pre-register klo in the AX + SR Privacy lists so the
        // user finds it ALREADY PRESENT when they hit Open Settings.
        // The macOS native AX alert ("klo wants Accessibility, open
        // System Settings or deny") fires here — alongside the
        // explanatory cloud card so the user has context — instead
        // of firing later at the same moment as the Settings deep
        // link, where it would compete with Settings for focus.
        // Both registration calls are idempotent: AX shows its alert
        // only on the first call per install (when klo isn't yet
        // registered); subsequent calls and SR are silent.
        .onAppear {
            permissions.forceRecheck()
            // Skip the AX prompt if it's already granted — calling
            // requestAccessibility() with prompt=true on an
            // already-trusted app is mostly a no-op, but on fresh
            // Debug builds (or after a tccutil reset that leaves
            // the user thinking they granted) macOS may still
            // re-pop the modal. Guarding by the recheck snapshot
            // means returning users never see the OS-native dialog
            // a second time.
            if permissions.accessibility != .granted {
                permissions.requestAccessibility()
            }
            if permissions.screenRecording != .granted {
                permissions.requestScreenRecording()
            }
        }
    }

    // MARK: - Stale-grant hint

    private var staleGrantHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KloColors.olive)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(permissions.hasCDHashDrifted
                         ? "This build's identity changed."
                         : "Already toggled it on?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KloColors.fg)
                    Text(permissions.hasCDHashDrifted
                         ? "Your previous grant was bound to an earlier klo build. macOS keeps grants per-binary, so this fresh build reads as untrusted. Re-bind below — one click, then re-toggle in System Settings."
                         : "klo can't see your grant yet. macOS sometimes loses trust between app rebuilds. Re-bind below, or in System Settings toggle klo OFF then back ON.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(KloColors.fg60)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    permissions.forceRecheck()
                    requestedAt = Date()
                    showStaleHint = false
                } label: {
                    Text("Recheck")
                }
                .buttonStyle(.kloGhost)
                .disabled(isReBinding)

                Button {
                    isReBinding = true
                    Task {
                        await permissions.resetAndReprompt()
                        // Reset transient UI state — the re-prompt
                        // restarts the System Settings flow as if first-run.
                        showStaleHint = false
                        requestedAt = Date()
                        isReBinding = false
                    }
                } label: {
                    if isReBinding {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Resetting…")
                        }
                    } else {
                        Text("Re-bind permissions")
                    }
                }
                .buttonStyle(.kloPrimary)
                .disabled(isReBinding)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(KloColors.olive.opacity(0.40), lineWidth: 0.5)
        )
    }

    // MARK: - Hero copy + pips

    /// Live-updating count: "Step 1 of 2 — Accessibility" while
    /// pending; "All set." when both granted.
    private var heroText: String {
        if permissions.requiredAllGranted { return "All set." }
        if permissions.accessibility != .granted {
            return "Step 1 of 2 — Accessibility."
        }
        return "Step 2 of 2 — Screen Recording."
    }

    /// Single progress pip. Granted = filled orange. Active (current
    /// step) = orange-bordered hollow. Pending = faint border.
    @ViewBuilder
    private func progressPip(granted: Bool, active: Bool) -> some View {
        Capsule()
            .fill(granted ? KloColors.olive
                  : active ? KloColors.olive.opacity(0.55)
                  : KloColors.borderFaint)
            .frame(width: active ? 22 : 14, height: 4)
            .animation(.easeOut(duration: 0.3), value: granted)
            .animation(.easeOut(duration: 0.3), value: active)
    }

    // MARK: - Restart toast

    private var restartingToast: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(KloColors.olive)
                .frame(width: 8, height: 8)
                .modifier(KloFireGlow(active: true, radius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("restarting klo")
                    .kloEyebrow()
                Text("Activating Screen Recording. See you in a moment.")
                    .font(.kloCaption)
                    .foregroundStyle(KloColors.fg80)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(KloColors.olive.opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: - Permission row (compact, no inline mockup)

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        status: PermissionsManager.Status,
        previouslyGranted: Bool = false,
        optional: Bool = false,
        actionLabel: String = "Open Settings",
        onAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // Icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(status == .granted
                          ? KloColors.olive.opacity(0.12)
                          : KloColors.bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                status == .granted ? KloColors.olive.opacity(0.4) : KloColors.border,
                                lineWidth: 0.5
                            )
                    )
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(status == .granted ? KloColors.olive : KloColors.fg60)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KloColors.fg)
                    if optional {
                        Text("optional")
                            .kloEyebrow()
                    }
                }
                Text(previouslyGranted && status != .granted
                     ? "Previously granted — toggle klo off then on in Settings if klo can't see it."
                     : description)
                    .font(.system(size: 12))
                    .foregroundStyle(previouslyGranted && status != .granted
                                     ? KloColors.olive.opacity(0.85)
                                     : KloColors.fg60)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Right-aligned action.
            if status == .granted {
                grantedPill
            } else {
                Button {
                    onAction()
                } label: {
                    Text(previouslyGranted ? "Recheck" : actionLabel)
                }
                .buttonStyle(.kloGhost)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    status == .granted ? KloColors.olive.opacity(0.30) : KloColors.border,
                    lineWidth: 0.5
                )
        )
    }

    private var grantedPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("granted")
                .kloEyebrow()
        }
        .foregroundStyle(KloColors.olive)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(KloColors.olive.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(KloColors.olive.opacity(0.45), lineWidth: 0.5)
        )
    }

    // MARK: - Chrome-extension card derived state

    private var bridgeStatusForCard: PermissionsManager.Status {
        bridge.extensionConnected ? .granted : .notRequested
    }

    private var bridgeCardDescription: String {
        if bridge.extensionConnected {
            return "klo can drive Chrome on your behalf."
        }
        if !bridge.sidecarReachable {
            return "klo's agent is still starting up — one moment."
        }
        return "Read tabs, click, fill forms. Currently in Web Store review."
    }
}
