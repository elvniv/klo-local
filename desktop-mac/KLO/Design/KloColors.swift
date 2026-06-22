import SwiftUI

/// klo's color tokens. Mirrors the CSS custom-properties shipped in
/// `extension/sidepanel.html:17–37` and the landing's tailwind config —
/// cream paper for light surfaces, near-black ink for dark, and a
/// single orange accent that should only appear as small dots, focus
/// rings, status pills, or pulses. Body text is always ink/paper —
/// orange must never carry a paragraph.
///
/// All values resolve through `@Environment(\.colorScheme)` via
/// `Color(light:dark:)` so the surfaces flip automatically. Tokens
/// outside the fg/bg families (orange, error, success) stay constant
/// across both themes — they're brand swatches, not surfaces.
enum KloColors {

    // ─── Brand swatches (theme-invariant) ────────────────────────────
    static let orange   = Color(red: 1.00, green: 0.584, blue: 0.000)   // #FF9500
    static let orangeHi = Color(red: 1.00, green: 0.701, blue: 0.278)   // #FFB347
    static let orangeLo = Color(red: 0.878, green: 0.498, blue: 0.000)  // #E07F00
    static let paper    = Color(red: 0.984, green: 0.972, blue: 0.949)  // #FBF8F2
    static let ink      = Color(red: 0.039, green: 0.039, blue: 0.039)  // #0A0A0A
    static let error    = Color(red: 0.863, green: 0.149, blue: 0.149)  // #DC2626
    static let success  = Color(red: 0.086, green: 0.639, blue: 0.290)  // #16A34A

    // ─── Notch palette (always dark surface — the overlay sits on a
    //     black panel that never flips). These tokens are the design
    //     vocabulary borrowed from Open's iOS app: cream as the primary
    //     payoff color, three semantic accents that map to klo's tool
    //     classes, and a white outline for resting notch chrome.
    // ─────────────────────────────────────────────────────────────────

    /// Off-white pill fill — the "primary CTA arrived" color. Use for
    /// the one thing the user should do next on a surface (Send,
    /// Continue, Start, Open Settings). Slightly warm to read as paper
    /// rather than clinical white.
    static let cream    = Color(red: 0.945, green: 0.925, blue: 0.898)  // #F1ECE5

    /// Olive / yellow-green — "reading" / "thinking" / passive-good.
    /// Maps to klo tool classes: AX read, shell read, success toggle.
    /// Also the breath/wisp orb color in living-state.
    static let olive    = Color(red: 0.659, green: 0.757, blue: 0.322)  // #A8C152
    /// Brighter olive — hot core / accent highlight in the olive
    /// family. Mirrors `orangeHi` in the orange ramp so any surface
    /// that needs a 3-stop gradient (e.g. the voice fire silhouette)
    /// can render in green without inventing new hues.
    static let oliveHi  = Color(red: 0.745, green: 0.835, blue: 0.435)  // #BED56F
    /// Cooler / darker olive — outer-edge gradient stop in the olive
    /// family. Mirrors `orangeLo` so the fire's base-glow outer ring
    /// has a calm green equivalent.
    static let oliveLo  = Color(red: 0.561, green: 0.659, blue: 0.278)  // #8FA847

    /// Copper / warm orange — "acting" / mutating. Maps to clicks,
    /// typing, key presses. Progress fills, avatar gradients.
    static let copper   = Color(red: 0.816, green: 0.541, blue: 0.290)  // #D08A4A

    /// Teal / cool blue-grey — "resting" / waiting / paused.
    static let teal     = Color(red: 0.482, green: 0.604, blue: 0.671)  // #7B9AAB

    /// Idle notch outline — olive at high opacity. Reads as a calm
    /// "alive but resting" pulse, but visibly green (not the faint
    /// shimmer the first pass gave us at 0.55). Pairs with
    /// `notchIdleGlow` for a small bloom around the silhouette.
    static let notchOutlineIdle = olive.opacity(0.80)

    /// Olive halo painted as a shadow behind the dormant notch.
    /// Tuned to read as "definitely green" without becoming a flood —
    /// the radii in KLOOverlayView keep the bloom small + crisp.
    static let notchIdleGlow = olive.opacity(0.50)

    // ─── Semantic surfaces (flip on dark mode) ───────────────────────
    /// Page-level background. Cream on light, near-black on dark.
    static let bg = Color.klo(light: paper, dark: ink)

    /// Card / lifted surface above bg. White on light, slightly-lifted
    /// dark on dark. Matches the extension's --bg-soft (#FFFFFF) /
    /// dark-mode #161616.
    static let bgSoft = Color.klo(light: .white,
                                  dark:  Color(red: 0.086, green: 0.086, blue: 0.086))

    /// Input background. Same family as bgSoft.
    static let bgInput = bgSoft

    /// Primary readable foreground.
    static let fg = Color.klo(light: ink, dark: paper)

    /// 80% foreground. Body text against bg / bgSoft.
    static let fg80 = Color.klo(light: ink.opacity(0.80),
                                dark:  Color.white.opacity(0.85))

    /// 60% foreground. Subtitles, secondary labels.
    static let fg60 = Color.klo(light: ink.opacity(0.60),
                                dark:  Color.white.opacity(0.60))

    /// 45% foreground. Eyebrows, captions, footnotes.
    static let fg45 = Color.klo(light: ink.opacity(0.45),
                                dark:  Color.white.opacity(0.45))

    /// Hairline borders.
    static let border       = Color.klo(light: ink.opacity(0.15),
                                        dark:  Color.white.opacity(0.12))
    static let borderStrong = Color.klo(light: ink.opacity(0.25),
                                        dark:  Color.white.opacity(0.20))
    static let borderFaint  = Color.klo(light: ink.opacity(0.07),
                                        dark:  Color.white.opacity(0.06))
}

// ─────────────────────────────────────────────────────────────────────
// Helper: build a Color that picks light vs dark based on color scheme.
// Wrapping NSColor avoids the SwiftUI `.dynamic` initializer's iOS-only
// availability.
//
// Named `klo(light:dark:)` (not `init(light:dark:)`) because some
// third-party packages — notably MarkdownUI — export a public
// `Color.init(light:dark:)` that would otherwise be ambiguous with
// our fileprivate init at every call site in this file. Static
// factory method dodges the clash cleanly.
// ─────────────────────────────────────────────────────────────────────
extension Color {
    fileprivate static func klo(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) {
            case .some:
                return NSColor(dark)
            default:
                return NSColor(light)
            }
        }))
    }
}
