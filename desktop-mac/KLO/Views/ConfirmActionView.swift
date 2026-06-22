import SwiftUI

/// Inline confirm bar — surfaced when the agent calls `confirm_action`
/// for a destructive / sending / money / system-changes action. Mirrors
/// the `PermissionRequiredView` vocabulary (compact, monospaced query
/// header, primary + ghost button row) so the two consent surfaces feel
/// like the same family.
///
/// Keyboard:
///   - ⌘+Return / ⌘+Enter on Accept (the conventional macOS commit
///     shortcut for "yes, do it" prompts).
///   - ESC on Cancel — handled by the global ESC ladder in
///     KLOWindowController so it stays consistent with every other
///     panel; `onExitCommand` at the body level here is the
///     belt-and-suspenders fallback if the global monitor isn't
///     installed.
struct ConfirmActionView: View {
    let payload: KLOState.ConfirmPayload
    let onAccept: () -> Void
    let onCancel: () -> Void

    @State private var appeared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Originating query — small, dim, monospaced. Tells the
            // user which task is asking for confirmation.
            if !payload.query.isEmpty {
                Text(payload.query)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .tracking(0.4)
                    .textCase(.lowercase)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(payload.query)
            }

            Text(payload.irreversible ? "Confirm — this can't be undone." : "Confirm to continue.")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            Text(payload.summary)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            if let danger = payload.danger, !danger.isEmpty {
                Text(danger)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    onAccept()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Accept")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.kloPrimary)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("⌘↩ to accept")

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.kloGhost)
                .help("Esc to cancel")

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 4)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                appeared = true
            }
        }
        // Belt-and-suspenders ESC handling. KLOWindowController's
        // global monitor handles ESC for every mode and is the source
        // of truth; this exists so the view still behaves correctly
        // if the monitor was somehow uninstalled (tests, future
        // refactors).
        .onExitCommand { onCancel() }
    }
}
