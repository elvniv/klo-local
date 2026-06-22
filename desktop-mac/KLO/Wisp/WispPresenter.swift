import Foundation
import SwiftUI
import Combine

/// Singleton state hub for the wisp overlay — the small glowing orange
/// presence that travels through the user's screen during an agent run.
///
/// Two writers:
///   - MacOpsExecutor publishes `actionFired(at:)` after each click /
///     type / key so the wisp animates to where klo just acted.
///   - KLOState calls `show()` / `hide()` on mode transitions so the
///     wisp appears at the start of `.working` and dissolves when the
///     run ends.
///
/// One reader: WispView observes this object and renders the orb +
/// halo + ember trail bound to `location` / `phase` / `pulseTrigger`.
///
/// Why a singleton: the wisp is a process-wide UI element and the
/// publishers live in different layers (MacOps vs agent client). A
/// shared `ObservableObject` avoids threading a reference through
/// every constructor.
@MainActor
final class WispPresenter: ObservableObject {
    static let shared = WispPresenter()

    /// Visible / hidden. Drives the overlay window's order-in/out.
    @Published var isActive: Bool = false

    /// Screen-absolute coords (top-left origin, Quartz space) of klo's
    /// last action. nil before the first action of a run — the wisp
    /// hovers at `notchHome` in that case.
    @Published var location: CGPoint? = nil

    /// What the wisp is doing right now. Drives the visual variant.
    @Published var phase: Phase = .thinking

    /// Bumped on every action; the view watches this for one-shot pulse
    /// animations. Using a Date instead of a counter so SwiftUI's
    /// `.onChange` fires on every action even at the same location.
    @Published var pulseTrigger: Date = .distantPast

    /// One-or-two-word verb that floats below the wisp (e.g. "Drafting",
    /// "Typing", "Reading inbox"). Set by KLOState whenever the agent's
    /// step_progress event lands. Nil means no label — the wisp shows
    /// just the orb. The view debounces fast updates so the label
    /// doesn't flicker.
    @Published var label: String? = nil

    enum Phase {
        case thinking   // breathing, no recent action
        case acting     // just clicked / typed — pulsing
        case stuck      // agent in a loop — trembling, red-tinted
    }

    private init() {}

    /// Compute notch home — the wisp's resting position when no action
    /// coord is known. Roughly the top center of the primary display.
    /// Top-left origin to match Quartz / CGEvent coordinates.
    var notchHome: CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: 720, y: 24)
        }
        let w = screen.frame.width
        return CGPoint(x: w / 2, y: 24)
    }

    func actionFired(at point: CGPoint) {
        location = point
        phase = .acting
        pulseTrigger = Date()
    }

    func startThinking() {
        phase = .thinking
    }

    func markStuck() {
        phase = .stuck
    }

    func show() {
        location = notchHome
        phase = .thinking
        isActive = true
        label = nil
    }

    /// Push a verb-in-motion label to display under the wisp. Trims to
    /// the first two words so the pill never wraps. Empty string clears.
    func setLabel(_ text: String?) {
        guard let raw = text, !raw.isEmpty else { label = nil; return }
        let words = raw.split(separator: " ", maxSplits: 2)
        let trimmed = words.prefix(2).joined(separator: " ")
        label = trimmed
    }

    /// Animate back to the notch home + dissolve. Caller controls when
    /// to fully hide; the view does a final flash before isActive flips.
    func hide() {
        // Pull location home so the dissolve animates from wherever the
        // wisp last was back to the notch. The view's exit transition
        // then handles the final fade.
        location = notchHome
        phase = .thinking
        // Defer isActive=false so the spring-to-home animation has
        // time to play out before the window orders out.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            isActive = false
        }
    }
}
