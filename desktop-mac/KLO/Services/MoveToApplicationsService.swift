import AppKit
import Foundation

/// Tells callers where klo is currently running from on disk. On
/// macOS 15 Sequoia, several TCC permissions (notably Screen Recording)
/// only stick reliably for apps in `/Applications/`. Apps running from
/// `~/Downloads`, `~/Library/Developer/Xcode/DerivedData/`, or
/// `~/Desktop` never even appear in the Privacy list — the OS refuses
/// to trust them at those paths.
enum AppLocation {
    /// True when klo is running from a path macOS considers
    /// "installed" (i.e. /Applications or /System/Applications).
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") ||
               path.hasPrefix("/System/Applications/")
    }

    /// Short, user-readable description of where klo is running from.
    /// Used in the Move-to-Applications card body so the user can
    /// see why klo wants to move ("klo is currently running from
    /// DerivedData…").
    static var shortPath: String {
        let path = Bundle.main.bundlePath
        if path.hasPrefix(NSHomeDirectory()) {
            return "~" + String(path.dropFirst(NSHomeDirectory().count))
        }
        return path
    }
}


/// Copies the running klo.app to `/Applications/KLO.app`, then triggers
/// a clean relaunch from the new path. The user is the one initiating
/// this (via the Move card on the Permissions step), so we don't ask
/// for confirmation here — caller already did.
///
/// If `/Applications/KLO.app` already exists from a previous move, we
/// overwrite it (`try? FileManager.default.removeItem` first). Same
/// behavior as dragging an app from a DMG when an older copy is there.
@MainActor
enum MoveToApplicationsService {

    enum MoveError: Error {
        case sourceNotFound
        case copyFailed(underlying: Error)
        /// Destination needs admin rights (writing to /Applications
        /// requires being the user or having authorization). On a
        /// normal user account this should just work.
        case destinationNotWritable
    }

    /// Copies + relaunches. Returns true on a successful copy (then
    /// relaunches, so the function call doesn't really "return" from
    /// the user's perspective). False on failure — the caller surfaces
    /// the error to the user.
    @discardableResult
    static func moveAndRelaunch() -> Bool {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/KLO.app")

        // Make sure source exists (defensive — Bundle.main.bundleURL
        // is always real, but sanity check).
        guard FileManager.default.fileExists(atPath: source.path) else {
            NSLog("KLO Move: source bundle missing at \(source.path)")
            return false
        }

        // Remove any existing /Applications/KLO.app from a prior move.
        // Ignored if it doesn't exist.
        try? FileManager.default.removeItem(at: destination)

        // Copy the bundle. FileManager.copyItem preserves the bundle
        // structure (it's just a directory copy under the hood).
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            NSLog("KLO Move: copied \(source.path) → \(destination.path)")
        } catch {
            NSLog("KLO Move: copy failed: \(error)")
            return false
        }

        // Mark Sparkle / launch services aware of the new location.
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        // Then immediately close the Finder selection (we don't want
        // to leave the user in Finder).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for app in NSWorkspace.shared.runningApplications
                where app.bundleIdentifier == "com.apple.finder" {
                // We just briefly highlighted in Finder for OS-level
                // registration; we don't actually need it foregrounded.
                // No-op — let the user keep whatever they had focused.
                _ = app
            }
        }

        // Relaunch from the new path. The RelaunchService accepts an
        // override; that'll spawn a helper that re-opens the moved
        // bundle once we exit, then we call NSApp.terminate.
        RelaunchService.relaunch(at: destination.path)
        return true
    }
}


/// First-launch "Move klo to Applications?" prompt. Shown BEFORE any
/// onboarding or permission flow — on Sequoia, TCC grants only stick
/// for apps in /Applications, so asking mid-permission was too late
/// (the user would grant, the grant wouldn't hold, and they'd be
/// asked again). Skippable; a decline is remembered so we never nag.
@MainActor
enum MoveToApplicationsPrompt {

    private static let skippedKey = "klo.skippedMoveToApplications"

    /// Returns true when a move + relaunch was started — the caller
    /// should stop the rest of its launch sequence (the app is about
    /// to terminate and reopen from /Applications).
    @discardableResult
    static func promptIfNeeded() -> Bool {
        guard !AppLocation.isInApplications else { return false }
        guard !UserDefaults.standard.bool(forKey: skippedKey) else { return false }

        let alert = NSAlert()
        alert.messageText = "Move klo to your Applications folder?"
        alert.informativeText = "klo is running from \(AppLocation.shortPath). macOS only remembers permissions like Screen Recording for apps in the Applications folder — moving now means you won't have to grant them twice. klo will move itself and reopen in a few seconds."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: skippedKey)
            NSLog("KLO Move: user skipped move-to-Applications at first launch")
            return false
        }
        if MoveToApplicationsService.moveAndRelaunch() {
            return true
        }
        NSLog("KLO Move: first-launch move failed — continuing from current location")
        return false
    }
}
