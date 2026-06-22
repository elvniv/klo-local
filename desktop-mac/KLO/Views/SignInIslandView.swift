import SwiftUI

/// Small sign-in island fired when the user submits a query while
/// signed out. Mirrors the permission-island vocabulary (compact,
/// dismissable, single primary action). OAuth runs in the user's
/// default browser; the existing klo:// deep-link callback flips
/// account.status to .signedInActive, and KLOOverlayView's
/// onChange(account.status) auto-resubmits the saved draftPrompt.
struct SignInIslandView: View {
    let draftPrompt: String?
    let status: AccountManager.Status
    let onSignIn: () -> Void
    let onDismiss: () -> Void

    @State private var appeared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Original draft prompt, if any — same monospace pattern
            // as PermissionRequiredView so the two islands feel like
            // siblings.
            if let draft = draftPrompt, !draft.isEmpty {
                Text(draft)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .tracking(0.4)
                    .textCase(.lowercase)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(draft)
            }

            Text(headline)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            Text(bodyCopy)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    onSignIn()
                } label: {
                    HStack(spacing: 8) {
                        googleGlyph
                        Text(primaryLabel)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.kloPrimary)
                .disabled(inFlight)

                if inFlight {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("waiting for your browser…")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Text("Not now")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.kloGhost)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 4)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { appeared = true }
        }
    }

    /// "Sign in" until OAuth kicks off, then "Continue in your browser".
    private var primaryLabel: String {
        switch status {
        case .awaitingOAuth: return "Continue in your browser"
        default:             return "Sign in with Google"
        }
    }

    private var inFlight: Bool {
        if case .awaitingOAuth = status { return true }
        return false
    }

    private var headline: String {
        if draftPrompt?.isEmpty == false {
            return "Sign in to run that."
        }
        return "Sign in to klo."
    }

    private var bodyCopy: String {
        "Opening Google in your browser. klo will step aside in a moment so you can finish — we'll auto-run your prompt when you're back."
    }

    /// Real Google G — same multi-color asset the iOS sign-in screen
    /// uses, copied into the Mac asset catalog as GoogleG.imageset so
    /// the button matches Google's brand guidelines instead of the
    /// previous gradient-text fake. Sits on a cream disc so the
    /// multi-color glyph reads crisp against the dark island surface.
    private var googleGlyph: some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 18, height: 18)
            Image("GoogleG")
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
        }
    }
}
