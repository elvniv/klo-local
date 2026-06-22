import SwiftUI

/// Cloud-onboarding step that prompts the user to install the klo
/// Chrome extension. Browser-driven tasks (chat, web automations)
/// require it. The Mac-only notch agent works without it, so this
/// step is skippable but visually emphasized as the most important
/// install in the flow.
///
/// Flow:
///   1. User clicks "Install klo for Chrome." We open the Chrome
///      Web Store URL via NSWorkspace and flip
///      coordinator.browserHandoff = .awaitingChromeInstall.
///   2. CeremonyWindowController observes the flip and orderOut's
///      the cloud panel so the user can interact with Chrome
///      unobstructed. It also installs an NSWorkspace activation
///      listener.
///   3. When klo regains focus (the user clicks back to klo after
///      installing or dismissing), the controller orderFront's the
///      cloud and the step's `browserOpened` flips true so we show
///      a "Did you install? [I'm done] [Re-open] [Skip]" UI.
///   4. "I'm done" or "Skip" both persist
///      `klo.didInstallChromeExtension = true` and call onContinue;
///      future runs of the cloud onboarding skip this step.
struct CloudChromeExtensionStep: View {
    @ObservedObject var coordinator: OnboardingFocusCoordinator

    /// Live extension/Chrome status. Drives two affordances: the
    /// "Install Google Chrome first" branch when stable Chrome isn't
    /// on the Mac, and (via the parent card's derived currentStep)
    /// auto-advancing past this step the moment the extension
    /// connects.
    @ObservedObject var bridge: BridgeStatusManager

    /// True after the user has clicked Install once. The view flips
    /// from "Install klo for Chrome" CTA to a "Did you install?"
    /// confirmation prompt. Survives the orderOut/orderFront cycle
    /// because the parent view doesn't get rebuilt while the cloud
    /// is hidden.
    @State private var browserOpened: Bool = false

    /// Chrome Web Store deep link to the klo extension. Hardcoded
    /// to the published store ID. If we rotate IDs (rare), bump this.
    static let storeURL = URL(string:
        "https://github.com/klo-local/klo-local/blob/main/docs/extension.md"
    )!

    /// UserDefaults key. Set when the user has resolved this step
    /// (installed or explicitly skipped) so the cloud's init() can
    /// auto-skip on returning launches.
    static let didInstallKey = "klo.didInstallChromeExtension"

    var body: some View {
        OnboardingStepShell(
            eyebrowLabel: browserOpened ? "did you install it?" : "browser step",
            title: "klo works inside your browser too.",
            subtitle: "Install the extension so klo can read pages, click, type, and fill forms — anywhere on the web. Same single-prompt feel, just inside your browser.",
            contentTopPadding: 28
        ) {
            content
        }
    }

    // MARK: - Body switch

    @ViewBuilder
    private var content: some View {
        if browserOpened {
            confirmationForm
        } else {
            installForm
        }
    }

    // MARK: - States

    /// Initial CTA — single big "Install klo for Chrome" button +
    /// a quiet skip link. Visually emphasized: full-width, bold.
    private var installForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Mockup card hint — visually grounds what they're about
            // to install, similar in spirit to the Permissions card.
            chromeMockupCard

            HStack {
                Spacer()
                if bridge.chromeInstalled {
                    Button {
                        coordinator.requestHandoff(.chromeExtension)
                        browserOpened = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Install klo for Chrome")
                        }
                    }
                    .buttonStyle(.kloPrimary)
                    .frame(maxWidth: 280)
                    .keyboardShortcut(.return)
                } else {
                    // No stable Chrome on this Mac — the Web Store
                    // can't install into a browser that doesn't exist.
                    // Point at the Chrome download instead; the bridge
                    // poll flips this branch back to the extension CTA
                    // the moment Chrome lands in /Applications.
                    Button {
                        bridge.openInstall()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Get Google Chrome")
                        }
                    }
                    .buttonStyle(.kloPrimary)
                    .frame(maxWidth: 280)
                    .keyboardShortcut(.return)
                }
            }

            if !bridge.chromeInstalled {
                HStack {
                    Spacer()
                    Text("Install Google Chrome first — the klo extension runs inside it.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(KloColors.fg60)
                }
            }

            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        // Setting the flag is enough — parent's derived
                        // currentStep re-renders to the next step on flip.
                        UserDefaults.standard.set(true, forKey: Self.didInstallKey)
                    } label: {
                        Text("Continue without browser tools")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(KloColors.fg45)
                    }
                    .buttonStyle(.plain)
                    Text("You can add this from Settings anytime.")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(KloColors.fg45.opacity(0.7))
                }
            }
        }
    }

    /// Fallback shown when the user clicked Return on the floating
    /// reminder pill WITHOUT installing the extension (and the bridge
    /// didn't auto-detect anything). The happy path now lives entirely
    /// on the reminder pill: it flips to a green "Extension installed"
    /// state and the cloud restores onto the next step automatically.
    /// This view only renders when the user explicitly bailed out.
    private var confirmationForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Circle()
                    .fill(KloColors.olive)
                    .frame(width: 10, height: 10)
                Text("welcome back")
                    .font(.kloBody)
                    .foregroundStyle(KloColors.fg60)
            }

            Text("Didn't get to it? No rush — you can install klo for Chrome later from Settings. Hit ⌘K in any tab once it's installed.")
                .font(.kloBody)
                .foregroundStyle(KloColors.fg80)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    UserDefaults.standard.set(true, forKey: Self.didInstallKey)
                } label: {
                    HStack(spacing: 8) {
                        Text("I'm done")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.kloPrimary)
                .frame(maxWidth: 220)
                .keyboardShortcut(.return)

                Button {
                    coordinator.requestHandoff(.chromeExtension)
                } label: {
                    Text("Re-open Web Store")
                }
                .buttonStyle(.kloGhost)

                Button {
                    UserDefaults.standard.set(true, forKey: Self.didInstallKey)
                } label: {
                    Text("Continue without it")
                }
                .buttonStyle(.kloGhost)
            }
        }
    }

    /// Mini visual that hints "this is what you're installing." A
    /// faux Chrome Web Store row with the klo icon — gives the user
    /// visual context for what the button will open.
    private var chromeMockupCard: some View {
        HStack(spacing: 14) {
            // klo icon swatch
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(KloColors.olive)
                    .frame(width: 44, height: 44)
                    .shadow(color: KloColors.olive.opacity(0.4), radius: 8, y: 3)
                Text("klo")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("klo browser agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KloColors.fg)
                Text("Hit ⌘K anywhere on the web")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(KloColors.fg60)
            }
            Spacer()
            Text("free")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(KloColors.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(KloColors.success.opacity(0.12))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KloColors.ink)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(KloColors.border, lineWidth: 0.5)
        )
    }
}
