import AppKit
import Combine

// Geometry of the notch on the screen klo currently lives on. The
// detector trusts Apple's official APIs (NSScreen.safeAreaInsets and
// NSScreen.auxiliaryTop{Left,Right}Area) — values come from the
// hardware itself, so they're correct on every MacBook variant
// without per-model calibration.
//
// Reference values (for verification, not hard-coded):
//
//   Model                              | width | height
//   -----------------------------------+-------+--------
//   MacBook Pro 14" M1/M2/M3 Pro/Max   | ~190  | 32 / 38
//   MacBook Pro 16" M1/M2/M3 Pro/Max   | ~210  | 32 / 38
//   MacBook Air 13" M2/M3              | ~190  | 32
//   MacBook Air 15" M2/M3              | ~210  | 32
//
// The 32pt → 38pt jump is a macOS Sequoia behavior change on some
// models; safeAreaInsets.top reports whichever value the running OS
// actually uses for menu-bar layout. Trust the API, not the table.
//
// Non-notched displays (hasNotch = false):
//   - Intel-era MacBook Pros (pre-2021)
//   - 13" Touch Bar MacBook Pros
//   - Mac mini, Mac Studio, Mac Pro
//   - All external monitors (when used as the main display)
//   - MacBook with lid closed + external display
struct NotchGeometry: Equatable {
    let hasNotch: Bool
    /// Vertical extent of the notch / menu bar in points.
    let height: CGFloat
    /// Horizontal extent of the notch in points.
    let width: CGFloat
    /// Left edge of the notch in screen-frame coordinates (points).
    let originX: CGFloat
    let screenFrame: CGRect

    static let none: NotchGeometry = NotchGeometry(
        hasNotch: false, height: 0, width: 0, originX: 0, screenFrame: .zero
    )
}

@MainActor
final class NotchDetector: ObservableObject {

    @Published private(set) var geometry: NotchGeometry = .none
    @Published private(set) var screen: NSScreen?

    private var screenChangeObserver: NSObjectProtocol?

    init() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Recompute notch geometry. `targetScreen` lets the window
    /// controller force a probe on a specific display when the user
    /// switches focus across monitors.
    func refresh(on targetScreen: NSScreen? = nil) {
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        self.screen = screen
        let g = Self.computeGeometry(for: screen)
        self.geometry = g
        let label = screen?.localizedName ?? "unknown"
        if g.hasNotch {
            NSLog("KLO: notch detected on \(label) → width=\(g.width)pt height=\(g.height)pt originX=\(g.originX) screen=\(Int(g.screenFrame.width))×\(Int(g.screenFrame.height))")
        } else {
            NSLog("KLO: no notch on \(label) (screen=\(screen.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "nil")) — using fallback pill")
        }
    }

    /// Pure geometry computation — no side effects. Used by the live
    /// detector and any test/reasoning code that wants to ask "would
    /// THIS screen have a notch?" without affecting cached state.
    static func computeGeometry(for screen: NSScreen?) -> NotchGeometry {
        guard let screen else { return .none }
        let frame = screen.frame
        let safeAreaTop = screen.safeAreaInsets.top
        let leftAux = screen.auxiliaryTopLeftArea
        let rightAux = screen.auxiliaryTopRightArea

        // STRICT has-notch check: ALL of (safe area top > 0) AND (both
        // auxiliary areas exist). Some non-notched scenarios report a
        // safe area top from the menu bar without auxiliary areas — we
        // treat those as no-notch and use the fallback pill renderer.
        guard safeAreaTop > 0,
              let leftAuxRect = leftAux,
              let rightAuxRect = rightAux,
              leftAuxRect.width > 0,
              rightAuxRect.width > 0
        else {
            return NotchGeometry(
                hasNotch: false,
                height: 0,
                width: 0,
                originX: 0,
                screenFrame: frame
            )
        }

        // Notch x-bounds derived from menu-bar regions on either side.
        // auxiliaryTopLeftArea covers the "apple menu" side; its maxX
        // is the notch's left edge. auxiliaryTopRightArea covers the
        // status-icons side; its width subtracted from the screen width
        // gives the notch's right edge.
        let notchMinX = leftAuxRect.maxX
        let notchMaxX = frame.width - rightAuxRect.width
        let notchWidth = max(0, notchMaxX - notchMinX)

        // Sanity guard: if the math gives a degenerate width, treat as
        // no-notch rather than rendering something wrong.
        guard notchWidth >= 100 else {
            return NotchGeometry(hasNotch: false, height: 0, width: 0,
                                 originX: 0, screenFrame: frame)
        }

        return NotchGeometry(
            hasNotch: true,
            height: safeAreaTop,
            width: notchWidth,
            originX: notchMinX,
            screenFrame: frame
        )
    }
}
