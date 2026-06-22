import SwiftUI

/// The wisp itself — a glowing olive orb with a soft halo and a faint
/// ember trail. Lives inside `WispOverlayWindowController`'s borderless
/// click-through NSPanel. Reads everything from `WispPresenter.shared`.
///
/// Visual vocabulary borrowed from Open iOS's breath-orb screen: a
/// big soft radial gradient that feels alive rather than alarming.
/// Red is reserved for the `.stuck` phase only — when klo's wedged and
/// the user needs to actually look. The Mac-app instance of the wisp
/// stays under ~80pt so it never blocks comprehension of the underlying
/// app.
struct WispView: View {
    @ObservedObject var presenter: WispPresenter

    // Local visual state for animations that don't read directly from
    // the presenter's @Published values.
    @State private var breath: CGFloat = 1.0
    @State private var pulse: CGFloat = 1.0
    @State private var trembleX: CGFloat = 0
    @State private var trembleY: CGFloat = 0
    @State private var lastPulseAt: Date = .distantPast

    /// Static color tokens. Olive borrowed from KloColors but inlined
    /// here so the wisp's color story stays self-contained — easy to
    /// tune the orb without reverberating into every other usage of
    /// the brand palette.
    private let oliveCore = Color(red: 0.659, green: 0.757, blue: 0.322)   // #A8C152
    private let oliveWarm = Color(red: 0.745, green: 0.835, blue: 0.443)   // brighter top
    private let redHot    = Color(red: 1.00, green: 0.36, blue: 0.18)      // stuck only

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Far halo — ambient glow that gives the orb presence on
                // any background. Larger + softer than the previous design
                // so it reads as "this surface is alive" rather than
                // "look at this dot". Mirrors Open's breath-orb falloff.
                Circle()
                    .fill(haloColor.opacity(0.22))
                    .frame(width: 96, height: 96)
                    .blur(radius: 22)

                // Outer halo — the main glow body.
                Circle()
                    .fill(haloColor.opacity(0.38))
                    .frame(width: 56, height: 56)
                    .blur(radius: 14)

                // Mid halo — slightly tighter glow.
                Circle()
                    .fill(haloColor.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .blur(radius: 6)

                // Core orb — bright, small.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [coreColor, coreColor.opacity(0.0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 9
                        )
                    )
                    .frame(width: 18, height: 18)
            }
            .frame(width: 100, height: 76)
            .scaleEffect(breath * pulse)

            // Verb floats under the orb — only when there's something
            // meaningful to say. Animates in/out so the label appears
            // and dissolves with the wisp's motion. Small black pill
            // with all-caps tracked typography — mirrors Open's caps
            // meta vocabulary so the wisp reads as quietly informative
            // rather than chatty.
            if let lbl = presenter.label, !lbl.isEmpty {
                Text(lbl)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.72))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: 160, height: 100)
        .offset(x: trembleX, y: trembleY)
        // Position the wisp at klo's last action (or notch home before
        // the first action). SwiftUI's spring traces the arc for free.
        .position(presenter.location ?? presenter.notchHome)
        .animation(
            .spring(response: 0.45, dampingFraction: 0.7),
            value: presenter.location
        )
        .onAppear { startBreathing() }
        .onChange(of: presenter.pulseTrigger) { _ in firePulse() }
        .onChange(of: presenter.phase) { newPhase in handlePhase(newPhase) }
        .allowsHitTesting(false)
    }

    private var coreColor: Color {
        switch presenter.phase {
        case .stuck:    return redHot
        default:        return oliveWarm
        }
    }
    private var haloColor: Color {
        switch presenter.phase {
        case .stuck:    return redHot
        default:        return oliveCore
        }
    }

    private func startBreathing() {
        // Slow heartbeat — only shows when idle / thinking. Pulse and
        // tremble multiplicatively combine via scaleEffect.
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            breath = 1.08
        }
    }

    private func firePulse() {
        // One-shot scale punch when an action fires. 0 → 1.5 → 1.0 in
        // ~220ms. The state machine restores `pulse = 1` so subsequent
        // breath continues to scale around 1.
        lastPulseAt = presenter.pulseTrigger
        withAnimation(.spring(response: 0.12, dampingFraction: 0.5)) {
            pulse = 1.55
        }
        // Decay back. Slight delay so the spring crest is visible.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                pulse = 1.0
            }
        }
    }

    private func handlePhase(_ phase: WispPresenter.Phase) {
        if phase == .stuck {
            startTremble()
        } else {
            stopTremble()
        }
    }

    private func startTremble() {
        withAnimation(.easeInOut(duration: 0.08).repeatForever(autoreverses: true)) {
            trembleX = 1.5
            trembleY = -1.0
        }
    }

    private func stopTremble() {
        withAnimation(.easeOut(duration: 0.15)) {
            trembleX = 0
            trembleY = 0
        }
    }
}

/// Wrapper used as the SwiftUI content of WispOverlayWindowController.
/// Fills the entire window so `.position(...)` inside WispView resolves
/// against full-screen coords. The wrapper itself is transparent and
/// non-hit-testing so clicks fall through to whatever's below.
struct WispHostView: View {
    @ObservedObject var presenter: WispPresenter

    var body: some View {
        ZStack {
            Color.clear
            if presenter.isActive {
                WispView(presenter: presenter)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: presenter.isActive)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
