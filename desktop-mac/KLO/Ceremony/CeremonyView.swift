import SwiftUI
import AppKit

/// Cinematic CONTENT body. Renders headline + sub-line on top of the
/// host's persistent backdrop / notch / wordmark layers, drives the
/// timeline that fades them in and out, and signals onComplete when
/// the audio resolves.
///
/// IMPORTANT: this view does NOT render the cloud backdrop, the notch
/// silhouette, or the wordmark — those live in `CeremonyHostView` so
/// they survive the cinematic→onboarding crossfade with their SwiftUI
/// state intact (no remount, no flicker). This view animates the
/// host's wordmark via `@Binding`s the host owns.
///
/// Cinematic timeline:
///   0.0 – 0.4    cloud + notch fade in (host already at full opacity;
///                this beat is a placeholder for audio sync)
///   0.4 – 2.0    wordmark scales + fades in (driven via host bindings)
///   2.0 – 4.0    hold
///   4.0 – 5.0    headline fades in
///   5.0 – 6.0    sub-line fades in
///   6.0 – 9.0    hold the full composition
///   9.0 – 10.5   hold (sound resolves)
///  10.5 – 11.5   headline + sub fade out (wordmark stays).
///                onComplete fires → coordinator transitions to onboarding.
struct CinematicContent: View {
    let notchGeometry: NotchGeometry
    @Binding var wordmarkOpacity: Double
    @Binding var wordmarkScale: CGFloat
    let onComplete: () -> Void

    enum Phase: Int {
        case opening, entering, holdWordmark, headlineIn, subIn,
             holdFull, holdResolve, dissolving, done
    }

    @State private var phase: Phase = .opening
    @State private var headlineOpacity: Double = 0.0
    @State private var subOpacity: Double = 0.0
    @State private var centerDarkenOpacity: Double = 0.0

    var body: some View {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)

        return ZStack(alignment: .top) {
            // Center darkening — opposite of the previous orange halo.
            // Drops the wordmark onto a deeper black so it reads as a
            // bold mark in a quiet space; the only orange in frame is
            // the notch silhouette's fire-glow above.
            RadialGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.40),
                startRadius: 0,
                endRadius: min(screen.width, screen.height) * 0.42
            )
            .opacity(centerDarkenOpacity)
            .ignoresSafeArea()

            // Headline + sub. Tight composition, anchored just below
            // where the wordmark sits in the host (host paints it at
            // ~32% from the top during cinematic).
            VStack(spacing: 0) {
                // Reserve vertical space matching where the host's
                // wordmark renders — this keeps the headline
                // visually below the wordmark instead of overlapping.
                Spacer().frame(height: screen.height * 0.32 + screen.height * 0.16 + 22)

                Text("Tell it what to do.")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))
                    .tracking(-0.5)
                    .opacity(headlineOpacity)

                Spacer().frame(height: 8)

                Text("klo does the rest.")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .opacity(subOpacity)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .onAppear { runTimeline() }
    }

    // MARK: - Timeline

    private func runTimeline() {
        // Sound starts immediately so audio + visual are simultaneous.
        CeremonyAudio.shared.play(named: "launch-ceremony", ext: "mp3", volume: 0.8)

        Task { @MainActor in
            // Beat: opening (0–0.4s). Host backdrop is already at full
            // opacity — this is the audio-sync hold beat.
            phase = .opening
            try? await Task.sleep(nanoseconds: 400_000_000)

            // Beat: entering (0.4–2.0s). Wordmark blooms in (host owns
            // the wordmark; we drive its opacity + scale via @Binding).
            // Subtle haptic at the bloom so the user feels the moment.
            HapticEngine.tap(.alignment)
            withAnimation(.easeOut(duration: 1.5)) {
                wordmarkOpacity = 1.0
                wordmarkScale = 1.0
                centerDarkenOpacity = 1.0
            }
            phase = .entering
            try? await Task.sleep(nanoseconds: 1_600_000_000)

            // Beat: holdWordmark (2.0–4.0s).
            phase = .holdWordmark
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Beat: headlineIn (4.0–5.0s).
            HapticEngine.tap(.alignment)
            withAnimation(.easeOut(duration: 0.7)) { headlineOpacity = 1.0 }
            phase = .headlineIn
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Beat: subIn (5.0–6.0s).
            withAnimation(.easeOut(duration: 0.7)) { subOpacity = 1.0 }
            phase = .subIn
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Beat: holdFull (6.0–9.0s).
            phase = .holdFull
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // Beat: holdResolve (9.0–10.5s). Final beat for sound.
            phase = .holdResolve
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            // Beat: dissolving (10.5–11.5s). Headline + sub fade out.
            // The host wordmark stays — coordinator will swap to
            // onboarding while it remains visible.
            withAnimation(.easeIn(duration: 1.0)) {
                headlineOpacity = 0.0
                subOpacity = 0.0
                centerDarkenOpacity = 0.6
            }
            phase = .dissolving
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            phase = .done
            onComplete()
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// Notch silhouette layer — renders the hardware notch shape at the
// top of the screen, filled black (matching the actual notch colour),
// surrounded by a pulsing orange fire-glow. Persistent through the
// entire cloud experience (cinematic + onboarding).
// ─────────────────────────────────────────────────────────────────────

struct NotchSilhouette: View {
    let geometry: NotchGeometry
    /// Halo radius for the breathing KloFireGlow. Defaults to the
    /// cinematic value (24) so existing call sites keep their look;
    /// the dormant-notch overlay in KLOOverlayView passes a much
    /// smaller value so the at-rest pulse reads tight + crisp instead
    /// of dominating the menu bar.
    var glowRadius: CGFloat = 24

    var body: some View {
        let topCornerRadius: CGFloat = 6
        let bottomCornerRadius: CGFloat = 14
        let shapeWidth = geometry.width + topCornerRadius * 2

        NotchShape(topCornerRadius: topCornerRadius,
                   bottomCornerRadius: bottomCornerRadius)
            .fill(KloColors.ink)
            .frame(width: shapeWidth, height: geometry.height)
            .modifier(KloFireGlow(active: true, radius: glowRadius))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}


// ─────────────────────────────────────────────────────────────────────
// ReturningWelcomeContent — brief "Welcome back." flourish for the
// relaunch flow. Shares the host's persistent backdrop / notch /
// wordmark layers; this view just animates the wordmark in, holds, and
// fades out — total ~2.4s. onComplete fires when the fade ends, the
// controller dismisses the cloud, and the rest of the app boots into
// the notch panel with its intro pulse.
// ─────────────────────────────────────────────────────────────────────

struct ReturningWelcomeContent: View {
    @Binding var wordmarkOpacity: Double
    @Binding var wordmarkScale: CGFloat
    let onComplete: () -> Void

    @State private var headlineOpacity: Double = 0.0
    @State private var subOpacity: Double = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 8)

            VStack(spacing: 12) {
                Text("Welcome back.")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))
                    .tracking(-0.5)
                    .opacity(headlineOpacity)

                Text("Press ⌘K from any app.")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .opacity(subOpacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, NSScreen.main.map { $0.frame.height * 0.46 } ?? 380)
        }
        .ignoresSafeArea()
        .onAppear { runTimeline() }
    }

    private func runTimeline() {
        // 0.0 → 0.6   wordmark + headline + sub fade in (concurrent)
        // 0.6 → 1.8   hold
        // 1.8 → 2.4   everything fades out together
        // 2.4         onComplete → controller dismisses the cloud

        withAnimation(.easeOut(duration: 0.6)) {
            wordmarkOpacity = 1.0
            wordmarkScale = 1.0
            headlineOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.6)) {
                subOpacity = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.6)) {
                wordmarkOpacity = 0
                headlineOpacity = 0
                subOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            onComplete()
        }
    }
}


// ─────────────────────────────────────────────────────────────────────
// CeremonyBackdrop — the atmospheric cloud.
//
// Previous iteration was rectangular: NSVisualEffectView (uniform blur
// across the whole panel) + uniform black wash + dark-edge vignette.
// Net read: "a window with blurry edges, flat dark middle." User
// feedback: "doesn't feel like a cloud at all."
//
// New composition: a concentrated cloud body in the middle of the
// screen, fully transparent at the corners. The desktop is visible
// all around the cloud — it has no rectangular boundary.
//
//   1. SOFT CLOUD BODY: large radial gradient, opaque at center
//      (#000 @ 0.55) → fully transparent at the edges. This is the
//      cloud's main mass.
//   2. DRIFT LAYER: smaller offset radial for organic asymmetry, so
//      the cloud doesn't read as a perfect sphere.
//   3. HIGHLIGHT: faint white radial at upper-right where light
//      "catches" the top of the cloud.
//   4. MASKED VIBRANCY: NSVisualEffectView for the desktop blur,
//      masked by the same radial shape — blur is concentrated where
//      the cloud is most opaque, screen edges show the unmodified
//      desktop.
// ─────────────────────────────────────────────────────────────────────

struct CeremonyBackdrop: View {
    var body: some View {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let bodyRadius = max(screen.width, screen.height) * 0.78

        ZStack {
            // (Vibrancy/blur layer removed — it produced a grey halo
            // around the dark cloud body that read as a separate
            // surrounding cloud. Now the dark gradient sits directly
            // on the user's desktop wallpaper with no frosty ring.)

            // 1. Soft cloud body. Deeper black at center; corners
            //    stay transparent so desktop wallpaper shows through
            //    the screen edges (no rectangular boundary). Deeper +
            //    tighter than v1 — the user wanted a more concentrated,
            //    more black core.
            RadialGradient(
                colors: [
                    Color.black.opacity(0.92),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.25),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: bodyRadius
            )

            // 2. Drift layer — offset to lower-left for organic
            //    asymmetry. Slightly stronger so the deeper cloud
            //    body still reads asymmetric.
            RadialGradient(
                colors: [
                    Color.black.opacity(0.32),
                    Color.clear
                ],
                center: UnitPoint(x: 0.32, y: 0.72),
                startRadius: 40,
                endRadius: bodyRadius * 0.55
            )

            // 3. Highlight — subtle warm catch on the upper-right of
            //    the cloud.
            RadialGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.clear
                ],
                center: UnitPoint(x: 0.62, y: 0.32),
                startRadius: 0,
                endRadius: bodyRadius * 0.45
            )
            .blendMode(.plusLighter)
        }
    }
}

