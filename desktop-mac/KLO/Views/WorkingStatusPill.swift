import SwiftUI

/// The notch's content during `.working` / `.resuming`.
///
/// Replaces the previous "empty notch + free-floating wisp orb across
/// the screen" approach that put the user's only source of agent
/// status in a different place every second. The pill keeps status
/// pinned to a known location (inside the notch silhouette) and reads
/// at a glance:
///
///     ●  READING THE PAGE                                  ×
///     ^ pulsing olive dot   ^ tracked all-caps verb        ^ cancel
///
/// The wisp orb still appears for physical click/type events as a
/// secondary "klo just acted HERE" flash, but it's no longer the
/// primary status surface. This pill is.
///
/// Width matches the surface (no internal background — the notch
/// silhouette IS the background). Vertical centering inside a
/// horizontally-dominant ~42pt pill silhouette.
struct WorkingStatusPill: View {
    @ObservedObject var presenter: WispPresenter
    let onCancel: () -> Void

    @State private var dotBreath: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing olive dot — the only thing inside the pill that
            // moves. Faster than the wisp orb's breath so it reads as
            // "working" rather than "idle." Soft halo gives it the
            // same alive-glow feeling as the wisp without competing
            // for attention.
            ZStack {
                Circle()
                    .fill(KloColors.olive.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .blur(radius: 4)
                Circle()
                    .fill(KloColors.olive)
                    .frame(width: 8, height: 8)
            }
            .scaleEffect(dotBreath)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    dotBreath = 1.25
                }
            }

            // The verb. WispPresenter publishes whatever the latest
            // tool call's "kind" is (Reading, Clicking, Typing, etc.).
            // Falls back to "WORKING" before the first tool fires.
            Text(displayLabel)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(.easeOut(duration: 0.18), value: presenter.label)

            Spacer(minLength: 8)

            // Cancel — small monoline X, low opacity until hover. Esc
            // and ⌘K still work globally; this is the explicit visible
            // affordance so the user never has to guess that the pill
            // is cancellable.
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Stop (Esc)")
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayLabel: String {
        if let label = presenter.label, !label.isEmpty {
            return label
        }
        return "Working"
    }
}
