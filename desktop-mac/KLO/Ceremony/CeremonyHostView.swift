import SwiftUI
import AppKit

/// Posted by `DemoSceneOne` when the user "presses ⌘K" — the host
/// listens and applies a brief, strong fire-glow burst to the real
/// notch silhouette so the user reads "klo lives in your notch" by
/// watching the real notch flare instead of a fake mockup.
extension Notification.Name {
    static let kloDemoSummonNotch = Notification.Name("klo.demoSummonNotch")
}

/// Unified SwiftUI root for the cloud panel. Owns the persistent
/// backdrop, notch silhouette, and wordmark watermark — these survive
/// the cinematic→onboarding crossfade with state intact (no remount).
///
/// Phase content:
///   - Cinematic: `CinematicContent` (headline + sub fade-in/out)
///   - Onboarding: `CloudOnboardingCard` (Permissions → Ready)
///
/// Visible chrome:
///   - Top-right close button — always visible during onboarding,
///     hidden during cinematic (so the cinematic isn't interrupted)
///     and during dimmedAwaiting (cloud is orderOut'd anyway).
///   - The handoff reminder is no longer rendered here — it's a
///     separate floating NSPanel owned by `HandoffReminderWindowController`.
///     Cleaner separation: cloud is gone during handoff; reminder
///     lives in its own surface that can't be confused with the cloud.
struct CeremonyHostView: View {

    @ObservedObject var coordinator: OnboardingFocusCoordinator
    @ObservedObject var account: AccountManager
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var bridge: BridgeStatusManager

    let notchGeometry: NotchGeometry
    let onCinematicComplete: () -> Void
    let onOnboardingDone: () -> Void
    /// User clicked × OR hit ⌘W / ⌘Q during onboarding — dismiss the
    /// cloud without marking onboarding complete. They can re-enter
    /// on next launch (or via the standalone SignIn window if they
    /// signed in before escaping).
    let onEscape: () -> Void

    private let screen: CGSize = NSScreen.main?.frame.size
        ?? CGSize(width: 1440, height: 900)

    /// True for ~1.4s when DemoSceneOne posts the summon notification.
    /// The real NotchSilhouette gets an extra-strong fire-glow during
    /// this window — the user's eye is drawn to the actual notch
    /// instead of any fake mockup.
    @State private var notchSummonPulse: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1 — Atmospheric cloud backdrop.
            CeremonyBackdrop()
                .ignoresSafeArea()

            // Layer 2 — Hardware notch silhouette + fire-glow.
            // Extra glow burst when DemoSceneOne summons.
            if notchGeometry.hasNotch {
                NotchSilhouette(geometry: notchGeometry)
                    .modifier(KloFireGlow(active: notchSummonPulse, radius: 64))
                    .scaleEffect(notchSummonPulse ? 1.08 : 1.0, anchor: .top)
                    .animation(.easeOut(duration: 0.28), value: notchSummonPulse)
            }

            // Layer 3 — klo wordmark watermark.
            wordmark

            // Layer 4 — Phase content. Crossfade cinematic → onboarding
            // inside the same SwiftUI tree (no remount).
            phaseContent

            // Layer 5 — Visible escape affordance. Top-right of screen,
            // macOS-conventional position. Demo tour + onboarding only;
            // cinematic shouldn't be interruptable mid-frame.
            if coordinator.phase != .cinematic {
                CloudCloseButton(onClose: onEscape)
                    .padding(.top, max(notchGeometry.height + 14, 38))
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .frame(width: screen.width, height: screen.height)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .kloDemoSummonNotch)) { _ in
            // Strong pulse for ~1.4s, then fade.
            withAnimation(.easeOut(duration: 0.25)) {
                notchSummonPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeIn(duration: 0.6)) {
                    notchSummonPulse = false
                }
            }
        }
    }

    // MARK: - Phase content

    @ViewBuilder
    private var phaseContent: some View {
        switch coordinator.phase {
        case .cinematic:
            CinematicContent(
                notchGeometry: notchGeometry,
                wordmarkOpacity: $wordmarkOpacity,
                wordmarkScale: $wordmarkScale,
                onComplete: onCinematicComplete
            )
            .transition(.opacity)

        case .demoTour:
            CloudDemoTour(coordinator: coordinator)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .onboarding:
            CloudOnboardingCard(
                permissions: permissions,
                bridge: bridge,
                coordinator: coordinator,
                account: account,
                onDone: onOnboardingDone
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .returningWelcome:
            // Brief "Welcome back." flourish for returning users.
            // Drives wordmark opacity directly so the wordmark fades
            // in with the headline + sub, then everything fades out
            // together when the host calls onCinematicComplete.
            ReturningWelcomeContent(
                wordmarkOpacity: $wordmarkOpacity,
                wordmarkScale: $wordmarkScale,
                onComplete: onCinematicComplete
            )
            .transition(.opacity)
        }
    }

    // MARK: - Wordmark (driven by CinematicContent during cinematic)

    @State private var wordmarkOpacity: Double = 0.0
    @State private var wordmarkScale: CGFloat = 0.85

    private var wordmark: some View {
        VStack(spacing: 0) {
            Image("KloLogoVector")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.white)
                .scaledToFit()
                .frame(maxHeight: wordmarkHeight)
                .scaleEffect(wordmarkScale)
                .opacity(wordmarkOpacity)
                .shadow(color: .white.opacity(0.18), radius: 40)
                .modifier(KloFireGlow(active: true, radius: wordmarkGlowRadius))
                .padding(.top, wordmarkTopPadding)
            Spacer(minLength: 0)
        }
    }

    private var wordmarkHeight: CGFloat {
        switch coordinator.phase {
        case .cinematic:        return screen.height * 0.16
        case .demoTour:         return 32
        case .onboarding:       return 28
        case .returningWelcome: return screen.height * 0.10
        }
    }

    private var wordmarkGlowRadius: CGFloat {
        switch coordinator.phase {
        case .cinematic:        return 60
        case .demoTour:         return 26
        case .onboarding:       return 18
        case .returningWelcome: return 44
        }
    }

    private var wordmarkTopPadding: CGFloat {
        switch coordinator.phase {
        case .cinematic:        return screen.height * 0.32
        case .demoTour:         return max(notchGeometry.height + 28, 52)
        case .onboarding:       return max(notchGeometry.height + 22, 44)
        case .returningWelcome: return screen.height * 0.30
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// CloudCloseButton — top-right circular close affordance. macOS-style
// (sized like a system close, but custom-painted to match klo brand).
// ⌘W shortcut wired so the keyboard-savvy user can quit instantly.
// ─────────────────────────────────────────────────────────────────────

struct CloudCloseButton: View {
    let onClose: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button {
            onClose()
        } label: {
            ZStack {
                Circle()
                    .fill(KloColors.bgSoft.opacity(hovered ? 1.0 : 0.92))
                    .overlay(
                        Circle()
                            .strokeBorder(KloColors.border, lineWidth: 0.5)
                    )
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KloColors.fg)
            }
            .frame(width: 36, height: 36)
            .scaleEffect(hovered ? 1.08 : 1.0)
            .shadow(color: .black.opacity(0.35), radius: hovered ? 14 : 10, y: 4)
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("w", modifiers: [.command])
        .onHover { hovered = $0 }
        .help("Close klo (⌘W or ⌘Q)")
    }
}
