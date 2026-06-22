import SwiftUI

/// klo's type scale. Discipline matches the landing's Inter weights:
/// headlines are LIGHT (300), body is regular (400), button labels and
/// emphasised body are medium (500). We don't use SwiftUI's semantic
/// styles like `.title` / `.headline` because AppKit picks SF Pro
/// weights from those that read as "system default" — which is the
/// exact thing we're trying to leave behind.
///
/// The mono family is JetBrains Mono on the landing; here we fall
/// back to `.system(.body, design: .monospaced)` (SF Mono) which is
/// visually compatible at the small sizes we use it for (eyebrows,
/// kbd hints, footer chrome).
extension Font {

    /// 56pt light — onboarding hero. Mirrors landing's
    /// `text-[clamp(2.75rem,10vw,8rem)] font-light`.
    static let kloHero = Font.system(size: 56, weight: .light, design: .default)

    /// 32pt light — settings + secondary screens.
    static let kloHeadline = Font.system(size: 32, weight: .light, design: .default)

    /// 22pt regular — section titles inside cards.
    static let kloTitle = Font.system(size: 22, weight: .regular, design: .default)

    /// 14pt regular — readable body. Default for paragraph copy.
    static let kloBody = Font.system(size: 14, weight: .regular, design: .default)

    /// 14pt medium — emphasised body, button labels.
    static let kloBodyEmphasis = Font.system(size: 14, weight: .medium, design: .default)

    /// 12pt regular — secondary copy, captions.
    static let kloCaption = Font.system(size: 12, weight: .regular, design: .default)

    /// Mono micro-text for eyebrow chips, kbd hints, footer chrome.
    /// Matches the extension's 9px JetBrains Mono with 0.18em letter
    /// spacing — SwiftUI's tracking is in points so we use a small
    /// positive value to approximate the same airy feel.
    static let kloEyebrow = Font.system(size: 9, weight: .medium, design: .monospaced)

    /// Mono body — for log lines, prompts, technical copy.
    static let kloMono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

// ─── Eyebrow modifier ────────────────────────────────────────────────
// Wraps a Text in the canonical eyebrow look: lowercase mono, fg-45,
// 0.18em-ish tracking. Used by the small "STEP 1" / "YOU'RE IN" /
// "NOT SIGNED IN YET" pills throughout the brand.
struct KloEyebrowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.kloEyebrow)
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(KloColors.fg45)
    }
}

extension View {
    func kloEyebrow() -> some View { modifier(KloEyebrowModifier()) }
}

// ─── Meta-caps modifier ──────────────────────────────────────────────
// Slightly bigger + more legible cousin of kloEyebrow, for section
// headers and inline status labels ("DESCRIPTION", "READING", "TYPING",
// "PURCHASE HISTORY"). Same all-caps + tracked + dimmed shape — uses
// SF Pro instead of mono because at 10-11pt the mono gets too dense
// when shown inline next to body copy.
struct KloMetaCapsModifier: ViewModifier {
    var opacity: Double = 0.55

    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .medium, design: .default))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Color.white.opacity(opacity))
    }
}

extension View {
    /// All-caps meta label — for section headers and status pills shown
    /// to the right of body copy. Pass `opacity:` to vary from 0.35
    /// (very quiet) to 0.85 (live status).
    func kloMetaCaps(opacity: Double = 0.55) -> some View {
        modifier(KloMetaCapsModifier(opacity: opacity))
    }
}
