import SwiftUI

/// Small TCC-permission island shown when the agent's tool call hit a
/// permission_denied. Compact, monospaced query header + primary "Grant"
/// CTA + Esc-to-dismiss. Shares vocabulary with `ConfirmActionView` and
/// `SignInIslandView` so the three consent surfaces feel like a family.
struct PermissionRequiredView: View {
    let query: String
    let service: KLOState.PermissionService
    let onGrant: () -> Void
    let onDismiss: () -> Void

    @State private var appeared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Original query — small, monospaced, dim. So the user
            // sees what they asked and what got blocked.
            Text(query)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.4)
                .textCase(.lowercase)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(query)

            Text("klo needs \(service.displayName) for that.")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            Text(bodyCopy)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    onGrant()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Grant \(service.displayName)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.kloPrimary)

                Button {
                    onDismiss()
                } label: {
                    Text("Not now")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.kloGhost)
                .keyboardShortcut(.escape, modifiers: [])

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
    }

    private var bodyCopy: String {
        switch service {
        case .screenRecording:
            return "Lets klo see your screen for tasks that need vision. Click Grant — System Settings opens and klo gets out of your way so you can toggle the switch."
        case .accessibility:
            return "Lets klo click and type for you. Click Grant — System Settings opens and klo gets out of your way so you can toggle the switch."
        case .appleEvents:
            return "Lets klo control scriptable apps like Notes, Calendar, Music. Click Grant — System Settings opens and klo gets out of your way."
        }
    }
}
