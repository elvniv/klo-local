import AppKit
import SwiftUI

/// Borderless NSWindow we use for every klo surface that ISN'T the
/// notch panel. Strips the title bar + traffic lights so we can paint
/// the entire frame ourselves; keeps the standard window level so it
/// behaves like a normal modal (not a HUD).
///
/// Drag is handled in two ways:
///   1. `isMovableByWindowBackground = true` — drag from any
///      non-hit-target part of the content;
///   2. `KloDragHandle` — explicit drag region you can drop into the
///      SwiftUI hierarchy if a more specific affordance is needed.
final class KloWindow: NSWindow {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        level = .normal
        // Standard window behaviour: appears in app switcher, can be
        // minimised via the keyboard equivalent, etc.
        collectionBehavior = [.fullScreenAuxiliary]
        // Borderless windows don't accept key input by default. We
        // override so text fields focus as expected.
        appearance = nil  // honour user OS appearance (light/dark)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


// ─────────────────────────────────────────────────────────────────────
// SwiftUI helpers wrapping the AppKit chrome we need on a borderless
// window: a drag region that responds to mouseDown anywhere in its
// bounds, and a small ✕ close button that doesn't look like an
// NSButton.
// ─────────────────────────────────────────────────────────────────────

/// Drop-in NSViewRepresentable that lets the user drag the window from
/// the area it occupies. Place it as an overlay or a tall transparent
/// strip at the top of the view.
struct KloDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Pass clicks to children if any (we have none today), but
            // intercept at our own level so the window starts dragging.
            return super.hitTest(point) ?? self
        }
    }
}


/// Custom × close button. No NSButton chrome, no system focus ring,
/// no rounded blue highlight on hover — just a quiet circle that
/// brightens on hover and dispatches close to the window.
///
/// Why not `NSApp.keyWindow?.performClose(nil)`: `KloWindow` uses the
/// borderless style mask, which doesn't include `.closable`. AppKit's
/// `performClose(_:)` silently no-ops on a window that isn't .closable
/// — so the previous implementation's button visually depressed but
/// did nothing. We now capture this button's actual hosting window
/// at first appearance via `KloWindowAccessor` and call `close()`
/// directly on it. Works regardless of style mask, and always closes
/// the right window (the one rendering THIS button) instead of
/// whatever `keyWindow` happens to be.
struct KloCloseButton: View {
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var hostWindow: NSWindow?

    var body: some View {
        Button {
            hostWindow?.close()
        } label: {
            ZStack {
                Circle()
                    .fill(hovered ? KloColors.borderFaint : Color.clear)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovered ? KloColors.fg : KloColors.fg60)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .background(KloWindowAccessor { hostWindow = $0 })
    }
}

/// Bridges from SwiftUI to the AppKit NSWindow that's hosting this
/// view. Used by `KloCloseButton` (and anywhere else that needs a
/// definite reference to the right window). The accessor renders a
/// zero-size NSView whose `.window` resolves once the view is in the
/// hierarchy; the closure delivers that window back into SwiftUI
/// `@State`. Repeats whenever the hosting window changes (which is
/// rare but possible — e.g., reparenting between windows).
struct KloWindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}


// ─────────────────────────────────────────────────────────────────────
// Reusable surface decoration: a soft pulsing olive ring driven by a
// TimelineView. Mirrors the `klo-fire-glow` keyframes the extension
// applies while the agent is working. Apply with .modifier(KloFireGlow())
// to any view that should breathe when active.
//
// Color note: was orange historically. Switched to olive because this
// modifier is the breathing-shadow under the startup notch pulse,
// the cinematic wordmark glow, the demo tour highlights, the
// permission transition toast, the handoff reminder, and the drag
// island — every "klo is alive" moment in the onboarding + startup
// flow. Orange read as alarm; olive matches the rest of the brand
// green and reads as "alive / thinking."
// ─────────────────────────────────────────────────────────────────────

struct KloFireGlow: ViewModifier {
    var active: Bool = true
    var radius: CGFloat = 28

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                // 2.4s ease-in-out cadence — same as the extension's
                // klo-fire-glow keyframes (0% → 50% → 100%).
                let phase = (sin(t * (.pi * 2 / 2.4)) + 1) / 2  // 0…1
                let opacity = 0.30 + (phase * 0.30)             // 0.30…0.60
                content
                    .shadow(color: KloColors.olive.opacity(opacity), radius: radius)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Apply the canonical klo "agent is working" glow.
    func kloFireGlow(active: Bool = true, radius: CGFloat = 28) -> some View {
        modifier(KloFireGlow(active: active, radius: radius))
    }
}
