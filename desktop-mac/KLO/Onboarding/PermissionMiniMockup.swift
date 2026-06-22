import SwiftUI

/// Animated mini-mockup of a System Settings → Privacy & Security row,
/// inspired by Loom / Cluely / Cleanshot. Sits inside a permission
/// card and previews exactly what the user will see + do in System
/// Settings: find klo in the list, click the toggle, done.
///
/// Driven by a TimelineView-derived clock so the animation runs on its
/// own without needing any external state. ~4s total cycle:
///
///   0.0 – 1.2s  toggle is OFF (gray pill, knob left). Cursor is
///               offscreen lower-right.
///   1.2 – 2.4s  cursor sprite slides in from below-right, lands on
///               the toggle.
///   2.4 – 2.8s  cursor "presses" (small downward nudge) → toggle
///               flips ON (orange pill, knob right). Cursor fades.
///   2.8 – 4.0s  hold ON (orange + checkmark feel).
///   reset, loop.
struct PermissionMiniMockup: View {
    let appLabel: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04)) { ctx in
            let cycle: Double = 4.0
            let t = ctx.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle)
            mockupBody(progress: t)
        }
        .frame(height: 90)
        .padding(.horizontal, 0)
    }

    private func mockupBody(progress t: Double) -> some View {
        // Toggle state derived from the timeline clock. Flip happens at
        // ~2.5s; before that it's off, after it's on (until reset).
        let toggleOn = t > 2.5
        // Cursor sprite slides in from 1.2 → 2.4, presses at 2.4 → 2.8,
        // fades after.
        let cursorAlpha: Double
        let cursorOffset: CGSize
        let cursorPress: CGFloat

        if t < 1.2 {
            cursorAlpha = 0.0
            cursorOffset = CGSize(width: 80, height: 60)
            cursorPress = 0.0
        } else if t < 2.4 {
            // Slide in. Linear interpolate across 1.2s.
            let p = (t - 1.2) / 1.2  // 0 → 1
            cursorAlpha = p
            cursorOffset = CGSize(
                width: 80 - 80 * p,  // 80 → 0
                height: 60 - 60 * p   // 60 → 0
            )
            cursorPress = 0.0
        } else if t < 2.8 {
            // Press (small downward nudge).
            let p = (t - 2.4) / 0.4
            cursorAlpha = 1.0 - p * 0.4
            cursorOffset = .zero
            cursorPress = CGFloat(p * 4)
        } else {
            // Fade.
            let p = min((t - 2.8) / 0.6, 1.0)
            cursorAlpha = (1.0 - p) * 0.6
            cursorOffset = CGSize(width: -10 * p, height: -8 * p)
            cursorPress = 0.0
        }

        return ZStack {
            // Mockup card surface — looks like a System Settings row.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KloColors.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(KloColors.borderFaint, lineWidth: 0.5)
                )

            // Two stacked rows so the mockup reads as a real list with
            // klo at the bottom — feels more authentic than a single
            // floating row.
            VStack(spacing: 0) {
                ghostRow
                Divider().background(KloColors.borderFaint)
                kloRow(toggleOn: toggleOn)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Cursor sprite — bottom-right of the mockup, slides in
            // toward the toggle, presses, fades.
            cursorSprite
                .opacity(cursorAlpha)
                .offset(cursorOffset)
                .offset(y: cursorPress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 28)
                .padding(.trailing, 22)
        }
    }

    // MARK: - Row pieces

    private var ghostRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(KloColors.borderFaint)
                .frame(width: 18, height: 18)
            Capsule()
                .fill(KloColors.borderFaint)
                .frame(width: 80, height: 8)
            Spacer()
            mockToggle(on: false, dim: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .opacity(0.6)
    }

    private func kloRow(toggleOn: Bool) -> some View {
        HStack(spacing: 10) {
            // klo icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(KloColors.ink)
                    .frame(width: 20, height: 20)
                Image("KloLogoVector")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .scaledToFit()
                    .frame(height: 12)
            }
            Text(appLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KloColors.fg)
            Spacer()
            mockToggle(on: toggleOn)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    /// Stylised macOS-style toggle. Orange when on (matching klo's
    /// brand color); gray when off.
    private func mockToggle(on: Bool, dim: Bool = false) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? KloColors.olive.opacity(dim ? 0.4 : 1.0)
                          : Color.gray.opacity(dim ? 0.25 : 0.40))
                .frame(width: 32, height: 18)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 2)
        }
        .animation(.easeOut(duration: 0.25), value: on)
    }

    private var cursorSprite: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(KloColors.fg)
            .shadow(color: .white.opacity(0.6), radius: 1)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
    }
}
