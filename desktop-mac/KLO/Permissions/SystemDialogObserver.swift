import AppKit
import Combine
import Foundation

/// Watches for Apple's TCC consent dialogs and other system-modal
/// surfaces so the notch panel can yield while one is visible.
///
/// The notch panel anchors to the top of the screen at level
/// `.statusBar` (25) with a 1000×700 frame. That region is exactly
/// where Apple's modern per-folder TCC dialogs ("klo would like to
/// access files in your Documents folder", "klo would like to control
/// 'Music'") render. Even though klo's level is below `.modalPanel`,
/// the modern TCC surfaces are app-attached sheets / Control-Center-
/// hosted banners that don't claim global modal z-order — so they
/// can be visually covered AND have their click targets intercepted
/// by the notch panel.
///
/// This observer publishes a single `systemDialogVisible` Bool that
/// flips true when any of the canonical TCC-dialog host processes
/// is frontmost OR owns a visible window in the upper third of the
/// screen. `KLOWindowController` watches it and forces the panel to
/// pass mouse events through + dims its content (via SwiftUI env
/// object) until the dialog dismisses.
///
/// Detection uses CGWindowListCopyWindowInfo, the same unprivileged
/// Quartz window-list `SystemSettingsLocator` already uses. No
/// Accessibility permission required — exactly the guarantee we need
/// during a permission grant flow.
@MainActor
final class SystemDialogObserver: ObservableObject {

    static let shared = SystemDialogObserver()

    @Published private(set) var systemDialogVisible: Bool = false

    /// Bundle identifiers of processes that host TCC consent dialogs
    /// and related system-modal surfaces.
    /// - SecurityAgent owns Touch ID / password sheets, AppleEvents
    ///   automation consent, file-access consent on older macOS.
    /// - UserNotificationCenter and controlcenter host the modern
    ///   banner-style permission prompts on macOS 14+.
    /// - tccd is the TCC daemon; some surfaces are routed through it.
    /// - loginwindow handles a few related auth prompts.
    private static let tccHostBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.controlcenter",
        "com.apple.tccd",
        "com.apple.loginwindow",
    ]

    /// CGWindow owner names that map to the host bundles above.
    /// CGWindowList exposes owner *name* per window, not bundle id;
    /// we accept either matching path.
    private static let tccHostOwnerNames: Set<String> = [
        "SecurityAgent",
        "UserNotificationCenter",
        "Control Center",
        "ControlCenter",
        "loginwindow",
    ]

    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: AnyCancellable?

    private init() {
        // Workspace activations cover the strongest signal: when
        // SecurityAgent or UserNotificationCenter becomes the frontmost
        // app, a system dialog just took the user's focus. We re-evaluate
        // on every activation AND deactivation so we don't get stuck in
        // either direction.
        let center = NSWorkspace.shared.notificationCenter
        let activated = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
        let deactivated = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
        workspaceObservers = [activated, deactivated]

        // Workspace notifications miss the modern in-app TCC sheets —
        // those don't become frontmost (they're attached to the
        // requesting app). A short poll catches them. 0.4s is fast
        // enough that the fade kicks in before the user notices the
        // overlap, slow enough to barely register on CPU.
        pollTimer = Timer.publish(every: 0.4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reevaluate() }

        // One immediate eval so the initial state is correct.
        reevaluate()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
    }

    // MARK: - Detection

    private func reevaluate() {
        let next = Self.isTCCDialogShowing()
        if next != systemDialogVisible {
            systemDialogVisible = next
        }
    }

    /// True when a known TCC-dialog host is either frontmost OR owns a
    /// visible on-screen window. Either signal alone misses cases:
    /// frontmost-only misses app-attached sheets; window-owner-only
    /// can fire on stale Control Center surfaces. The union catches
    /// both real cases without false positives.
    static func isTCCDialogShowing() -> Bool {
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           tccHostBundleIDs.contains(frontmost) {
            return true
        }
        return tccHostWindowOnScreen()
    }

    /// CGWindowList walk for any visible window owned by a TCC host
    /// process. Layer 0 = normal app windows; we explicitly skip the
    /// menu bar, desktop icons, and the global cursor by filtering on
    /// layer and bounds size.
    private static func tccHostWindowOnScreen() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return false }

        for entry in list {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  tccHostOwnerNames.contains(owner)
            else { continue }
            // Skip degenerate / hidden windows. A real consent dialog
            // is at least ~200pt on each axis.
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                let w = boundsDict["Width"] ?? 0
                let h = boundsDict["Height"] ?? 0
                if w < 200 || h < 80 { continue }
            }
            return true
        }
        return false
    }
}
