import Combine
import Sparkle
import SwiftUI

/// klo's Sparkle wrapper. Owns the SPUStandardUpdaterController so
/// SwiftUI views can observe `canCheckForUpdates` and `updateAvailable`
/// as `@Published` properties.
///
/// Pattern is Arc-inspired: Sparkle's *scheduled* "Update Available"
/// modal is suppressed via `SPUStandardUserDriverDelegate
/// .supportsGentleScheduledUpdateReminders = true` and we surface
/// discovery in klo's notch instead. A small olive arrow above the
/// dormant pill. Tapping the arrow invokes `checkForUpdates()` which
/// re-uses Sparkle's stock install/restart sheet (focused, modal). We
/// only customize the *discovery* surface; the *commit* moment stays
/// Sparkle's responsibility.
///
/// Was missing entirely from klo through 1.1.5. The framework was
/// linked + bundled but never instantiated, so no installed klo had
/// ever checked for updates. Added in 1.1.6.
///
/// Refs:
///   - https://sparkle-project.org/documentation/gentle-reminders/
///   - https://sparkle-project.org/documentation/programmatic-setup/
///   - https://resources.arc.net/hc/en-us/articles/21489650267031
@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    /// True when Sparkle is in a state where a user-initiated check
    /// would proceed (not already mid-check, not blocked by an
    /// in-progress install). The Settings "Check for Updates…"
    /// button binds its `.disabled` modifier to this.
    @Published private(set) var canCheckForUpdates = false

    /// Non-nil when Sparkle's most recent scheduled check found a
    /// newer version. The notch's idle pill subscribes to this and
    /// shows a small olive arrow when set. Cleared once the user
    /// interacts with Sparkle's install sheet.
    @Published private(set) var updateAvailable: SUAppcastItem?

    private let controller: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate

    init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )

        // KVO → @Published bridge. Sparkle exposes `canCheckForUpdates`
        // as a KVO-observable property; the Combine publisher converts
        // it into something SwiftUI views can observe directly.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)

        delegate.onScheduledUpdateFound = { [weak self] update in
            Task { @MainActor in self?.updateAvailable = update }
        }
        delegate.onResolved = { [weak self] in
            Task { @MainActor in self?.updateAvailable = nil }
        }
    }

    /// Trigger a user-initiated check. Sparkle shows its stock
    /// "Checking for Updates…" sheet, then either "You're up to date"
    /// or the install sheet. The user-initiated path is NOT a gentle
    /// reminder. We always show the standard UI here because the
    /// user explicitly asked.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Convenience for views that shouldn't have to `import Sparkle`
    /// just to read a version string.
    var availableVersionString: String? {
        updateAvailable?.displayVersionString ?? updateAvailable?.versionString
    }
}

/// Private delegate that bridges Sparkle's class-based delegate
/// protocols to closure callbacks. Pulled out so `UpdaterManager`'s
/// initializer can pass concrete delegates to the
/// SPUStandardUpdaterController constructor without the `self` chicken-
/// and-egg problem (controller takes delegates at init; `self`
/// isn't available until `super.init` returns).
private final class UpdaterDelegate: NSObject,
                                      SPUUpdaterDelegate,
                                      SPUStandardUserDriverDelegate {
    var onScheduledUpdateFound: ((SUAppcastItem) -> Void)?
    var onResolved: (() -> Void)?

    /// Hand off the "we found a scheduled update" UX to klo's notch
    /// rather than letting Sparkle's default modal steal focus.
    /// User-initiated checks still get the stock UI.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // state.userInitiated == false → background/scheduled check.
        // Don't let Sparkle pop a modal; surface in the notch instead.
        // When the user clicks the notch arrow, we call
        // controller.updater.checkForUpdates() which fires another
        // check with userInitiated=true; that path shows the stock
        // install sheet.
        if !state.userInitiated {
            onScheduledUpdateFound?(update)
        }
    }

    /// Fires after the user clicks our notch arrow (or any other
    /// path that triggers a user-initiated check). Clear the discovery
    /// badge so we don't double-signal once Sparkle's install sheet is
    /// on screen.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onResolved?()
    }
}
