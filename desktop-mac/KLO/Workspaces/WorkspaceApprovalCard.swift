import SwiftUI

/// The approval moment — klo wants to do something irreversible.
///
/// Design language (mirrors WorkspaceInitiatedCard):
///   1. 760pt wide, chat-panel ratio. No popup feel.
///   2. NO header bar. The ask is the first thing the eye sees.
///   3. Workspace slug as whisper-grade meta at top-right.
///   4. Payload sits below the ask in a fixed, internally-scrollable
///      area. The card's overall height never changes — the notch
///      geometry stays intentional. Long payloads scroll in place.
///   5. Same action vocabulary as init card + chat panel.
struct WorkspaceApprovalCard: View {
    let approval: KLOState.WorkspaceApproval
    @ObservedObject var state: KLOState

    @State private var approvePressed: Bool = false

    var body: some View {
        ZStack {
            chassis
            VStack(alignment: .leading, spacing: 0) {
                slugMeta
                    .padding(.bottom, 14)
                askFocal
                if !approval.payload.isEmpty {
                    payloadBlock
                        .padding(.top, 14)
                }
                Spacer(minLength: 10)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 760, height: 320)
        .onExitCommand {
            Task { await state.resolveWorkspaceApproval(approval, approved: false) }
        }
    }

    // MARK: - Chassis (same vocabulary as init)

    private var chassis: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(KloColors.olive.opacity(0.07))
                .blur(radius: 20)
                .frame(width: 772, height: 332)

            RoundedRectangle(cornerRadius: 18)
                .fill(Color(white: 0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.09), lineWidth: 0.6)
                )
        }
    }

    // MARK: - Slug meta

    private var slugMeta: some View {
        HStack {
            Spacer(minLength: 0)
            Text(approval.workspaceSlug)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.34))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Focal point — the ask

    private var askFocal: some View {
        Text(approval.ask)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.95))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Payload (fixed-height, internally scrollable)

    /// Inline payload block. Fixed height — the card never grows.
    /// Long payloads scroll inside this block, so the notch
    /// geometry stays intentional and predictable. Compact rows,
    /// whisper-grade keys, body-weight values.
    private var payloadBlock: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(approval.payload.indices, id: \.self) { idx in
                    payloadRow(approval.payload[idx])
                }
            }
        }
        .frame(maxHeight: 130)
        .padding(.top, 2)
        // Hairline above the payload block — same hairline language
        // as the chat panel's optional pickup separator.
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, -28),
            alignment: .top
        )
    }

    private func payloadRow(_ entry: KLOState.WorkspacePayloadEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(entry.key.lowercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(width: 92, alignment: .leading)
            Text(entry.value)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Button {
                Task { await state.resolveWorkspaceApproval(approval, approved: false) }
            } label: {
                Text("reject")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Button {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.65)) {
                    approvePressed = true
                }
                Task {
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    await state.resolveWorkspaceApproval(approval, approved: true)
                }
            } label: {
                Text("approve")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(KloColors.olive)
                    )
                    .scaleEffect(approvePressed ? 0.94 : 1.0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Release the gate  •  ⌘⏎")
        }
    }
}
