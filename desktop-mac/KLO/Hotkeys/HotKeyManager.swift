import AppKit
import HotKey

// Wraps the HotKey SPM package. Registers global hotkeys that fire from
// any active app (Safari, VS Code, Slack) and dispatches state
// transitions onto the main actor.
//
// Voice mode is now re-enabled via ⌘⇧K. AgentClient routes the
// transcript / audio path through either VapiBridge or RealtimeBridge
// based on KLO_VOICE_PROVIDER (env or UserDefaults), so the hotkey
// stays provider-agnostic.
@MainActor
final class HotKeyManager {
    private weak var state: KLOState?
    private var commandK: HotKey?
    private var commandShiftK: HotKey?
    private var commandShiftA: HotKey?
    private var commandShiftComma: HotKey?
    private let openSettings: (() -> Void)?
    private let cancelRun: (() -> Void)?

    init(
        state: KLOState,
        openSettings: (() -> Void)? = nil,
        cancelRun: (() -> Void)? = nil
    ) {
        self.state = state
        self.openSettings = openSettings
        self.cancelRun = cancelRun
    }

    /// True iff the agent is actively executing — pressing the toggle
    /// hotkey in any of these modes should CANCEL the run, not just
    /// toggle the input panel. Without this guard, ⌘K during a run
    /// silently flips the UI to text-input mode while the agent keeps
    /// running the prior task — the user thought they stopped it,
    /// the model keeps clicking, force-close becomes the only out.
    private func runIsInFlight() -> Bool {
        guard let mode = state?.mode else { return false }
        switch mode {
        case .working, .resuming, .confirmingAction:
            return true
        default:
            return false
        }
    }

    func register() {
        let cmdK = HotKey(key: .k, modifiers: [.command])
        cmdK.keyDownHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Active run → cancel + collapse. Don't switch to text
                // input behind the user's back. They pressed the key
                // to STOP, not to start a new prompt.
                if self.runIsInFlight() {
                    self.cancelRun?()
                    self.state?.collapseToIdle()
                    return
                }
                self.state?.toggleText()
            }
        }
        commandK = cmdK

        // ⌘⇧K toggles voice mode. KLOOverlayView responds to the
        // .voiceExpanded mode by rendering the fire silhouette overlay
        // and VoiceInputView.onAppear calls AgentClient.startVoiceCapture
        // which branches to the active voice provider (Vapi default,
        // Realtime when KLO_VOICE_PROVIDER=realtime).
        let cmdShiftK = HotKey(key: .k, modifiers: [.command, .shift])
        cmdShiftK.keyDownHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Same cancel-first semantics as ⌘K. Pressing a hotkey
                // during a run is universally "stop."
                if self.runIsInFlight() {
                    self.cancelRun?()
                    self.state?.collapseToIdle()
                    return
                }
                self.state?.toggleVoice()
            }
        }
        commandShiftK = cmdShiftK

        // ⌘⇧A opens the inline Composio connections browser from any
        // app. Captures any in-flight text-mode draft so Esc restores
        // it. No-op when a run is in flight — don't interrupt the
        // model's tool loop just to browse apps.
        let cmdShiftA = HotKey(key: .a, modifiers: [.command, .shift])
        cmdShiftA.keyDownHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.runIsInFlight() { return }
                // No way to read the in-flight TextInputView text from
                // here without plumbing — leave previousDraft=nil and
                // let the user re-type if they had something. Future
                // enhancement: KLOState could publish the current
                // textInputDraft from TextInputView's @State.
                self.state?.showConnections(previousDraft: nil)
            }
        }
        commandShiftA = cmdShiftA

        // ⌘⇧, opens Settings. We deliberately use SHIFT+, not bare ⌘,
        // because ⌘, is reserved by macOS for the foreground app's
        // settings menu — registering it globally would step on every
        // other app the user is in.
        if openSettings != nil {
            let cmdShiftComma = HotKey(key: .comma, modifiers: [.command, .shift])
            cmdShiftComma.keyDownHandler = { [weak self] in
                Task { @MainActor in self?.openSettings?() }
            }
            commandShiftComma = cmdShiftComma
        }

        NSLog("KLO: hotkeys registered (⌘K = text, ⌘⇧K = voice, ⌘⇧A = apps, ⌘⇧, = settings)")
    }

    func unregister() {
        commandK = nil
        commandShiftK = nil
        commandShiftA = nil
        commandShiftComma = nil
        NSLog("KLO: hotkeys unregistered")
    }
}
