import SwiftUI
import AppKit

// Paywall card rendered INSIDE the notch panel when the user submits a
// prompt while not signed-in / subscribed. Mirrors ResultPanelView's
// visual rhythm (28pt horizontal, 22pt top, fade-in cascade) so the
// transition from text-input → paywall feels like a normal panel
// state change.
//
// Routes the user to the right next action based on `reason`:
//   - .signInRequired       → opens standalone SignIn window
//   - .subscribeRequired    → opens Stripe Checkout in browser
//   - .updateBillingRequired→ opens Stripe Customer Portal in browser
//   - .resubscribeRequired  → opens Stripe Checkout in browser
//
// Once Stripe completes (webhook → Supabase → /auth/me → AccountManager
// flips to .signedInActive), the parent KLOOverlayView observes the
// status change and auto-resubmits `draftPrompt` so the user's
// original ⌘K-Return doesn't feel wasted.
struct PaywallPanelView: View {
    let reason: KLOState.PaywallReason
    let draftPrompt: String

    @EnvironmentObject var state: KLOState
    @EnvironmentObject var account: AccountManager
    @State private var openingAction: Bool = false
    @State private var actionFailed: Bool = false
    @State private var appeared: Bool = false
    // Tier the user tapped in the picker. "starter" or "pro". Drives
    // the CTA copy + the body the checkout request sends. Defaults
    // to starter — the cheaper option that gets most users in the
    // door. Only relevant when reason is subscribeRequired /
    // resubscribeRequired; ignored for sign-in / billing flows.
    // Single live plan: $20/mo (Stripe's legacy STRIPE_PRICE_ID).
    // The two-tier picker ($15 Starter / $30 Pro) was launch-config
    // that never matched the live Stripe price — checkout omits the
    // tier so the server bills the real plan.

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            eyebrow
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -4)
                .animation(.easeOut(duration: 0.30).delay(0.00), value: appeared)

            Text(headline)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 4)
                .animation(.easeOut(duration: 0.36).delay(0.06), value: appeared)

            Text(body_)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.36).delay(0.10), value: appeared)

            if showsTierPicker {
                tierPicker
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)
                    .animation(.easeOut(duration: 0.36).delay(0.13), value: appeared)
            }

            primaryAction
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(.easeOut(duration: 0.36).delay(0.16), value: appeared)

            if actionFailed {
                Text("Couldn't reach klo. Check your connection.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KloColors.error.opacity(0.85))
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            footer
                .opacity(appeared ? 0.85 : 0)
                .animation(.easeOut(duration: 0.30).delay(0.22), value: appeared)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
        .onExitCommand { state.collapseToIdle() }
    }

    // MARK: - Header eyebrow

    private var eyebrow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KloColors.orange)
                .frame(width: 6, height: 6)
                .modifier(KloFireGlow(active: true, radius: 6))
            Text(eyebrowLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    // MARK: - Primary CTA

    private var primaryAction: some View {
        Button { runPrimaryAction() } label: {
            HStack(spacing: 8) {
                if openingAction {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(openingAction ? "Opening…" : ctaLabel)
                if !openingAction {
                    Image(systemName: ctaIcon)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(KloColors.orange)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(KloColors.orange.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return)
        .disabled(openingAction)
    }

    // MARK: - Tier picker

    /// Shown when the user needs to (re)subscribe — including the new
    /// time-trial outcomes (.dailyLimitReached, .trialExpired) which are
    /// both upgrade-CTA flows. Sign-in / billing-update flows skip it
    /// (no tier choice to make in those paths).
    private var showsTierPicker: Bool {
        switch reason {
        case .subscribeRequired, .resubscribeRequired,
             .dailyLimitReached, .trialExpired:
            return true
        case .signInRequired, .updateBillingRequired:
            return false
        }
    }

    private var tierPicker: some View {
        planCard(
            title: "klo",
            price: "$20/mo",
            blurb: "Unlimited chats and voice. Cancel anytime."
        )
    }

    @ViewBuilder
    private func planCard(title: String, price: String, blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Text(price)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(blurb)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(KloColors.orange.opacity(0.85), lineWidth: 1.0)
        )
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !draftPrompt.isEmpty {
                Text("Your prompt: \"\(draftPrompt)\" — we'll retry once you're set up.")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Text("settings (\u{2318},)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.50))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("esc to dismiss")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
    }

    // MARK: - Reason → copy + actions

    private var eyebrowLabel: String {
        switch reason {
        case .signInRequired:           return "sign in required"
        case .subscribeRequired:        return "subscribe to klo pro"
        case .updateBillingRequired:    return "billing needs attention"
        case .resubscribeRequired:      return "subscription ended"
        case .dailyLimitReached:        return "limit reached today"
        case .trialExpired:             return "trial ended"
        }
    }

    private var headline: String {
        switch reason {
        case .signInRequired:           return "Sign in to use klo."
        case .subscribeRequired:        return "Pick a plan."
        case .updateBillingRequired:    return "Update your billing."
        case .resubscribeRequired:      return "Welcome back. Pick a plan."
        case .dailyLimitReached:        return "You've hit your 5 chats for today."
        case .trialExpired:             return "Your 7-day trial just ended."
        }
    }

    private var body_: String {
        switch reason {
        case .signInRequired:
            return "klo is signed out. Sign in with your email and we'll send you a link to come back."
        case .subscribeRequired:
            return "Two tiers. Both unlock every prompt, the browser agent, and voice mode. Pro adds unlimited voice and person research."
        case .updateBillingRequired:
            return "Your last payment didn't go through. Update your card to keep using klo."
        case .resubscribeRequired:
            return "Your subscription ended. Pick a plan to reactivate."
        case .dailyLimitReached:
            return "More tomorrow at midnight, or upgrade now for unlimited chats + voice."
        case .trialExpired:
            return "Pick a plan to keep klo. Cancel anytime."
        }
    }

    private var ctaLabel: String {
        switch reason {
        case .signInRequired:           return "Sign in"
        case .subscribeRequired, .resubscribeRequired,
             .dailyLimitReached, .trialExpired:
            let verb = (reason == .resubscribeRequired) ? "Reactivate" : "Upgrade"
            return "\(verb) — $20/mo"
        case .updateBillingRequired:    return "Update billing"
        }
    }

    private var ctaIcon: String {
        switch reason {
        case .signInRequired:           return "arrow.right"
        case .subscribeRequired:        return "arrow.up.right.square"
        case .updateBillingRequired:    return "arrow.up.right.square"
        case .resubscribeRequired:      return "arrow.up.right.square"
        case .dailyLimitReached:        return "arrow.up.right.square"
        case .trialExpired:             return "arrow.up.right.square"
        }
    }

    // MARK: - Actions

    private func runPrimaryAction() {
        actionFailed = false
        openingAction = true
        switch reason {
        case .signInRequired:
            // Kick the Google OAuth flow directly from the paywall —
            // opens Sign in with Google in the user's default browser.
            // The AccountManager observer in KLOOverlayView auto-
            // resubmits when status flips on deep-link return.
            // No standalone window in the loop anymore.
            HapticEngine.tap(.alignment)
            Task { await account.startSignInWithGoogle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                openingAction = false
            }
        case .subscribeRequired, .resubscribeRequired,
             .dailyLimitReached, .trialExpired:
            Task {
                // No tier param: the server falls back to the legacy
                // STRIPE_PRICE_ID, which is the live $20/mo plan. Same
                // checkout flow for all four upgrade reasons.
                if let url = await account.startCheckout(tier: nil) {
                    NSWorkspace.shared.open(url)
                    HapticEngine.tap(.levelChange)
                    // Start polling /auth/me so we detect the active
                    // subscription within a couple of seconds of
                    // Stripe firing the webhook.
                    account.beginPostCheckoutPolling()
                } else {
                    actionFailed = true
                }
                openingAction = false
            }
        case .updateBillingRequired:
            Task {
                if let url = await account.openBillingPortal() {
                    NSWorkspace.shared.open(url)
                    HapticEngine.tap(.levelChange)
                    account.beginPostCheckoutPolling()
                } else {
                    actionFailed = true
                }
                openingAction = false
            }
        }
    }
}
