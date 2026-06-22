import SwiftUI

/// Wraps the chat input row with a row of proactive pills BELOW it.
/// Pills mix two flavors:
///
///   - Live signals (calendar event in 45m, page open in a browser /
///     known app) — pushed to the leading edge so they're the first
///     thing the eye sees when the user opens the notch.
///   - Connector starter prompts (gmail, slack, notion, linear, …) —
///     the same 8 featured Composio toolkits the iOS app pushes in
///     chat (PromptSuggestions.swift), ranked by what the user has
///     connected.
///
/// Tap a pill → its prompt is dropped into the input via
/// `state.pendingDraftRestore`, the existing channel that TextInputView
/// already listens to. We deliberately do NOT auto-submit; the iOS
/// app doesn't either. The user wants a starting line, not a fait
/// accompli.
///
/// Snapshot lifecycle has two beats: connector pills are computed
/// synchronously on appear so the row is non-empty on first paint, then
/// the async snapshot adds live signals when they arrive.
struct ProactiveTextHost: View {
    let onSubmit: (String) -> Void

    @EnvironmentObject var state: KLOState
    @EnvironmentObject var account: AccountManager

    var body: some View {
        ZStack(alignment: .top) {
            inputStack

            // Conversation history — layered over the input surface
            // rather than swapped in via a mode, so closing it drops
            // the user straight back into whatever they were doing.
            // Black background fully covers the input stack beneath.
            if state.showingHistory {
                ConversationHistoryOverlay()
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86),
                   value: state.showingHistory)
    }

    private var inputStack: some View {
        VStack(spacing: 0) {
            // Live-thread peek — when the user re-opens the notch with
            // a conversation still in memory, the last exchange sits
            // above the input as a quiet "you're mid-thread" cue.
            // Mutually exclusive with the mirror pickup below (that
            // strip is gated on messages.isEmpty), so the two never
            // stack.
            if !state.messages.isEmpty {
                ThreadPeekStrip()
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            // Cross-surface pickup (hermes-five M1). Sits ABOVE the
            // input row so the user notices "klo told you something
            // on your phone" before they start typing a new prompt.
            // Visible only while the local notch transcript is empty
            // and the cloud returned at least one carried-over turn.
            if !state.mirrorPickup.isEmpty && state.messages.isEmpty {
                MirrorPickupView(
                    messages: state.mirrorPickup,
                    onAccept: handlePickupAccept,
                    onDismiss: { state.clearMirrorPickup() },
                )
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }

            TextInputView(onSubmit: onSubmit)

            if !state.proactiveCards.isEmpty {
                ProactivePillsRow(signals: state.proactiveCards) { signal in
                    handlePillTap(signal)
                }
                .padding(.top, 4)
                .padding(.bottom, 9)
            }

            // Time-trial status chip. Renders only for users mid-trial
            // (gated inside the view via account.shouldShowTrialIndicator)
            // so paid + expired users see an empty View — VStack
            // collapses cleanly with no leftover spacing.
            TrialStatusIndicator()
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86),
                   value: state.proactiveCards.isEmpty)
        .animation(.spring(response: 0.42, dampingFraction: 0.86),
                   value: state.mirrorPickup.isEmpty)
        .animation(.spring(response: 0.42, dampingFraction: 0.86),
                   value: state.messages.isEmpty)
        .animation(.easeOut(duration: 0.22),
                   value: account.shouldShowTrialIndicator)
        .onAppear {
            // Synchronous first paint: connector pills only. These
            // don't require any system probe, so the row never starts
            // empty.
            let connected = Set(account.connectedToolkits)
            if state.proactiveCards.isEmpty {
                state.proactiveCards = ProactiveSignalsService.shared
                    .connectorPillsOnly(connected: connected)
            }
        }
        .task {
            // Async second beat: live signals (calendar event, screen
            // page) prepend in front of the connector pills.
            let connected = Set(account.connectedToolkits)
            let snapshot = await ProactiveSignalsService.shared.snapshot(connectedToolkits: connected)
            withAnimation(.spring(response: 0.50, dampingFraction: 0.86)) {
                state.proactiveCards = snapshot
            }
            // Cross-surface mirror — fetch the latest slice from
            // klo-cloud so the pickup row appears when there's
            // something fresh from the iPhone / extension. Account
            // must be signed in; the helper itself returns [] when
            // not.
            state.mirrorPickupLoading = true
            let rows = await MirrorClient.fetchRecent(using: account, limit: 6)
            state.mirrorPickupLoading = false
            // Filter to only the most recent assistant turn (the
            // strongest "pick up" signal) plus its immediate user
            // prompt. Bail out entirely if the most recent message
            // came from this Mac — there's nothing to pick up.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                state.mirrorPickup = Self.filterPickupCandidates(rows)
            }
        }
        // Re-snapshot whenever the user's connected-toolkits list flips
        // (a Composio connect/disconnect finishes and /auth/me lands
        // with the new array). Without this, tapping "connect calendar"
        // would only refresh the pill row the next time the user
        // re-opened the notch — visible lag between the OAuth callback
        // and the pill disappearing.
        .onChange(of: account.connectedToolkits) { _, newValue in
            Task {
                let next = await ProactiveSignalsService.shared.snapshot(
                    connectedToolkits: Set(newValue),
                )
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    state.proactiveCards = next
                }
            }
        }
        // klo 2.1 Track A: refresh the pill row when SchedulesManager
        // picks up a new active run, a new suggestion lands, or a run
        // finishes. The leading edge of the row becomes the live
        // "▸ running" / "💡 routine" surface so the user feels klo
        // working without re-opening the notch.
        .onChange(of: schedules.activeRuns) { _, _ in
            Task { await refreshPills() }
        }
        .onChange(of: schedules.suggestions) { _, _ in
            Task { await refreshPills() }
        }
    }

    @MainActor
    private func refreshPills() async {
        let connected = Set(account.connectedToolkits)
        let next = await ProactiveSignalsService.shared.snapshot(
            connectedToolkits: connected,
        )
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            state.proactiveCards = next
        }
    }

    /// klo 2.1: hook SchedulesManager so its @Published changes can
    /// trigger pill-row refreshes via .onChange above. Stored as a
    /// @StateObject would create a second poll loop; @ObservedObject
    /// just observes the existing shared singleton.
    @ObservedObject private var schedules = SchedulesManager.shared

    /// Convert the raw mirror slice into a tight set of 1-2 messages
    /// the pickup view can render. Filters out anything where the most
    /// recent message originated from this Mac surface (no value
    /// surfacing what the user already saw locally).
    private static func filterPickupCandidates(_ rows: [MirrorMessage]) -> [MirrorMessage] {
        guard let first = rows.first else { return [] }
        if first.source == "mac" { return [] }
        // Keep just the most recent assistant + (optionally) its user
        // prompt for context. Slim row makes scanning cheap.
        let assistant = rows.first(where: { $0.role == "assistant" }) ?? first
        if assistant.source == "mac" { return [] }
        return [assistant]
    }

    private func handlePickupAccept() {
        // Slurp the carried-over assistant text into the notch's
        // local transcript so the user can continue from there. The
        // notch panel will need to be in `.completed` mode for the
        // chat thread to be visible — so we transition into it,
        // seeding the messages array.
        let mapped: [KLOState.Message] = state.mirrorPickup.map { m in
            KLOState.Message(
                role: m.role == "user" ? .user : .assistant,
                content: m.content,
                scopedService: m.scoped_service,
            )
        }
        state.messages.append(contentsOf: mapped)
        // Seed the completed state with the assistant text so the
        // existing `.completed(query:response:)` surface renders the
        // restored thread immediately.
        let lastUser = mapped.last(where: { $0.role == .user })?.content ?? ""
        let lastAssistant = mapped.last(where: { $0.role == .assistant })?.content ?? ""
        if !lastAssistant.isEmpty {
            state.showCompleted(query: lastUser, response: lastAssistant)
        }
        state.clearMirrorPickup()
    }

    private func handlePillTap(_ signal: ProactiveSignal) {
        if signal.prompt == ProactiveSignal.connectCalendarPrompt {
            // Route the pill straight into the standard Composio OAuth
            // flow. AccountManager opens the browser, the bounce page
            // returns via klo://composio?...&connection_id=..., and
            // /auth/me refresh then re-publishes `connectedToolkits`.
            // Our .onChange below catches that flip and refreshes the
            // pill row, at which point the calendar pill disappears
            // (replaced by the googlecalendar connector pill) without
            // any further wiring here.
            account.startComposioConnect(toolkit: "googlecalendar")
            return
        }
        // klo 2.1 Track A: routine-suggestion pill. Sentinel prompt
        // carries the suggestion id; tap kicks off the preview-run
        // path which posts to chat and then surfaces the
        // "schedule this?" follow-up.
        if signal.prompt.hasPrefix(ProactiveSignal.suggestionPromptPrefix) {
            let id = String(signal.prompt.dropFirst(ProactiveSignal.suggestionPromptPrefix.count))
            // klo 2.1.1: enter .working IMMEDIATELY for tap-time visual
            // confirmation + mark this as a preview so the cancel X +
            // completion router both know what to do.
            let name = SchedulesManager.shared.suggestions.first { $0.id == id }?.name
                ?? "routine"
            state.markUserTap()
            state.startWorking(query: "Preview: \(name)")
            state.markCurrentRunAsPreview(suggestionId: id)
            Task {
                let outcome = await SchedulesManager.shared.previewSuggestion(id)
                if outcome != .dispatched {
                    // Cloud rejected the preview before the run even
                    // started (Mac offline / not signed in / etc).
                    // Drop the working state we eagerly entered and
                    // surface a transient notice with what went wrong.
                    await MainActor.run {
                        state.clearPreviewMarker()
                        state.collapseToIdle()
                        state.showTransientNotice(outcome.humanMessage)
                    }
                }
            }
            return
        }
        // klo 2.1 Track A: running-schedule pill. For now tap routes
        // to Settings → Schedules so the user can see the row +
        // cancel. (A dedicated inline panel is a follow-up polish
        // pass.)
        if signal.prompt.hasPrefix(ProactiveSignal.runningPillPrefix) {
            SettingsWindowController.shared.show()
            return
        }
        guard !signal.prompt.isEmpty else { return }
        // Fill, don't submit — matches iOS PromptSuggestions behavior.
        // The existing pendingDraftRestore channel is what
        // TextInputView already listens to for /apps panel returns; the
        // .onChange wiring (added in TextInputView) lets it pick up
        // changes after first appear.
        state.pendingDraftRestore = signal.prompt
    }
}
