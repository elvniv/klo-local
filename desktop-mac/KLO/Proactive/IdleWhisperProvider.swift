import AppKit
import Foundation

/// Computes ONE soft suggestion line for the empty input bar.
///
/// Two sources, in order of preference:
///   1. Frontmost-app context via `ProactiveSignalsService.screenSignal()`
///      — if the user is on a browser tab, in Mail, in Linear, etc, we
///      emit the matching curated verb ("summarize this page", "draft
///      a reply", "what to ship today"). Same probe the pill row uses
///      so klo's brand voice stays consistent.
///   2. A deterministic curated rotation when no context fires —
///      keeps the surface useful on a quiet desktop without becoming
///      random or surveillant.
///
/// One whisper, not a list. The pill row is the engagement-design
/// surface (list of options); the whisper is one quiet starter that's
/// easy to ignore. Honest per the wow-moments framework.
@MainActor
enum IdleWhisperProvider {

    /// Curated lines. Plain-prose, lowercase, varied verb shapes so
    /// the rotation reads like real thought-starters rather than a
    /// formal menu. Add / edit liberally — the only rule is that
    /// each line should produce a meaningful klo run on its own.
    static let curatedRotation: [String] = [
        "brief me on today",
        "draft a reply to my last email",
        "what's on my screen",
        "summarize the linear issues i'm assigned",
        "find me a flight to nyc next friday morning",
        "remind me to send invoice on monday",
        "play something focus-y",
        "pull the most recent thread with paul",
        "what did i ship this week",
    ]

    /// Build a whisper for the current moment.
    ///
    /// `seed` lets callers (e.g. FirstPromptIslandWindowController)
    /// pick a deterministic rotation index without coupling to wall
    /// time — useful when we want the same example to show across
    /// multiple subsequent reads in the same session.
    static func compute(seed: UInt64? = nil) async -> KLOState.IdleWhisper? {
        // Screen probe first — context-aware always beats curated.
        if let signal = await ProactiveSignalsService.shared.screenSignal() {
            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            return KLOState.IdleWhisper(
                text: signal.label,
                prompt: signal.prompt,
                source: .screen(appBundleID: bundle),
            )
        }
        // Curated fallback. Deterministic rotation across calls so a
        // tight summon-then-resummon doesn't shuffle text under the
        // user's eye. Uses a per-day seed by default so the rotation
        // feels stable inside a session but doesn't pin to one phrase
        // for weeks.
        let line = pickCurated(seed: seed)
        return KLOState.IdleWhisper(text: line, prompt: line, source: .curated)
    }

    /// Same data the empty-input whisper uses, but the first-prompt
    /// island wants a guaranteed line (the user has nothing else to
    /// look at on first launch). Always returns a curated phrase.
    static func firstPromptExample(seed: UInt64? = nil) -> String {
        pickCurated(seed: seed)
    }

    private static func pickCurated(seed: UInt64?) -> String {
        let index: Int
        if let seed = seed {
            index = Int(seed % UInt64(curatedRotation.count))
        } else {
            // Per-day seed — same line for a given day's first summon,
            // shifts on the next day so the rotation feels alive.
            let day = Int(Date().timeIntervalSince1970 / 86_400)
            index = day % curatedRotation.count
        }
        return curatedRotation[index]
    }
}
