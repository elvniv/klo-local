import SwiftUI

/// The chat command bar. Two presentations:
///
///   - Standalone (`.textExpanded` in `KLOOverlayView`): the only thing
///     in the panel. Default `contentInsets` matches the previous
///     standalone padding (22h, 16v).
///   - Inline (in `ResultPanelView`'s completed state): part of the
///     same surface as the chat thread. Caller passes `contentInsets`
///     that align with the panel's content rhythm — no negative-bleed
///     hacks needed.
///
/// Composition borrowed from Open iOS's input pattern: monogram on the
/// left, free-text field in the middle, a cream-filled circle FAB
/// appearing on the right the moment there's anything to send. A
/// hairline baseline underline below the row gives the input visual
/// weight without a box, and a tiny ALL-CAPS hint sits beneath it
/// when something can be sent.
///
/// The cursor + selection use klo orange — the one place in the
/// surface where the brand color still shouts. Voice mode is
/// intentionally absent this iteration.
struct TextInputView: View {
    let onSubmit: (String) -> Void
    /// Padding around the row's content. Caller decides — the standalone
    /// mode uses the default, but the inline-in-thread case can override
    /// to a tighter rhythm.
    var contentInsets: EdgeInsets = EdgeInsets(top: 14, leading: 22, bottom: 12, trailing: 18)
    /// Whether to render the inline Settings affordance. True for the
    /// standalone .textExpanded mode where this view IS the entire
    /// surface — users need a gear to open Settings without leaving
    /// the notch. False for the inline-in-ResultPanelView mode where
    /// the chat header already has its own gear and a second one in
    /// the footer would be visual noise.
    var showSettingsButton: Bool = true

    @EnvironmentObject var state: KLOState
    @EnvironmentObject var account: AccountManager
    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    // ─── Slash-app autocomplete state ──────────────────────────────────
    //
    // When the user types `/<prefix>` (a slash followed by letters, no
    // space yet), we surface a popover of matching Composio toolkits
    // above the input bar — Raycast-style. Connected apps sort first
    // so the user's actual workflow lives at the top.
    //
    // Acceptance flow:
    //   1. User types `/n` → popover shows Notion + other 'n…' apps
    //   2. User presses Return (or Tab) → text becomes `/notion ` (full
    //      slug + space). Cursor at end. Popover hides.
    //   3. User types `list my pages`. Text: `/notion list my pages`.
    //   4. Submit → KLOOverlayView.handleSubmit strips the leading
    //      `/<slug> ` prefix and fires the run with `scopedService=notion`.
    //
    // The slash + slug stays visible in the text while typing, colored
    // in the service's brand color, so the user has a clear "I'm in
    // Notion mode" handle without needing a separate chip widget.
    @State private var suggestions: [ComposioApp] = []
    @State private var showSuggestions: Bool = false

    /// Reserved slash commands handled by KLOOverlayView.handleSubmit
    /// (open ConnectionsView etc). Filtered out of app suggestions so
    /// they never collide.
    private static let reservedSlashCommands: Set<String> = [
        "apps", "connect", "connections", "integrations",
    ]

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Active slash-app scope, if the user has typed `/<slug>` matching
    /// a real Composio toolkit (with or without a query after it).
    /// Drives the brand-color text tint while typing. nil when no scope.
    private var detectedScope: ComposioApp? {
        guard let token = parsedScopeToken(of: text) else { return nil }
        return account.composioCatalogSnapshot.first {
            $0.slug.lowercased() == token
        }
    }

    /// Extract the slug token from text shaped like `/<slug>` or
    /// `/<slug> <rest>`. Returns lowercase slug, or nil if the text
    /// doesn't start with a slash + letters.
    private func parsedScopeToken(of input: String) -> String? {
        guard input.hasPrefix("/") else { return nil }
        let body = input.dropFirst()
        let token = body.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !token.isEmpty else { return nil }
        return String(token).lowercased()
    }

    // Hoisted from inside the body's modifier chain — combining
    // optional + AnyShapeStyle + Color was too much for the Swift type
    // checker inside foregroundStyle(). Pre-computing keeps body easy.
    private var textForegroundStyle: AnyShapeStyle {
        if let scope = detectedScope {
            return AnyShapeStyle(BrandStyle.color(for: scope.slug))
        }
        return AnyShapeStyle(Color.white.opacity(0.96))
    }

    private var textCursorTint: Color {
        detectedScope.map { BrandStyle.color(for: $0.slug) } ?? KloColors.orange
    }

    private var placeholderText: String {
        detectedScope.map { "ask \($0.name)…" } ?? "ask klo"
    }

    // Extracted from body to keep the type-checker complexity under
    // SwiftUI's limit. The accumulation of .foregroundStyle (with the
    // hoisted AnyShapeStyle), .onChange, and .onExitCommand on a single
    // TextField was enough to trigger "expression too complex" errors
    // on every save.
    @ViewBuilder
    private var inputTextField: some View {
        TextField(text: $text, axis: .horizontal) {
            Text(placeholderText)
                .foregroundStyle(.white.opacity(0.34))
        }
        .textFieldStyle(.plain)
        .font(.system(size: 16, weight: .regular))
        // When a /slug scope is detected, tint the text in the
        // service's brand color so the user has a clear visual
        // anchor for "I'm asking Notion specifically."
        .foregroundStyle(textForegroundStyle)
        .tracking(0.1)
        .tint(textCursorTint)
        .focused($fieldFocused)
        .onSubmit(submit)
        .onExitCommand {
            if showSuggestions {
                // Dismiss the popover first; only collapse the
                // notch on a second Esc when no popover is up.
                showSuggestions = false
            } else {
                state.collapseToIdle()
            }
        }
        .onChange(of: text) { newValue in
            updateSuggestions(for: newValue)
            // First keystroke clears the whisper. Already-typed text
            // stays. Keeps the whisper from competing with the user's
            // own thought once they've committed to typing.
            if !newValue.isEmpty, state.idleWhisper != nil {
                state.idleWhisper = nil
            }
        }
        .onAppear {
            // Trigger an initial fetch so the first /<key> the
            // user types has suggestions ready. Cheap — ignored
            // if the snapshot is already populated.
            Task { await account.ensureComposioCatalog() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Soft idle whisper — one quiet starter line above the
            // input bar. Visible only when the input is empty AND a
            // whisper has been computed (frontmost-app context probe
            // or curated rotation). Tap inserts the prompt; first
            // keystroke clears it via the .onChange below. Kept above
            // the row so it reads as "klo's hint" not "your typing."
            if !hasText, let whisper = state.idleWhisper {
                Button {
                    text = whisper.prompt
                    fieldFocused = true
                    state.idleWhisper = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(KloColors.fg45)
                        Text(whisper.text)
                            .font(.system(size: 13, weight: .regular).italic())
                            .foregroundStyle(KloColors.fg45)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suggested starter: \(whisper.text). Tap to fill the input.")
                .padding(.leading, 22 + 17 + 14) // wordmark padding + width + hstack spacing
                .transition(.opacity.combined(with: .offset(y: 2)))
            }
            HStack(spacing: 14) {
                // klo wordmark — quiet brand stamp on the left of the input.
                // 0.7 opacity reads as a watermark next to the placeholder
                // (also at ~0.34 opacity), letting the typed text dominate.
                Image("KloLogo")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(height: 17)
                    .opacity(0.72)
                    .accessibilityLabel("klo")
                    .allowsHitTesting(false)

                inputTextField

                // Utility affordances — small icons at the trailing edge
                // of the EMPTY input. Disappear the moment the user
                // starts typing so the send FAB can take their place.
                //
                // Order is intentional: gear first (Settings is the
                // higher-frequency action: open Settings + see usage,
                // billing, account), grid second (Connected apps is a
                // discovery surface — used less often but visually
                // hooks the eye more, so it sits closest to the FAB
                // position the user's mouse drifts toward).
                if !hasText {
                    // Conversation affordances — history + new chat.
                    // Lead the icon cluster: they act on the thread the
                    // user is looking at, while gear/grid/waveform are
                    // app-level destinations.
                    HoverGlyphButton(
                        systemName: "clock.arrow.circlepath",
                        helpText: "Conversation history  •  ↑"
                    ) {
                        state.showingHistory = true
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    HoverGlyphButton(
                        systemName: "plus",
                        helpText: "New conversation  •  ⌘N"
                    ) {
                        state.startNewConversation()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    if showSettingsButton {
                        Button {
                            SettingsWindowController.shared.show()
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help("Settings  •  ⌘,")
                        .keyboardShortcut(",", modifiers: .command)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }

                    Button {
                        state.showConnections(previousDraft: nil)
                    } label: {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(KloColors.olive.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Connected apps  •  /apps  •  ⌘⇧A")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    // Voice-mode entry — hands the panel off to the Realtime
                    // bridge so the user can just talk. Matches the iPhone
                    // app's chat-nav waveform icon so the two surfaces
                    // expose voice mode the same way. ⌘⇧K hotkey already
                    // bound globally, but having the icon here makes it
                    // discoverable to users who don't memorize shortcuts.
                    Button {
                        state.toggleVoice()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(KloColors.olive.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Voice mode  •  ⌘⇧K")
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                // Cream-filled circle FAB — appears the moment there's
                // text to send. Mirrors Open iOS's round next-button
                // (see screen 10, screen 125). The cream fill is the
                // "press me" signal; absence means "nothing to do yet."
                if hasText {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(KloColors.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(KloColors.cream))
                            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("↩ Send")
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.85))
                    ))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hasText)

            // Baseline hairline + tiny caps hint. The line is the
            // entire visual chrome of the input — no box, no shaded
            // background, just a thin underline that says "this is
            // a field, type here." The caps row beneath is the Open
            // signature: status that doesn't shout.
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(hasText
                          ? Color.white.opacity(0.22)
                          : Color.white.opacity(0.12))
                    .frame(height: 0.5)
                    .frame(maxWidth: .infinity)
                    .animation(.easeOut(duration: 0.18), value: hasText)
            }

            HStack(spacing: 0) {
                Text("ASK KLO")
                    .font(.system(size: 9, weight: .semibold, design: .default))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.32))

                Spacer(minLength: 8)

                if hasText {
                    HStack(spacing: 6) {
                        Image(systemName: "return")
                            .font(.system(size: 9, weight: .semibold))
                        Text("SEND")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.0)
                    }
                    .foregroundStyle(.white.opacity(0.50))
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: hasText)
        }
        .padding(.top, contentInsets.top)
        .padding(.bottom, contentInsets.bottom)
        .padding(.leading, contentInsets.leading)
        .padding(.trailing, contentInsets.trailing)
        .frame(maxWidth: .infinity)
        // Slash-app suggestions render in a real NSPopover (via
        // SwiftUI's .popover modifier) so they escape the notch
        // panel's clipShape — a SwiftUI .overlay would get clipped
        // against the host's rounded mask and chop the suggestion
        // list off at the top. The popover anchor is the top edge
        // of the input row and the arrow points down at it, so the
        // list sits cleanly above where the user is typing.
        .popover(
            isPresented: $showSuggestions,
            attachmentAnchor: .point(.top),
            arrowEdge: .bottom
        ) {
            SlashAppSuggestions(
                suggestions: suggestions,
                connectedToolkits: account.connectedToolkits,
                onAccept: { acceptSuggestion($0) }
            )
            .frame(width: 320)
            .padding(8)
        }
        .onAppear {
            // Restore any draft that was preserved when the user opened
            // the connections panel via /apps + dismissed it via Esc.
            // KLOState.dismissConnections() stashes the draft here so
            // TextInputView's @State text picks it up on re-mount.
            if let restored = state.pendingDraftRestore, !restored.isEmpty {
                text = restored
                state.pendingDraftRestore = nil
            }
            DispatchQueue.main.async { fieldFocused = true }
        }
        // Reactive draft injection — listens AFTER first appear so the
        // proactive pills row (which sits BELOW this view) can fill the
        // input on tap without remounting. Same channel as the
        // /apps-panel return path; the .onAppear above handles the
        // initial mount case, this handler covers all subsequent
        // mid-session drops.
        .onChange(of: state.pendingDraftRestore) { newValue in
            guard let restored = newValue, !restored.isEmpty else { return }
            text = restored
            state.pendingDraftRestore = nil
            fieldFocused = true
        }
        // Conversation shortcuts. A local monitor (not .keyboardShortcut)
        // because ↑ never reaches SwiftUI shortcuts — the focused
        // TextField's field editor eats arrow keys for caret movement —
        // and because ⌘N must keep working while the user is typing
        // (the glyph buttons above only render when the field is empty).
        .background(KeyDownCatcher(handler: handleConversationKeys))
    }

    /// ↑ on an empty input opens the history overlay; ⌘N starts a
    /// fresh conversation. Both gated to the standalone .textExpanded
    /// surface (this view also mounts inline in ResultPanelView, where
    /// ↑ should stay with the transcript scroll) and suppressed while
    /// the history overlay is up — its own catcher owns the keys then.
    private func handleConversationKeys(_ event: NSEvent) -> Bool {
        guard state.mode == .textExpanded, !state.showingHistory else { return false }
        // ⌘N — new conversation, regardless of what's typed.
        if event.keyCode == 45 && event.modifierFlags.contains(.command) {
            state.startNewConversation()
            text = ""
            return true
        }
        // ↑ with empty input — open history. With text present the
        // arrow stays with the field editor (caret to line start).
        if event.keyCode == 126,
           event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
           text.isEmpty,
           !showSuggestions {
            state.showingHistory = true
            return true
        }
        return false
    }

    // (suggestionsOverlay removed — the slash suggestion list is now
    // rendered by the `.popover` modifier on the input row above so it
    // can extend beyond the notch panel's clipShape.)

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // If the popover is up, Return ACCEPTS the top suggestion
        // (Slack/Linear behavior) rather than submitting. User then
        // types their query against the scoped slug.
        if showSuggestions, let top = suggestions.first {
            acceptSuggestion(top)
            return
        }
        showSuggestions = false
        onSubmit(trimmed)
        text = ""
    }

    // MARK: - Slash autocomplete

    /// Recompute the suggestion list when text changes. We surface
    /// suggestions only while the user is still TYPING the slug — once
    /// they hit space, the slug is committed and the popover steps out
    /// of their way.
    private func updateSuggestions(for input: String) {
        guard input.hasPrefix("/") else {
            showSuggestions = false
            suggestions = []
            return
        }
        let afterSlash = String(input.dropFirst())
        // If a space exists, the user has moved past the slug into the
        // query — hide suggestions.
        if afterSlash.contains(" ") {
            showSuggestions = false
            suggestions = []
            return
        }
        let prefix = afterSlash.lowercased()
        // Empty `/` alone: nothing to suggest yet (don't dump the whole
        // 300+ catalog onto the user).
        if prefix.isEmpty {
            showSuggestions = false
            suggestions = []
            return
        }
        let connected = Set(account.connectedToolkits)
        let bundled = BrandStyle.bundledSlugs
        let matches = account.composioCatalogSnapshot.filter { app in
            // Reserved commands are not Composio apps; skip defensively.
            guard !Self.reservedSlashCommands.contains(app.slug) else { return false }
            let slug = app.slug.lowercased()
            let nameKey = app.name.replacingOccurrences(of: " ", with: "").lowercased()
            return slug.hasPrefix(prefix) || nameKey.hasPrefix(prefix)
        }
        // Sort: connected first, then bundled (i.e. ones with real
        // logos), then alphabetical. Stable secondary by name.
        let sorted = matches.sorted { lhs, rhs in
            let lc = connected.contains(lhs.slug) ? 0 : 1
            let rc = connected.contains(rhs.slug) ? 0 : 1
            if lc != rc { return lc < rc }
            let lb = bundled.contains(lhs.slug.lowercased()) ? 0 : 1
            let rb = bundled.contains(rhs.slug.lowercased()) ? 0 : 1
            if lb != rb { return lb < rb }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        suggestions = Array(sorted.prefix(6))
        showSuggestions = !suggestions.isEmpty
    }

    /// Accept a suggestion: replace whatever the user has typed (`/no`,
    /// `/notion`, etc.) with the canonical full slug + trailing space.
    /// Cursor naturally lands after the space because we set `text`
    /// before SwiftUI re-renders.
    private func acceptSuggestion(_ app: ComposioApp) {
        text = "/\(app.slug) "
        showSuggestions = false
        // Keep focus in the field so the user can immediately type
        // their query (and not have to click back into the input).
        fieldFocused = true
    }
}


// MARK: - Hover glyph button

/// Small trailing-edge icon button with a hover brighten — the quiet
/// affordance treatment for the conversation controls (history, new
/// chat). Kept dimmer at rest (0.45) than the gear/grid icons so the
/// cluster doesn't read as five equally-loud targets.
private struct HoverGlyphButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 0.75 : 0.45))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(helpText)
    }
}

// MARK: - Suggestion popover view

/// Floating card rendered ABOVE the input bar listing matched Composio
/// toolkits. Each row shows the brand-colored bundled logo + name +
/// "connected" pill where applicable. Click-to-accept; the parent's
/// keyboard handling (Return) accepts the top row.
struct SlashAppSuggestions: View {
    let suggestions: [ComposioApp]
    let connectedToolkits: [String]
    let onAccept: (ComposioApp) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.slug) { idx, app in
                Button {
                    onAccept(app)
                } label: {
                    suggestionRow(app, isTop: idx == 0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private func suggestionRow(_ app: ComposioApp, isTop: Bool) -> some View {
        let isConnected = connectedToolkits.contains(app.slug)
        let displayName = BrandStyle.displayName(slug: app.slug, catalogName: app.name)
        HStack(spacing: 10) {
            // Small brand logo or monogram — same fallback chain as
            // the tiles in ConnectionsView.
            if BrandStyle.bundledLogo(for: app.slug) != nil,
               let img = BrandStyle.bundledLogo(for: app.slug) {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Text(BrandStyle.monogram(slug: app.slug, catalogName: app.name))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrandStyle.color(for: app.slug))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(BrandStyle.color(for: app.slug).opacity(0.22))
                    )
            }
            Text(displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            // Hint on the top row that Return accepts it.
            if isTop {
                Text("↩")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer(minLength: 8)
            if isConnected {
                Text("connected")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(BrandStyle.color(for: app.slug))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(BrandStyle.color(for: app.slug).opacity(0.16))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTop ? Color.white.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
