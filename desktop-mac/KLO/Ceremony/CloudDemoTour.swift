import SwiftUI
import AppKit

/// Premium animated demo tour that plays AFTER the cinematic and
/// BEFORE the user is asked to grant permissions. Three scenes that
/// show the user what klo is and does, in calm, deliberate beats —
/// the user feels held instead of immediately hit with a configuration
/// ask.
///
/// Mental model: Apple keynote slide deck. Each scene auto-advances;
/// the user can press Continue / Return to advance early, or click
/// "skip intro" to jump straight to permissions.
///
/// Scenes:
///   1. Tell it. In English.             (~15s)
///   2. It does the rest.                (~10s)
///   3. Anywhere on your Mac.            (~9s)
///
/// (The "⌘K from any app" intro scene used to live here as Scene 1
/// but was deleted — the post-onboarding `FirstPromptIslandWindowController`
/// teaches the same thing at the moment it actually matters, so
/// covering it twice was noise.)
struct CloudDemoTour: View {

    @ObservedObject var coordinator: OnboardingFocusCoordinator

    @State private var sceneIndex: Int = 0

    /// Per-scene auto-advance duration. All scenes auto-advance now
    /// that the gated ⌘K scene is gone.
    private let sceneDurations: [TimeInterval] = [15.0, 10.0, 9.0]

    private static let sceneCount = 3

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scene content — switch on sceneIndex with crossfade.
            Group {
                switch sceneIndex {
                case 0: DemoSceneTwo()
                case 1: DemoSceneThree()
                default: DemoSceneFour()
                }
            }
            .id(sceneIndex)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom UI — pip indicator + skip + continue.
            bottomChrome
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.5), value: sceneIndex)
        .onAppear {
            // Start the ethereal ambient bed when the demo tour first
            // appears. Idempotent — playAmbient is a no-op if already
            // playing, so re-entries don't restart the loop.
            CeremonyAudio.shared.playAmbient(
                named: "onboarding-ambient",
                ext: "mp3",
                targetVolume: 0.42,
                fadeIn: 1.6
            )
        }
        .task(id: sceneIndex) {
            // Subtle haptic + swoosh at each scene boundary. Skipped on
            // sceneIndex 0 which fires on appear, not on a transition.
            if sceneIndex > 0 {
                HapticEngine.transition()
                CeremonyAudio.shared.playSceneSwoosh()
            }
            let duration = sceneIndex < sceneDurations.count
                ? sceneDurations[sceneIndex]
                : sceneDurations.last ?? 6.0
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            advance()
        }
    }

    // MARK: - Bottom chrome (pips + skip + continue)

    private var bottomChrome: some View {
        HStack(alignment: .center, spacing: 24) {
            skipLink

            Spacer(minLength: 0)

            sceneIndicator

            Spacer(minLength: 0)

            continueButton
        }
    }

    private var sceneIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.sceneCount, id: \.self) { i in
                Capsule()
                    .fill(i == sceneIndex ? KloColors.olive
                          : i < sceneIndex ? KloColors.olive.opacity(0.55)
                          : Color.white.opacity(0.18))
                    .frame(width: i == sceneIndex ? 22 : 10, height: 4)
                    .animation(.easeOut(duration: 0.3), value: sceneIndex)
            }
        }
    }

    private var skipLink: some View {
        Button {
            coordinator.transitionToOnboarding()
        } label: {
            Text("skip intro")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.45))
        }
        .buttonStyle(.plain)
        .frame(width: 140, alignment: .leading)
        .help("Skip the intro and go straight to permissions")
    }

    private var continueButton: some View {
        Button {
            HapticEngine.tap(.alignment)
            advance()
        } label: {
            HStack(spacing: 8) {
                Text(continueLabel)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(.kloPrimary)
        .frame(width: 200, alignment: .trailing)
        .keyboardShortcut(.return)
    }

    private var continueLabel: String {
        sceneIndex == Self.sceneCount - 1 ? "Get started" : "Continue"
    }

    private func advance() {
        if sceneIndex >= Self.sceneCount - 1 {
            coordinator.transitionToOnboarding()
        } else {
            sceneIndex += 1
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// Shared scene chrome — headline + sub block, sized for the cloud.
// ─────────────────────────────────────────────────────────────────────

private struct SceneCopy: View {
    let headline: String
    let sub: String

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.95))
                .tracking(-0.5)
                .multilineTextAlignment(.center)

            Text(sub)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


// ─────────────────────────────────────────────────────────────────────
// SceneFrame — vertical-centering wrapper used by all 4 scenes.
//
// Reserves enough top padding (140pt) to clear the host's wordmark
// (which renders at the top of the screen), and enough bottom padding
// (130pt) to clear the bottom chrome (skip / pips / continue). Inner
// spacers center scene content in the remaining area, so heroes don't
// stick to the top or bottom edges.
// ─────────────────────────────────────────────────────────────────────

private struct SceneFrame<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(.top, 140)
        .padding(.bottom, 130)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// (DemoSceneOne + DarkKeycap deleted — "Press ⌘K from any app" was
// redundant with the post-onboarding FirstPromptIslandWindowController,
// which teaches the same shortcut at the moment it actually matters.)


// ─────────────────────────────────────────────────────────────────────
// Scene — Tell it. In English.
// ─────────────────────────────────────────────────────────────────────

private struct DemoSceneTwo: View {

    private struct PromptStep {
        let prompt: String
        let resultIcon: String   // SF Symbol
        let resultText: String
    }

    /// Each step is a full prompt → working → result cycle.
    /// Tuned to read as "klo actually did the thing" instead of just
    /// "look, text appeared."
    private let steps: [PromptStep] = [
        PromptStep(
            prompt: "summarize this article.",
            resultIcon: "doc.text",
            resultText: "Article summarized in 4 points."
        ),
        PromptStep(
            prompt: "send Mike the latest revenue.",
            resultIcon: "paperplane.fill",
            resultText: "Email sent to Mike."
        ),
        PromptStep(
            prompt: "find me a flight to NYC tuesday.",
            resultIcon: "airplane",
            resultText: "3 flights found, opening Kayak."
        )
    ]

    @State private var stepIndex: Int = 0
    @State private var typedChars: Int = 0
    @State private var workingPulse: Bool = false
    @State private var showResult: Bool = false

    private var currentStep: PromptStep { steps[stepIndex] }
    private var typedString: String {
        String(currentStep.prompt.prefix(typedChars))
    }

    var body: some View {
        SceneFrame {
            VStack(spacing: 40) {
                SceneCopy(
                    headline: "Tell it. In English.",
                    sub: "No commands to learn. No menus to find."
                )

                VStack(spacing: 14) {
                    chatPanelMockup
                        .modifier(KloFireGlow(active: workingPulse, radius: 30))

                    // Result chip slides up from below the panel.
                    resultChip
                        .opacity(showResult ? 1.0 : 0.0)
                        .offset(y: showResult ? 0 : 12)
                        .animation(.easeOut(duration: 0.35), value: showResult)
                }
            }
        }
        .onAppear { runScene() }
    }

    private var chatPanelMockup: some View {
        let panelWidth: CGFloat = 580
        let panelHeight: CGFloat = 88

        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KloColors.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(KloColors.olive.opacity(0.35), lineWidth: 0.8)
                )

            HStack(spacing: 14) {
                // Left: tiny klo wordmark
                Image("KloLogoVector")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white.opacity(0.65))
                    .scaledToFit()
                    .frame(width: 28)

                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 1, height: 28)

                // Middle: live-typed prompt + caret. The text grows
                // character-by-character via typedChars binding.
                HStack(alignment: .center, spacing: 2) {
                    Text(typedString)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Caret()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
        }
        .frame(width: panelWidth, height: panelHeight)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
    }

    private var resultChip: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(KloColors.olive)
            Image(systemName: currentStep.resultIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(currentStep.resultText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(KloColors.ink.opacity(0.92))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(KloColors.olive.opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: KloColors.olive.opacity(0.18), radius: 16, y: 4)
    }

    /// Per-prompt cycle: type → pause → working glow → result chip
    /// → hold → fade → next. ~5s per step. Total ~15s for 3 steps.
    private func runScene() {
        Task { @MainActor in
            for i in 0..<steps.count {
                stepIndex = i
                typedChars = 0
                workingPulse = false
                showResult = false

                // Brief beat before typing starts (caret blinks).
                try? await Task.sleep(nanoseconds: 350_000_000)

                // Type each character. ~55ms per char feels deliberate
                // without dragging.
                let prompt = steps[i].prompt
                for c in 0..<prompt.count {
                    typedChars = c + 1
                    let perChar: UInt64 = c == 0 ? 120_000_000 : 55_000_000
                    try? await Task.sleep(nanoseconds: perChar)
                }

                // Pause after typing — like a person finishing a thought.
                try? await Task.sleep(nanoseconds: 380_000_000)

                // klo working — fire glow on the panel for ~1s.
                withAnimation(.easeInOut(duration: 0.35)) {
                    workingPulse = true
                }
                HapticEngine.tap(.alignment)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation(.easeInOut(duration: 0.35)) {
                    workingPulse = false
                }

                // Result chip — "✓ <result>" slides up.
                showResult = true
                HapticEngine.tap(.levelChange)
                try? await Task.sleep(nanoseconds: 1_400_000_000)

                // Fade everything out before the next step.
                withAnimation(.easeIn(duration: 0.35)) {
                    showResult = false
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}

/// Simple blinking caret using TimelineView so it doesn't depend on
/// any external state.
private struct Caret: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let visible = (t.truncatingRemainder(dividingBy: 1.0)) < 0.55
            Rectangle()
                .fill(KloColors.olive)
                .frame(width: 2, height: 22)
                .opacity(visible ? 1.0 : 0.0)
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// Scene 3 — It does the rest (action chips)
// ─────────────────────────────────────────────────────────────────────

private struct DemoSceneThree: View {
    @State private var visibleChipIndex: Int = -1
    @State private var burst: Bool = false

    private let chips: [(icon: String, label: String)] = [
        ("cursorarrow.click",       "click"),
        ("keyboard",                "type"),
        ("arrow.up.right.square",   "navigate")
    ]

    var body: some View {
        SceneFrame {
            VStack(spacing: 48) {
                SceneCopy(
                    headline: "It does the rest.",
                    sub: "Clicks, types, fills forms. Like you would, just faster."
                )

                ZStack {
                    // Optional fire-glow burst behind the chips.
                    Circle()
                        .fill(KloColors.olive.opacity(burst ? 0.18 : 0.0))
                        .frame(width: 280, height: 280)
                        .blur(radius: 50)
                        .animation(.easeOut(duration: 0.6), value: burst)

                    HStack(spacing: 18) {
                        ForEach(0..<chips.count, id: \.self) { i in
                            chip(icon: chips[i].icon, label: chips[i].label)
                                .opacity(visibleChipIndex >= i ? 1.0 : 0.0)
                                .scaleEffect(visibleChipIndex >= i ? 1.0 : 0.85)
                                .animation(.easeOut(duration: 0.4), value: visibleChipIndex)
                        }
                    }
                }
            }
        }
        .onAppear { runScene() }
    }

    private func chip(icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KloColors.olive)
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KloColors.ink)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func runScene() {
        // Chips appear sequentially, ~0.4s apart. Burst at 1.6s.
        for i in 0..<chips.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4 + 0.3) {
                visibleChipIndex = i
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            burst = true
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// Scene 4 — Anywhere on your Mac (orbiting app icons)
// ─────────────────────────────────────────────────────────────────────

private struct DemoSceneFour: View {
    private let appGlyphs: [String] = [
        "safari.fill",
        "envelope.fill",
        "note.text",
        "message.fill",
        "terminal.fill",
        "calendar",
        "globe"
    ]

    private let orbitRadius: CGFloat = 150
    private let tileSize: CGFloat = 52

    var body: some View {
        SceneFrame {
            VStack(spacing: 48) {
                SceneCopy(
                    headline: "Anywhere on your Mac.",
                    sub: "Native macOS. From Safari to Notes to your terminal."
                )

                // Hero: klo wordmark in the center, app glyphs orbiting.
                ZStack {
                    ForEach(0..<appGlyphs.count, id: \.self) { i in
                        appTile(systemName: appGlyphs[i])
                            .modifier(OrbitModifier(
                                index: i,
                                total: appGlyphs.count,
                                radius: orbitRadius,
                                cycle: 28.0  // seconds for full rotation
                            ))
                    }

                    Image("KloLogoVector")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(.white)
                        .scaledToFit()
                        .frame(width: 90)
                        .modifier(KloFireGlow(active: true, radius: 32))
                }
                .frame(width: 360, height: 360)
            }
        }
    }

    private func appTile(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KloColors.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: tileSize, height: tileSize)
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

/// Places a view at angular position `(2π * index / total) + (t / cycle * 2π)`
/// around a circle of given radius.
private struct OrbitModifier: ViewModifier {
    let index: Int
    let total: Int
    let radius: CGFloat
    let cycle: Double

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let baseAngle = (Double(index) / Double(total)) * 2 * .pi
            let timeAngle = (t.truncatingRemainder(dividingBy: cycle)) / cycle * 2 * .pi
            let angle = baseAngle + timeAngle
            let x = cos(angle) * Double(radius)
            let y = sin(angle) * Double(radius)
            content
                .offset(x: CGFloat(x), y: CGFloat(y))
        }
    }
}
