import AppKit
import Combine
import Foundation

/// Single source of truth for "is the klo Chrome extension currently
/// connected to our local sidecar?" — surfaced as a @Published Bool
/// so SwiftUI views (the onboarding card AND the runtime missing-
/// extension panel) can update live as the user installs / quits /
/// re-launches Chrome.
///
/// The agent2 sidecar already exposes the bridge state at
/// `GET http://127.0.0.1:8787/health` → `subsystems.chrome_extension`.
/// We poll it on the same 1.5s cadence the PermissionsManager uses,
/// so the brand stays consistent: cards flip without the user having
/// to leave klo and come back.
@MainActor
final class BridgeStatusManager: ObservableObject {

    /// True when the sidecar reports the Chrome extension is
    /// connected to its `/extension` WebSocket. False covers all of:
    /// extension not installed, Chrome closed, user signed out of
    /// Chrome — we can't distinguish those, by design.
    @Published private(set) var extensionConnected: Bool = false

    /// True when the sidecar answered the last /health poll at all.
    /// False means klo's OWN agent process is down — a different
    /// failure from "extension not connected", and views consult this
    /// so they don't blame the extension for a dead sidecar.
    @Published private(set) var sidecarReachable: Bool = true

    /// True if we've never received a sidecar response yet, so the
    /// onboarding card can show a quiet "checking…" state instead of
    /// flashing "not connected" before the first poll completes.
    @Published private(set) var hasFirstResponse: Bool = false

    /// True when ANY Chromium-family browser is installed on this Mac.
    /// The klo Web Store listing installs into Chrome, Edge, Brave, Arc,
    /// Dia, Vivaldi, Opera, Chromium — anything that ships with the
    /// Chrome Web Store runtime — so the install CTAs branch on this:
    /// no Chromium browser → point at the Chrome download page instead
    /// of a Web Store the user can't use. Refreshed on the same poll
    /// cadence so the copy flips live the moment a browser lands in
    /// /Applications. Optimistic `true` default avoids flashing
    /// "get Chrome" before the first check.
    ///
    /// Property name kept as `chromeInstalled` for source compatibility
    /// with call sites that pre-date the family expansion. Semantically
    /// it now means "Web Store reachable from this Mac."
    @Published private(set) var chromeInstalled: Bool = true

    static let webStoreURL = URL(string: "https://github.com/klo-local/klo-local/blob/main/docs/extension.md")!
    static let chromeDownloadURL = URL(string: "https://www.google.com/chrome/")!

    /// Bundle IDs we accept as "Chromium-family." Order is irrelevant —
    /// presence of ANY one flips `chromeInstalled` to true. Verified
    /// IDs only (don't guess; an unknown ID resolves to nil and the
    /// `if-let-installed` branch never fires, which silently treats a
    /// real Chromium browser as missing).
    private static let chromiumFamilyBundleIDs: [String] = [
        "com.google.Chrome",           // Google Chrome stable
        "com.google.Chrome.beta",      // Chrome Beta
        "com.google.Chrome.canary",    // Chrome Canary
        "com.brave.Browser",           // Brave
        "company.thebrowser.Browser",  // Arc
        "company.thebrowser.dia",      // Dia (Browser Company)
        "com.microsoft.edgemac",       // Microsoft Edge
        "org.chromium.Chromium",       // open-source Chromium
        "com.vivaldi.Vivaldi",         // Vivaldi
        "com.operasoftware.Opera",     // Opera
    ]

    private let healthURL = URL(string: "http://127.0.0.1:8787/health")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Aggressive timeout — we'd rather miss a tick than back up
        // on a hung sidecar.
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 1.5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private var poller: AnyCancellable?

    init() {
        // Mirror PermissionsManager's 1.5s Timer.publish cadence so
        // the bridge card and the OS-permission cards refresh at the
        // same beat. Visually consistent and simple to reason about.
        poller = Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
        // Fire one immediately so the UI doesn't sit on `false` for
        // 1.5s after launch when the bridge is actually live already.
        Task { @MainActor in self.tick() }
    }

    deinit { poller?.cancel() }

    /// Open the right install destination: the Web Store listing when
    /// Chrome is present, the Chrome download page when it isn't (the
    /// Web Store can't install into a browser that doesn't exist).
    func openInstall() {
        refreshChromeInstalled()
        NSWorkspace.shared.open(chromeInstalled ? Self.webStoreURL : Self.chromeDownloadURL)
    }

    /// Force a fresh poll (e.g. immediately after the user tapped
    /// "Install" in the runtime card so the Retry button can lift
    /// out of its disabled state without waiting for the next tick).
    func recheck() {
        tick()
    }

    private func tick() {
        refreshChromeInstalled()
        Task { [weak self] in
            await self?.poll()
        }
    }

    private func refreshChromeInstalled() {
        let installed = Self.chromiumFamilyBundleIDs.contains { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
        if chromeInstalled != installed {
            chromeInstalled = installed
        }
    }

    private func poll() async {
        do {
            let (data, _) = try await session.data(from: healthURL)
            let connected = Self.parseConnected(from: data)
            await MainActor.run {
                self.applyConnectedState(connected, reachable: true)
            }
        } catch {
            // Sidecar itself is unreachable — distinct from "extension
            // not connected" so views can show "klo's agent is down"
            // instead of blaming the extension.
            await MainActor.run {
                self.applyConnectedState(false, reachable: false)
            }
        }
    }

    private func applyConnectedState(_ connected: Bool, reachable: Bool) {
        if !hasFirstResponse {
            hasFirstResponse = true
        }
        // Avoid spurious objectWillChange when the value didn't move,
        // so SwiftUI views don't re-render every 1.5s for nothing.
        if extensionConnected != connected {
            extensionConnected = connected
        }
        if sidecarReachable != reachable {
            sidecarReachable = reachable
        }
    }

    /// Parses the sidecar /health JSON shape:
    ///   { "ok": true, "subsystems": { "chrome_extension": "connected", … }, … }
    private static func parseConnected(from data: Data) -> Bool {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let subsystems = json["subsystems"] as? [String: Any],
            let chrome = subsystems["chrome_extension"] as? String
        else { return false }
        return chrome.lowercased() == "connected"
    }
}
