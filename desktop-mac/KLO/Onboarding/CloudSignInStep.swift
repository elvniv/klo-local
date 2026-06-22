import SwiftUI

/// Google-OAuth sign-in step tuned for the cloud-hosted onboarding card.
///
/// Mirrors `SignInStep` (the standalone-window version) with the
/// lighter visual weight that matches `CloudPermissionsStep` and
/// `CloudReadyStep`. The cloud owns the full first-launch journey —
/// Permissions → Ready → Sign in → notch — so the user never gets
/// dropped from the cool dark cloud into a bland standalone window.
///
/// AccountManager state drives the body:
///   - default: "Sign in with Google" button
///   - awaitingOAuth: pulse pill + "finish in your browser" copy
///   - signedIn*: confirmation + auto-advance after 0.6s
struct CloudSignInStep: View {
    @ObservedObject var account: AccountManager
    @ObservedObject var coordinator: OnboardingFocusCoordinator

    var body: some View {
        OnboardingStepShell(
            eyebrowLabel: eyebrowLabel,
            eyebrowDot: eyebrowDot,
            title: "Sign in.",
            subtitle: "One click. Sign in with your Google account — klo opens it in your browser and brings you back here.",
            contentTopPadding: 28
        ) {
            content
        }
    }

    // MARK: - Body switch

    @ViewBuilder
    private var content: some View {
        switch account.status {
        case .awaitingOAuth:
            awaitingForm
        case .signedInActive, .signedInUnsubscribed,
             .signedInPastDue, .signedInExpired:
            signedInConfirmation
        default:
            signInForm
        }
    }

    // MARK: - States

    private var signInForm: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Spacer()
                Button {
                    coordinator.requestHandoff(.googleSignIn)
                } label: {
                    HStack(spacing: 10) {
                        googleGlyph
                        Text("Sign in with Google")
                    }
                }
                .buttonStyle(.kloPrimary)
                .frame(maxWidth: 280)
                .keyboardShortcut(.return)
            }
            if let err = account.lastSignInError {
                Text(err)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(KloColors.fg60)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var awaitingForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Circle()
                    .fill(KloColors.olive)
                    .frame(width: 10, height: 10)
                Text("waiting on your browser")
                    .font(.kloBody)
                    .foregroundStyle(KloColors.fg60)
            }

            Text("klo opened Google sign-in in your default browser. Finish there and we'll bring you right back. Feel free to switch apps in the meantime.")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg80)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    coordinator.requestHandoff(.googleSignIn)
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

    private var signedInConfirmation: some View {
        // No Continue button — the parent's derived currentStep
        // re-renders to .ready as soon as account.isSignedIn flips.
        // This view is shown for a brief moment between sign-in
        // landing and the cloud crossfading away.
        VStack(alignment: .leading, spacing: 12) {
            Text("Signed in.")
                .font(.kloTitle)
                .foregroundStyle(KloColors.fg)
            Text("Bringing you back…")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg60)
        }
    }

    // MARK: - Helpers

    /// Real Google G — uses the GoogleG.imageset asset (multi-color
    /// brand mark) on a cream disc. Earlier this rendered SF Symbol
    /// "g.circle.fill" which is a monochrome generic glyph, not the
    /// actual Google logo.
    private var googleGlyph: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 22, height: 22)
            Image("GoogleG")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        }
    }

    private var eyebrowLabel: String {
        switch account.status {
        case .awaitingOAuth: return "browser open"
        case .signedInActive, .signedInUnsubscribed,
             .signedInPastDue, .signedInExpired: return "signed in"
        default: return "last step · sign in"
        }
    }

    private var eyebrowDot: Color {
        switch account.status {
        case .signedInActive, .signedInUnsubscribed: return KloColors.success
        case .awaitingOAuth: return KloColors.olive
        case .signedInPastDue, .signedInExpired: return KloColors.error
        default: return KloColors.olive
        }
    }
}
