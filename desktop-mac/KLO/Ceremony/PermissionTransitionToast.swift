import AppKit
import SwiftUI

/// Top-center "you can't miss this" toast that fires the moment a
/// required permission flips to granted. The user is staring at System
/// Settings when this happens — without an attention-grabbing beat
/// from klo, they don't realize klo detected the grant or that there
/// might be more to do.
///
/// The toast briefly activates klo (NSApp.activate +
/// NSRunningApplication.activate) so it actually appears in front of
/// System Settings, displays a big "✓ {permission} granted" + a
/// "next" callout, then auto-dismisses after 1.6s. The existing
/// sequential handoff in `OnboardingFocusCoordinator.celebrateAndRestore`
/// fires the next permission's pane after the toast settles.
@MainActor
final class PermissionTransitionToastWindowController {

    static let shared = PermissionTransitionToastWindowController()

    private var panel: PermissionTransitionToastPanel?

    /// Show the toast. `current` is the permission that just landed.
    /// `next` is what's coming up (nil → "all done").
    func show(current: Handoff, next: Handoff?) {
        let view = PermissionTransitionToastView(current: current, next: next)
        let host = NSHostingController(rootView: view)
        host.preferredContentSize = NSSize(
            width: PermissionTransitionToastPanel.width,
            height: PermissionTransitionToastPanel.height
        )

        if let existing = panel {
            existing.contentViewController = host
            existing.setFrame(idealFrame(), display: true)
            existing.orderFrontRegardless()
            return
        }

        let p = PermissionTransitionToastPanel(contentRect: idealFrame())
        p.contentViewController = host
        p.setFrame(idealFrame(), display: false)
        p.orderFrontRegardless()
        panel = p

        // Briefly bring klo to the foreground so the user actually sees
        // the toast — they're looking at System Settings otherwise.
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Top-center of the screen, ~80pt from the menu bar / notch.
    private func idealFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100,
                          width: PermissionTransitionToastPanel.width,
                          height: PermissionTransitionToastPanel.height)
        }
        let frame = screen.frame
        let topInset: CGFloat = (screen.safeAreaInsets.top + 24)
        let originX = frame.midX - PermissionTransitionToastPanel.width / 2
        let originY = frame.maxY - PermissionTransitionToastPanel.height - topInset
        return NSRect(x: originX, y: originY,
                      width: PermissionTransitionToastPanel.width,
                      height: PermissionTransitionToastPanel.height)
    }
}


// ─────────────────────────────────────────────────────────────────────
// Floating NSPanel — top-center, .floating level, ignoresMouseEvents
// = true (purely informational; never intercepts clicks).
// ─────────────────────────────────────────────────────────────────────

final class PermissionTransitionToastPanel: NSPanel {
    static let width: CGFloat = 540
    static let height: CGFloat = 120

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
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// ─────────────────────────────────────────────────────────────────────
// SwiftUI body — big checkmark + "{permission} granted" + next step.
// ─────────────────────────────────────────────────────────────────────

struct PermissionTransitionToastView: View {
    let current: Handoff
    let next: Handoff?

    @State private var appeared: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            // Big check icon — fire-glow burst on appearance.
            ZStack {
                Circle()
                    .fill(KloColors.olive.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(KloColors.olive)
            }
            .modifier(KloFireGlow(active: true, radius: 20))
            .scaleEffect(appeared ? 1.0 : 0.7)
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: appeared)

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(KloColors.fg)
                    .lineLimit(1)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 4)
                    .animation(.easeOut(duration: 0.35).delay(0.06), value: appeared)

                HStack(spacing: 8) {
                    Text(subText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(KloColors.fg60)
                        .lineLimit(2)
                    if next != nil {
                        animatedArrow
                    }
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.35).delay(0.12), value: appeared)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: PermissionTransitionToastPanel.width,
               height: PermissionTransitionToastPanel.height,
               alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(KloColors.olive.opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
        .onAppear { appeared = true }
    }

    private var headline: String {
        "\u{2713} \(current.label) granted"
    }

    private var subText: String {
        if let next = next {
            return "Next up: \(next.label) — opening it now"
        }
        return "All set! Bringing klo back…"
    }

    /// Right-pointing arrow that nudges horizontally.
    private var animatedArrow: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let x = sin(t * (.pi * 2 / 1.2)) * 5.0
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KloColors.olive)
                .offset(x: CGFloat(x))
        }
    }
}
