import SwiftUI

/// "Save sign-in for {host} to klo?" island. Fires after the user
/// submits a login form inside the embedded WKWebView and klo's
/// capture script intercepts the form values. The user can:
///   - **Save** → KloKeychain writes an InternetPassword item scoped
///     to klo's signing identity, biometry-gated. Next visit, klo can
///     autofill via web.autofill.
///   - **Not now** → in-memory hold drops the password without writing.
///     Klo will ask again next time the user signs in.
///
/// Mirrors the SignInIslandView vocabulary: compact, dismissable,
/// single primary action. The reasoning is the same — credential
/// prompts shouldn't hog the screen.
struct SaveCredentialIslandView: View {
    let host: String
    let username: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var appeared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Host badge — same compact monospace treatment as the
            // sign-in island's draftPrompt. Reads as "this is where you
            // just signed in" without restating it in a sentence.
            Text(host.lowercased())
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.4)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("save sign-in to klo?")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            Text(bodyCopy)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button(action: onAccept) {
                    Text("save to klo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KloColors.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(KloColors.olive))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)

                Button(action: onDecline) {
                    Text("not now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)

                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.98)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                appeared = true
            }
        }
    }

    private var bodyCopy: String {
        // username can be empty (some forms only have a password
        // field with the username implicit). Trim around either.
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty {
            return "klo will store this sign-in in your login keychain so it can fill it next time. touch id required to unlock."
        }
        return "klo will store \(trimmedUser) for \(host) in your login keychain. touch id required to unlock."
    }
}
