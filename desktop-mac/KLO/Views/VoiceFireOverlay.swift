import SwiftUI

// Fire-themed voice-mode overlay. Every visible element is a radial
// gradient sized so it fades to clear well INSIDE its frame's bounds.
// The composite is then masked by a radial gradient sized to the
// frame's HEIGHT (not max(w,h)), so the dissolve completes before any
// rectangular edge can show through.
struct VoiceFireOverlay: View {
    @State private var pulse: Bool = false
    @State private var sway: Bool = false
    @State private var coreFlash: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                // 1. Soft base glow — radial centered at top, fading to
                //    clear at radius = h * 0.9. The 0.9 multiplier keeps
                //    the fade inside the frame's vertical bounds, never
                //    touching the rectangular sides.
                // Olive ramp — opacities + radii unchanged from the
                // orange version so the flame's silhouette + animation
                // read identical; only the hue family swapped.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: KloColors.oliveLo.opacity(0.55), location: 0.00),
                        .init(color: KloColors.olive.opacity(0.30), location: 0.35),
                        .init(color: KloColors.oliveHi.opacity(0.10), location: 0.70),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.9
                )
                .blur(radius: 22)

                // 2. Center body — breathing flame, fades to clear at
                //    radius = h * 0.65 so it never reaches the sides.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: KloColors.oliveLo.opacity(0.65), location: 0.00),
                        .init(color: KloColors.olive.opacity(0.30), location: 0.45),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.65
                )
                .scaleEffect(x: pulse ? 1.05 : 0.96, y: pulse ? 1.22 : 0.92, anchor: .top)
                .blur(radius: 22)

                // 3. Hot core — small bright blob
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: KloColors.oliveHi.opacity(0.85), location: 0.00),
                        .init(color: KloColors.olive.opacity(0.40), location: 0.45),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.40
                )
                .opacity(coreFlash ? 0.95 : 0.55)
                .scaleEffect(x: 1.0, y: coreFlash ? 1.18 : 0.85, anchor: .top)
                .blur(radius: 26)

                // 4. Three drifting flame plumes positioned around the
                //    centerline. Each plume's gradient fades to clear at
                //    radius < its own frame, so no plume-frame edge shows.
                FlamePlume(hueShift: -0.05, height: h)
                    .position(x: w * 0.36, y: 0)
                    .scaleEffect(x: 1.0, y: pulse ? 1.20 : 0.90, anchor: .top)
                    .offset(x: sway ? 16 : -10)

                FlamePlume(hueShift: 0.0, height: h)
                    .position(x: w * 0.5, y: 0)
                    .scaleEffect(x: 1.0, y: sway ? 1.15 : 0.92, anchor: .top)

                FlamePlume(hueShift: 0.05, height: h)
                    .position(x: w * 0.64, y: 0)
                    .scaleEffect(x: 1.0, y: pulse ? 0.95 : 1.18, anchor: .top)
                    .offset(x: sway ? -14 : 12)

                // 5. Embers — drifting upward
                ForEach(0..<14, id: \.self) { i in
                    Ember(
                        startX: w * (0.20 + Double(i) * 0.045),
                        bottomY: h * 0.78,
                        topY: h * 0.10,
                        size: 3 + CGFloat(i % 3) * 1.4,
                        duration: 2.6 + Double(i % 4) * 0.4,
                        delay: Double(i) * 0.18
                    )
                }
            }
            .compositingGroup()
            // Composite mask uses the FRAME HEIGHT (not max(w,h)) so
            // the radial fade completes within the visible vertical
            // band — no rectangular cutoff possible.
            .mask(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white, location: 0.00),
                        .init(color: .white, location: 0.55),
                        .init(color: Color.white.opacity(0.55), location: 0.78),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.95
                )
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    sway = true
                }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    coreFlash = true
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Single flame plume — radial gradient sized so its fade-to-clear
/// completes well before the frame's rectangular edges. Frame is
/// generous (480×360) and gradient endRadius is ~150pt, so the visible
/// plume is a soft ellipse with no rectangular boundary.
private struct FlamePlume: View {
    let hueShift: Double
    let height: CGFloat

    var body: some View {
        // hueShift used to bias the orange ramp; with olive we
        // translate it into alpha jitter so each plume reads as a
        // slightly dimmer or brighter olive. The animation timing
        // logic in the parent stays identical.
        let alphaJitter = max(0.40, min(0.70, 0.55 + hueShift))
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: KloColors.olive.opacity(alphaJitter), location: 0.00),
                .init(color: KloColors.oliveHi.opacity(alphaJitter * 0.45), location: 0.55),
                .init(color: .clear, location: 1.00)
            ]),
            center: UnitPoint(x: 0.5, y: 0.0),
            startRadius: 0,
            // endRadius scales with the parent height so plumes shrink
            // proportionally if the overlay frame changes.
            endRadius: height * 0.55
        )
        // Frame far larger than the gradient so corner-to-corner distance
        // exceeds the gradient's reach — no plume-frame edge ever visible.
        .frame(width: height * 1.6, height: height * 1.2)
        .blur(radius: 18)
    }
}

/// Single rising ember — pure Circle, intrinsically organic.
private struct Ember: View {
    let startX: CGFloat
    let bottomY: CGFloat
    let topY: CGFloat
    let size: CGFloat
    let duration: Double
    let delay: Double

    @State private var rising: Bool = false

    var body: some View {
        Circle()
            .fill(KloColors.oliveHi)
            .frame(width: size, height: size)
            .shadow(color: KloColors.olive.opacity(0.7), radius: 4)
            .blur(radius: 0.5)
            .position(
                x: startX + (rising ? CGFloat.random(in: -22...22) : 0),
                y: rising ? topY : bottomY
            )
            .opacity(rising ? 0 : 0.9)
            .onAppear {
                withAnimation(
                    .easeOut(duration: duration)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    rising = true
                }
            }
    }
}
