import SwiftUI

/// Horizontal row of proactive pills that sits beneath the notch's
/// chat input — replaces the previous "cards above" treatment with
/// the same outline-capsule vocabulary the iOS app uses to push
/// connector starter prompts in chat (`the native prompt suggestions model`).
///
/// Pills are sorted so the most-context-aware ones lead: live signals
/// (calendar, screen) first, then connector starters ranked by
/// connected-first. Tap a pill → its prompt fills the input. Matches
/// iOS — never auto-submit, so the user can edit a starting line.
struct ProactivePillsRow: View {
    let signals: [ProactiveSignal]
    let onSelect: (ProactiveSignal) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(signals.enumerated()), id: \.element.id) { idx, signal in
                    ProactivePill(signal: signal) { onSelect(signal) }
                        // Stagger entrance so the row reads as a sweep
                        // rather than a single pop. 45ms between pills
                        // because pills are smaller than cards — the
                        // sweep wants to feel quicker.
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: 3))
                                    .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(Double(idx) * 0.045)),
                                removal: .opacity.animation(.easeOut(duration: 0.14)),
                            ),
                        )
                }
            }
            .padding(.horizontal, 22)
        }
        // Faded edge mask hints at horizontal-scrollability without an
        // obvious indicator. Same trick the iOS PromptSuggestions row
        // uses, and the same trick Open uses on its category strips.
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing,
                )
                .frame(width: 14)
                Rectangle().fill(Color.black)
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing,
                )
                .frame(width: 14)
            },
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proactive suggestions")
    }
}

/// A single outline-capsule pill — glyph + 12pt mono label.
struct ProactivePill: View {
    let signal: ProactiveSignal
    let onTap: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    private var accentColor: Color {
        switch signal.accent {
        case .olive:  return KloColors.olive
        case .copper: return KloColors.copper
        case .teal:   return KloColors.teal
        case .brand:
            if case .composio(let slug) = signal.icon {
                return BrandStyle.color(for: slug)
            }
            return Color.white.opacity(0.50)
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                glyph
                Text(signal.label)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(hovered ? 0.95 : 0.80))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .tracking(0.1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.05 : 0.02)),
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        hovered
                            ? accentColor.opacity(0.55)
                            : Color.white.opacity(0.15),
                        lineWidth: 0.6,
                    ),
            )
            .scaleEffect(pressed ? 0.965 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.80), value: hovered)
            .animation(.easeOut(duration: 0.10), value: pressed)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false },
        )
        .help(signal.prompt)
        .accessibilityLabel("Try: \(signal.label)")
        .accessibilityHint("Fills the input with a starter prompt.")
    }

    // ─── Glyph ─────────────────────────────────────────────────────────
    // SF Symbols for live pills (rendered in the accent color so they
    // read as "klo's own signal"). Composio brand logos for connector
    // pills, with a colored monogram fallback when no bundled asset
    // exists — same chain ConnectionsView and the iOS PromptSuggestions
    // use, so the brand vocabulary is one across surfaces.

    @ViewBuilder
    private var glyph: some View {
        switch signal.icon {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 14, height: 14)
        case .composio(let slug):
            if let img = BrandStyle.bundledLogo(for: slug) {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
            } else {
                Text(BrandStyle.monogram(slug: slug, catalogName: signal.label))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrandStyle.color(for: slug))
                    .frame(width: 13, height: 13)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(BrandStyle.color(for: slug).opacity(0.18)),
                    )
            }
        }
    }
}
