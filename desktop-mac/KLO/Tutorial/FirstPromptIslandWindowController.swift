import AppKit
import Combine
import SwiftUI

/// Full-screen dimmed cinematic surface shown ONCE after onboarding
/// completes. Teaches the two things the user can't figure out on
/// their own: how to summon klo (⌘K) and how to send their first
/// prompt.
///
/// Visual chassis matches the original cinematic + demo tour exactly:
/// dim radial backdrop, centered content, big headline + sub, white-
/// on-dark keycap hero with a soft glow. Lives at `.floating` level
/// with `ignoresMouseEvents = true` so the notch panel (at `.screenSaver`)
/// sits cleanly on top when the user presses ⌘K and the user can
/// type into it through the dim.
///
/// Two stages, driven by `KLOState.mode`:
///   - Stage A — `.idle`: "Press ⌘K from anywhere." with the keycap
///     hero glowing in the center.
///   - Stage B — `.textExpanded`: "Tell klo what to do." pointing up
///     at the notch input.
///
/// Auto-dismiss on first prompt submission (`mode` transitions out of
/// `.textExpanded` into a working/result state) OR a 60s safety
/// timeout in Stage B. Persistence: `klo.didShowFirstPromptDemo`
/// flag set on dismiss, so it only ever runs once per install.
@MainActor
final class FirstPromptIslandWindowController {

    static let shared = FirstPromptIslandWindowController()

    static let didShowKey = "klo.didShowFirstPromptDemo"

    private var panel: NSPanel?
    private let viewState = FirstPromptIslandState()
    private var cancellables: Set<AnyCancellable> = []
    private var dismissTimer: Timer?

    func showIfNeeded(state: KLOState, account: AccountManager) {
        guard panel == nil else { return }
        guard !UserDefaults.standard.bool(forKey: Self.didShowKey) else { return }
        // Removed the `account.isSignedIn` guard. The whole point of this
        // island is to teach the user "press ⌘K to summon klo" on first
        // run. Gating it behind sign-in meant a fresh install showed the
        // cinematic, dropped the user into the notch with no explanation,
        // and waited silently. There was no teaching moment because the
        // user hadn't signed in yet. The sign-in island fires lazily when
        // they actually press ⌘K and type a prompt, which is the right
        // time to ask for auth (they've now shown intent to use klo).
        _ = account

        viewState.stage = state.mode == .textExpanded ? .typePrompt : .pressHotkey

        let view = FirstPromptIslandView()
            .environmentObject(viewState)
        let host = NSHostingController(rootView: view)
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.preferredContentSize = frame.size

        let p = FirstPromptIslandPanel(contentRect: frame)
        p.contentViewController = host
        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        panel = p

        state.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self = self else { return }
                switch mode {
                case .idle:
                    self.viewState.stage = .pressHotkey
                    self.cancelDismissTimer()
                case .textExpanded:
                    if self.viewState.stage != .typePrompt {
                        self.viewState.stage = .typePrompt
                        self.scheduleSafetyDismiss(after: 60)
                    }
                default:
                    self.dismiss(persist: true)
                }
            }
            .store(in: &cancellables)
    }

    func dismiss(persist: Bool) {
        cancelDismissTimer()
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel = nil
        if persist {
            UserDefaults.standard.set(true, forKey: Self.didShowKey)
        }
    }

    private func scheduleSafetyDismiss(after seconds: TimeInterval) {
        cancelDismissTimer()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(persist: true) }
        }
    }

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
}


// ─────────────────────────────────────────────────────────────────────
// Stage state
// ─────────────────────────────────────────────────────────────────────

@MainActor
final class FirstPromptIslandState: ObservableObject {
    enum Stage: Equatable { case pressHotkey, typePrompt }
    @Published var stage: Stage = .pressHotkey
}


// ─────────────────────────────────────────────────────────────────────
// Panel — full-screen, click-through, sits BELOW the notch panel.
// ─────────────────────────────────────────────────────────────────────

final class FirstPromptIslandPanel: NSPanel {
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
        // `.floating` puts us above normal app windows but BELOW the
        // notch panel (which lives at `.screenSaver`). The user can
        // press ⌘K to summon the notch panel and type into it; the
        // notch sits clearly on top of our dim.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // CRITICAL: click-through. The user needs to be able to click
        // into Chrome / Finder / wherever to actually use klo — we're
        // purely informational. The dim is visual only.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// ─────────────────────────────────────────────────────────────────────
// SwiftUI body — matches the cinematic / demo tour style:
//   - Dim radial backdrop (like the cloud's CeremonyBackdrop but
//     scaled down).
//   - Centered content block (eyebrow → headline → sub → keycap hero
//     OR arrow).
//   - Cinematic typography (light weights, large sizes).
// ─────────────────────────────────────────────────────────────────────

struct FirstPromptIslandView: View {
    @EnvironmentObject var state: FirstPromptIslandState

    var body: some View {
        ZStack {
            // Dim backdrop — heavy enough that the cinematic content
            // reads clearly without competing with whatever's under it.
            // The user can still see their wallpaper / app outline
            // through the gradient, but the centered text + keycaps
            // have unambiguous contrast.
            RadialGradient(
                colors: [
                    Color.black.opacity(0.82),
                    Color.black.opacity(0.94)
                ],
                center: .center,
                startRadius: 200,
                endRadius: 900
            )
            .ignoresSafeArea()

            // Centered cinematic content
            Group {
                switch state.stage {
                case .pressHotkey: pressHotkeyScene
                case .typePrompt:  typePromptScene
                }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.35), value: state.stage)
        }
    }

    // MARK: - Stage A — Press ⌘K

    private var pressHotkeyScene: some View {
        VStack(spacing: 32) {
            eyebrow(text: "summon klo")

            Text("Press \u{2318}K from any app.")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text("klo lives in your notch. Hit the shortcut and it'll come down to meet you.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

            // Keycap hero — same chassis as the cinematic demo tour's
            // Scene 1. White-on-dark keycaps with a soft fire glow,
            // gently pulsing to read as "press me."
            HStack(spacing: 20) {
                CinematicKeycap(label: "\u{2318}")
                Text("+")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.30))
                CinematicKeycap(label: "K")
            }
            .kloFireGlow(active: true, radius: 40)
            .padding(.top, 8)
        }
    }

    // MARK: - Stage B — Type your first prompt

    private var typePromptScene: some View {
        // Curated example shown as a faded italic preview under the
        // headline. Same rotation source as the empty-input whisper
        // (IdleWhisperProvider.curatedRotation) so the brand voice is
        // consistent between the first-launch island and the everyday
        // input bar. Deterministic per-day rotation: a fresh-install
        // user sees one specific example, not a random pull each
        // re-appearance.
        let example = IdleWhisperProvider.firstPromptExample()
        return VStack(spacing: 32) {
            eyebrow(text: "your first prompt")

            Text("Tell klo what to do.")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            VStack(spacing: 14) {
                Text("Anything you'd ask a coworker. Hit Return when ready.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)

                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("try: \(example)")
                        .font(.system(size: 14, weight: .regular).italic())
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }

            // Subtle upward chevron pointing at the notch. The user
            // sees this AFTER they pressed ⌘K, so the notch panel is
            // already visible above — the chevron is a "look up there"
            // nudge, not a literal hero.
            Image(systemName: "chevron.up")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 4)
        }
    }

    // MARK: - Eyebrow

    private func eyebrow(text: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KloColors.olive)
                .frame(width: 6, height: 6)
                .kloFireGlow(active: true, radius: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(2.0)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.60))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}


// ─────────────────────────────────────────────────────────────────────
// CinematicKeycap — white-on-dark keycap matching the cinematic
// demo tour's `DarkKeycap` (which lived inside CloudDemoTour and was
// deleted along with DemoSceneOne). Same chassis: rounded square,
// semibold glyph, soft inner stroke, drop shadow.
// ─────────────────────────────────────────────────────────────────────

private struct CinematicKeycap: View {
    let label: String

    @State private var hint: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(KloColors.ink.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 12, y: 6)
            .scaleEffect(hint ? 1.04 : 1.0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                ) {
                    hint = true
                }
            }
    }
}
