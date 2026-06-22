import SwiftUI

/// Compact fire — TOP-anchored so flames originate at the top of the
/// frame and fall downward (looks like fire spilling out of the notch).
/// All radii scale with the frame's height so the same view works at
/// any size: tiny inside the notch silhouette, generous as an overflow
/// layer that escapes the silhouette.
struct MiniFireView: View {
    @State private var pulse: Bool = false
    @State private var sway: Bool = false
    @State private var coreFlash: Bool = false

    /// Optional tap-to-stop callback. When non-nil, a small central
    /// hotspot (160pt circle anchored at the visual center of the
    /// flame) is hit-test eligible — tapping it invokes `onStop`. The
    /// outer plumes / embers stay `allowsHitTesting(false)` so users
    /// can't dismiss the panel by stray clicks on the visual fringe.
    /// Used by voice mode to give users a clear way to interrupt klo
    /// without reaching for ⌘⇧K.
    var onStop: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                // Base warm glow — anchored at TOP, falls downward.
                // Hue family swapped from orange ramp to olive ramp;
                // opacities + radii unchanged so the fire's silhouette
                // and animation read identical, just glowing green.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: KloColors.oliveLo.opacity(0.55), location: 0.00),
                        .init(color: KloColors.olive.opacity(0.30), location: 0.40),
                        .init(color: KloColors.oliveHi.opacity(0.10), location: 0.75),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 1.0
                )
                .blur(radius: 8)

                // Body — breathing flame, falls down.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: KloColors.oliveLo.opacity(0.65), location: 0.00),
                        .init(color: KloColors.olive.opacity(0.30), location: 0.50),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.85
                )
                .scaleEffect(x: pulse ? 1.10 : 0.90, y: pulse ? 1.18 : 0.85, anchor: .top)
                .blur(radius: 8)

                // Hot core — flickering bright blob at top.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: KloColors.oliveHi.opacity(0.85), location: 0.00),
                        .init(color: KloColors.olive.opacity(0.40), location: 0.50),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: h * 0.55
                )
                .opacity(coreFlash ? 0.95 : 0.55)
                .scaleEffect(x: 1.0, y: coreFlash ? 1.18 : 0.85, anchor: .top)
                .blur(radius: 10)

                // Three drifting plumes — emerge from top, drift down.
                MiniFlamePlume(hueShift: -0.05, height: h)
                    .position(x: w * 0.36, y: 0)
                    .scaleEffect(x: 1.0, y: pulse ? 1.18 : 0.92, anchor: .top)
                    .offset(x: sway ? 8 : -6)

                MiniFlamePlume(hueShift: 0.0, height: h)
                    .position(x: w * 0.5, y: 0)
                    .scaleEffect(x: 1.0, y: sway ? 1.12 : 0.95, anchor: .top)

                MiniFlamePlume(hueShift: 0.05, height: h)
                    .position(x: w * 0.64, y: 0)
                    .scaleEffect(x: 1.0, y: pulse ? 0.95 : 1.18, anchor: .top)
                    .offset(x: sway ? -7 : 7)

                // Embers — start at top, fall downward and fade.
                ForEach(0..<8, id: \.self) { i in
                    MiniEmber(
                        startX: w * (0.25 + Double(i) * 0.07),
                        topY: h * 0.10,
                        bottomY: h * 0.85,
                        size: 1.5 + CGFloat(i % 3) * 0.7,
                        duration: 1.6 + Double(i % 4) * 0.35,
                        delay: Double(i) * 0.16
                    )
                }

                // Tap-to-stop hotspot — 160pt invisible circle at the
                // flame's center. Per reviewer guidance, we DO NOT make
                // the whole fire view tap-eligible: it's a 940×440
                // frame, way too easy to dismiss accidentally while
                // reaching for menu bar / other panel chrome. Restrict
                // tap to a small central region.
                if let onStop {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 160, height: 160)
                        .contentShape(Circle())
                        .position(x: w * 0.5, y: h * 0.32)
                        .onTapGesture {
                            onStop()
                        }
                        .help("Tap to stop voice mode")
                }
            }
            .compositingGroup()
            // Composite mask anchored at top so dissolve completes
            // within the frame's vertical band.
            .mask(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white, location: 0.00),
                        .init(color: .white, location: 0.55),
                        .init(color: Color.white.opacity(0.50), location: 0.80),
                        .init(color: .clear, location: 1.00)
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: max(w, h) * 0.95
                )
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    sway = true
                }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    coreFlash = true
                }
            }
        }
        // Hit testing on iff a tap-stop callback is wired. Without a
        // callback, the fire is purely visual (e.g. ambient overlay)
        // and must NOT intercept clicks meant for the menu bar or
        // other panel chrome. With a callback, the inner 160pt
        // hotspot becomes tap-eligible; the rest is still inert
        // because only the Circle has a real fill / contentShape.
        .allowsHitTesting(onStop != nil)
    }
}

private struct MiniFlamePlume: View {
    let hueShift: Double
    let height: CGFloat

    var body: some View {
        // hueShift used to bias the orange ramp (red 0.85→1.0,
        // green 0.30→0.55). With the olive ramp we don't need
        // per-plume hue jitter — each plume reads as a slightly
        // dimmer or brighter olive based on the existing opacity
        // variance. Keep the parameter on the call site so the
        // animation timing logic stays identical.
        let alphaJitter = max(0.40, min(0.70, 0.55 + hueShift))
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: KloColors.olive.opacity(alphaJitter), location: 0.00),
                .init(color: KloColors.oliveHi.opacity(alphaJitter * 0.45), location: 0.55),
                .init(color: .clear, location: 1.00)
            ]),
            center: UnitPoint(x: 0.5, y: 0.0),
            startRadius: 0,
            endRadius: height * 0.7
        )
        .frame(width: height * 1.4, height: height * 1.2)
        .blur(radius: 8)
    }
}

private struct MiniEmber: View {
    let startX: CGFloat
    let topY: CGFloat
    let bottomY: CGFloat
    let size: CGFloat
    let duration: Double
    let delay: Double

    @State private var falling: Bool = false

    var body: some View {
        Circle()
            .fill(KloColors.oliveHi)
            .frame(width: size, height: size)
            .shadow(color: KloColors.olive.opacity(0.7), radius: 3)
            .blur(radius: 0.4)
            .position(
                x: startX + (falling ? CGFloat.random(in: -10...10) : 0),
                y: falling ? bottomY : topY
            )
            .opacity(falling ? 0 : 0.85)
            .onAppear {
                withAnimation(
                    .easeIn(duration: duration)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    falling = true
                }
            }
    }
}
