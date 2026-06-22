import SwiftUI

/// Tag chip — small rounded pill with a tracked all-caps label. The
/// design vocabulary borrowed from Open iOS where every meditation
/// belongs to one of three semantic classes (REST / BALANCE / ENERGY)
/// and gets a colored chip showing that class. For klo we map the
/// same three colors to tool classes so the user can read the agent's
/// current activity at a glance without parsing words.
///
///   .olive  → reading / thinking / observational (AX walks, shell
///             reads, screenshot, label_coverage check)
///   .copper → acting / mutating (clicks, typing, key presses, the
///             agent is doing something to the system)
///   .teal   → waiting / paused / resting (between turns, awaiting
///             user confirm, polling)
///
/// At 22pt height with a 90% opacity fill and white 10pt label, the
/// chip reads as a quiet "this is what's happening" rather than a
/// shouty notification.
struct KloTagChip: View {
    enum Tone {
        case olive
        case copper
        case teal

        var fill: Color {
            switch self {
            case .olive:  return KloColors.olive
            case .copper: return KloColors.copper
            case .teal:   return KloColors.teal
            }
        }
    }

    let label: String
    let tone: Tone

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .default))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.fill.opacity(0.88))
            )
    }
}
