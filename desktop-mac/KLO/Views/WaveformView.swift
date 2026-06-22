import SwiftUI

// 5 vertical bars driven by `audioLevel` (0..1). Bar heights animate
// smoothly between updates. Color: #2B7FFF.
//
// VoiceInputView feeds this from mic-level state or a lightweight
// speech-feel animation while capture is warming up.
struct WaveformView: View {
    let audioLevel: Double

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 4
    private let maxBarHeight: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: barGap) {
            ForEach(0..<barCount, id: \.self) { index in
                let phaseOffset = Double(index) / Double(barCount)
                let normalized = max(0.05, min(1.0, abs(sin((audioLevel + phaseOffset) * .pi))))
                Capsule()
                    // Olive matches the rest of the voice surface
                    // (mic indicator + progress dots are already olive).
                    // Orange was the legacy "active accent" — too loud
                    // for a constantly-animating waveform.
                    .fill(KloColors.olive)
                    .frame(width: barWidth, height: maxBarHeight * CGFloat(normalized))
                    .animation(.easeInOut(duration: 0.15), value: audioLevel)
            }
        }
        .frame(height: maxBarHeight)
    }
}
