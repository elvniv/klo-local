import SwiftUI

/// Subtle status chip that sits beneath the notch's chat input and
/// proactive pills row. Renders ONLY for users mid-trial — paid
/// subscribers and expired-trial users return EmptyView so the
/// host VStack collapses cleanly with no spacing.
///
/// Why this view exists:
/// The Path B free tier is 5 chats/day for 7 days, then paywall.
/// Showing the user where they are in that trial (chats remaining
/// today + days remaining overall) makes the upgrade decision feel
/// chosen rather than ambushed — and the visible-ticking-counter
/// dynamic is what drives 8-12% conversion (vs 3-5% on tools that
/// hide the cap). Cursor + Linear use the same pattern.
///
/// Visual rhythm matches the rest of the notch surface:
///   - 10pt JetBrains Mono, 1.4 letter-spacing, uppercase
///   - Olive at 65-75% opacity for normal state
///   - Orange when the chat count OR day count goes critical
///     (last chat of day, last day of trial)
///   - 22pt left padding so it lines up with TextInputView and
///     ProactivePillsRow (configured at the call site, not here)
///
/// Reads state from AccountManager via @EnvironmentObject. Never
/// fires network calls on its own — refreshes happen at AccountManager
/// layer (post-chat, app foreground, /auth/me poll).
struct TrialStatusIndicator: View {
    @EnvironmentObject var account: AccountManager

    var body: some View {
        Group {
            if account.shouldShowTrialIndicator {
                HStack(spacing: 6) {
                    chatPart
                    Text("·")
                        .foregroundStyle(KloColors.fg45)
                    daysPart
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .textCase(.uppercase)
                .transition(
                    .opacity.combined(with: .offset(y: 2))
                )
                .animation(.easeOut(duration: 0.22), value: account.chatsToday)
                .animation(.easeOut(duration: 0.22), value: account.daysLeft)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Chat-count segment

    /// The first half: "3 OF 5 LEFT" / "5 CHATS TODAY" / "1 CHAT LEFT".
    /// Turns orange when the remaining count is critical (1 or 0).
    @ViewBuilder
    private var chatPart: some View {
        let limit = account.chatsLimit
        let used = account.chatsToday
        let remaining = max(0, limit - used)
        let isCritical = remaining <= 1

        let label: String = {
            // Edge: server reports unlimited (paid tier in trial state)
            // — shouldn't happen in practice because shouldShowTrialIndicator
            // gates on free tier, but degrade silently if it does.
            if limit <= 0 { return "" }
            if remaining == 0 {
                return "0 left today"
            }
            if used == 0 {
                // First chat of the day — set expectations cleanly
                // ("5 CHATS TODAY") rather than "5 OF 5 LEFT" which
                // reads as a warning when the user hasn't done anything.
                return "\(limit) chats today"
            }
            if remaining == 1 {
                return "1 chat left today"
            }
            return "\(remaining) of \(limit) left"
        }()

        Text(label)
            .foregroundStyle(
                isCritical
                    ? KloColors.orange
                    : KloColors.olive.opacity(0.75)
            )
    }

    // MARK: - Days-left segment

    /// The second half: "7 DAYS LEFT" / "LAST DAY". Turns orange on
    /// the last day to signal the trial-end conversion moment.
    @ViewBuilder
    private var daysPart: some View {
        let days = account.daysLeft
        let isCritical = days <= 1

        let label: String = {
            if days <= 0 {
                // Defensive: shouldShowTrialIndicator already gates on
                // daysLeft > 0, so this path is unreachable in practice.
                return "trial ended"
            }
            if days == 1 {
                return "last day"
            }
            return "\(days) days left"
        }()

        Text(label)
            .foregroundStyle(
                isCritical
                    ? KloColors.orange
                    : KloColors.olive.opacity(0.65)
            )
    }
}
