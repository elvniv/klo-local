import SwiftUI

// klo is a menu-bar-less, dock-less app — the notch line is the only UI.
// Info.plist sets LSUIElement=true so AppKit doesn't auto-create a Dock
// icon or main menu. The Settings scene below satisfies the SwiftUI App
// protocol's Scene requirement without producing any window of its own.
@main
struct KLOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
