import SwiftUI
import AppKit

// Conversation resume surfaces for the .textExpanded panel:
//
//   - ThreadPeekStrip — quiet one-glance reminder of the live thread
//     (last exchange + relative time) above the input row. Click opens
//     the history overlay (textExpanded has no inline transcript — the
//     bubble transcript lives in .completed's ResultPanelView).
//   - ConversationHistoryOverlay — the resumable-conversations list
//     layered over the textExpanded content. NOT a mode: it's a view
//     affordance driven by state.showingHistory, so the mode machine,
//     panel hit-testing, and Esc plumbing stay untouched (the window
//     controller's Esc handler checks showingHistory first).
//
// Keyboard wiring follows the EscapeKeyCatcher pattern from
// ConnectionsView — a local NSEvent monitor mounted via .background —
// because SwiftUI's TextField swallows arrow keys into caret movement
// before .onMoveCommand ever fires.

// MARK: - Relative time

/// Tight "2m ago" stamps for the strip + list rows. The stock
/// RelativeDateTimeFormatter says "2 minutes ago", which is too wide
/// for a chip that shares a line with a title.
func kloCompactAgo(_ date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    if seconds < 60 { return "now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    let days = hours / 24
    if days < 7 { return "\(days)d ago" }
    let weeks = days / 7
    return "\(weeks)w ago"
}

// MARK: - Key catcher

/// Local keyDown monitor mounted via `.background` so it sees special
/// keys (arrows, Return, ⌘⌫) before the focused TextField's field
/// editor consumes them. `handler` returns true to swallow the event.
/// Same lifecycle discipline as ConnectionsView's EscapeKeyCatcher:
/// install on window attach, remove on detach + deinit.
struct KeyDownCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.handler = handler
    }

    private final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                    guard let handled = self?.handler?(ev), handled else { return ev }
                    return nil
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

// MARK: - Thread peek strip

/// Compact "you're mid-thread" reminder above the input row. Shows the
/// most recent user prompt (and assistant reply when present) so a
/// re-summoned notch reads as a continuation, not a blank slate.
/// Visually quiet on purpose — the input row stays the eye's target.
struct ThreadPeekStrip: View {
    @EnvironmentObject var state: KLOState
    @ObservedObject private var store = ConversationStore.shared
    @State private var hovered = false

    private var lastUserPrompt: String? {
        state.messages.last(where: { $0.role == .user })?.content
    }

    private var lastAssistantReply: String? {
        state.messages.last(where: { $0.role == .assistant })?.content
    }

    /// Live messages don't carry dates — the store's active thread
    /// does, so the time chip reads from there. Hidden when the live
    /// transcript has no persisted counterpart (mirror-pickup seeds).
    private var lastTurnDate: Date? {
        store.activeConversation?.lastMessage?.date
    }

    var body: some View {
        Button {
            // textExpanded has no inline transcript view, so the strip
            // routes to the history overlay where the full thread (and
            // every other thread) is one keystroke away.
            state.showingHistory = true
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if let prompt = lastUserPrompt {
                        Text(prompt)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let reply = lastAssistantReply {
                        Text(reply)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                if let date = lastTurnDate {
                    Text(kloCompactAgo(date))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(hovered ? 0.45 : 0.25))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.07 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .help("Continue this conversation — click for history")
    }
}

// MARK: - History overlay

/// The resumable-conversations list, layered over the textExpanded
/// content while `state.showingHistory` is true. Raycast-style:
/// filter-as-you-type, ↑/↓ selection, Return resumes, ⌘⌫ deletes,
/// Esc closes (intercepted by KLOWindowController.handleEscape before
/// its collapse-the-panel default).
struct ConversationHistoryOverlay: View {
    @EnvironmentObject var state: KLOState
    @ObservedObject private var store = ConversationStore.shared

    @State private var filter: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredID: UUID?
    @FocusState private var filterFocused: Bool

    /// Rows visible without scrolling; the list scrolls past this.
    private static let rowHeight: CGFloat = 42

    private var filteredConversations: [ConversationStore.Conversation] {
        let all = store.list
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { conv in
            conv.title.lowercased().contains(needle)
                || (conv.lastMessage?.content.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            if store.list.isEmpty {
                emptyState
            } else {
                conversationList
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            footerHints
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .background(KeyDownCatcher(handler: handleKey))
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.async { filterFocused = true }
        }
        .onChange(of: filter) { _, _ in
            // Filtering reshuffles the row set — snap selection back to
            // the top so ↑/↓ always start from the best match.
            selectedIndex = 0
        }
    }

    // MARK: Header (filter row)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))

            TextField(text: $filter) {
                Text("search conversations")
                    .foregroundStyle(.white.opacity(0.30))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.92))
            .tint(KloColors.orange)
            .focused($filterFocused)

            Spacer(minLength: 8)

            if !store.list.isEmpty {
                Text("\(store.list.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.30))
            }
        }
    }

    // MARK: List

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if filteredConversations.isEmpty {
                        Text("no matches")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.40))
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(filteredConversations.enumerated()), id: \.element.id) { idx, conv in
                        row(conv, isSelected: idx == selectedIndex)
                            .id(conv.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: selectedIndex) { _, newIndex in
                guard filteredConversations.indices.contains(newIndex) else { return }
                proxy.scrollTo(filteredConversations[newIndex].id, anchor: nil)
            }
        }
    }

    @ViewBuilder
    private func row(_ conv: ConversationStore.Conversation, isSelected: Bool) -> some View {
        let isHovered = hoveredID == conv.id
        // Previously the row was a Button with the hover-revealed
        // delete X as a NESTED Button inside its label. SwiftUI's
        // hit-testing breaks badly with button-in-button: the outer
        // row's action stops firing reliably even on areas well
        // clear of the inner X, so users could see history but
        // couldn't click into a row to resume.
        //
        // Now: the row is a styled container with .onTapGesture for
        // resume; the delete X is a real sibling Button positioned
        // on top. The X gets clicks in its own hit area (no nesting),
        // and the rest of the row fires resume cleanly.
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conv.title.isEmpty ? "untitled" : conv.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let preview = conv.lastMessage?.content {
                    Text(preview)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.50))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            // Hover swaps the time chip for a delete x — same
            // footprint so rows don't reflow under the cursor.
            // The delete Button is a sibling, NOT nested inside
            // the row's tap target, so its hit area is its own
            // 20×20 frame and the rest of the row remains tappable.
            if isHovered {
                Button {
                    delete(conv.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete conversation  •  ⌘⌫")
            } else {
                Text(kloCompactAgo(conv.updatedAt))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected
                      ? Color.white.opacity(0.08)
                      : (isHovered ? Color.white.opacity(0.05) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            state.resumeConversation(conv.id)
        }
        .onHover { hovering in
            hoveredID = hovering ? conv.id : (hoveredID == conv.id ? nil : hoveredID)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.25))
            Text("Nothing here yet — your conversations will appear here.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer hints

    private var footerHints: some View {
        HStack(spacing: 14) {
            hint(symbol: "↑↓", label: "navigate")
            hint(symbol: "↩", label: "resume")
            hint(symbol: "⌘⌫", label: "delete")
            hint(symbol: "esc", label: "close")
            Spacer(minLength: 0)
        }
    }

    private func hint(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.40))
            Text(label)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.28))
        }
    }

    // MARK: Keyboard

    /// Arrow / Return / ⌘⌫ interception. Esc is deliberately NOT
    /// handled here — KLOWindowController's localEscMonitor was
    /// installed first (local monitors fire in install order) so it
    /// sees Esc before us; its handleEscape checks showingHistory and
    /// closes the overlay instead of collapsing the panel. Everything
    /// else (typing) falls through to the focused filter field.
    private func handleKey(_ event: NSEvent) -> Bool {
        let rows = filteredConversations
        switch event.keyCode {
        case 126:  // ↑
            guard !rows.isEmpty else { return true }
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 125:  // ↓
            guard !rows.isEmpty else { return true }
            selectedIndex = min(rows.count - 1, selectedIndex + 1)
            return true
        case 36, 76:  // Return / keypad Enter
            guard rows.indices.contains(selectedIndex) else { return true }
            state.resumeConversation(rows[selectedIndex].id)
            return true
        case 51:  // Delete (⌫)
            guard event.modifierFlags.contains(.command) else { return false }
            guard rows.indices.contains(selectedIndex) else { return true }
            delete(rows[selectedIndex].id)
            return true
        default:
            return false
        }
    }

    private func delete(_ id: UUID) {
        let wasLive = (state.currentConversationID == id)
        ConversationStore.shared.delete(id: id)
        // Deleting the thread the live transcript came from leaves
        // `messages` orphaned — clear them so the next prompt doesn't
        // resurrect a conversation the user just deleted.
        if wasLive {
            state.messages = []
            state.currentConversationID = nil
        }
        if selectedIndex >= filteredConversations.count {
            selectedIndex = max(0, filteredConversations.count - 1)
        }
    }
}
