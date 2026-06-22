import SwiftUI
import WebKit

/// The visible part of klo's embedded web. Hosts `WebViewManager.shared
/// .webView` and surrounds it with two thin klo-styled rows:
///
///   ┌─────────────────────────────────────────────────────────────┐
///   │  ●   clicking 'Round trip'        gmail.com         [⏘] [✕] │  ← chromeBar
///   │  ╴ ╴ ╴ scrolled · read page text ╴ ╴ ╴                      │  ← (optional) ticker
///   ├─────────────────────────────────────────────────────────────┤
///   │                                                             │
///   │                     [ WKWebView ]                           │
///   │                                                             │
///   ├─────────────────────────────────────────────────────────────┤
///   │  ↳ tell klo to do something else…    ⏎ steer · ⌘⏎ add  [→]  │  ← inputRow
///   └─────────────────────────────────────────────────────────────┘
///
/// Three working modes:
///   - **idle**: klo is between tool calls (reading model output). Dot
///     dim, no action label, no ticker.
///   - **working**: klo is dispatching a tool. Pulsing olive ring,
///     current-action label in olive, ticker shows recent actions.
///   - **paused** (user took over): chrome bar gets teal accent, large
///     HAND BACK button, input row replaced by "you have control" copy.
///     The user is free to click + type inside the WKWebView.
///
/// The WKWebView is owned by WebViewManager (not by this view) so it
/// survives mount/unmount cycles. Pane state (URL, scroll, cookies) is
/// preserved across panel dismissal.
struct WebPaneView: View {
    @ObservedObject var manager: WebViewManager
    @EnvironmentObject var state: KLOState
    @EnvironmentObject var agentClient: AgentClient
    let onDismiss: () -> Void

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var toast: String? = nil
    /// Drives the working dot's pulsing ring animation.
    @State private var pulse: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            if showsTicker {
                ticker
                    .transition(.opacity)
            }
            Divider().overlay(Color.white.opacity(0.10))
            // CLIP the webView to the available SwiftUI area. The
            // WKWebView's NSView frame is forced to 1100×720 (see
            // WebViewContainer.canonicalSize) so the page lays out at
            // a stable desktop size; SwiftUI clips visually to fit the
            // panel. The user sees the top-left chunk; the model sees
            // the full CSS viewport via snapshot/screenshot.
            WebViewContainer(webView: manager.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            Divider().overlay(accentColor.opacity(0.30))
            inputRow
        }
        .background(Color.black)
        .onReceive(NotificationCenter.default.publisher(for: .kloInjectionAcknowledged)) { note in
            handleInjectionAck(note)
        }
        .onAppear {
            inputFocused = !state.isPaused
            pulse = true
        }
        .onChange(of: state.isPaused) { _, paused in
            inputFocused = !paused
        }
        .animation(.easeInOut(duration: 0.24), value: state.isPaused)
        .animation(.easeInOut(duration: 0.22), value: state.currentAction)
    }

    // MARK: - Chrome bar

    private var chromeBar: some View {
        HStack(spacing: 12) {
            workingDot

            if let label = activeLabel {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }

            Text(displayedURL)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            takeOverPill

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss pane (Esc cancels run)")
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    /// The colored dot that signals klo's working state. Dim white when
    /// idle, olive + pulsing ring when working, teal-solid when paused.
    private var workingDot: some View {
        ZStack {
            // Pulsing ring — only while working
            if isWorking {
                Circle()
                    .stroke(accentColor.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.0 : 0.6)
                    .opacity(pulse ? 0.0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.1).repeatForever(autoreverses: false),
                        value: pulse,
                    )
            }
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
    }

    /// The TAKE OVER / HAND BACK pill that lives in the chrome bar.
    /// When klo is running and the user isn't in control: shows
    /// "TAKE OVER" in a subtle outlined pill. When paused: shows
    /// "HAND BACK" in a prominent filled-accent pill, drawing the eye.
    @ViewBuilder
    private var takeOverPill: some View {
        if state.isPaused {
            Button(action: handleHandBack) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("HAND BACK")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(KloColors.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(KloColors.copper))
                .overlay(Capsule().stroke(KloColors.copper.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Return control to klo")
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else if isWorking || hasActiveRun {
            Button(action: handleTakeOver) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("TAKE OVER")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Pause klo and drive the page yourself")
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    // MARK: - Ticker (recent actions)

    /// Whether to show the breadcrumb row of recent actions. Only
    /// during active work AND when we have at least one prior action.
    private var showsTicker: Bool {
        guard !state.isPaused else { return false }
        return state.recentActions.count >= 2
    }

    /// Horizontal breadcrumb showing the last 2-3 things klo did, with
    /// the freshest on the right. Gives the user a "what just happened"
    /// trail without leaving the pane.
    private var ticker: some View {
        // recentActions is appended-to as klo dispatches tools; the
        // last entry is the active one (shown in the chrome bar
        // above). Take the previous 2 as the breadcrumb tail.
        let recents = state.recentActions
        let tailCount = min(2, max(0, recents.count - 1))
        let startIdx = max(0, recents.count - 1 - tailCount)
        let tailRange = startIdx ..< max(startIdx, recents.count - 1)
        let lastIdx = tailRange.last
        return HStack(spacing: 10) {
            ForEach(Array(tailRange), id: \.self) { i in
                let action = recents[i]
                let position = i - startIdx
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.30))
                    Text(action.label)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.40))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .opacity(1.0 - Double(tailCount - 1 - position) * 0.25)
                if let lastIdx, i < lastIdx {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.18))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input row

    /// Bottom row. Three states:
    ///   - **paused**: full-width "you have control" banner with a
    ///     small "type to leave klo a note" affordance. The note
    ///     queues as an inject for when klo resumes.
    ///   - **working**: persistent steer/inject input. ⏎ pivots klo,
    ///     ⌘⏎ adds context, hint chips visible while typing.
    ///   - **idle** (rare in webPane): same as working, no real
    ///     difference since the run hasn't ended.
    private var inputRow: some View {
        ZStack {
            if state.isPaused {
                handedOverBanner
            } else {
                steerInputRow
            }

            if let toast {
                HStack(spacing: 6) {
                    Text(toast)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KloColors.olive)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.92))
                        .overlay(Capsule().stroke(KloColors.olive.opacity(0.55), lineWidth: 1))
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(height: 48)
    }

    private var steerInputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KloColors.olive.opacity(0.75))

            TextField(text: $draft, axis: .horizontal) {
                Text(placeholderText)
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.92))
            .focused($inputFocused)
            .tint(KloColors.olive)
            .onSubmit(submitSteer)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.command) {
                    submitInject()
                    return .handled
                }
                return .ignored
            }

            if inputFocused && !draft.isEmpty {
                HStack(spacing: 8) {
                    chip("⏎ steer")
                    chip("⌘⏎ add")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    /// Banner shown while the user has taken over. Full-width copper
    /// accent, a steady (non-pulsing) icon, copy that orients the user
    /// to what they can do. Type-to-leave-note still works — any text
    /// they enter and submit gets queued as an inject for when klo
    /// resumes.
    private var handedOverBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KloColors.copper)

            VStack(alignment: .leading, spacing: 1) {
                Text("YOU HAVE CONTROL")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(KloColors.copper)
                Text("klo is paused — click + type freely. press HAND BACK when ready.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Inline mini-input — user can leave klo a note that gets
            // delivered on resume.
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.35))
                TextField(text: $draft, axis: .horizontal) {
                    Text("leave klo a note")
                        .foregroundStyle(Color.white.opacity(0.25))
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(maxWidth: 240)
                .onSubmit(submitInject)  // pause-time notes are inject (additive)
                .tint(KloColors.copper)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.white.opacity(0.04))
                    .overlay(Capsule().stroke(KloColors.copper.opacity(0.25), lineWidth: 1))
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: - Helpers (computed properties)

    private var displayedURL: String {
        if let url = manager.currentURL?.absoluteString, !url.isEmpty {
            return url
        }
        return "loading…"
    }

    private var isWorking: Bool {
        !state.isPaused && state.currentAction != nil
    }

    /// Whether there's an active run regardless of "working right now"
    /// — used so TAKE OVER stays visible during between-tool-call
    /// thinking pauses. If there's no run, no take-over button.
    private var hasActiveRun: Bool {
        switch state.mode {
        case .working, .resuming, .webPane: return true
        default: return false
        }
    }

    private var activeLabel: String? {
        if state.isPaused {
            return "paused · you're driving"
        }
        guard let raw = state.currentAction, !raw.isEmpty else { return nil }
        if raw.count <= 42 { return raw }
        return String(raw.prefix(41)) + "…"
    }

    private var dotColor: Color {
        if state.isPaused { return KloColors.copper }
        if isWorking { return KloColors.olive }
        if manager.isLoading { return KloColors.olive.opacity(0.7) }
        return Color.white.opacity(0.22)
    }

    private var accentColor: Color {
        state.isPaused ? KloColors.copper : KloColors.olive
    }

    private var placeholderText: String {
        if isWorking { return "steer klo · ⏎ pivot · ⌘⏎ add" }
        return "tell klo to do something else…"
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Action handlers

    private func submitSteer() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        agentClient.sendInterrupt(text, kind: .steer)
        draft = ""
    }

    private func submitInject() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        agentClient.sendInterrupt(text, kind: .inject)
        draft = ""
    }

    private func handleTakeOver() {
        agentClient.pauseRun()
        // Optimistic UI: flip state immediately. The WS will reconcile
        // when the server emits its status_change(paused=true) ack —
        // since both flip to the same value, no flicker.
        state.isPaused = true
    }

    private func handleHandBack() {
        agentClient.resumeRun()
        state.isPaused = false
    }

    private func handleInjectionAck(_ note: Notification) {
        guard let info = note.userInfo,
              let kind = info["kind"] as? String else { return }
        let label = (kind == "steer") ? "↪ steered" : "↳ injected"
        withAnimation(.easeInOut(duration: 0.16)) {
            toast = label
        }
        let snapshot = label
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if toast == snapshot {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toast = nil
                }
            }
        }
    }
}

/// NSViewRepresentable wrapper that hosts an existing WKWebView. The
/// WKWebView is created and owned by WebViewManager — this view just
/// attaches and detaches it from the SwiftUI hierarchy. That decoupling
/// is what lets the page state survive mount/unmount: when the user
/// dismisses the panel and the SwiftUI view tears down, the WKWebView
/// instance keeps living in WebViewManager.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    /// The CSS viewport we lock the WKWebView to. The page is laid out
    /// as if it were a 1100×720 desktop browser at all times — that's
    /// what `web.snapshot()` reports, and what `web.press(idx)`
    /// dispatches against. SwiftUI clips visually to whatever container
    /// area the panel currently has; the underlying NSView frame stays
    /// constant.
    ///
    /// Why this matters: SwiftUI sizes child NSViews to fit its layout
    /// slot. When the panel's content area is in a transition (e.g.
    /// idle → .webPane mode flipping while the spring animates) the
    /// WKWebView would be momentarily sized to the OLD mode's dims
    /// (often 760×100 for .textExpanded). The page's CSS layout
    /// collapses to that, every bounding rect becomes garbage, and
    /// `web.press(idx)` clicks at coordinates that are no longer in
    /// the right place. Forcing a constant frame eliminates the race.
    static let canonicalSize = NSSize(width: 1100, height: 720)

    func makeNSView(context: Context) -> WKWebView {
        // SwiftUI takes the webView out of whatever NSView it was in
        // (the hidden holder window owned by WebViewManager) and
        // re-parents it into its host view. webView.window becomes
        // the visible KLOPanel automatically.
        webView.frame.size = Self.canonicalSize
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // SwiftUI keeps trying to resize NSViews on every layout pass.
        // Override that — the webView's CSS viewport must stay constant
        // so snapshot coords match press coords across the whole run.
        if nsView.frame.size != Self.canonicalSize {
            nsView.frame.size = Self.canonicalSize
        }
    }

    /// CRUCIAL: when SwiftUI tears down the WebPaneView (any mode flip
    /// out of `.webPane` — the panel collapses, the save-credential
    /// island shows, the mode goes to `.idle`, etc.), the webView
    /// would otherwise be left with no superview and no window. Every
    /// subsequent NSEvent dispatch (click, type) would fail with
    /// "WKWebView is not mounted in a window."
    ///
    /// Re-parenting back to the persistent hidden holder keeps
    /// webView.window non-nil at all times. The next time the user
    /// opens the pane, makeNSView re-parents it back into the visible
    /// host. No state loss.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        Task { @MainActor in
            WebViewManager.shared.reparentToHolder()
        }
    }
}
