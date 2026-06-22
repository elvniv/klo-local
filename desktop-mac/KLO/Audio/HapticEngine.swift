import AppKit

/// Trackpad haptic feedback wrapper. macOS Force-Touch trackpads can
/// fire physical haptic taps; we use them at meaningful moments in the
/// onboarding so the experience has weight — the user feels it, not
/// just sees it.
///
/// `NSHapticFeedbackManager.defaultPerformer` only fires when the user
/// is actively touching the trackpad. That's fine — it's a bonus feel
/// for users on laptops; users on a Magic Mouse / external display get
/// the visuals + audio without missing critical info.
///
/// Patterns:
///   - `.alignment` — soft tap. Default for transitions.
///   - `.levelChange` — firmer tap. Used for "klo summoned" beats.
///   - `.generic` — default system feedback.
@MainActor
enum HapticEngine {

    /// Fire one haptic tap with the given pattern.
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Two firm taps in quick succession. Used for the "klo summoned"
    /// moment in DemoSceneOne — the user presses ⌘K and the laptop
    /// gives them a tactile "klo woke up" feel.
    static func summon() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// Soft tap for scene-to-scene transitions in the demo tour and
    /// onboarding card crossfades.
    static func transition() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Firm tap for "permission granted" celebratory moment.
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
