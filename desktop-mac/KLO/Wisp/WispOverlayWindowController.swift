import AppKit
import SwiftUI

/// Borderless, click-through, always-on-top NSPanel that hosts the
/// wisp overlay across the entire primary display. Lifetime is the
/// app's; the panel stays alive but invisible (ordered out) until
/// `WispPresenter.shared.isActive` flips true, at which point it
/// orders front with a fade-in.
///
/// Why a panel (NSPanel) instead of NSWindow:
///   - `.nonactivatingPanel` so summoning the wisp doesn't steal focus
///     from whatever app klo is driving.
///   - panels naturally accept `.canJoinAllSpaces` collection behavior
///     so the wisp follows the user across Mission Control spaces.
///
/// Why level = .screenSaver:
///   - Above almost everything (other apps, dock, menu bar) so the
///     wisp is visible while klo drives apps that maximize. Below
///     system dialogs and the lockscreen so we don't fight the OS.
///
/// Why ignoresMouseEvents:
///   - The wisp must NEVER block user input. Every click must pass
///     through to whatever's below. This is a presence overlay, not
///     a UI surface.
@MainActor
final class WispOverlayWindowController: NSObject {

    private var panel: NSPanel?
    private let presenter: WispPresenter
    private var visibilityTask: Task<Void, Never>?

    init(presenter: WispPresenter = .shared) {
        self.presenter = presenter
        super.init()
    }

    /// Build the panel + host the SwiftUI view + start observing the
    /// presenter's isActive stream. Idempotent: subsequent calls no-op.
    func show() {
        if panel != nil { return }
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = false
        p.contentView = NSHostingView(rootView: WispHostView(presenter: presenter))
        p.setFrame(frame, display: true)

        panel = p

        // Subscribe to the presenter's isActive stream. The window stays
        // alive across its lifetime; only orderFront / orderOut toggles
        // as the wisp activates / deactivates. Combine's @Published
        // exposes `.values` as an AsyncSequence on macOS 12+.
        visibilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await active in self.presenter.$isActive.values {
                self.applyVisibility(active)
            }
        }
    }

    deinit {
        visibilityTask?.cancel()
    }

    private func applyVisibility(_ active: Bool) {
        guard let p = panel else { return }
        if active {
            if !p.isVisible {
                p.orderFrontRegardless()
            }
        } else {
            if p.isVisible {
                p.orderOut(nil)
            }
        }
    }
}
