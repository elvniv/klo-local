import SwiftUI

/// Settings shell — single Account pane (no tab bar, since we'd just
/// be padding for one tab). Top strip is a transparent drag region
/// with a quiet × in the corner; the rest is paper, brand-styled
/// account UI all the way down.
struct SettingsView: View {
    @ObservedObject var account: AccountManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Card surface — paper background, soft shadow handled by
            // the KloWindow itself (hasShadow = true). The internal
            // rounded corner is what the user reads as the "edge of
            // the app" since there's no title bar.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KloColors.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(KloColors.border, lineWidth: 0.5)
                )

            // Drag region — fills the whole card so any neutral area
            // moves the window. Sits behind interactive content.
            KloDragHandle()
                .allowsHitTesting(true)

            VStack(spacing: 0) {
                // Header strip: transparent (drags the window via
                // KloDragHandle below), holds nothing else — the
                // wordmark on the AccountView does the chrome work.
                Color.clear.frame(height: 28)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AccountView(account: account)
                        SchedulesSection(account: account)
                        RecentTasksSection()
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }

            // Quiet × pinned to the corner — no traffic lights, no
            // title bar. Above the drag handle so clicks land here.
            KloCloseButton()
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
        .frame(width: 460, height: 580)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Compact list of the user's most recent conversations, read from the
/// persistent ConversationStore (JSON in Application Support, capped at
/// the last ~50 conversations). Each row is clickable: it resumes that
/// thread in the notch panel (via the .kloResumeConversation
/// notification AppDelegate routes to KLOState, since Settings has no
/// direct reference to the state machine). Hidden when no history yet.
private struct RecentTasksSection: View {
    @ObservedObject private var store = ConversationStore.shared
    @State private var hoveredID: UUID?

    var body: some View {
        let recent = Array(store.list.prefix(8))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("recent conversations")
                    .kloEyebrow()

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent) { conv in
                        Button {
                            NotificationCenter.default.post(
                                name: .kloResumeConversation,
                                object: nil,
                                userInfo: ["id": conv.id]
                            )
                            // The user's intent is "go chat" — close
                            // Settings so the notch panel can take key
                            // focus without the key-window observer
                            // collapsing it on the next Settings click.
                            SettingsWindowController.shared.close()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(conv.title.isEmpty ? "untitled" : conv.title)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(KloColors.fg80)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(conv.title)
                                Spacer(minLength: 8)
                                Text(conv.updatedAt, format: .relative(presentation: .named))
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(KloColors.fg60)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(hoveredID == conv.id
                                          ? KloColors.fg.opacity(0.06)
                                          : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredID = hovering ? conv.id : (hoveredID == conv.id ? nil : hoveredID)
                        }
                        .help("Resume this conversation")
                    }
                }
                .padding(.horizontal, -8)
            }
            .padding(.top, 20)
        }
    }
}
