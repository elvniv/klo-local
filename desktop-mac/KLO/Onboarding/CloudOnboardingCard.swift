import SwiftUI
import AppKit

/// Cloud-hosted onboarding card. Steps: Phone app → Chrome extension
/// → Ready. The current step is **derived** from observable state
/// (BridgeStatusManager, UserDefaults) — there's no imperative
/// `@State step` to mutate or routing logic to duplicate between init
/// and onAppear. SwiftUI re-renders the right step automatically the
/// moment any input changes.
///
/// Routing source of truth (one place, any reader):
///   UserDefaults `klo.didShareiPhoneApp` ⤳ skip Phone app
///   UserDefaults `klo.didInstallChromeExtension`
///     OR `bridge.extensionConnected` ⤳ skip Chrome
///   otherwise ⤳ Ready
///
/// `requiredEverGranted` is the durable "we have seen these granted"
/// signal — survives the SR auto-relaunch's brief TCC propagation
/// race so the post-relaunch cloud opens on the next undone step
/// instead of flashing back to Permissions.
struct CloudOnboardingCard: View {

    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var bridge: BridgeStatusManager
    @ObservedObject var coordinator: OnboardingFocusCoordinator
    @ObservedObject var account: AccountManager
    let onDone: () -> Void

    /// `@AppStorage` observes the UserDefaults key — when the phone-app
    /// step's button writes `true`, SwiftUI re-evaluates this view's
    /// `var body` (and `currentStep` with it), letting the transition
    /// to `.ready` fire. Reading `UserDefaults.standard.bool(...)` from
    /// inside `var body` does NOT subscribe to changes; the step would
    /// silently stay on `.phoneApp` forever after the user clicked
    /// "I'm done" because nothing would tell SwiftUI to re-render.
    @AppStorage(CloudPhoneAppStep.didShareKey) private var didShareiPhoneApp: Bool = false

    /// Same observation pattern for the Chrome-extension step: set by
    /// the step's Skip / "I'm done" buttons (and by the coordinator's
    /// handoff-completion path when the bridge detects the extension),
    /// so the derived `currentStep` advances the moment it flips.
    @AppStorage(CloudChromeExtensionStep.didInstallKey) private var didResolveChromeExtension: Bool = false

    /// Durable flag — set once when the user has completed the cloud
    /// onboarding to .ready. Consulted on launch by `AppDelegate` to
    /// decide whether to replay the cloud or jump to the welcome-back
    /// flourish. (Previously lived on the now-deleted
    /// `OnboardingWindowController`.)
    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "klo.onboardingCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "klo.onboardingCompleted") }
    }

    /// Declaration order = flow order (the step indicator's "done"
    /// fill compares rawValues). `.permissions` and `.signIn` are
    /// unreachable (see currentStep) but kept for the island routes.
    enum Step: Int, CaseIterable {
        case permissions, signIn, phoneApp, chromeExtension, ready
    }

    /// **Derived** — recomputed every body evaluation from observable
    /// inputs. No imperative state, no race between init and onAppear,
    /// no `advance()` helpers.
    private var currentStep: Step {
        // .permissions REMOVED from the onboarding flow. The full-page
        // list of permission cards is a bad UX — it interrupts users
        // mid-grant (auto-relaunch fights them), keeps re-appearing on
        // every cdhash drift, and forces users to grant things they
        // may never need (Screen Recording for a Music task, etc.).
        // New pattern: dump users into the notch, surface a small
        // island prompt inline when a tool call actually hits a TCC
        // denial. The .permissions Step + CloudPermissionsStep view
        // are kept in source so an island can route back to them
        // later if we want a guided multi-perm setup screen — but
        // the onboarding flow never lands here.
        // _ = permissions silences the unused warning since
        // the property is still on the struct for the .permissions
        // case body below.
        _ = permissions
        _ = account
        // Sign-in is gone from the picker — fired from inside the
        // notch as a small .signInRequired island via
        // AgentClient.submitQuery when the user submits a query while
        // signed out.

        // .phoneApp re-enabled — pointing new Mac users at the iOS
        // listing during onboarding is the highest-conversion moment
        // for cross-device install. Scanning a QR right after the
        // demo tour, while the user already has phone in hand for
        // OAuth fallbacks, converts orders-of-magnitude better than
        // any post-install push. Single-shot via @AppStorage so the
        // button tap re-renders the parent and the step transitions.
        if !didShareiPhoneApp {
            return .phoneApp
        }

        // Chrome-extension beat — one skippable step. Browser tools
        // (read the tab, click, fill) need the extension; surfacing
        // it here beats the runtime MissingExtensionPanel dead-end on
        // the user's first browser ask. Auto-skips (and auto-ADVANCES,
        // since `bridge` is observed) when the bridge already reports
        // the extension connected — nothing to install, no step.
        if !didResolveChromeExtension && !bridge.extensionConnected {
            return .chromeExtension
        }

        return .ready
    }

    private let screen: CGSize = NSScreen.main?.frame.size
        ?? CGSize(width: 1440, height: 900)

    /// Card frame: floor at 940×720 (fits 16" MBP comfortably), cap at
    /// 70%×80% of screen so it doesn't dominate small displays or grow
    /// to absurd sizes on large ones.
    private var cardWidth: CGFloat { min(940, max(720, screen.width * 0.62)) }
    private var cardHeight: CGFloat { min(720, max(560, screen.height * 0.78)) }

    var body: some View {
        let step = currentStep
        VStack(spacing: 0) {
            stepIndicator(active: step)
                .padding(.top, 18)
                .padding(.bottom, 14)

            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch step {
                    case .permissions:
                        CloudPermissionsStep(
                            permissions: permissions,
                            bridge: bridge,
                            focusCoordinator: coordinator,
                            // Surface the stale-hint immediately if
                            // EITHER permission was durably granted
                            // before but TCC currently says otherwise.
                            // Common in dev builds (cdhash drift) and
                            // on the post-relaunch path when TCC trust
                            // hasn't yet re-propagated to the new
                            // process. Used to require BOTH durable
                            // flags set; that meant a user who'd only
                            // granted AX got no feedback after relaunch.
                            forceShowStaleHint:
                                (permissions.hasEverGrantedAccessibility
                                    && permissions.accessibility != .granted)
                                || (permissions.hasEverGrantedScreenRecording
                                    && permissions.screenRecording != .granted)
                        )
                    case .chromeExtension:
                        CloudChromeExtensionStep(coordinator: coordinator, bridge: bridge)
                    case .signIn:
                        CloudSignInStep(account: account, coordinator: coordinator)
                    case .phoneApp:
                        CloudPhoneAppStep()
                    case .ready:
                        // No UI — `.ready` is a transient terminal
                        // marker that fires `onDone` via the `.task`
                        // below. The post-onboarding first-prompt
                        // cinematic island owns the "you're set up"
                        // beat now, so there's no Ready card to show.
                        Color.clear.frame(height: 0)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .animation(.easeOut(duration: 0.22), value: step)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        // Fire onDone the moment derived `currentStep` reaches
        // `.ready` — no user click needed, the cloud just hands off
        // to the first-prompt cinematic island.
        .task(id: step) {
            if step == .ready {
                onDone()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(KloColors.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(KloColors.border, lineWidth: 0.5)
        )
        // On sign-in the heavy drop shadow reads as a cover over the
        // OAuth browser window peeking around the card — drop it there.
        .shadow(color: .black.opacity(step == .signIn ? 0 : 0.45),
                radius: step == .signIn ? 0 : 40,
                y: step == .signIn ? 0 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Step indicator

    private func stepIndicator(active: Step) -> some View {
        // Only the steps the flow can actually land on — .permissions
        // and .signIn are unreachable (see currentStep) and .ready is
        // a transient terminal marker with no UI.
        let visibleSteps: [Step] = [.phoneApp, .chromeExtension]
        return HStack(spacing: 8) {
            ForEach(visibleSteps, id: \.rawValue) { s in
                Capsule()
                    .fill(s == active ? KloColors.olive
                          : s.rawValue < active.rawValue ? KloColors.olive.opacity(0.55)
                          : KloColors.border)
                    .frame(width: s == active ? 22 : 14, height: 4)
                    .animation(.easeOut(duration: 0.25), value: active)
            }
        }
    }
}
