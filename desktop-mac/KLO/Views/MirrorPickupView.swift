import SwiftUI

/// The "from your iPhone, 12m ago" affordance that sits ABOVE the
/// proactive pills row when the user opens the notch via ⌘K and
/// klo-cloud's /messages has something newer than the local in-memory
/// transcript. Tap → load the carried-over reply into the chat thread
/// so the user can continue from where their other surface left off.
///
/// Visual treatment is a tight horizontal strip: tiny dot + source +
/// relative-time eyebrow on the left, the assistant's last-reply
/// preview clamped to one line in the middle, a dismiss X on the right.
/// Quieter than the iOS pickup card (which gets full vertical real
/// estate on a phone empty screen) — here the notch panel is short
/// and the input row is the eye's primary target.
struct MirrorPickupView: View {
    let messages: [MirrorMessage]
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    private var headline: MirrorMessage? {
        messages.first(where: { $0.role == "assistant" }) ?? messages.first
    }

    private var sourceLabel: String {
        guard let h = headline else { return "" }
        switch h.source {
        case "mac":       return "FROM YOUR MAC"
        case "ios":       return "FROM YOUR IPHONE"
        case "extension": return "FROM CHROME"
        case "voice":     return "FROM VOICE"
        case "scheduled": return "FROM A NUDGE"
        default:          return "FROM ANOTHER SURFACE"
        }
    }

    var body: some View {
        guard let h = headline else { return AnyView(EmptyView()) }
        return AnyView(
            Button(action: onAccept) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(KloColors.olive)
                        .frame(width: 4, height: 4)

                    Text("\(sourceLabel) · \(relativeAgo(h.created_at).uppercased())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(KloColors.olive.opacity(0.92))
                        .fixedSize()

                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 1, height: 10)

                    Text(h.content)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Text("pick up")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(KloColors.olive.opacity(0.95))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(KloColors.olive.opacity(0.85))

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(KloColors.olive.opacity(hovered ? 0.10 : 0.06)),
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(KloColors.olive.opacity(hovered ? 0.55 : 0.30),
                                      lineWidth: 0.6),
                )
                .scaleEffect(pressed ? 0.985 : 1.0)
                .animation(.easeOut(duration: 0.10), value: pressed)
                .animation(.easeOut(duration: 0.18), value: hovered)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false },
            )
            .help("Pick up where you left off")
            .accessibilityLabel("Pick up \(sourceLabel.lowercased())")
        )
    }

    private func relativeAgo(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return ""
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
