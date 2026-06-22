import Foundation
import SwiftUI

// State machine for the panel. Views observe via @EnvironmentObject; the
// hotkey manager and agent client mutate via the transition methods.
//
// Transitions (per plan):
//   idle → textExpanded     ⌘K
//   idle → voiceExpanded    ⌘⇧K
//   textExpanded ↔ voiceExpanded   mic icon tap
//   any expanded → idle     Escape, click outside, hotkey toggle
//   textExpanded → working  Return key submits the query
//   voiceExpanded → working after voice capture submits text
//   working → idle          run completion, cancellation, or tap on pill
@MainActor
final class KLOState: ObservableObject {

    enum Mode: Equatable {
        case idle
        case textExpanded
        case voiceExpanded
        case working(query: String)
        case completed(query: String, response: String)
        case failed(query: String, error: String)
        // Specialised failure surface: the agent's run hit a tool that
        // needs the Chrome extension, but the extension wasn't
        // connected. Rendered as a brand-styled card with Install +
        // Retry buttons in ResultPanelView, instead of the raw salmon
        // error string. `response` carries the agent's final message
        // when the run still completed gracefully without the tool —
        // the card shows it so the reply isn't lost behind the CTA.
        case failedExtensionMissing(query: String, response: String?)
        // Auth/billing gate: user submitted a prompt but isn't signed
        // in or doesn't have an active subscription. Rendered as a
        // PaywallPanelView with the right CTA depending on reason.
        // draftPrompt is the text the user submitted — preserved so
        // we can auto-resubmit after they unlock.
        case paywallRequired(reason: PaywallReason, draftPrompt: String)
        // The agent tried to do something but hit a macOS TCC denial
        // (Accessibility / Screen Recording / AppleEvents). Rendered
        // as a small island with a Grant button. The query is saved
        // so we can auto-re-submit once the user grants the missing
        // permission. service identifies which TCC service to deep-
        // link System Settings to.
        case permissionRequired(query: String, service: PermissionService)
        // Transient state shown for ~600ms right after the user grants
        // a permission and klo auto-retries their original task.
        // Surfaces a small "Continuing your request…" pill so the user
        // knows klo is back and resuming, not that they need to repeat
        // the prompt. The panel then transitions into .working on the
        // first stream event from the retried run.
        case resuming(query: String)
        // The user submitted a query but isn't signed in. Rendered as
        // a small "Sign in with Google" island. draftPrompt is the
        // query they typed; preserved so we can auto-re-submit once
        // account.status flips signed-in via the OAuth callback.
        case signInRequired(draftPrompt: String?)
        // The agent called the `confirm_action` tool for a sending /
        // money / destructive / system-change. Rendered as an inline
        // confirm bar with Accept (⌘+Enter) and Cancel (Esc). Once
        // resolved via AgentClient.submitConfirm, the run continues
        // in the sidecar and we drop back to `.working` to await the
        // next status event.
        case confirmingAction(payload: ConfirmPayload)
        // Embedded web pane mode — klo's overlay expands into a large
        // panel hosting WKWebView. Activated when MacOpsServer receives
        // a web.open call (it posts the .kloShowWebPane notification).
        // The query string is the original prompt that led here, so the
        // pane's close X can fall back to .working(query) instead of
        // .idle (the agent run is still ongoing in the background).
        case webPane(query: String)
        // The user just submitted a login form inside the embedded
        // WKWebView. Klo intercepted the form values and wants to ask
        // "Save sign-in for {host} to klo?" — a small island in the
        // notch with two buttons. pendingId references the in-memory
        // password held by CredCaptureCoordinator; if the user accepts,
        // the notch posts a notification with the pendingId that the
        // coordinator resolves into a keychain write.
        case offerSaveCredential(host: String, username: String, pendingId: String)
        // Inline connections browser — Composio toolkits with search +
        // tile grid. Enterable from .textExpanded (via /apps slash
        // command or the icon affordance in the empty text bar) or
        // from .idle / .textExpanded (via the ⌘⇧A global hotkey).
        // previousDraft is whatever the user had typed in .textExpanded
        // before opening connections — Esc restores it so a 3-second
        // detour to connect Gmail doesn't lose their in-flight prompt.
        case connections(previousDraft: String?)
        // klo 2.0.0: always-confirm gate for a new schedule. Triggered
        // when the polling SchedulesManager finds a pending row in
        // klo-cloud (created by the agent's schedule_task tool, the
        // routine builder, or an accepted suggestion). The confirm
        // card shows cadence + prompt + scoping; Confirm promotes the
        // row to scheduled_tasks, Cancel drops it. After resolve, drops
        // back to whatever mode was active before.
        case scheduleConfirm(pending: PendingSchedule)
        // Long-horizon harness: klo recognized a multi-day ask and
        // called workspace_init. Hero card surfaces the brief, the
        // workspace path, and the init summary. User taps Open (Finder)
        // or Got it (dismiss to textExpanded).
        case workspaceInitiated(snapshot: WorkspaceSnapshot)
        // Long-horizon harness: a worker queued an external-action
        // approval via workspace_request_human. Gate card shows ask +
        // payload preview. User taps Approve (releases the gate) or
        // Reject (records refusal + dismisses).
        case workspaceApproval(approval: WorkspaceApproval)
    }

    /// Payload for `.confirmingAction`. Mirrors the JSON the sidecar
    /// emits in the `confirm_request` event.
    struct ConfirmPayload: Equatable {
        let summary: String
        let irreversible: Bool
        let danger: String?
        /// The query that triggered this run — shown as the dim
        /// monospaced header above the summary so the user knows
        /// which task is asking.
        let query: String
    }

    /// Which macOS TCC service is blocking the current task.
    enum PermissionService: Equatable {
        case accessibility
        case screenRecording
        case appleEvents

        var displayName: String {
            switch self {
            case .accessibility:    return "Accessibility"
            case .screenRecording:  return "Screen Recording"
            case .appleEvents:      return "Automation (Apple Events)"
            }
        }

        /// `x-apple.systempreferences:` URL pointing at the right pane.
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

    /// Why klo can't run the prompt right now. Maps to AccountManager
    /// + klo-cloud /usage/task_start error codes.
    ///
    /// Time-trial cases (`dailyLimitReached`, `trialExpired`) flow from
    /// the new Path B pricing: Free tier is 5 chats/day × 7-day window.
    /// AgentClient parses the 402 `detail.error` field and routes to the
    /// matching reason; PaywallPanelView shows distinct copy + the same
    /// $20/mo Pro upgrade picker.
    enum PaywallReason: Equatable {
        case signInRequired             // .unknown / .signedOut / .awaitingOAuth
        case subscribeRequired          // legacy / generic 402 fallback
        case updateBillingRequired      // .signedInPastDue
        case resubscribeRequired        // .signedInExpired
        case dailyLimitReached          // 6th chat today, trial still active
        case trialExpired               // past day 7 of the trial window
    }

    @Published var mode: Mode = .idle

    // ─── Conversation state ─────────────────────────────────────────────
    //
    // The notch chat is multi-turn: each user submission appends a
    // .user message and each successful agent reply appends a .assistant
    // message. AgentClient.submitQuery sends `messages` (minus the just-
    // typed prompt) as `prior_messages` so the model has the full thread
    // for follow-ups.
    //
    // Collapsing the panel does NOT wipe the conversation any more —
    // close + reopen keeps the transcript so the user can pick up where
    // they left off. The array is capped (maxLiveMessages) so
    // prior_messages stays bounded, and every turn is also persisted to
    // ConversationStore (JSON in Application Support) across sessions,
    // grouped into resumable conversations.

    struct Message: Identifiable, Equatable {
        enum Role: String { case user, assistant }
        let id: UUID = UUID()
        let role: Role
        let content: String
        /// Composio toolkit slug (e.g., "notion") when the user prefixed
        /// the submission with `/<slug>`. Drives the service chip
        /// rendered before the message text in TurnView. Nil for
        /// assistant turns and for un-scoped user turns. Stable across
        /// the conversation — included in `prior_messages` payload so
        /// the model remembers the original scope across follow-ups.
        var scopedService: String? = nil
    }

    @Published var messages: [Message] = []

    /// Tail cap for the in-memory conversation so the `prior_messages`
    /// payload can't grow without bound now that collapse no longer
    /// clears it. Full history (last ~50 conversations) lives in
    /// ConversationStore.
    private static let maxLiveMessages = 40

    /// Mirrors ConversationStore's active pointer so views can react
    /// to thread switches without observing the store directly.
    /// Nil between startNewConversation() and the first turn of the
    /// next thread (the store creates conversations lazily on append).
    /// Starts nil even when the store has a persisted pointer — fresh
    /// launches deliberately don't reload the live transcript, and the
    /// mirror syncs on the first append/resume.
    @Published var currentConversationID: UUID? = nil

    /// True while the conversation-history overlay is up inside the
    /// .textExpanded panel. Deliberately NOT a mode — the overlay is
    /// a view affordance layered over text input, and keeping it out
    /// of the mode machine means none of the panel/hit-testing/escape
    /// plumbing needs new cases. Reset on any transition to .idle.
    @Published var showingHistory: Bool = false

    /// How long a thread can sit untouched before ⌘K starts a fresh
    /// one instead of silently extending it. Two hours matches the
    /// migration's session-splitting gap in ConversationStore, so
    /// resumed history and live behavior agree on what "one
    /// conversation" means.
    private static let conversationStaleAfter: TimeInterval = 2 * 60 * 60

    /// Archive the current thread and start clean. The old thread
    /// stays in ConversationStore (the conversations array IS the
    /// archive) — only the active pointer and the live transcript
    /// reset. Sealing first keeps a dangling user turn from reading
    /// as an open request if the thread is later resumed.
    func startNewConversation() {
        sealDanglingUserTurn()
        ConversationStore.shared.startNew()
        messages = []
        currentConversationID = nil
    }

    /// Load a stored conversation back into the live transcript so the
    /// next prompt continues that thread (its tail rides along as
    /// prior_messages). Seals the current thread first so switching
    /// away mid-exchange doesn't leave an open request behind.
    ///
    /// Lands the user in the full chat surface (`.completed` mode with
    /// the last exchange as the active view) so they actually FEEL
    /// like they're inside the thread — scrollback visible, input bar
    /// below, ready to continue. The previous behavior dropped to
    /// `.textExpanded` (slim input bar) so the loaded transcript was
    /// invisible and the user couldn't tell anything had loaded.
    func resumeConversation(_ id: UUID) {
        sealDanglingUserTurn()
        guard let conv = ConversationStore.shared.resume(id: id) else { return }
        messages = conv.messages.suffix(Self.maxLiveMessages).map { entry in
            Message(
                role: entry.role == "user" ? .user : .assistant,
                content: entry.content,
                scopedService: entry.scopedService
            )
        }
        currentConversationID = id
        showingHistory = false

        // Find the most-recent user→assistant pair to seed
        // `.completed` mode's headline view. Walk backwards from the
        // tail because a thread normally ends on an assistant reply;
        // pair that with the user message immediately before it.
        var lastUser: String? = nil
        var lastAssistant: String? = nil
        for msg in messages.reversed() {
            if lastAssistant == nil, msg.role == .assistant {
                lastAssistant = msg.content
                continue
            }
            if lastAssistant != nil, msg.role == .user {
                lastUser = msg.content
                break
            }
        }

        if let q = lastUser, let r = lastAssistant {
            // Full chat surface — ResultPanelView shows the latest
            // exchange + scrollback of the rest of `messages`. Feels
            // like the user re-entered the thread mid-conversation.
            setMode(.completed(query: q, response: r))
        } else {
            // Edge case: conversation has no completed exchange yet
            // (e.g. only a user turn was saved without a reply, or
            // history is empty). Fall back to the input bar so the
            // user can type their first/next prompt.
            if mode != .textExpanded {
                setMode(.textExpanded)
            }
        }
    }

    /// Called on idle → textExpanded. If the active thread's last turn
    /// is older than the staleness window, quietly rotate to a fresh
    /// conversation — the user opening the notch after lunch almost
    /// certainly wants a new thread, and the old one stays one ↑ away
    /// in the history overlay.
    private func startNewConversationIfStale() {
        guard let last = ConversationStore.shared.activeConversation?.lastMessage?.date else { return }
        if Date().timeIntervalSince(last) > Self.conversationStaleAfter {
            startNewConversation()
        }
    }

    // ─── Transient notice (lightweight toast) ──────────────────────────
    //
    // Small, auto-dismissing status line rendered below the notch by
    // KLOOverlayView regardless of mode. Used for failures that need a
    // brief user-visible acknowledgement but no dedicated panel — e.g.
    // a pause/cancel POST that didn't reach the sidecar.

    @Published var transientNotice: String? = nil
    private var noticeDismissTask: Task<Void, Never>? = nil

    // ─── klo 2.1.1 — scheduled-run feedback ──────────────────────────────
    //
    // Mac previously had NO record of which in-flight run was a preview
    // vs a regular user-typed prompt. That meant the notch Cancel X
    // went to the local-run cancel path even for cloud-dispatched
    // preview runs (no-op), and the completion router couldn't tell
    // "I just tapped a suggestion" from "klo's 9am cadence ticked."
    // Both end-of-run paths funneled to the same silent dropoff the
    // user complained about on "Check disk space weekly."
    @Published var pendingPreviewSuggestionId: String? = nil
    @Published var pendingRunNowTaskId: String? = nil
    @Published private(set) var lastUserTap: Date = .distantPast
    @Published var notchHardwareDotShouldPulse: Bool = false

    /// Mark "the user just did something" so the completion router can
    /// distinguish from passive cadence fires. Tap-suggestion + tap-
    /// run-now both call this first thing.
    func markUserTap() { lastUserTap = Date() }

    /// Bind a tap-suggestion event to the in-flight preview run so the
    /// notch Cancel X + completion router know what to do.
    func markCurrentRunAsPreview(suggestionId: String) {
        pendingPreviewSuggestionId = suggestionId
    }

    func clearPreviewMarker() {
        pendingPreviewSuggestionId = nil
    }

    /// Cloud-dispatched scheduled run finished and pushed its result —
    /// append into the live transcript so the chat surface shows it the
    /// same way Mac-local runs do.
    func appendScheduledMessage(content: String, metadata: [String: Any]) {
        let msg = Message(role: .assistant, content: content)
        messages.append(msg)
        while messages.count > Self.maxLiveMessages {
            messages.removeFirst()
        }
    }

    func showTransientNotice(_ text: String, duration: TimeInterval = 3.5) {
        noticeDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            transientNotice = text
        }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                self.transientNotice = nil
            }
        }
    }

    /// Compact-by-default with an opt-in expand. The notch's `.completed`
    /// surface usually shows just the latest assistant reply + the input
    /// bar; flipping this true grows the panel to a scrollable bubble
    /// transcript of `messages`. Local UI affordance, but published
    /// here so `KLOOverlayView.surfaceDimensions` (which decides panel
    /// height) and `ResultPanelView` (which decides what to render)
    /// stay in sync without prop drilling. Reset to false alongside
    /// `messages` on any transition to `.idle`.
    @Published var transcriptExpanded: Bool = false

    // ─── Live tool activity (the "passing-by chips" in the working fire) ──
    //
    // The agent's run lifecycle on the wire emits `step_progress` events
    // for every tool call (computer.screenshot, computer.click_element,
    // applescript, accessibility, ...). AgentClient translates those
    // into a human-friendly `currentAction` label here, which the
    // working-mode overlay renders as a single subtitled status line
    // above the fire glow. `recentActions` is the rolling tail used for
    // the "← took screenshot   ◉ clicking now" ticker treatment.
    //
    // All three reset on transition to .idle or when a new run starts.

    /// Human label for the action klo is doing right this second
    /// ("looking at your screen", "clicking the menu bar"). Nil between
    /// tool calls — the model is reasoning, not acting.
    ///
    /// Kept for the wisp overlay (still uses single-string label). The
    /// notch's working surface now uses `activityBubbles` instead.
    @Published var currentAction: String? = nil

    /// Stack of activity bubbles for the working-mode fire surface.
    /// Newest-first — index 0 is what was just emitted. Capped at 3
    /// by `appendActivityBubble` and auto-pruned by `_pruneOldBubbles`.
    /// FireBubblesView reads this; nobody else should mutate it.
    @Published var activityBubbles: [ActivityBubble] = []

    /// Rolling tail of recent action labels for the ticker. Capped at
    /// 4 entries; oldest drops off as new ones arrive. Used only by
    /// the working overlay; not persisted across runs.
    @Published var recentActions: [ToolAction] = []

    /// Total tool calls dispatched since the run started. Drives the
    /// "· 3 actions" subtitle.
    @Published var actionCount: Int = 0

    /// True once any `web` tool call fired during the current run.
    /// Cleared with the rest of the activity ledger. The overlay uses
    /// this + the bridge's extension status to caption degraded runs.
    @Published var sawWebActivity: Bool = false

    /// Which surface klo is currently targeting. Drives the wisp /
    /// fire indicator's tint so the user can tell at a glance whether
    /// the agent is in the high-trust accessibility/web path or in the
    /// pixel-vision fallback. Set by `noteToolActivity` based on the
    /// tool that just fired.
    enum TargetingMethod: String, Equatable {
        case unknown
        case accessibility   // identity-based, highest trust (olive)
        case web             // Chrome extension, high trust (teal)
        case applescript     // scriptable apps, high trust (olive)
        case shell           // file/system ops, high trust (olive)
        case vision          // computer.click_element / find_element (copper warning)
    }
    @Published var currentTargetingMethod: TargetingMethod = .unknown

    /// Wall-clock start of the active run — used to render the
    /// "· 2.4s" elapsed marker. Set when entering .working, cleared
    /// when leaving it.
    @Published var workingStartedAt: Date? = nil

    /// Mirrors the server-side run state's `paused` flag. Flipped by
    /// `status_change` events with a `paused` key. When true, the
    /// WebPaneView shows the HAND BACK pill instead of the working
    /// indicator + steer input — the user is driving the page.
    @Published var isPaused: Bool = false

    struct ToolAction: Identifiable, Equatable {
        let id: UUID = UUID()
        let label: String
        let startedAt: Date
    }

    /// Called by AgentClient when a `step_progress` arrives. Translates
    /// the raw tool name + action + detail into a sentence the user
    /// understands. Pushes onto `recentActions`, updates `currentAction`
    /// for the wisp overlay + voice mode's progressLine, AND appends an
    /// ActivityBubble for the notch's working surface.
    func noteToolActivity(name: String, action: String?, detail: String?) {
        // 2.1.1 — first-tool-fired path. The QueryPhraser bubble +
        // heartbeat used to fire unconditionally on every submit, even
        // for chitchat replies that never used a tool. Now they only
        // arm when klo has actually started doing screen / connector /
        // shell work, which is what the fire+bubble surface is for.
        // For text-only replies the chat panel stays calm.
        let isFirstToolFire = (actionCount == 0)

        // currentAction now ALSO routes through ActivityTranslator
        // (instead of the legacy humanizeTool which leaked
        // "ASKING TELL" / "USING GMAIL_LIST_THREADS"). Voice mode's
        // progressLine + the wisp overlay both read this — they get
        // the same friendly copy as the bubble stack. Fall back to
        // the legacy humanizer if the translator suppresses (returns
        // nil) so we always have SOMETHING to show in voice mode.
        let translated = ActivityTranslator.translate(
            name: name, action: action, detail: detail
        )
        let label = translated
            ?? Self.humanizeTool(name: name, action: action, detail: detail)
        currentAction = label
        actionCount += 1
        if isFirstToolFire {
            // Inject the dopamine bubble + start the silent-reasoning
            // heartbeat now that we know klo is genuinely working. The
            // QueryPhraser opener references the user's prompt, so we
            // need the original query — grab it off mode.
            if case .working(let query) = mode {
                appendActivityBubble(QueryPhraser.startingPhrase(for: query))
            }
            _startWorkingHeartbeat()
        }
        // Web tool fired this run. The overlay pairs this with the
        // bridge's live extension status to caption the working pill
        // ("working without the Chrome extension") so degraded web
        // runs are visible while they happen, not just after.
        if name == "web" { sawWebActivity = true }
        // Track which surface we're currently driving so the wisp
        // overlay can tint accordingly. Vision-fallback gets a
        // distinct (copper) tint so the user knows when reliability
        // drops to "best guess on pixels."
        switch name {
        case "accessibility":
            currentTargetingMethod = .accessibility
        case "web":
            currentTargetingMethod = .web
        case "applescript":
            currentTargetingMethod = .applescript
        case "shell":
            currentTargetingMethod = .shell
        case "computer":
            // Only flag as vision when the action is a vision-targeted
            // one. open_app / screenshot / type / key / scroll / wait
            // are all high-trust under `computer`.
            if action == "click_element" || action == "find_element" {
                currentTargetingMethod = .vision
            }
        default:
            break  // memory_*, request_permission, confirm_action etc — leave previous
        }
        let entry = ToolAction(label: label, startedAt: Date())
        recentActions.append(entry)
        if recentActions.count > 4 {
            recentActions.removeFirst(recentActions.count - 4)
        }
        // Push a short verb to the wisp overlay so the floating orb
        // carries the "what" alongside the "where". The presenter
        // trims to the first two words so the label fits.
        WispPresenter.shared.setLabel(label)

        // The bubble surface — the new primary working UI. The
        // translator returns nil for too-granular tools (screenshots,
        // AX index reads, single keypresses) so we don't flood the
        // stack with noise. Bubbles are also rate-limited: if a new
        // bubble would have the SAME text as the most-recent one, we
        // skip it (back-to-back identical clicks shouldn't pile up).
        if let bubbleText = ActivityTranslator.translate(
            name: name, action: action, detail: detail
        ) {
            appendActivityBubble(bubbleText)
        }
        // klo 2.1.1: every genuine tool activity resets the silent-
        // period clock. Heartbeats only surface when klo has actually
        // gone quiet for 12s+ — not on top of real progress.
        _resetWorkingHeartbeatDelay()
    }

    /// Append a bubble to the working-mode stack. Newest-first; capped
    /// at 3 visible. De-duplicates against the most recent bubble so
    /// rapid repeated tool calls (e.g. 5 accessibility clicks in a
    /// row) don't visually thrash. Public so QueryPhraser's starting
    /// bubble can be injected from startWorking().
    func appendActivityBubble(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let head = activityBubbles.first, head.text == trimmed {
            return  // Already on top — don't duplicate.
        }
        activityBubbles.insert(
            ActivityBubble(text: trimmed),
            at: 0
        )
        // Hard cap — keeps the published array compact even if the
        // view briefly renders fewer.
        while activityBubbles.count > 5 {
            activityBubbles.removeLast()
        }
    }

    func clearToolActivity() {
        currentAction = nil
        recentActions.removeAll()
        actionCount = 0
        workingStartedAt = nil
        sawWebActivity = false
        activityBubbles.removeAll()
        currentTargetingMethod = .unknown
    }

    /// Map the raw tool name + action + detail to a human label. The
    /// goal is conversational: "looking at your screen" reads better
    /// than "computer.screenshot {scope: window}". Intentionally
    /// undecorated — no quotes, no parentheses — so it sits cleanly
    /// in the working overlay's single-line treatment.
    private static func humanizeTool(name: String, action: String?, detail: String?) -> String {
        let n = name.lowercased()
        let a = (action ?? "").lowercased()
        let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines)

        // computer.* — vision + input ops
        if n == "computer" {
            switch a {
            case "screenshot":             return "looking at your screen"
            case "open_app":               return d.map { "opening \($0)" } ?? "opening an app"
            case "click_element":          return d.map { "clicking \($0)" } ?? "clicking"
            case "find_element":           return d.map { "finding \($0)" } ?? "finding an element"
            case "left_click", "right_click", "double_click", "triple_click":
                                            return "clicking"
            case "left_click_drag":        return "dragging"
            case "type":                   return d.map { "typing \(Self.shorten($0))" } ?? "typing"
            case "paste_text":             return "pasting"
            case "key":                    return d.map { "pressing \($0)" } ?? "pressing a key"
            case "hold_key":               return "holding a key"
            case "scroll":                 return "scrolling"
            case "mouse_move":             return "moving the cursor"
            case "wait":                   return "waiting a beat"
            case "get_cursor_position":    return "checking the cursor"
            default:                       return "running computer · \(a)"
            }
        }
        // accessibility.* — AX walking + writes
        if n == "accessibility" {
            switch a {
            case "actionable_index":       return "scanning the active app"
            case "focused_snapshot":       return "reading the focused window"
            case "screen_text":            return "reading on-screen text"
            case "menu_select":            return d.map { "navigating menu · \($0)" } ?? "navigating menus"
            case "press":                  return d.map { "pressing \($0)" } ?? "pressing"
            case "fill":                   return d.map { "filling \(Self.shorten($0))" } ?? "filling a field"
            case "set_focused":            return "focusing a control"
            default:                       return "using accessibility · \(a)"
            }
        }
        // applescript — read-only for now
        if n == "composio_execute" {
            // detail is typically the toolkit name (e.g. "notion"); action
            // might be the Composio action slug (e.g. "create_page"). Show
            // a friendly per-toolkit verb where we can.
            let toolkit = d?.lowercased() ?? a
            switch toolkit {
            case "notion":         return "writing to notion"
            case "gmail":          return "checking gmail"
            case "googlecalendar": return "looking at your calendar"
            case "googledrive":    return "browsing google drive"
            case "googlesheets":   return "updating sheets"
            case "googledocs":     return "editing docs"
            case "slack":          return "in slack"
            case "linear":         return "in linear"
            case "github":         return "in github"
            case "asana":          return "in asana"
            case "jira":           return "in jira"
            case "discord":        return "in discord"
            case "dropbox":        return "in dropbox"
            case "hubspot":        return "in hubspot"
            case "stripe":         return "in stripe"
            case "salesforce":     return "in salesforce"
            case "trello":         return "in trello"
            case "zoom":           return "in zoom"
            case "twilio":         return "via twilio"
            case "":               return "using an integration"
            default:               return "using \(toolkit)"
            }
        }
        if n == "composio_list_actions" {
            let toolkit = d?.lowercased() ?? a
            return toolkit.isEmpty ? "browsing integrations" : "scanning \(toolkit) actions"
        }
        if n == "applescript"      { return d.map { "asking \(Self.shorten($0))" } ?? "running applescript" }
        if n == "shell"            { return d.map { "running \(Self.shorten($0))" } ?? "running a command" }
        if n == "read_file"        { return d.map { "reading \($0)" } ?? "reading a file" }
        if n == "write_file"       { return d.map { "writing \($0)" } ?? "writing a file" }
        if n == "browser_task"     { return "browsing" }
        if n == "memory_remember"  { return "saving to memory" }
        if n == "memory_recall"    { return "checking memory" }
        if n == "memory_forget"    { return "forgetting" }
        if n == "request_permission" { return "asking for a permission" }
        if n == "i_couldnt_do_this"  { return "couldn't finish that" }
        // Fallback: name + action if action is meaningful.
        return a.isEmpty ? n : "\(n) · \(a)"
    }

    private static func shorten(_ s: String, max: Int = 28) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    func appendUserMessage(_ content: String, scopedService: String? = nil) {
        // Seal any dangling user turn first. A run that hung, failed,
        // or got force-quit leaves an unanswered user message; shipped
        // as prior_messages it reads as an OPEN REQUEST and the model
        // re-executes it instead of the new prompt (the "it kept
        // rerunning my old YouTube search" bug). A synthetic assistant
        // turn closes the exchange so history stays context, not a
        // to-do list.
        sealDanglingUserTurn()
        messages.append(Message(
            role: .user,
            content: content,
            scopedService: scopedService,
        ))
        trimLiveMessages()
        ConversationStore.shared.appendToActive(role: "user", content: content, scopedService: scopedService)
        currentConversationID = ConversationStore.shared.activeConversationID
    }

    /// If the transcript ends on an unanswered user message, append a
    /// terse assistant note that the request didn't finish. Called
    /// before each new user turn and from terminal failure paths.
    func sealDanglingUserTurn() {
        guard messages.last?.role == .user else { return }
        let note = "(klo didn't finish this request — it was interrupted.)"
        messages.append(Message(role: .assistant, content: note))
        ConversationStore.shared.appendToActive(role: "assistant", content: note)
    }

    func appendAssistantMessage(_ content: String) {
        messages.append(Message(role: .assistant, content: content))
        trimLiveMessages()
        ConversationStore.shared.appendToActive(role: "assistant", content: content)
        currentConversationID = ConversationStore.shared.activeConversationID
    }

    private func trimLiveMessages() {
        if messages.count > Self.maxLiveMessages {
            messages.removeFirst(messages.count - Self.maxLiveMessages)
        }
    }

    func toggleTranscriptExpanded() {
        transcriptExpanded.toggle()
    }

    // Direction-aware springs:
    //   openSpring — idle → expanded.  Lively entrance with a touch of
    //                bounce so the notch feels like it's "waking up".
    //   closeSpring — any → idle.  Decisive exit with no overshoot so the
    //                 panel settles cleanly back to a thin notch line.
    //   morphSpring — expanded → expanded (text → working, working →
    //                 completed, etc.).  Balanced, gentle settle.
    // All three are .spring() rather than the macOS 14 .smooth/.bouncy so
    // the app keeps its 13.0 deployment target.
    static let openSpring: Animation = .spring(response: 0.46, dampingFraction: 0.78, blendDuration: 0.20)
    static let closeSpring: Animation = .spring(response: 0.34, dampingFraction: 0.94, blendDuration: 0.20)
    static let morphSpring: Animation = .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.25)

    // Backwards-compat alias for views that used to reference modeTransition
    // directly. The balanced morph spring is the safest default.
    static let modeTransition: Animation = morphSpring

    var isExpanded: Bool {
        switch mode {
        // `.resuming` is treated like `.working` here — both render as a
        // small pill, not a full expanded panel, so click-away dismiss
        // and the panel's mouse-passthrough semantics apply.
        case .idle, .working, .resuming: return false
        case .textExpanded, .voiceExpanded, .completed, .failed, .failedExtensionMissing, .paywallRequired, .permissionRequired, .signInRequired, .confirmingAction, .webPane, .offerSaveCredential, .connections, .scheduleConfirm, .workspaceInitiated, .workspaceApproval: return true
        }
    }

    // Helper — pick the right spring for a transition based on the
    // direction of travel. Idle→X = open, X→idle = close, X→Y = morph.
    private func spring(from: Mode, to: Mode) -> Animation {
        switch (from, to) {
        case (.idle, _): return Self.openSpring
        case (_, .idle): return Self.closeSpring
        default: return Self.morphSpring
        }
    }

    private func setMode(_ next: Mode) {
        let anim = spring(from: mode, to: next)
        // klo 2.1.1: the moment the user opens klo into ANY non-idle
        // surface, clear the "unacknowledged background run" dot on
        // the notch hardware. Opening klo IS the acknowledgement.
        let leavingIdle: Bool = {
            if case .idle = mode {
                if case .idle = next { return false }
                return true
            }
            return false
        }()
        if leavingIdle, notchHardwareDotShouldPulse {
            notchHardwareDotShouldPulse = false
        }
        // klo 2.1.1: preview marker is per-run. Any transition to a
        // terminal state clears it so the next run's Cancel X uses
        // the correct path.
        if case .completed = next {
            pendingPreviewSuggestionId = nil
            pendingRunNowTaskId = nil
        }
        if case .idle = next {
            // The conversation survives dismissal — close + reopen
            // keeps the transcript (it's also persisted across
            // sessions via ConversationStore). Only the view-affordance
            // state resets here.
            if transcriptExpanded { transcriptExpanded = false }
            if showingHistory { showingHistory = false }
            // Proactive cards are also per-opening: clear on dismiss
            // so the next open re-snapshots fresh signals (relative
            // calendar timing stays honest).
            if !proactiveCards.isEmpty { proactiveCards.removeAll() }
            if idleWhisper != nil { idleWhisper = nil }
            clearToolActivity()
            pendingPreviewSuggestionId = nil
            pendingRunNowTaskId = nil
            // klo 2.1.1: cancel any in-flight heartbeat task — if the
            // user collapsed or the run was cancelled mid-flight, we
            // don't want stale heartbeat bubbles popping later.
            _stopWorkingHeartbeat()
        }
        // Tool activity is meaningful only DURING .working. The moment
        // we leave working (to .completed, .failed, .permissionRequired,
        // anything), the chips should clear so the next view doesn't
        // inherit a stale "looking at your screen" subtitle.
        if case .working = mode, case .working = next {
            // staying in working — preserve activity
        } else if case .working = mode {
            clearToolActivity()
        }

        // Wisp overlay visibility — the small glowing presence that
        // follows klo across the screen during a run. Show on entry to
        // any "agent is doing something" state; hide otherwise. The
        // presenter's hide() animates the wisp home before dismissing
        // so the user sees klo "return" from wherever it was acting.
        let nextIsActive = Self.modeWantsWisp(next)
        let prevIsActive = Self.modeWantsWisp(mode)
        if nextIsActive && !prevIsActive {
            WispPresenter.shared.show()
        } else if !nextIsActive && prevIsActive {
            WispPresenter.shared.hide()
        }

        // Publish the mode change WITHOUT a withAnimation wrapper.
        //
        // The wrapper used to batch this @Published write into an
        // animation transaction, which raced with the OTHER @Published
        // writes that landed milliseconds earlier (messages.append from
        // appendAssistantMessage in AgentClient). The race surfaced as
        // the "ghost state" bug: response text written into
        // state.messages was invisible until the user dismissed +
        // re-summoned the panel, because ResultPanelView's body
        // evaluated inside the transaction and captured an empty
        // messages snapshot.
        //
        // Visual transitions are still animated — the view layer
        // applies explicit .transition(.opacity.animation(...)) and
        // .animation(spring, value: mode) modifiers (see KLOOverlayView
        // case branches). Those don't depend on this mutation being
        // inside withAnimation — they animate based on identity diffs.
        _ = anim  // intentionally unused; kept for future per-mode tuning hook
        mode = next
    }

    /// True iff `mode` is one of the states where klo is actively
    /// executing on the user's behalf — so the wisp should be visible.
    /// .textExpanded / .voiceExpanded are user-input modes (klo is
    /// waiting for the user), so the wisp stays hidden there.
    private static func modeWantsWisp(_ mode: Mode) -> Bool {
        switch mode {
        case .working, .resuming, .confirmingAction:
            return true
        default:
            return false
        }
    }

    // ---- transitions ----

    func toggleText() {
        switch mode {
        case .textExpanded:
            setMode(.idle)
        default:
            // Opening from idle is the "fresh summon" moment — the
            // right place to decide whether the lingering thread is
            // stale. Mid-session re-entries (completed → textExpanded
            // etc.) skip the check: the user is actively in a flow.
            if case .idle = mode {
                startNewConversationIfStale()
            }
            // ⌘K from any non-text state lands in text input, ready for
            // a follow-up prompt.
            setMode(.textExpanded)
        }
    }

    func toggleVoice() {
        switch mode {
        case .voiceExpanded:
            setMode(.idle)
        default:
            setMode(.voiceExpanded)
        }
    }

    func collapseToIdle() { setMode(.idle) }

    /// Show the inline Composio connections panel.
    /// Three trigger paths converge here: the /apps slash command in
    /// the text bar, the icon affordance on the empty text input, and
    /// the ⌘⇧A global hotkey. previousDraft preserves whatever the
    /// user was typing so Esc can restore it.
    func showConnections(previousDraft: String? = nil) {
        setMode(.connections(previousDraft: previousDraft))
    }

    /// Dismiss the connections panel. If we have a previousDraft, drop
    /// back into .textExpanded with that text (re-populated on the
    /// next render via TextInputView's initial-state propagation).
    /// Otherwise back to idle.
    func dismissConnections() {
        if case .connections(let draft) = mode, let draft, !draft.isEmpty {
            setMode(.textExpanded)
            // The actual text restoration happens in TextInputView via
            // a binding/initialDraft mechanism — KLOState just owns the
            // mode transition. (Wired in KLOOverlayView when it injects
            // the draft into TextInputView's initial text.)
            pendingDraftRestore = draft
        } else {
            setMode(.idle)
        }
    }

    /// One-shot draft restoration after dismissing connections. Read +
    /// cleared by TextInputView on appear. Lives here (not on the view)
    /// because the transition out of .connections happens before
    /// .textExpanded's view re-renders.
    @Published var pendingDraftRestore: String? = nil

    /// The current snapshot of proactive cards shown above the input
    /// in `.textExpanded`. Refreshed by `ProactiveTextHost` on appear;
    /// cleared in `setMode(.idle)` so the next opening regenerates
    /// (calendar relative-time stays accurate). Lives on state — not
    /// inside the host — so `KLOOverlayView.surfaceDimensions` can
    /// grow the panel height when cards arrive without prop drilling.
    @Published var proactiveCards: [ProactiveSignal] = []

    /// One soft line that sits above the empty input bar — keyed off
    /// what the user just had focus on (browser tab title, frontmost
    /// app verb) or, when no context fires, a curated rotation. Tap
    /// inserts the prompt into the input. Cleared on first keystroke
    /// and on collapse to idle. Set by `IdleWhisperProvider` when the
    /// notch transitions to `.textExpanded` with an empty thread.
    ///
    /// Why one line, not the pill row: the pill row is a list-shaped
    /// recommendation surface (engagement-design adjacent). The whisper
    /// is one suggestion, low-confidence by design, easy to ignore.
    @Published var idleWhisper: IdleWhisper? = nil

    struct IdleWhisper: Equatable, Identifiable {
        let id: UUID = UUID()
        /// What the user reads in the faded line.
        let text: String
        /// What lands in the input on tap. Usually equals `text` for
        /// curated rotations; for screen probes it's the longer verbose
        /// prompt sourced from ProactiveSignal.prompt.
        let prompt: String
        let source: Source

        enum Source: Equatable {
            case curated
            case screen(appBundleID: String)
        }
    }

    // ─── Long-horizon workspace surfaces ─────────────────────────────
    //
    // The Python sidecar's workspace primitives (agent2/workspace.py +
    // agent2/tools.py:workspace_*) create durable on-disk initiatives.
    // Two moments surface to the user as notch cards:
    //   1. `workspace_init` fired → WorkspaceInitiatedCard hero moment
    //      shown via `Mode.workspaceInitiated(snapshot)`.
    //   2. `workspace_request_human` queued a pending external action →
    //      WorkspaceApprovalCard trust gate shown via
    //      `Mode.workspaceApproval(approval)`. User taps Approve / Reject.
    //
    // Wired into the existing setMode pipeline so the panel size + the
    // outer-click-dismiss behaviour reuse the schedule-confirm pattern.
    // Resolution of an approval bridges back into the Python sidecar via
    // `WorkspaceBridge.shared.resolveApproval(...)` (TODO — for v1 the
    // resolve method just writes pending.json directly).

    struct WorkspaceSnapshot: Equatable {
        /// `meal-tracking-launch-2026-06-18` etc — filesystem slug.
        let slug: String
        /// User's original brief, captured verbatim into brief.md.
        let brief: String
        /// Absolute path to the workspace dir. Used by "Open" buttons
        /// to surface the user's files in Finder.
        let rootPath: String
        /// Bulleted checklist of what klo did during init. Each item
        /// renders with an olive check on WorkspaceInitiatedCard. Order
        /// matters — the card animates them in sequentially.
        let initSteps: [String]
        /// Human-readable cadence ("every monday", "weekdays", "daily")
        /// when klo scheduled a recurring check-in during init. nil
        /// when no schedule was created. The card parses this to render
        /// a 7-day drumbeat widget at the footer of the body.
        let cadence: String?
        /// Snapshots of the 5 workspace files captured at init. The card
        /// renders these as a real material stack so the workspace feels
        /// like a folder you could touch, not an abstraction.
        let files: [WorkspaceFile]
    }

    struct WorkspaceFile: Equatable {
        let name: String
        let bytes: Int
        /// Single-character monospace glyph used by the card row, e.g.
        /// "B" for brief, "P" for plan, "L" for log, "D" for decisions,
        /// "P" for pending. Renders as an inset olive-tinted square so
        /// the user reads the stack as a real folder listing.
        let glyph: String
    }

    struct WorkspacePayloadEntry: Equatable {
        let key: String
        let value: String
    }

    struct WorkspaceApproval: Equatable {
        /// Matches the `clearance_id` returned by workspace_request_human.
        let clearanceId: String
        /// Workspace slug — shown as a monospaced eyebrow.
        let workspaceSlug: String
        /// Why klo is asking (e.g. "publishing to YouTube").
        let reason: String
        /// One-line ask (e.g. "approve YT Short #1 for publish?").
        let ask: String
        /// Payload key-value pairs the user wants to see before approving
        /// (title, body, file path, publish_time, etc). Typed as a struct
        /// rather than tuple array so Equatable synthesizes cleanly +
        /// SwiftUI ForEach gets a stable identity.
        let payload: [WorkspacePayloadEntry]
    }

    func surfaceWorkspaceInitiated(_ snapshot: WorkspaceSnapshot) {
        setMode(.workspaceInitiated(snapshot: snapshot))
    }

    func surfaceWorkspaceApproval(_ approval: WorkspaceApproval) {
        setMode(.workspaceApproval(approval: approval))
    }

    /// Called by WorkspaceInitiatedCard's "Got it" tap and by the auto-
    /// fall-through after Open is pressed. Falls back to textExpanded so
    /// the user lands in a familiar surface ready for follow-up.
    func dismissWorkspaceInitiated() {
        setMode(.textExpanded)
    }

    /// Called by WorkspaceApprovalCard's Approve / Reject taps. v1 logs
    /// to the console; later this will POST through the bridge so the
    /// sidecar's pending.json gets updated and the waiting tool unblocks.
    func resolveWorkspaceApproval(_ approval: WorkspaceApproval, approved: Bool) async {
        // TODO(workspace-bridge): pipe to agent2 sidecar so the Python
        // workspace_check_clearance call returns the resolution.
        print("[workspace] approval \(approval.clearanceId) → \(approved ? "approved" : "rejected")")
        setMode(.textExpanded)
    }

    // ─── Cross-surface mirror pickup (hermes-five M1) ──────────────────
    //
    // When the user's iPhone has produced messages while the notch
    // was idle (or another Mac instance, or the Chrome extension), we
    // fetch the most recent slice from klo-cloud's /messages endpoint
    // and surface them as a small "pick up where you left off" card
    // ABOVE the proactive pills row when ⌘K opens the notch.

    /// Most-recent first slice of mirror messages from klo-cloud.
    /// Empty when there's nothing to surface OR before the first
    /// `refreshMirrorPickup()` of this opening.
    @Published var mirrorPickup: [MirrorMessage] = []

    /// True while a /messages GET is in flight. Drives the pickup
    /// view's loading state on its very first appearance per session.
    @Published var mirrorPickupLoading: Bool = false

    func clearMirrorPickup() {
        mirrorPickup.removeAll()
    }

    func startWorking(query: String) {
        // Reset the activity ledger BEFORE the mode transition so the
        // working overlay mounts with a clean slate. The setMode
        // transition guard above only clears on LEAVING working, not
        // entering — for entering, we do it here explicitly so the
        // workingStartedAt timestamp lines up with the user's
        // perception of "I just hit return".
        clearToolActivity()
        workingStartedAt = Date()

        // 2.1.1 — DO NOT inject the QueryPhraser bubble or start the
        // heartbeat here. The fire+bubble surface is reserved for runs
        // where klo is actually doing tool work (driving the screen,
        // fetching from a connector, running a shell command). For a
        // chitchat reply ("hey" → "hi back"), klo stays in the chat
        // panel with thinking dots and the answer streams in — no
        // fire, no bubble, no "on it" yelled across the panel for what
        // should have been a quiet hello.
        //
        // Both the QueryPhraser bubble and the heartbeat are now armed
        // inside `noteToolActivity` on the FIRST tool event. If the
        // agent finishes with no tools (text-only reply), neither
        // ever fires — the bubble overlay was deferred and unwound
        // cleanly to .completed.
        setMode(.working(query: query))
    }

    // MARK: - Working heartbeat (2.1.1)

    private var _heartbeatTask: Task<Void, Never>? = nil
    private var _heartbeatPhrases: [String] = [
        "still on it",
        "thinking through it",
        "still working on this for you",
        "almost there",
        "give me a sec, working on it",
    ]
    private var _heartbeatIndex: Int = 0

    private func _startWorkingHeartbeat() {
        _stopWorkingHeartbeat()
        _heartbeatIndex = 0
        _heartbeatTask = Task { [weak self] in
            // First heartbeat: 12s. Subsequent: every 20s. Stops the
            // moment we leave .working OR noteToolActivity fires (which
            // calls _resetWorkingHeartbeat below).
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self else { return }
                    if case .working = self.mode {
                        let phrase = self._heartbeatPhrases[
                            self._heartbeatIndex % self._heartbeatPhrases.count
                        ]
                        self._heartbeatIndex += 1
                        self.appendActivityBubble(phrase)
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func _stopWorkingHeartbeat() {
        _heartbeatTask?.cancel()
        _heartbeatTask = nil
    }

    /// Called from noteToolActivity to delay the next heartbeat — every
    /// real tool call resets the silent-period clock so heartbeats only
    /// surface during genuine silent reasoning, not on top of real
    /// activity.
    private func _resetWorkingHeartbeatDelay() {
        guard _heartbeatTask != nil else { return }
        _startWorkingHeartbeat()
    }

    func showCompleted(query: String, response: String) {
        setMode(.completed(query: query, response: response))

        // klo 2.1.1: when a run completes while the user is in another
        // app (Safari, Cursor, browser, etc.), the notch's chat panel
        // is technically visible at the top of the screen but easy to
        // miss without an attention cue. Pulse the notch-hardware dot +
        // post a quiet transient notice so they actually know klo is
        // done. Cleared when they tap into klo (the leaving-idle hook
        // in setMode handles it — but completed isn't idle, so we
        // also clear via the panel's own dismiss path).
        if !NSApp.isActive {
            notchHardwareDotShouldPulse = true
            showTransientNotice("klo finished — look up at the notch")
        }

        // Cancel any heartbeat work — the run is over.
        _stopWorkingHeartbeat()
    }

    /// Schedule confirm presentation. Called by SchedulesManager when
    /// it polls and finds pending rows. Only surfaces the card when
    /// the notch is in a non-disruptive state (idle, textExpanded, or
    /// completed) — interrupting an active run with a confirm card
    /// would feel wrong, so pending rows wait until the user is at a
    /// natural pause point. After Confirm/Cancel, we chain through
    /// any remaining queued rows by calling this again.
    func presentNextPendingConfirmIfNeeded() {
        guard let next = SchedulesManager.shared.pending.first else { return }
        switch mode {
        case .idle, .textExpanded, .completed:
            setMode(.scheduleConfirm(pending: next))
        default:
            break   // wait — current activity has priority
        }
    }

    /// Called by ScheduleConfirmCard's Confirm button. Routes through
    /// SchedulesManager which hits POST /pending_schedules/{id}/confirm
    /// and refreshes the active list. Returns the user to the textExpanded
    /// input so they can keep going.
    func confirmPendingSchedule(_ pending: PendingSchedule) async {
        _ = await SchedulesManager.shared.confirm(pending.id)
        showTransientNotice("Scheduled. klo will run it on cadence.")
        // Drop back to text input; queue chains via the polling pickup.
        setMode(.textExpanded)
        presentNextPendingConfirmIfNeeded()
    }

    /// Called by ScheduleConfirmCard's Cancel button. Optional reason
    /// feeds the suggestion-detector negative-signal loop (Phase 7).
    func rejectPendingSchedule(_ pending: PendingSchedule, reason: String? = nil) async {
        _ = await SchedulesManager.shared.reject(pending.id, reason: reason)
        setMode(.textExpanded)
        presentNextPendingConfirmIfNeeded()
    }

    func showFailed(query: String, error: String) {
        sealDanglingUserTurn()
        setMode(.failed(query: query, error: error))
    }

    /// Surface the embedded web pane (WebPaneView hosting WebViewManager
    /// .shared.webView). Called by the AppDelegate's observer of the
    /// `.kloShowWebPane` notification — which MacOpsServer posts when the
    /// model fires `web.open`. Passing `query` keeps a back-reference to
    /// the original prompt so dismissing the pane can return to the
    /// underlying .working state.
    func showWebPane(query: String) {
        setMode(.webPane(query: query))
    }

    /// Leave the web pane and return to the working state so the agent
    /// run continues (the run hasn't ended just because the user
    /// dismissed the pane — model can still web.click/text behind the
    /// scenes; we just stopped showing it).
    func dismissWebPane() {
        if case .webPane(let query) = mode {
            setMode(.working(query: query))
        }
    }

    /// Specialised failure transition for the "user asked klo to do
    /// something in the browser but the Chrome extension isn't
    /// connected" case. Drives ResultPanelView's branded card. Pass
    /// `response` when the run completed gracefully without the tool
    /// so the agent's reply stays visible on the card.
    func showFailedExtensionMissing(query: String, response: String? = nil) {
        sealDanglingUserTurn()
        setMode(.failedExtensionMissing(query: query, response: response))
    }

    /// Block the prompt — surfaces the PaywallPanelView with the
    /// right CTA. AgentClient calls this from submitQuery /
    /// handleVoiceTranscript when account.isReady is false.
    func requirePaywall(reason: PaywallReason, draftPrompt: String) {
        setMode(.paywallRequired(reason: reason, draftPrompt: draftPrompt))
    }

    /// Surface the small permission island. AgentClient calls this
    /// when a final_message text contains a TCC-denial signal. The
    /// query is preserved so we can auto-re-submit once the user
    /// grants the missing permission.
    func requirePermission(query: String, service: PermissionService) {
        setMode(.permissionRequired(query: query, service: service))
    }

    /// Bridge state between "permission just granted" and "agent is
    /// running the auto-retried task." Surfaces a brief "Continuing
    /// your request…" pill so the moment reads as recovery rather
    /// than a fresh turn. Called by PermissionGrantOrchestrator before
    /// firing its retry closure. The transition into `.working` is
    /// driven by the actual run's first stream event in AgentClient —
    /// no manual transition needed here, since `startWorking(query:)`
    /// fires from submitQuery's path anyway.
    func noteAutoRetry(query: String) {
        setMode(.resuming(query: query))
    }

    /// Surface the small sign-in island. AgentClient calls this when
    /// submitQuery is invoked but the user isn't signed in. draftPrompt
    /// is preserved so KLOOverlayView can auto-re-submit once the
    /// OAuth callback lands and account.status flips signed-in.
    func requireSignIn(draftPrompt: String?) {
        setMode(.signInRequired(draftPrompt: draftPrompt))
    }

    /// Surface the inline confirm bar — agent called `confirm_action`
    /// for a destructive / sending / money action. AgentClient calls
    /// this from its `confirm_request` event handler. The accept/cancel
    /// buttons (and the global ESC handler / ⌘+Enter shortcut) post
    /// to /runs/<id>/confirm via AgentClient.submitConfirm.
    func requireConfirmation(payload: ConfirmPayload) {
        setMode(.confirmingAction(payload: payload))
    }

    /// Surface the "Save sign-in to klo?" prompt. Called by
    /// CredCaptureCoordinator (the WKScriptMessageHandler) when the
    /// user submits a login form inside the embedded WKWebView. We
    /// detect submission JS-side, hold the password in-memory keyed by
    /// `pendingId`, then surface this island. Accept → coordinator
    /// writes to KloKeychain. Decline → coordinator drops the in-
    /// memory hold without persisting.
    func offerSaveCredential(host: String, username: String, pendingId: String) {
        setMode(.offerSaveCredential(host: host, username: username, pendingId: pendingId))
    }

    /// Dismiss the save-credential island. Returns to the prior pane
    /// (either .webPane if the WKWebView is still open, or .idle).
    /// CredCaptureCoordinator listens for this via the notification
    /// path so it can flush the in-memory hold whether the user
    /// accepted or declined.
    func dismissSaveCredential() {
        // Bouncing back to .webPane when the form submission likely
        // led to a navigation that landed the user back inside the
        // app they were signing into. If the pane was already torn
        // down (rare), fall through to idle.
        if case .offerSaveCredential = mode {
            setMode(.idle)
        }
    }
}
