import SwiftUI

/// Shared layout shell for every cloud-onboarding step. Each step
/// (Permissions, Chrome, Sign in, Ready) used to duplicate the same
/// `VStack { eyebrow / headline / subtitle / content / spacer }`
/// structure — visual tweaks meant editing four near-identical bodies.
///
/// Now they all funnel through this shell. The step body is just:
///
///     OnboardingStepShell(eyebrowLabel: "permissions",
///                        title: "Step 1 of 2 — Accessibility.",
///                        subtitle: "klo needs 2 things from macOS …") {
///         // step-specific cards / forms
///     }
///
/// One place to adjust eyebrow capsule styling, hero typography, or
/// content padding. Visual changes ripple to all four steps.
struct OnboardingStepShell<Content: View>: View {
    let eyebrowLabel: String
    /// Filled color of the dot inside the eyebrow capsule. Defaults to
    /// klo orange; sign-in flips between orange/success/error based on
    /// account status.
    var eyebrowDot: Color = KloColors.olive
    let title: String
    let subtitle: String
    /// When set, the title animates between values (used by the
    /// permissions step which shows "Step 1 of 2 — Accessibility."
    /// → "Step 2 of 2 — Screen Recording." → "All set.").
    var animateTitle: Bool = false
    /// Optional padding above the content block. Defaults to a
    /// comfortable 22pt; sign-in uses 28 for breathing room.
    var contentTopPadding: CGFloat = 22
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow

                Group {
                    if animateTitle {
                        Text(title)
                            .id(title)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: title)
                    } else {
                        Text(title)
                    }
                }
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(KloColors.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.55)

                Text(subtitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(KloColors.fg60)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
                .padding(.top, contentTopPadding)
        }
    }

    private var eyebrow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(eyebrowDot)
                .frame(width: 6, height: 6)
            Text(eyebrowLabel)
                .kloEyebrow()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(KloColors.border, lineWidth: 0.5)
        )
    }
}
