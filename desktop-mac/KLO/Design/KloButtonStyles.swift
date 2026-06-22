import SwiftUI

/// klo's button vocabulary — three styles that cover every CTA the
/// brand ever needs. They map 1:1 with the extension's CSS:
///
///   .kloPrimary  ↔ extension `.btn-primary` (orange fill, ink text,
///                  pill, scale-up on hover, dim on disabled)
///   .kloGhost    ↔ extension `.send-btn` ghost outline (transparent,
///                  hairline border, picks up orange on hover OR when
///                  the parent has .has-input style ambient state)
///   .kloIcon     ↔ extension `.menu-btn` (square, transparent, only
///                  reads on hover) — for ⋯ / × / ⌘K-style chrome
///                  affordances.
///
/// All three explicitly hide every Apple default that would leak in:
/// no `.borderedProminent` blue, no system focus ring, no rounded-rect
/// background, no SF symbol weight changes from the system style.

// ─── Primary CTA: cream pill ──────────────────────────────────────────
// The "moment of payoff" button — off-white fill with near-black text,
// arrow glyph the caller adds at the end of the label ("Continue →").
// Borrowed from Open iOS's pattern: there is at most ONE cream-filled
// pill on screen at a time; everything else is ghost or text. Orange
// is no longer the primary fill — it's reserved for `.kloAccent` below.
struct KloPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kloBodyEmphasis)
            .foregroundStyle(KloColors.ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(KloColors.cream)
                    // Subtle inner highlight when hovered — paper-on-paper
                    // doesn't take a hue lift well, so we use brightness
                    // bump instead of a separate creamHi token.
                    .brightness(hovered && enabled ? 0.02 : 0)
            )
            .shadow(color: .black.opacity(0.20),
                    radius: hovered && enabled ? 14 : 8,
                    x: 0, y: hovered && enabled ? 6 : 4)
            .opacity(enabled ? (configuration.isPressed ? 0.88 : 1.0) : 0.40)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered && enabled ? 1.01 : 1.0))
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}


// ─── Accent CTA: orange pill (was the old .kloPrimary) ───────────────
// For agent-action moments where orange's "this is klo's doing" energy
// is right — e.g. "Run again", "Retry", or the legacy-flow CTAs that
// already shipped expecting orange. New surfaces should default to
// `.kloPrimary` (cream) and reach for `.kloAccent` only when the
// design specifically calls for the brand swatch.
struct KloAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kloBodyEmphasis)
            .foregroundStyle(KloColors.ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered && enabled ? KloColors.orangeHi : KloColors.orange)
            )
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.40)
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered && enabled ? 1.01 : 1.0))
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}


// ─── Ghost: hairline outline, picks up orange on hover ───────────────
struct KloGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kloBodyEmphasis)
            .foregroundStyle(hovered && enabled ? KloColors.fg : KloColors.fg60)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered && enabled ? KloColors.bgSoft : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        hovered && enabled ? KloColors.borderStrong : KloColors.border,
                        lineWidth: 1
                    )
            )
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.40)
            .animation(.easeInOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}


// ─── Icon: square, transparent, fades in on hover ────────────────────
struct KloIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovered && enabled ? KloColors.fg : KloColors.fg60)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered && enabled ? KloColors.borderFaint : Color.clear)
            )
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.40)
            .animation(.easeInOut(duration: 0.10), value: hovered)
            .onHover { hovered = $0 }
    }
}


// ─── Stop: orange-outlined square, used during agent-running state ───
// Mirrors the extension's `.stop-btn` (the round outlined button that
// replaces the send button when the agent is working). The stop-fill
// glyph + orange outline are the universal "press to interrupt" cue.
struct KloStopButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(KloColors.orange)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(hovered ? KloColors.orange.opacity(0.20) : KloColors.orange.opacity(0.10))
            )
            .overlay(
                Circle()
                    .strokeBorder(KloColors.orange, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : (hovered ? 1.04 : 1.0))
            .animation(.easeInOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}


// ─── Convenience static accessors ────────────────────────────────────
extension ButtonStyle where Self == KloPrimaryButtonStyle {
    static var kloPrimary: KloPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == KloAccentButtonStyle {
    static var kloAccent: KloAccentButtonStyle { .init() }
}
extension ButtonStyle where Self == KloGhostButtonStyle {
    static var kloGhost: KloGhostButtonStyle { .init() }
}
extension ButtonStyle where Self == KloIconButtonStyle {
    static var kloIcon: KloIconButtonStyle { .init() }
}
extension ButtonStyle where Self == KloStopButtonStyle {
    static var kloStop: KloStopButtonStyle { .init() }
}
