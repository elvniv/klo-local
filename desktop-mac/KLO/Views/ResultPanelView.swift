import MarkdownUI
import SwiftUI

/// Multi-turn chat surface. The panel that appears after the agent
/// finishes a run.
///
/// Mental model: this is a CONVERSATION, not a header + body + footer.
/// Every turn — user OR klo — is rendered with the same vocabulary
/// (eyebrow attribution + body text), flowing top-to-bottom. Compact
/// mode shows the last turn pair; transcript mode shows all of them.
/// No bubbles, no right-aligned vs left-aligned mix, no chrome
/// fighting with the content.
///
/// The error variant reuses the same shell with no input bar — the
/// recovery path is dismiss + new prompt, not inline retry.
struct ResultPanelView: View {
    let query: String
    let responseText: String
    let isError: Bool
    let onDismiss: () -> Void
    /// Submit a follow-up. Wired in `KLOOverlayView` to
    /// `AgentClient.submitQuery`. Only the chat (non-error) path passes
    /// this; error variant is read-only.
    var onSubmit: ((String) -> Void)? = nil
    /// `.working` mode renders the same chat panel as `.completed`,
    /// just with a "thinking" placeholder where the response text
    /// would be. The orange action ticker (KLOOverlayView's
    /// WorkingActivityOverlay) stays parallel for actual tool calls;
    /// this dots indicator covers the in-between moments where klo is
    /// reasoning, not acting.
    var isThinking: Bool = false

    @EnvironmentObject var state: KLOState
    @State private var appeared: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // ─── Header strip — only the transcript pill, top-right.
            // Empty for the first turn (no history to expand) and for
            // the error path. Reserved height keeps the conversation
            // from jumping when the pill appears at turn 2.
            header
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .frame(height: 28)

            // ─── Conversation thread — fills all available space
            // between header and input. Scrolls within itself.
            thread
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(.easeOut(duration: 0.40).delay(0.08), value: appeared)

            // ─── Footer — input bar (chat) or escape hint (error).
            // No negative-bleed hacks: the divider runs panel-edge
            // to panel-edge naturally because we mount it at the
            // outer VStack level (not nested inside padding).
            if !isError, let onSubmit = onSubmit {
                threadDivider
                TextInputView(
                    onSubmit: onSubmit,
                    contentInsets: EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 20),
                    // Header already has the gear — second one in the
                    // input bar would be visual clutter.
                    showSettingsButton: false
                )
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.32).delay(0.16), value: appeared)
            } else {
                threadDivider
                errorFooter
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .opacity(appeared ? 0.85 : 0)
                    .animation(.easeOut(duration: 0.32).delay(0.20), value: appeared)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand { onDismiss() }
        .onAppear {
            DispatchQueue.main.async { appeared = true }
        }
    }

    // MARK: - Header (transcript pill)

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            settingsGearButton
                .opacity(appeared ? 0.55 : 0)
                .animation(.easeOut(duration: 0.32).delay(0.10), value: appeared)
            Spacer(minLength: 0)
            if !isError {
                copyResponseButton
                    .opacity(appeared ? 0.65 : 0)
                    .animation(.easeOut(duration: 0.32).delay(0.10), value: appeared)
            }
            if !isError && state.messages.count > 2 {
                transcriptPill
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.32).delay(0.10), value: appeared)
            }
        }
    }

    /// One-click copy of the agent's latest response — backup for users
    /// who don't intuit they can drag-select inside the notch. Mirrors
    /// the macOS pattern (single icon, no label, .help tooltip).
    @State private var copyFlashed: Bool = false
    private var copyResponseButton: some View {
        Button {
            copyResponseToClipboard()
            withAnimation(.easeOut(duration: 0.18)) { copyFlashed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.22)) { copyFlashed = false }
            }
        } label: {
            Image(systemName: copyFlashed ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copyFlashed ? KloColors.olive : .white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy klo's response (⌘C)")
        .accessibilityLabel("Copy response")
    }

    private func copyResponseToClipboard() {
        let payload: String = {
            let m = state.messages.last(where: { $0.role == .assistant })?.content
            if let m = m, !m.isEmpty { return m }
            return responseText
        }()
        guard !payload.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
    }

    /// Small SF Symbols gear at the chat-panel header's top-left. Opens
    /// the Settings window via the shared SettingsWindowController — the
    /// same surface ⌘, opens. Low-opacity ink-on-dark so it reads as a
    /// utility affordance, not part of the conversation.
    ///
    /// Lives here (not on KLOOverlayView) because the chat panel is
    /// where users settle and would intuitively look for a settings
    /// shortcut; ephemeral states (working, voice, sign-in island)
    /// don't surface this and don't need it.
    private var settingsGearButton: some View {
        Button {
            SettingsWindowController.shared.show()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings")
    }

    private var transcriptPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                state.toggleTranscriptExpanded()
            }
        } label: {
            HStack(spacing: 6) {
                Text(state.transcriptExpanded ? "collapse" : "\(turnCount) turns")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .textCase(.lowercase)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(state.transcriptExpanded ? 180 : 0))
            }
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.transcriptExpanded ? "Show only the latest turn" : "Show the full conversation")
    }

    /// Number of user turns — the count the user actually thinks in.
    /// "2 messages" reads weird; "2 turns" is the conversational unit.
    private var turnCount: Int {
        max(1, state.messages.filter { $0.role == .user }.count)
    }

    // MARK: - Thread (the actual conversation)

    @ViewBuilder
    private var thread: some View {
        if isError {
            // Error: single user turn + the error text styled red. Same
            // vocabulary as a normal turn, just the response color shifts.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TurnView(
                        eyebrow: "you",
                        text: query,
                        textColor: .white.opacity(0.92)
                    )
                    .padding(.bottom, 22)
                    Text(displayedText)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(KloColors.error.opacity(0.92))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        } else if state.transcriptExpanded {
            transcriptScroll
        } else {
            compactScroll
        }
    }

    /// Compact view: just the LAST turn pair (final user prompt +
    /// final assistant response). The assistant text streams in
    /// character-by-character via `StreamingText` and the scroll view
    /// follows the bottom edge so long replies stay visible without
    /// the user having to scroll. Once the reveal finishes the cursor
    /// fades out and text is fully selectable.
    @ViewBuilder
    private var compactScroll: some View {
        let lastUserMsg = state.messages.last(where: { $0.role == .user })
        let lastUser = lastUserMsg?.content ?? query
        let lastUserScope = lastUserMsg?.scopedService
        // Prefer the parameter when the parent passed real content
        // (the .completed(_, response) case in KLOOverlayView).
        // state.messages is the live transcript and can lag this view's
        // construction by a frame when the agent emits final_message +
        // status_change in rapid succession. Reaching for it first
        // produced the "ghost state" where the panel rendered with an
        // empty assistant slot until the user dismissed + re-summoned.
        let lastAssistant: String = {
            if !responseText.isEmpty { return responseText }
            return state.messages.last(where: { $0.role == .assistant })?.content ?? ""
        }()

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TurnView(
                        eyebrow: "you",
                        text: lastUser,
                        textColor: .white.opacity(0.78),
                        scopedService: lastUserScope
                    )
                    .padding(.bottom, 22)

                    // Klo's response slot — either thinking dots (no
                    // text yet) or the streaming-in answer. No "klo"
                    // eyebrow: the panel IS klo, attribution would be
                    // redundant chrome.
                    if isThinking || lastAssistant.isEmpty {
                        ThinkingDots()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        StreamingText(text: lastAssistant, onAdvance: {
                            // Scroll the bottom into view as text grows.
                            // No `withAnimation` — a snap-to-bottom on
                            // each tiny height delta reads continuous
                            // and avoids stacking multiple in-flight
                            // animations (the source of "hitchy"). When
                            // the bottom hasn't moved (text growing
                            // within a line), this is a no-op.
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Anchor for auto-scroll. 0.5pt clear strip; just
                    // needs an id, not visible weight.
                    Color.clear
                        .frame(height: 0.5)
                        .id(Self.bottomAnchor)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }

    /// SwiftUI ID used by both the streaming-text auto-scroll and the
    /// transcript view's "scroll to latest" hook. String literal kept
    /// here so we don't drift between the two callsites.
    private static let bottomAnchor: String = "__klo_chat_bottom"

    /// Transcript view: every turn pair, top to bottom. Auto-scrolls
    /// to the latest turn on appear and on count change AND tracks the
    /// streaming bottom edge as the latest assistant reply types in.
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.messages.enumerated()), id: \.element.id) { idx, msg in
                        if msg.role == .user {
                            TurnView(
                                eyebrow: "you",
                                text: msg.content,
                                textColor: .white.opacity(0.78),
                                scopedService: msg.scopedService
                            )
                            .id(msg.id)
                            .padding(.top, idx == 0 ? 4 : 28)
                            .padding(.bottom, 18)
                        } else {
                            // Only the LATEST assistant message gets the
                            // streaming reveal — older turns are history,
                            // they should appear instantly. `streaming:
                            // false` short-circuits the typewriter.
                            let isLatest = (msg.id == state.messages.last?.id)
                            StreamingText(
                                text: msg.content,
                                streaming: isLatest,
                                onAdvance: isLatest ? {
                                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                                } : nil
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(msg.id)
                        }
                    }

                    if isThinking || state.messages.last?.role == .user {
                        ThinkingDots()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }

                    Color.clear
                        .frame(height: 0.5)
                        .id(Self.bottomAnchor)
                }
                .padding(.bottom, 8)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: state.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Divider above the input

    private var threadDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: - Belt-and-suspenders error truncation

    private var displayedText: String {
        if isError && responseText.count > 240 {
            return String(responseText.prefix(240)) + "…"
        }
        return responseText
    }

    // MARK: - Error footer (esc hint)

    private var errorFooter: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                HStack(spacing: 5) {
                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    Text("dismiss")
                        .font(.system(size: 11, weight: .regular))
                }
                .foregroundStyle(.white.opacity(0.40))
            }
            .buttonStyle(.plain)
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// TurnView — single conversation turn. Eyebrow attribution above the
// text. Used for user turns. Klo's responses skip the eyebrow (the
// panel IS klo) and render as plain Text inline in the parent — that
// asymmetry is intentional: it removes a redundant "klo" label and
// lets the answer be the visual focus of every pair.
// ─────────────────────────────────────────────────────────────────────

private struct TurnView: View {
    let eyebrow: String
    let text: String
    let textColor: Color
    /// Composio toolkit slug if this turn was scoped via `/<slug>` in
    /// the input bar. nil = no scope (regular turn). Renders a small
    /// brand-colored capsule with the service logo right above the
    /// message text so the user can scan their transcript and see
    /// "this one was about Notion" without reading the text.
    var scopedService: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.40))
                if let slug = scopedService {
                    ServiceChip(slug: slug)
                }
            }
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(textColor)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// ServiceChip — brand-colored capsule shown above a user turn when the
// user scoped their query with `/<slug>`. Logo on the left, friendly
// name on the right, all on a tinted background. Same vocabulary as
// the ConnectionsView tiles so the visual language is consistent.
// ─────────────────────────────────────────────────────────────────────

private struct ServiceChip: View {
    let slug: String

    private var displayName: String {
        BrandStyle.displayName(slug: slug, catalogName: slug.capitalized)
    }

    private var brandColor: Color {
        BrandStyle.color(for: slug)
    }

    var body: some View {
        HStack(spacing: 5) {
            // Bundled brand logo if we have one, monogram fallback
            // otherwise — same chain as ConnectionsView tiles.
            if let logo = BrandStyle.bundledLogo(for: slug) {
                logo
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
            } else {
                Text(BrandStyle.monogram(slug: slug, catalogName: slug.capitalized))
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(brandColor)
                    .frame(width: 11, height: 11)
            }
            Text(displayName.lowercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(brandColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(brandColor.opacity(0.18))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(brandColor.opacity(0.30), lineWidth: 0.5)
        )
    }
}


// ─────────────────────────────────────────────────────────────────────
// StreamingText — character-by-character reveal for klo's response.
//
// The sidecar emits the response as a single `final_message`, not as
// token-by-token deltas — so this is a CLIENT-SIDE reveal, not "real"
// streaming. The user perceives the same thing as long as the cadence
// feels alive (~80 chars/sec is the sweet spot — slow enough to read
// along, fast enough to never feel sluggish).
//
// A subtle "▋" cursor follows the visible-text edge while revealing
// and fades out 0.3s after completion. Long text and instant-reveal
// (`streaming: false`) bypass the animation — useful for transcript
// history where older turns should appear immediately.
//
// Selection works on the FINAL text only — once the reveal completes.
// Trying to select mid-stream feels broken because the underlying
// string is changing under the user's cursor; better to disable until
// done. Stable-by-the-time-the-user-tries.
// ─────────────────────────────────────────────────────────────────────

private struct StreamingText: View {
    let text: String
    /// When false, render the full text instantly with no cursor.
    /// Used by transcript history to skip the typewriter for older
    /// turns. Default true.
    var streaming: Bool = true
    /// Called whenever the visible text grows. The parent uses this
    /// to scroll the chat to the bottom edge as text appears, so the
    /// user doesn't have to chase the bottom themselves. Throttled
    /// internally to ~12 calls/sec — one per typing burst — to keep
    /// the scroll smooth without scheduling 80 scroll ops per second.
    var onAdvance: (() -> Void)? = nil

    @State private var revealedCount: Int = 0
    @State private var isComplete: Bool = false
    @State private var streamTask: Task<Void, Never>? = nil

    /// Maximum time the typewriter animation should ever take. Long
    /// responses ramp the reveal rate up so we don't trap markdown
    /// rendering behind a 20-second typewriter on a 1500-char wall of
    /// text. The animation should feel "alive" — a couple seconds at
    /// most — not exhaustive.
    private static let maxRevealSeconds: Double = 1.5

    /// Floor reveal cadence — short replies still get a touch of life
    /// (typewriter on "Hello!" at 80 cps takes ~75ms).
    private static let minCharsPerSecond: Double = 80

    var body: some View {
        // Single-mode MarkdownUI rendering. We previously swapped to an
        // NSTextView-backed `SelectableMarkdownText` once the typewriter
        // settled, but the NSScrollView layout cycle inside SwiftUI
        // proposed a zero-sized content view in some configurations
        // (notably past-chat history, where streaming=true ran the
        // typewriter to completion and then triggered the swap) — the
        // result was "text streams in and vanishes." That broke the
        // chat surface badly enough to lose user trust.
        //
        // The Copy button in ResultPanelView's header gives users a
        // one-tap path to copy the full response. Drag-select within
        // a MarkdownUI paragraph still works, and the response is
        // also reachable from past-chat history. The select-all
        // shortcut still routes through the focused field when the
        // input bar has focus; we don't try to globally re-bind ⌘A
        // here.
        Markdown(streaming ? String(text.prefix(revealedCount)) : text)
            .markdownTheme(.klo)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if !streaming {
                    isComplete = true
                    revealedCount = text.count
                    return
                }
                startReveal()
            }
            .onChange(of: text) { newValue in
                // If the underlying text changed (rare — usually the same
                // string for the same message id, but shielding for safety)
                // restart the reveal from the start.
                stopReveal()
                revealedCount = 0
                isComplete = false
                if !streaming {
                    isComplete = true
                    revealedCount = newValue.count
                } else {
                    startReveal()
                }
            }
            .onDisappear { stopReveal() }
    }

    // MARK: - Reveal driver

    private func startReveal() {
        stopReveal()
        let total = text.count
        guard total > 0 else {
            isComplete = true
            return
        }
        // For very short text, skip the whole animation — feels
        // tedious to wait for "ok." to type out.
        if total < 4 {
            revealedCount = total
            isComplete = true
            return
        }
        // Log when streaming-markdown rendering kicks off so we can
        // verify in the unified log that the new code path is live.
        NSLog("KLO Chat: rendering Markdown view — len=%d head=%@",
              total, String(text.prefix(60)))
        streamTask = Task { @MainActor in
            // Dynamic reveal rate so the typewriter completes within
            // `maxRevealSeconds` no matter how long the response is.
            // Short answers still feel typewritten (floor at
            // minCharsPerSecond ≈ 80 cps); long answers blaze through
            // so markdown formatting kicks in within ~1.5s of arrival.
            let cps = max(Self.minCharsPerSecond, Double(total) / Self.maxRevealSeconds)
            let interval = 1.0 / cps

            // Throttle the auto-scroll callback. Calling it on every
            // single character would queue 80 scroll ops/sec; 12/sec
            // is plenty for the bottom edge to stay visible without
            // per-char scroll churn. Hops on every 7th char (~11 cps).
            var sinceLastScrollNotify = 0
            while revealedCount < total && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                // Reveal in small bursts of 1-2 chars per tick — gives
                // the appearance of human-typist micro-variance without
                // dropping below the 80cps baseline.
                let burst = (revealedCount % 6 == 0) ? 2 : 1
                revealedCount = min(total, revealedCount + burst)
                sinceLastScrollNotify += burst
                if sinceLastScrollNotify >= 7 {
                    sinceLastScrollNotify = 0
                    onAdvance?()
                }
            }
            // Final scroll so the very last line lands at the bottom.
            onAdvance?()
            // Mark complete so any future onAppear (e.g. transcript
            // expand) short-circuits the typewriter.
            isComplete = true
        }
    }

    private func stopReveal() {
        streamTask?.cancel()
        streamTask = nil
    }
}


// ─────────────────────────────────────────────────────────────────────
// ThinkingDots — three small dots, staggered breathing pulse. Sits in
// the chat panel where the assistant response would go, the moment
// after the user submits + before any text streams back.
//
// Deliberately monochrome white (not orange). The orange dot is
// reserved for ACTIVE TOOL CALLS in the working overlay below the
// notch — keeping the colors separate means a glance tells the user
// "klo is thinking" vs "klo is doing X". Same color would conflate
// the two states.
//
// Cadence: 1.0s period, each dot offset 0.18s from the next. The
// breathing curve is `(sin(t*2π) + 1)/2` mapped to opacity 0.30→0.95
// + a tiny scale lift. TimelineView keeps it at 30 fps without any
// @State or Timer; cheap to leave running.
// ─────────────────────────────────────────────────────────────────────

private struct ThinkingDots: View {
    private static let dotSize: CGFloat = 5
    private static let spacing: CGFloat = 7
    private static let period: Double = 1.0
    private static let stagger: Double = 0.18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: Self.spacing) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = breath(at: t - Double(i) * Self.stagger)
                    Circle()
                        .fill(.white.opacity(0.30 + 0.65 * phase))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .scaleEffect(0.85 + 0.30 * phase)
                }
            }
            // Vertical room ≈ 15pt body line — keeps the panel from
            // resizing when streaming text replaces this.
            .frame(height: 21, alignment: .leading)
        }
        .accessibilityLabel("klo is thinking")
    }

    /// Smooth 0..1 breathing curve. Two arguments converge to the
    /// same expression but extracted for readability.
    private func breath(at time: Double) -> Double {
        (sin((time / Self.period) * 2 * .pi) + 1) / 2
    }
}


// MARK: - Selectable markdown text view (NSTextView-backed)

/// Renders markdown as an `NSAttributedString` inside a real
/// `NSTextView`, so the user can drag-select, ⌘A, and ⌘C the agent's
/// response. MarkdownUI's `Markdown` view doesn't propagate
/// `.textSelection(.enabled)` to its inner runs in 2.4.1, which is
/// why selection silently never worked on the completed panel.
///
/// We intentionally use AppKit here — SwiftUI's `Text(AttributedString)`
/// has its own selection limitations (no ⌘A within a non-keyWindow
/// panel) and doesn't render block-level markdown like headers or
/// code fences. NSTextView is the canonical macOS surface for
/// selectable rich text, and the notch panel is set up to become
/// key during `.completed` (see KLOWindowController) so key
/// equivalents route here correctly.
struct SelectableMarkdownText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = true
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        // Belt-and-suspenders for ⌘C — NSTextView already implements
        // copy: by default; this binds the menu item so ⌘C works even
        // when no responder targets explicitly.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        textView.menu = menu

        scroll.documentView = textView
        textView.textStorage?.setAttributedString(Self.attributed(from: text))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Skip identity-equal updates — avoids resetting the selection
        // every time the parent body re-renders.
        let current = textView.textStorage?.string ?? ""
        if current == text { return }
        textView.textStorage?.setAttributedString(Self.attributed(from: text))
    }

    /// Convert markdown to a styled NSAttributedString matching the
    /// notch panel's typography. Falls back to plain text if markdown
    /// parsing fails so the user always sees the response.
    private static func attributed(from markdown: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        let fg = NSColor.white.withAlphaComponent(0.92)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8

        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: fg,
            .paragraphStyle: paragraph,
        ]

        // Try markdown parsing via AttributedString (macOS 12+).
        if let attr = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            let ns = NSMutableAttributedString(attributedString: NSAttributedString(attr))
            let full = NSRange(location: 0, length: ns.length)
            ns.addAttributes(attrs, range: full)
            // AttributedString preserves bold/italic via inline run
            // attributes — normalize their size to match the body text
            // without clobbering bold/italic traits.
            let fontKey = NSAttributedString.Key.font
            ns.enumerateAttribute(fontKey, in: full) { value, range, _ in
                if let font = value as? NSFont {
                    let resized = NSFontManager.shared.convert(font, toSize: 14)
                    ns.addAttribute(fontKey, value: resized, range: range)
                }
            }
            return ns
        }
        return NSAttributedString(string: markdown, attributes: attrs)
    }
}
