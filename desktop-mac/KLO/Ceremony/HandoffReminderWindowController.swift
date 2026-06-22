import AppKit
import Combine
import SwiftUI

/// Floating reminder pill shown in the top-right while the cloud is
/// `orderOut`'d for a handoff (System Settings or Chrome Web Store).
/// This is the only klo surface visible while the user is in another
/// app — without it they have no way back (klo is `LSUIElement: true`,
/// no Dock icon, no Cmd-Tab entry, and the notch panel hasn't booted
/// yet during onboarding).
///
/// Generic over `Handoff`: the body switches on the kind for copy +
/// step-number + completion-signal source. Permission handoffs also
/// surface the `AppDragIslandWindowController` (klo icon docked to the
/// Settings window so the user can drag it onto the TCC list — Sequoia
/// doesn't auto-add apps there). Chrome handoff doesn't need the
/// island since the install path lives entirely inside the browser.
@MainActor
final class HandoffReminderWindowController {

    private var panel: NSPanel?

    /// Show the reminder for `handoff`. Idempotent: a second call with
    /// the same kind rebinds the panel contents without rebuilding.
    func show(
        handoff: Handoff,
        permissions: PermissionsManager,
        bridge: BridgeStatusManager?,
        account: AccountManager,
        coordinator: OnboardingFocusCoordinator
    ) {
        let view = HandoffReminderView(
            handoff: handoff,
            permissions: permissions,
            bridge: bridge,
            account: account,
            coordinator: coordinator
        )
        let host = NSHostingController(rootView: view)
        host.preferredContentSize = NSSize(width: HandoffReminderPanel.width,
                                           height: HandoffReminderPanel.height)

        if let existing = panel {
            existing.contentViewController = host
            existing.setFrame(idealFrame(), display: true)
            existing.orderFrontRegardless()
            return
        }

        let p = HandoffReminderPanel(contentRect: idealFrame())
        p.contentViewController = host
        p.setFrame(idealFrame(), display: false)
        p.orderFrontRegardless()
        panel = p
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Top-right of the main screen, 24pt right margin, (notch height
    /// + 18pt) top inset.
    private func idealFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100,
                          width: HandoffReminderPanel.width,
                          height: HandoffReminderPanel.height)
        }
        let frame = screen.frame
        let topInset: CGFloat = (screen.safeAreaInsets.top + 18)
        let rightMargin: CGFloat = 24
        let originX = frame.maxX - HandoffReminderPanel.width - rightMargin
        let originY = frame.maxY - HandoffReminderPanel.height - topInset
        return NSRect(x: originX, y: originY,
                      width: HandoffReminderPanel.width,
                      height: HandoffReminderPanel.height)
    }
}


// ─────────────────────────────────────────────────────────────────────
// Reminder panel — borderless floating NSPanel.
// ─────────────────────────────────────────────────────────────────────

final class HandoffReminderPanel: NSPanel {
    static let width: CGFloat = 340
    static let height: CGFloat = 220

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
        // Interactive: the Return button needs clicks. Pill sits in the
        // top-right corner where the destination app's main UI doesn't
        // reach, so accepting clicks here doesn't block interaction.
        ignoresMouseEvents = false
    }

    // Stay non-key so the Return button click doesn't steal text focus
    // from System Settings / Chrome — SwiftUI hit-testing still
    // delivers the click.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// ─────────────────────────────────────────────────────────────────────
// SwiftUI body — kind-aware. Permission handoffs render the inline
// PermissionMiniMockup as their action prompt; chrome handoff renders
// a short copy block since the install is in the browser.
// ─────────────────────────────────────────────────────────────────────

struct HandoffReminderView: View {
    let handoff: Handoff
    @ObservedObject var permissions: PermissionsManager
    /// Optional — only consulted for the chrome handoff. Permission +
    /// google sign-in handoffs ignore it.
    var bridge: BridgeStatusManager?
    /// Optional — only consulted for the google sign-in handoff.
    @ObservedObject var account: AccountManager
    @ObservedObject var coordinator: OnboardingFocusCoordinator

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(stepLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(KloColors.fg60)
                    .id(handoff)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: handoff)
                Spacer(minLength: 8)
                statusDot
            }

            if handoff.isPermission {
                PermissionMiniMockup(appLabel: "klo")
            } else {
                browserBody
            }

            Spacer(minLength: 0)

            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: HandoffReminderPanel.width, height: HandoffReminderPanel.height,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isCelebrating ? KloColors.olive.opacity(0.55) : KloColors.border,
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .modifier(KloFireGlow(active: isCelebrating, radius: 24))
    }

    // MARK: - Bottom bar (return / continue affordance)

    /// Permission handoffs + waiting-state browser handoffs: small
    /// icon-only Return button. Browser handoff *completed* state:
    /// prominent labeled "Continue to klo" pill so the user has a
    /// clear next step after finishing in their browser.
    @ViewBuilder
    private var bottomBar: some View {
        if !handoff.isPermission && isCelebrating {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    coordinator.forceReturnFromHandoff()
                } label: {
                    HStack(spacing: 8) {
                        Text("Continue to klo")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.kloPrimary)
                .frame(maxWidth: 220)
                .keyboardShortcut(.return)
            }
        } else {
            HStack {
                Spacer(minLength: 0)
                Button {
                    coordinator.forceReturnFromHandoff()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KloColors.fg60)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(KloColors.bg))
                        .overlay(Circle().strokeBorder(KloColors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Return to klo")
            }
        }
    }

    // MARK: - Browser-handoff body (chrome install + google sign-in)

    private var browserBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KloColors.fg)
            Text(subhead)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(KloColors.fg60)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: String {
        switch handoff {
        case .chromeExtension:
            return isComplete ? "Extension installed." : "klo is waiting on your install."
        case .googleSignIn:
            return isComplete ? "Signed in." : "Finish signing in with Google."
        default:
            return ""
        }
    }

    private var subhead: String {
        switch handoff {
        case .chromeExtension:
            return isComplete
                ? "Finish setting it up in your browser — pin the icon, sign in, anything else you need. Then click Continue."
                : "Finish in Chrome — we'll detect it. Or come back any time."
        case .googleSignIn:
            return isComplete
                ? "Come back to klo when you're done in your browser."
                : "Sign in to Google in your browser — we'll detect it. Or come back any time."
        default:
            return ""
        }
    }

    // MARK: - Derived state

    /// "Step 1 · Accessibility" / "Step 2 · Screen Recording" /
    /// "Step · Chrome extension" — chrome doesn't get a number since
    /// it's always one card after permissions in the cloud flow.
    private var stepLabel: String {
        switch handoff {
        case .accessibility:
            return "Step 1 · Accessibility"
        case .screenRecording:
            let n = (permissions.accessibility == .granted) ? 2 : 1
            return "Step \(n) · Screen Recording"
        case .chromeExtension:
            return "Step · Chrome extension"
        case .googleSignIn:
            return "Step · Google sign-in"
        }
    }

    private var isComplete: Bool {
        switch handoff {
        case .accessibility:    return permissions.accessibility == .granted
        case .screenRecording:  return permissions.screenRecording == .granted
        case .chromeExtension:  return bridge?.extensionConnected ?? false
        case .googleSignIn:     return account.isSignedIn
        }
    }

    private var isCelebrating: Bool {
        coordinator.lastCompletedHandoff == handoff
    }

    @ViewBuilder
    private var statusDot: some View {
        if isCelebrating || isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(KloColors.olive)
        } else {
            Circle()
                .fill(KloColors.olive)
                .frame(width: 8, height: 8)
                .modifier(KloFireGlow(active: true, radius: 8))
        }
    }
}
