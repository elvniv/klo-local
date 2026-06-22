import SwiftUI
import AppKit

/// Account pane content. Lives inside SettingsView's borderless card,
/// or inside the Onboarding sign-in step. Same logic as the prior
/// AccountTab — only the chrome changed: cream paper, hand-drawn
/// wordmark, single orange-dot eyebrow pill, brand text-field +
/// button styles, no system blue, no system grey rounded buttons.
struct AccountView: View {
    @ObservedObject var account: AccountManager
    @ObservedObject private var updater = UpdaterManager.shared
    @State private var openingCheckout: Bool = false
    @State private var openingPortal: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Eyebrow pill — small lowercase mono with the orange dot,
            // mirrors landing/welcome's "PRESS ⌘K" / "YOU'RE IN" pill.
            statusEyebrow

            // Headline — light, generous, brand voice. The line below
            // it carries the actual user-visible status as a subtitle.
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.kloHeadline)
                    .foregroundStyle(KloColors.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detail {
                    Text(detail)
                        .font(.kloBody)
                        .foregroundStyle(KloColors.fg60)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 4)

            // Free-trial usage strip — visible only while the user is on
            // the free tier (mid-trial) or on the legacy lifetime trial.
            // Hidden for fresh signed-out users and active subscribers to
            // keep the view uncluttered. The strip itself picks the right
            // visualization (time-trial vs lifetime-trial) based on
            // which fields are populated.
            if account.shouldShowTrialIndicator
                || account.accessMode == "trial"
                || account.accessMode == "exhausted" {
                trialUsageStrip
            }

            // State-dependent action block.
            switch account.status {
            case .unknown:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(KloColors.orange)
            case .signedOut:
                signInBlock
            case .awaitingOAuth:
                awaitingBlock
            case .signedInUnsubscribed:
                subscribeBlock
            case .signedInActive:
                activeBlock
                // Connected Apps (Composio). Only surfaced when the
                // user is on an active subscription — matches the Pro-
                // tier gate on the server-side composio endpoints.
                IntegrationsView(account: account)
            case .signedInPastDue, .signedInExpired:
                billingIssueBlock
            }

            Spacer(minLength: 0)

            // Footer — tiny mono links, no system blue.
            footerLinks
        }
        .padding(.top, 24)
        .onAppear {
            // One-shot refresh so opening Settings always shows current
            // trial counters and subscription state. Cheap — single
            // /auth/me call, no polling.
            Task { await account.refreshNow() }
        }
    }

    // MARK: - Sub-views

    private var statusEyebrow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(eyebrowDotColor)
                .frame(width: 6, height: 6)
                .shadow(color: eyebrowDotColor.opacity(0.55), radius: 4)
            Text(eyebrowText)
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

    private var signInBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("klo opens Google sign-in in your default browser and brings you back here when you're done.")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg80)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await account.startSignInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Sign in with Google")
                }
            }
            .buttonStyle(.kloPrimary)
            .keyboardShortcut(.return)

            if let err = account.lastSignInError {
                Text(err)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(KloColors.fg60)
                    .italic()
            }
        }
    }

    private var awaitingBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish Google sign-in in your browser. klo catches the redirect and signs you in here.")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg80)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await account.startSignInWithGoogle() }
                } label: {
                    Text("Re-open Google sign-in")
                }
                .buttonStyle(.kloGhost)

                Button {
                    account.signOut()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.kloGhost)
            }
        }
    }

    private var subscribeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subscribePitch)
                .font(.kloBody)
                .foregroundStyle(KloColors.fg80)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openingCheckout = true
                Task {
                    if let url = await account.startCheckout() {
                        NSWorkspace.shared.open(url)
                        // Mirror PaywallPanelView: poll /auth/me every
                        // 2.5s for up to 6 min so we catch the
                        // webhook-driven status flip without waiting
                        // for the user to click around.
                        account.beginPostCheckoutPolling()
                    }
                    openingCheckout = false
                }
            } label: {
                HStack(spacing: 8) {
                    if openingCheckout {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(KloColors.ink)
                    }
                    Text(openingCheckout ? "Opening checkout…" : "Subscribe — $20/mo")
                }
            }
            .buttonStyle(.kloPrimary)
            .keyboardShortcut(.return)
            .disabled(openingCheckout)

            Button {
                account.signOut()
            } label: {
                Text("Sign out")
            }
            .buttonStyle(.kloGhost)
        }
    }

    // Pitch copy adapts to whether the user is mid-trial or post-trial.
    // The non-trial fallback handles cancelled subs and older accounts
    // that pre-date the trial schema.
    private var subscribePitch: String {
        switch account.accessMode {
        case "trial":
            let left = account.trialRunsRemaining
            return "You're on the free trial — \(left) run\(left == 1 ? "" : "s") left. Subscribe for unlimited runs at $20/mo. Cancel anytime."
        case "exhausted":
            return "Free trial used up. $20/mo unlocks unlimited runs from here. Cancel anytime."
        default:
            return "10 free runs to try, then $20/mo. Unlimited after that. Cancel anytime."
        }
    }

    // Free-trial usage indicator. Renders above the action block when
    // the user is in trial or exhausted mode. Thin orange progress bar +
    // monospace counter to mirror the eyebrow pill aesthetic.
    private var trialUsageStrip: some View {
        // Render the time-trial visualization (Path B: 5/day × 7 days)
        // when the server has populated the new time-trial fields. Falls
        // through to the legacy lifetime-runs visualization for any user
        // still on the old gate. Both can coexist during rollout; the
        // legacy path can be removed once telemetry shows zero traffic.
        Group {
            if account.currentTier == "free" && account.trialExpiresAt != nil {
                timeTrialStripBody
            } else {
                legacyLifetimeTrialStripBody
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(KloColors.border, lineWidth: 0.5)
        )
    }

    /// Time-trial body: two lines (chats today + days left in trial)
    /// with a progress bar showing the daily count.
    private var timeTrialStripBody: some View {
        let used = account.chatsToday
        let limit = max(account.chatsLimit, 1)
        let fraction = min(1.0, max(0.0, Double(used) / Double(limit)))
        let chatsCritical = (limit - used) <= 1
        let days = account.daysLeft
        let daysCritical = days <= 1
        let daysLabel: String = {
            if days <= 0 { return "trial ended" }
            if days == 1 { return "last day of trial" }
            return "\(days) days left in trial"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("free trial")
                    .kloEyebrow()
                Spacer(minLength: 8)
                Text("\(used) / \(limit) chats today")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(chatsCritical ? KloColors.orange : KloColors.fg80)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(KloColors.border.opacity(0.4))
                    Capsule(style: .continuous)
                        .fill(chatsCritical ? KloColors.orange : KloColors.olive)
                        .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 6)
            HStack {
                Spacer()
                Text(daysLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(daysCritical ? KloColors.orange : KloColors.fg60)
            }
        }
    }

    /// Legacy lifetime-trial body. Pre-Path-B users on the old
    /// 10-runs-total counter see this until they hit a /usage/today
    /// call (which migrates them to the time-trial code path).
    private var legacyLifetimeTrialStripBody: some View {
        let used = account.trialRunsUsed
        let limit = max(account.trialRunsLimit, 1)
        let fraction = min(1.0, max(0.0, Double(used) / Double(limit)))
        let exhausted = account.accessMode == "exhausted"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("free trial")
                    .kloEyebrow()
                Spacer(minLength: 8)
                Text("\(used) / \(limit) runs")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(exhausted ? KloColors.error : KloColors.fg80)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(KloColors.border.opacity(0.4))
                    Capsule(style: .continuous)
                        .fill(exhausted ? KloColors.error : KloColors.orange)
                        .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 6)
        }
    }

    private var activeBlock: some View {
        HStack(spacing: 10) {
            Button {
                openingPortal = true
                Task {
                    if let url = await account.openBillingPortal() {
                        NSWorkspace.shared.open(url)
                    }
                    openingPortal = false
                }
            } label: {
                HStack(spacing: 8) {
                    if openingPortal {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(KloColors.fg60)
                    }
                    Text(openingPortal ? "Opening portal…" : "Manage billing")
                }
            }
            .buttonStyle(.kloGhost)
            .disabled(openingPortal)

            Button {
                account.signOut()
            } label: {
                Text("Sign out")
            }
            .buttonStyle(.kloGhost)
        }
    }

    private var billingIssueBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update your payment method to keep using klo.")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg80)

            HStack(spacing: 10) {
                Button {
                    openingPortal = true
                    Task {
                        if let url = await account.openBillingPortal() {
                            NSWorkspace.shared.open(url)
                        }
                        openingPortal = false
                    }
                } label: {
                    Text("Open billing portal")
                }
                .buttonStyle(.kloPrimary)

                Button {
                    account.signOut()
                } label: {
                    Text("Sign out")
                }
                .buttonStyle(.kloGhost)
            }
        }
    }

    private var footerLinks: some View {
        HStack(spacing: 14) {
            Link(destination: URL(string: "https://www.getklo.com/privacy")!) {
                Text("privacy")
                    .kloEyebrow()
            }
            .buttonStyle(.plain)

            Text("·")
                .font(.kloEyebrow)
                .foregroundStyle(KloColors.fg45)

            Link(destination: URL(string: "https://www.getklo.com/terms")!) {
                Text("terms")
                    .kloEyebrow()
            }
            .buttonStyle(.plain)

            Spacer()

            // Make the version tag tappable so power users can trigger
            // an update check from Settings without leaving the app.
            // LSUIElement apps have no menu-bar "Check for Updates…"
            // item; this is the manual escape hatch. Disabled while
            // Sparkle is already mid-check.
            Button {
                updater.checkForUpdates()
            } label: {
                Text("klo · v\(Bundle.main.shortVersion)")
                    .kloEyebrow()
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)
            .help("Check for updates")
        }
        .padding(.top, 4)
    }

    // MARK: - Status copy / colors

    private var headline: String {
        switch account.status {
        case .signedInActive:        return "You're set."
        case .signedInUnsubscribed:
            // Differentiate "in trial" from "exhausted" so the page
            // reads as either a welcome or a graceful upsell.
            switch account.accessMode {
            case "trial":     return "You're in. Free trial active."
            case "exhausted": return "Free trial complete."
            default:          return "Pick a plan."
            }
        case .awaitingOAuth:         return "Finish in your browser."
        case .signedInPastDue:       return "Payment past due."
        case .signedInExpired:       return "Subscription ended."
        case .signedOut:             return "Welcome to klo."
        case .unknown:               return "Loading…"
        }
    }

    private var detail: String? {
        switch account.status {
        case .signedInActive(let e, let plan):  return "\(plan) · \(e)"
        case .signedInUnsubscribed(let e):      return e
        case .signedInPastDue(let e),
             .signedInExpired(let e):            return e
        case .awaitingOAuth:                     return "Google sign-in opened in your browser."
        case .signedOut:                         return "Sign in with Google below."
        case .unknown:                           return nil
        }
    }

    private var eyebrowText: String {
        switch account.status {
        case .signedInActive:        return "active"
        case .signedInUnsubscribed:
            switch account.accessMode {
            case "trial":     return "trial"
            case "exhausted": return "trial used"
            default:          return "no plan"
            }
        case .awaitingOAuth:         return "browser open"
        case .signedInPastDue:       return "past due"
        case .signedInExpired:       return "expired"
        case .signedOut:             return "sign in"
        case .unknown:               return "checking"
        }
    }

    private var eyebrowDotColor: Color {
        switch account.status {
        case .signedInActive:                            return KloColors.success
        case .awaitingOAuth:                             return KloColors.orange
        case .signedInUnsubscribed:
            // Green while the trial is live (positive state), orange
            // when it's spent (call-to-action).
            return account.accessMode == "trial" ? KloColors.success : KloColors.orange
        case .signedInPastDue, .signedInExpired:         return KloColors.error
        case .signedOut, .unknown:                       return KloColors.fg45
        }
    }
}


// Bundle helper used by the footer.
private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
}
