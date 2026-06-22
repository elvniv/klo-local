import AppKit
import SwiftUI

// Custom NSPanel that:
//  - Stays out of the active-app's way (nonactivatingPanel).
//  - Floats above normal app windows (level: statusBar) but stays
//    BELOW macOS system dialogs (TCC consent prompts, modalPanels,
//    permission alerts). Earlier this was .screenSaver (1000) which
//    sat above EVERY system dialog — that meant when macOS popped an
//    "Allow klo to record your screen?" prompt, klo's notch was
//    visually above it AND captured clicks meant for "Allow". User
//    was stuck. .statusBar (25) puts klo above regular apps + full-
//    screen content but lets the OS's own alerts win z-order
//    naturally, so clicks pass through to "Allow" / "Deny".
//  - Becomes key only when expanded — so the user can type into the
//    panel while the underlying app keeps its focus state otherwise.
final class KLOPanel: NSPanel {

    /// Set by the window controller whenever state changes. When false,
    /// canBecomeKey returns false — the panel is decorative (idle line)
    /// and shouldn't grab keyboard focus.
    var allowsKey: Bool = false {
        didSet { invalidateRestorableState() }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true   // idle by default
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { allowsKey }
}

/// NSHostingView that lets clicks fall through any region SwiftUI didn't
/// claim as interactive.
///
/// The notch panel is a 1000×700pt transparent slab pinned to the
/// top-center of the screen. Without this subclass, AppKit hands the
/// hosting view EVERY click that lands anywhere in that frame — even over
/// fully transparent areas marked `.allowsHitTesting(false)` — so a large
/// chunk of the screen's top-middle silently stops responding to clicks
/// whenever klo isn't in full mouse-ignore mode (the idle extension-nudge
/// pill is up, the working bubbles are showing, an expanded result panel
/// is open, …). Users described it as "a dead zone in the top-middle."
///
/// AppKit often sees SwiftUI controls as the hosting view itself, so the
/// window controller supplies explicit surface rects for the current mode.
/// Points inside those rects go to SwiftUI; everything else passes through
/// to the app underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// AppKit sees most SwiftUI content as this hosting view, not as
    /// separate NSView children. The window controller provides the
    /// current KLO surface rects so we can pass through transparent
    /// canvas while still letting SwiftUI receive clicks on real KLO UI.
    var activeHitTestRegions: ((NSRect) -> [NSRect])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard let regions = activeHitTestRegions else {
            return hit === self ? nil : hit
        }
        return regions(bounds).contains { $0.contains(point) } ? hit : nil
    }
}
