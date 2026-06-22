import AppKit

/// Borderless full-screen panel that hosts the cloud experience.
/// Mirrors KLOPanel's setup — sits above other apps, doesn't activate,
/// no chrome — but spans the entire screen rather than wrapping the
/// notch.
///
/// During the cinematic: `ignoresMouseEvents = true` (user can't
/// accidentally interrupt). After the host's phase flips to onboarding,
/// `CeremonyWindowController` toggles `ignoresMouseEvents = false` so
/// the cards are interactive. During a handoff the controller
/// `orderOut`s the panel entirely (no dim hedge); the `HandoffReminderWindowController`
/// pill takes over as the only klo surface.
final class CeremonyPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    // Onboarding cards need text input (sign-in field) so the panel
    // MUST be able to become key once the cinematic finishes. canBecomeKey
    // tracks ignoresMouseEvents — when the controller flips it to false
    // (onboarding interactive phase), the panel can become key.
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    /// klo runs as `LSUIElement: true` so there's no menu bar to host
    /// the standard ⌘Q. Without this override, ⌘Q sails past the
    /// cloud panel and the user has no way to quit short of force-
    /// quitting the app. Catch ⌘Q and ⌘W here and route to NSApp
    /// terminate so the user is never stuck.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "q" {
                NSApp.terminate(nil)
                return true
            }
            if chars == "w" {
                // ⌘W asks the host's escape affordance to fire (it
                // owns the dismiss + post-cloud routing). The button
                // has the same shortcut wired in SwiftUI, so just let
                // SwiftUI handle it by returning false here.
                return super.performKeyEquivalent(with: event)
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
