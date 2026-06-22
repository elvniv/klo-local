import SwiftUI
import AppKit

/// The init moment — klo just accepted a long-horizon brief.
///
/// Design language (after iteration on real screen feedback):
///   1. Match the chat panel rhythm. 760pt wide, like textExpanded.
///      The card feels like the same surface, not a popup.
///   2. NO header bar. No icons. No headline. The first thing the
///      user sees is their own words. Eye lands in 150ms.
///   3. Workspace slug is a whisper-grade meta line at the top-right,
///      same register as the chat panel's faded affordances.
///   4. Actions hug the bottom — minimal pill on the right, ghost on
///      the left. Same vocabulary as the chat panel's submit button.
///   5. Nothing clashes with the physical notch silhouette above.
struct WorkspaceInitiatedCard: View {
    let snapshot: KLOState.WorkspaceSnapshot
    @ObservedObject var state: KLOState

    var body: some View {
        ZStack {
            chassis
            VStack(alignment: .leading, spacing: 0) {
                slugMeta
                    .padding(.bottom, 18)
                briefFocal
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 760, height: 220)
        .onExitCommand {
            state.dismissWorkspaceInitiated()
        }
    }

    // MARK: - Chassis (quiet ink, soft warmth)

    private var chassis: some View {
        ZStack {
            // A subtle warmth at the chassis level — barely visible,
            // just enough that the card doesn't read as pure black.
            // Matches the chat panel's "alive but quiet" register.
            RoundedRectangle(cornerRadius: 22)
                .fill(KloColors.olive.opacity(0.07))
                .blur(radius: 20)
                .frame(width: 772, height: 232)

            RoundedRectangle(cornerRadius: 18)
                .fill(Color(white: 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.09), lineWidth: 0.6)
                )
        }
    }

    // MARK: - Slug meta (whisper-grade top line)

    /// Single line at the top-right, sub-eyebrow weight. Tells the
    /// user which workspace this is for; reads as byline, not header.
    /// No icon — pure typography mirrors how the chat panel handles
    /// secondary information.
    private var slugMeta: some View {
        HStack {
            Spacer(minLength: 0)
            Text(snapshot.slug)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.34))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Focal point — the user's brief

    /// 18pt italic regular. The entire card exists for this line. No
    /// container tint, no quote marks, no padding rectangle — just
    /// the user's words on the panel surface.
    private var briefFocal: some View {
        Text(snapshot.brief)
            .font(.system(size: 18, weight: .regular))
            .italic()
            .foregroundStyle(Color.white.opacity(0.95))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer (chat-panel button vocabulary)

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Button {
                state.dismissWorkspaceInitiated()
            } label: {
                Text("got it")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Button {
                openPlan()
                state.dismissWorkspaceInitiated()
            } label: {
                Text("open plan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(KloColors.olive)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Open plan.md  •  ⌘⏎")
        }
    }

    private func openPlan() {
        let root = NSString(string: snapshot.rootPath).expandingTildeInPath
        let plan = URL(fileURLWithPath: root).appendingPathComponent("plan.md")
        if FileManager.default.fileExists(atPath: plan.path) {
            NSWorkspace.shared.open(plan)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
        }
    }
}
