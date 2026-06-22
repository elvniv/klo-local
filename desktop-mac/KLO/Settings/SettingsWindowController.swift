import AppKit
import SwiftUI

/// Hosts the SwiftUI Settings view in its own borderless KloWindow.
/// We strip every Apple default — title bar, traffic lights, system
/// blue tab chip, default focus rings — so the chrome reads as klo,
/// not as "an unfinished System Preferences pane."
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Read-only accessor for KLOWindowController so it can identify
    /// Settings clicks and demote the notch panel's level out from
    /// under Settings's close button. See KLOWindowController's
    /// installKeyWindowObserver for usage.
    var currentWindow: NSWindow? { window }
    private weak var account: AccountManager?

    func configure(account: AccountManager) {
        self.account = account
    }

    func show() {
        guard let account = account else {
            NSLog("KLO Settings: configure() not called yet")
            return
        }
        if let win = window {
            account.recheck()
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(account: account)
        let hosting = NSHostingController(rootView: view)
        // Removing the title bar gives us the full vertical band — bump
        // the content size so the layout breathes.
        let contentRect = NSRect(x: 0, y: 0, width: 460, height: 580)
        hosting.preferredContentSize = contentRect.size
        let win = KloWindow(contentRect: contentRect)
        win.contentViewController = hosting
        win.title = "klo"  // shows up in app switcher / Mission Control only
        win.center()
        win.delegate = self
        self.window = win
        account.recheck()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        account?.recheck()
    }
}
