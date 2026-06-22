import SwiftUI

/// "klo is doing something" surface. Two things, nothing else:
///
///   1. A small, more-transparent green fire — 60% smaller than the
///      voice-mode fire (the user's exact spec). Visually reads as an
///      "upside-down, more transparent" version of the dormant notch
///      pulse: glow hangs downward from where the hardware notch sits.
///
///   2. Friendly activity bubbles fanning out horizontally below the
///      fire. Newest enters from the right with a spring; older bubbles
///      drift left and fade.
///
/// NO rectangle. NO border. NO cloud. NO chrome. The notch chrome
/// stack in KLOOverlayView.notchSilhouette skips the NotchShape mask +
/// black background + orange outline entirely for `.working` mode, so
/// this view renders directly against the desktop wallpaper.
///
/// Layout (720×280, top-anchored — no surrounding rectangle):
///
///         ════════[ notch hardware ]════════
///                       ╱╲                       ← 376×176 MiniFireView
///                     ╱    ╲                       (60% of voice fire)
///                   (  fire  )                     opacity ~0.55 — more
///                     ╲    ╱                       transparent than voice
///                       ╲╱
///
///       [⊙ on it]  [⊙ opening notes]  [⊙ writing down]   ✕
struct FireBubblesView: View {
    @ObservedObject var state: KLOState
    var onCancel: () -> Void

    /// klo 2.1.1: surface a PREVIEW badge next to the Cancel X when
    /// the in-flight run is a routine preview. Read from KLOState's
    /// preview marker set by ProactiveTextHost on tap. The badge
    /// disappears when the marker clears (completion / collapse).
    private var isPreview: Bool {
        state.pendingPreviewSuggestionId != nil
    }

    // Max visible at once. Older bubbles drift off the left.
    private let maxVisible: Int = 3
    private let bubbleSpacing: CGFloat = 10
    private let bubbleHoldSec: TimeInterval = 5.0

    // Dimensions — kept in sync with KLOOverlayView.surfaceDimensions.
    private let panelWidth: CGFloat = 720
    private let panelHeight: CGFloat = 220

    // Fire size — 60% of voice fire's 940×440 (per user spec:
    // "60% smaller version" → 40% of voice fire dimensions). Voice
    // fire fills the screen during real-time mode; this scaled-down
    // version hangs from the notch like an upside-down dormant pulse.
    private let fireWidth: CGFloat = 376
    private let fireHeight: CGFloat = 176

    // Distance from the panel TOP down to where bubbles should sit
    // — equals the hardware notch height (~32pt) + topOverlap (4pt)
    // + a small breathing gap, so bubbles land RIGHT under the notch
    // hardware bottom edge. The fire (176pt tall, pinned to top)
    // glows behind/around the bubbles since fire opacity is 0.55.
    private let bubblesTopOffset: CGFloat = 44

    var body: some View {
        ZStack(alignment: .top) {
            // 1. FIRE — hangs upside-down from the notch hardware,
            //    significantly more transparent than the voice fire so
            //    it reads as ambient activity, not a centerpiece. The
            //    user described this as "an upside-down, more
            //    transparent pulsing notch" — that's what MiniFireView
            //    gives us at this size with a low opacity.
            MiniFireView()
                .frame(width: fireWidth, height: fireHeight)
                .opacity(0.55)
                .allowsHitTesting(false)
                .scaleEffect(bubbleArrivalPulse ? 1.06 : 1.0, anchor: .top)
                .animation(.easeOut(duration: 0.35),
                           value: bubbleArrivalPulse)

            // 2. BUBBLES — horizontal row below the fire. Sit just
            //    inside the fire's bottom edge so they feel born from
            //    the flame.
            HStack(alignment: .center, spacing: bubbleSpacing) {
                ForEach(visibleBubbles) { bubble in
                    BubbleChip(text: bubble.text,
                               age: ageFraction(of: bubble))
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing)
                                    .combined(with: .opacity)
                                    .animation(.spring(response: 0.42,
                                                       dampingFraction: 0.78)),
                                removal: .opacity
                                    .combined(with: .move(edge: .leading))
                                    .animation(.easeOut(duration: 0.45))
                            )
                        )
                        .id(bubble.id)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, bubblesTopOffset)
            .padding(.horizontal, 24)
            // Bubbles are a status readout, not controls. Marking the row
            // non-interactive lets clicks over it fall through to the app
            // the user is working in (PassthroughHostingView relies on
            // SwiftUI reporting these regions as un-hit).
            .allowsHitTesting(false)

            // 3. PREVIEW BADGE + CANCEL — top-right corner. The badge
            // only appears when the in-flight query starts with
            // "Preview: " (the marker the routine-suggestion tap path
            // sets in ProactiveTextHost). Olive PREVIEW chip makes it
            // unambiguous this is a one-shot preview, not a regular run.
            HStack(spacing: 6) {
                Spacer()
                if isPreview {
                    Text("PREVIEW")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(KloColors.olive)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(KloColors.olive.opacity(0.12))
                                .overlay(
                                    Capsule().strokeBorder(
                                        KloColors.olive.opacity(0.3),
                                        lineWidth: 0.5,
                                    ),
                                )
                        )
                }
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(KloColors.fg45.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPreview ? "Cancel preview" : "Cancel")
                .padding(.trailing, 8)
                .padding(.top, 4)
            }
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .top)
        .background(
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Color.clear
            }
            .frame(width: 0, height: 0)
        )
        .onChange(of: state.activityBubbles.count) { _, _ in
            withAnimation { bubbleArrivalPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation { bubbleArrivalPulse = false }
            }
        }
    }

    @State private var bubbleArrivalPulse: Bool = false

    /// HStack renders left→right; state stores newest-first, so
    /// reverse the slice. Result: oldest on the left, newest on the
    /// right where the eye naturally lands after submitting.
    private var visibleBubbles: [ActivityBubble] {
        Array(state.activityBubbles.prefix(maxVisible)).reversed()
    }

    /// 0.0 = brand new, 1.0+ = past hold window. BubbleChip uses this
    /// to drive opacity decay so older bubbles dim out gracefully.
    private func ageFraction(of bubble: ActivityBubble) -> Double {
        let age = Date().timeIntervalSince(bubble.createdAt)
        return min(max(age / bubbleHoldSec, 0), 1.2)
    }
}


// MARK: - One bubble chip

/// One floating activity phrase. Minimal pill — just enough material
/// for text legibility against any desktop wallpaper. Olive dot +
/// soft glow tie the bubble's color to the fire above.
private struct BubbleChip: View {
    let text: String
    let age: Double

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KloColors.oliveHi)
                .frame(width: 5, height: 5)
                .shadow(color: KloColors.olive.opacity(0.7), radius: 4)
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(KloColors.fg.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(KloColors.olive.opacity(0.18),
                              lineWidth: 0.5)
        )
        .shadow(color: KloColors.olive.opacity(0.22), radius: 10, x: 0, y: 1)
        .opacity(opacityForAge)
    }

    private var opacityForAge: Double {
        if age < 0.4 { return 1.0 }
        if age < 0.9 { return 0.78 }
        return 0.50
    }
}
