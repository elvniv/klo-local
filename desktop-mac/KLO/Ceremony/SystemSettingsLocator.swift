import AppKit
import Foundation

/// Finds the frontmost System Settings (or System Preferences on
/// macOS 12) window and returns its screen-coordinate frame so the
/// drag island can dock itself just below it.
///
/// Uses CGWindowListCopyWindowInfo — plain Quartz window-list, NOT
/// the AX (Accessibility) APIs. That matters: this works even before
/// klo has been granted Accessibility (which is exactly when we need
/// it most — during the permission grant flow).
///
/// Coordinate conversion: kCGWindowBounds is top-left-origin Quartz
/// space; AppKit NSScreen.frame is bottom-left-origin. We flip y
/// against the primary screen's height so the returned NSRect is
/// usable directly with NSWindow.setFrame(...).
enum SystemSettingsLocator {

    /// Owner names we're willing to anchor to. macOS 13+ ships
    /// "System Settings"; macOS 12 was "System Preferences"; older
    /// versions had the same name. Matching either keeps us
    /// compatible across versions without runtime version checks.
    private static let ownerNames: Set<String> = [
        "System Settings",
        "System Preferences"
    ]

    /// Returns the LARGEST System Settings window's frame in AppKit
    /// screen coords (bottom-left origin), or nil if none is on-screen.
    ///
    /// We pick the largest (by area) rather than the frontmost, because
    /// System Settings can spawn smaller child windows — modal sheets,
    /// dropdowns, the Touch ID auth dialog — that are still owned by
    /// the same process. Anchoring to those would yank the island into
    /// the modal's space and obscure the password field / Accept
    /// button. The main window is always the biggest one.
    static func frontmostFrame() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }

        var best: CGRect?
        var bestArea: CGFloat = 0

        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  ownerNames.contains(owner),
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            let qx = boundsDict["X"] ?? 0
            let qy = boundsDict["Y"] ?? 0
            let qw = boundsDict["Width"] ?? 0
            let qh = boundsDict["Height"] ?? 0

            // Skip degenerate / minimized-to-Dock windows AND skip
            // small modal sheets — the main Settings window is at
            // least ~600pt wide.
            guard qw >= 500, qh >= 400 else { continue }

            let area = qw * qh
            if area <= bestArea { continue }

            let primaryHeight = NSScreen.screens.first?.frame.height
                ?? NSScreen.main?.frame.height
                ?? qh
            let appKitY = primaryHeight - qy - qh
            best = CGRect(x: qx, y: appKitY, width: qw, height: qh)
            bestArea = area
        }
        return best
    }

    /// True when a system auth panel (Touch ID prompt, password sheet)
    /// is currently the frontmost app. The drag island should hide
    /// while this is true — once klo is in the Privacy list, the
    /// island has done its job and the user needs to interact with the
    /// auth panel without anything covering it.
    static func authPromptIsFrontmost() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // SecurityAgent owns Touch ID / password sheets that elevate
        // privacy toggles. loginwindow handles a few related prompts.
        return id == "com.apple.SecurityAgent" || id == "com.apple.loginwindow"
    }

    /// True only when System Settings (or legacy System Preferences) is
    /// the frontmost application — i.e., the user is actually looking
    /// at it, not just that it's running in the background.
    ///
    /// `frontmostFrame()` above can return non-nil for a Settings
    /// window that's buried behind other apps (CGWindowList's
    /// `optionOnScreenOnly` means "not minimized to the Dock", not
    /// "the user can see it"). For card-show gating we want strict
    /// "Settings is the active app" semantics so the instruction card
    /// only appears when the user is actually in Settings.
    static func settingsIsFrontmost() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return id == "com.apple.systempreferences"
    }
}
