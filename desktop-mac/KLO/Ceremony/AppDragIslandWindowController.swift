import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Small "drag klo here" island that DOCKS to the bottom of System
/// Settings during a permission handoff. macOS Sequoia tightened TCC:
/// apps don't appear in Privacy lists (Accessibility, Screen Recording)
/// until the user explicitly adds them via the `+` button OR drags the
/// .app onto the list. This island shows klo's actual app icon, large
/// + bobbing + draggable — the user grabs it and drops it onto System
/// Settings's Privacy list, macOS adds klo as an entry. Same UX as
/// Loom / CleanShot / Cluely.
///
/// The icon's drag carries `Bundle.main.bundleURL` as a `public.file-url`
/// — System Settings accepts file-URL drops and treats it identically
/// to dragging klo.app from Finder. We use AppKit's NSDraggingSource
/// directly (not SwiftUI's `.onDrag`) so we get a deterministic
/// `draggingSession(_:endedAt:operation:)` callback when the user drops
/// — that's the signal the coordinator uses to schedule the relaunch
/// that picks up the new TCC trust.
@MainActor
final class AppDragIslandState: ObservableObject {
    @Published var current: Handoff = .accessibility
    @Published var stepNumber: Int = 1
    @Published var totalSteps: Int = 2
}

/// Notification posted when the user drops klo's icon (regardless of
/// where — accepted or not). The coordinator listens and, if the drop
/// landed somewhere that accepted it, schedules a relaunch ~1.4s later
/// to give TCC time to record the grant before the new process boots.
extension Notification.Name {
    static let kloPermissionDragEnded = Notification.Name("klo.permission.dragEnded")
}

/// userInfo key carrying `NSDragOperation.rawValue` (`UInt`). `0` means
/// the user dropped into nothing / cancelled; non-zero means a target
/// accepted the drop.
let kloPermissionDragOperationKey = "operation"

@MainActor
final class AppDragIslandWindowController {

    /// Shared singleton — both the cloud-onboarding handoff AND the
    /// runtime "permissionRequired" path surface the island, and we
    /// want the same visual instance to handle both (no duplicate
    /// panels stacking).
    static let shared = AppDragIslandWindowController()

    private var panel: AppDragIslandPanel?

    /// 5 Hz timer that re-checks System Settings's window position and
    /// re-docks the island below it. Started on show, stopped on dismiss.
    /// Without this the island would only get its initial position and
    /// not follow if the user dragged Settings around. Same timer hides
    /// the island when an auth modal (Touch ID / password) becomes
    /// frontmost — the user needs an unobstructed path to the password
    /// field; re-shows when the modal closes.
    private var trackingTimer: Timer?

    /// Active-permission context, observed by the SwiftUI view so its
    /// headline + subtitle stay in sync with what the user is granting.
    let state = AppDragIslandState()

    /// Show the island for a specific permission. Updates `state` so
    /// the view's headline reflects "Add klo to {permission}". Idempotent
    /// — calling for a different permission just rebinds state.
    func show(for permission: Handoff, stepNumber: Int = 1, totalSteps: Int = 2) {
        // Drag island is permission-only — chrome handoff has no list-
        // adding step. Defensive guard so a misuse doesn't render a
        // confusing island over Chrome.
        guard permission.isPermission else { return }
        state.current = permission
        state.stepNumber = stepNumber
        state.totalSteps = totalSteps
        showPanelIfNeeded()
    }

    /// Back-compat overload — used in places that don't yet pass a
    /// permission. Defaults to current state.
    func show() {
        showPanelIfNeeded()
    }

    private func showPanelIfNeeded() {
        let view = AppDragIslandView()
            .environmentObject(state)
        let host = NSHostingController(rootView: view)
        host.preferredContentSize = NSSize(
            width: AppDragIslandPanel.width,
            height: AppDragIslandPanel.height
        )

        // Only flash the panel forward immediately if System Settings is
        // actually the frontmost app right now. Otherwise we create the
        // panel but leave it hidden — the tracking timer will orderFront
        // it the moment Settings becomes frontmost (after the user
        // clicks "Open System Preferences" on Apple's native consent
        // dialog, or after Settings finishes cold-launching from the
        // URL deep-link the orchestrator just fired).
        //
        // Strict frontmost check, not `frontmostFrame() != nil` — the
        // latter is true for any Settings window on-screen including
        // ones buried under other apps. Showing the card while Settings
        // is buried is the bug the user reported.
        let settingsAlreadyOpen = SystemSettingsLocator.settingsIsFrontmost()

        if let existing = panel {
            existing.contentViewController = host
            existing.setFrame(idealFrame(), display: settingsAlreadyOpen)
            if settingsAlreadyOpen {
                existing.orderFrontRegardless()
            }
            return
        }

        let p = AppDragIslandPanel(contentRect: idealFrame())
        p.contentViewController = host
        p.setFrame(idealFrame(), display: false)
        if settingsAlreadyOpen {
            p.orderFrontRegardless()
        }
        panel = p
        startTracking()
    }

    func dismiss() {
        stopTracking()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Sit the island AT the bottom of System Settings, overlapping its
    /// lower rows. Centered horizontally on Settings's midX, bottom
    /// edge inset 14pt up from Settings's bottom edge. Reads as "a
    /// little island at the bottom of the settings page" — exactly the
    /// placement the user picked from the layout sketch.
    ///
    /// Falls back to center-left of the screen if Settings isn't found
    /// yet (just-opened race / user minimized it).
    private func idealFrame() -> NSRect {
        let panelW = AppDragIslandPanel.width
        let panelH = AppDragIslandPanel.height

        if let settings = SystemSettingsLocator.frontmostFrame() {
            let originX = settings.midX - panelW / 2
            // AppKit coords: settings.minY is Settings's BOTTOM edge.
            // origin.y is the island's BOTTOM edge. +14pt floats the
            // island just above Settings's bottom border.
            let originY = settings.minY + 14
            let target = NSRect(x: originX, y: originY, width: panelW, height: panelH)
            return clampToVisibleScreen(target, near: settings)
        }
        return defaultFrame(width: panelW, height: panelH)
    }

    /// Center-left fallback when System Settings can't be located.
    private func defaultFrame(width: CGFloat, height: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: width, height: height)
        }
        let frame = screen.frame
        let originX = frame.minX + frame.width * 0.10
        let originY = frame.midY - height / 2
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    /// Keep the island on-screen and within Settings's horizontal
    /// bounds. Vertical position is intentionally fixed (overlap
    /// bottom of Settings); we only correct horizontal overflow if
    /// Settings sits very close to a screen edge.
    private func clampToVisibleScreen(_ rect: NSRect, near anchor: CGRect) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return rect }

        var r = rect
        if r.minX < visible.minX {
            r.origin.x = visible.minX + 8
        }
        if r.maxX > visible.maxX {
            r.origin.x = visible.maxX - r.width - 8
        }
        return r
    }

    // MARK: - Tracking timer (dock + auth-modal hide)

    private func startTracking() {
        stopTracking()
        // 5 Hz. Slow enough to barely register on CPU, fast enough that
        // dragging Settings around feels like the island is glued to it.
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard let panel = self.panel else { return }
                // Touch ID / password modal up → get out of the way.
                // The island has done its job (klo is in the Privacy
                // list); the user now needs an unobstructed path to the
                // password field. Restore as soon as the auth modal
                // closes (in case the user cancels).
                if SystemSettingsLocator.authPromptIsFrontmost() {
                    if panel.isVisible { panel.orderOut(nil) }
                    return
                }
                // Only show the instruction card once System Settings is
                // actually the frontmost app — i.e., the user can see
                // it. Before that, Apple's own native consent dialog
                // ("klo would like to control your computer using
                // accessibility features") is up, or Settings is still
                // cold-launching, or Settings is buried behind other
                // apps. In all those cases the card would compete with
                // whatever IS on screen, or worse, float on the desktop
                // with no Settings window for context.
                //
                // Strict frontmost-app check, not "any Settings window
                // is on-screen somewhere" — the loose check was what
                // caused the bug where the card appeared even though
                // Settings was buried.
                guard SystemSettingsLocator.settingsIsFrontmost() else {
                    if panel.isVisible { panel.orderOut(nil) }
                    return
                }
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
                let target = self.idealFrame()
                let delta = abs(panel.frame.origin.x - target.origin.x)
                    + abs(panel.frame.origin.y - target.origin.y)
                if delta > 0.5 {
                    panel.setFrame(target, display: false)
                }
            }
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }
}


// ─────────────────────────────────────────────────────────────────────
// Panel — borderless floating NSPanel. ignoresMouseEvents = false so
// the icon's drag gesture works.
// ─────────────────────────────────────────────────────────────────────

final class AppDragIslandPanel: NSPanel {
    // Small "little island" — sized so it can dock under even a tall
    // System Settings window without overflowing the screen. The
    // horizontal layout (icon left, label right) keeps it short.
    static let width: CGFloat = 200
    static let height: CGFloat = 168

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // CRITICAL: must accept mouse events so the icon drag works.
        ignoresMouseEvents = false
    }

    // Stay non-key — the drag gesture works without us being key, and
    // staying non-key means System Settings keeps text focus / doesn't
    // get bumped when this panel appears.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// ─────────────────────────────────────────────────────────────────────
// AppKit drag source — wraps NSDraggingSource so we get a deterministic
// drop callback (the SwiftUI .onDrag modifier doesn't expose one). On
// drop we post `.kloPermissionDragEnded` with the operation in userInfo;
// the coordinator listens and schedules a relaunch when the operation
// is non-zero (drop accepted by some target — usually Settings).
// ─────────────────────────────────────────────────────────────────────

final class DraggableIconNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var iconImage: NSImage?

    override var isFlipped: Bool { false }

    /// CRITICAL: when System Settings (or any other app) is the active
    /// app and the user clicks our icon, macOS would normally consume
    /// the first click as "bring klo's panel forward" — never delivering
    /// mouseDown to our view, so beginDraggingSession never runs. Same
    /// problem when klo's notch is the active panel (in the runtime
    /// preflight case): the notch panel sits at .statusBar (25), this
    /// drag-island panel sits at .floating (3) — clicks on the icon
    /// would otherwise need a second click to land. Returning true
    /// passes the first click straight through to mouseDown, the drag
    /// starts immediately, and the drag-end signal can fire.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let fileURL = fileURL, let iconImage = iconImage else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        // Render the dragging-image at the icon's actual frame so the
        // ghost the user sees while dragging matches what they grabbed.
        let frame = NSRect(origin: .zero, size: bounds.size)
        item.setDraggingFrame(frame, contents: iconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // .copy lets Settings's Privacy list accept the drop the same
        // way it accepts klo.app dragged from Finder.
        return [.copy, .generic]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Post the drag-end notification so listeners can act if needed.
        // No relaunch — with the Mac app being the TCC consumer, the
        // running process reads live trust the moment the user toggles
        // the switch in Settings. PermissionMonitor's poll picks it up
        // within ~0.4s and the orchestrator dismisses + auto-retries.
        NotificationCenter.default.post(
            name: .kloPermissionDragEnded,
            object: nil,
            userInfo: [kloPermissionDragOperationKey: operation.rawValue]
        )
    }
}

struct DraggableAppIcon: NSViewRepresentable {
    let fileURL: URL
    let iconImage: NSImage

    func makeNSView(context: Context) -> DraggableIconNSView {
        let v = DraggableIconNSView()
        v.fileURL = fileURL
        v.iconImage = iconImage
        // Show the icon visually inside the drag-source view via a
        // child NSImageView. The wrapper NSView itself doesn't draw
        // anything; it just provides the drag-source machinery.
        let img = NSImageView(image: iconImage)
        img.imageScaling = .scaleProportionallyUpOrDown
        img.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(img)
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            img.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            img.topAnchor.constraint(equalTo: v.topAnchor),
            img.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    func updateNSView(_ nsView: DraggableIconNSView, context: Context) {
        nsView.fileURL = fileURL
        nsView.iconImage = iconImage
    }
}


// ─────────────────────────────────────────────────────────────────────
// SwiftUI body — small docked island: 64pt klo icon on the orange well
// (left) + "DRAG KLO → into the list" caption (right). Step indicator
// at the top mirrors the reminder pill's cadence.
// ─────────────────────────────────────────────────────────────────────

struct AppDragIslandView: View {
    @EnvironmentObject var state: AppDragIslandState

    private let bundleURL: URL = Bundle.main.bundleURL

    /// The actual klo app icon (the same NSImage shown in the Dock —
    /// black squircle + white klo). Pulled live from the bundle so it
    /// matches whatever the user sees in their Dock.
    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            paneIndicator
            instructionCard
            subhead
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: AppDragIslandPanel.width,
               height: AppDragIslandPanel.height,
               alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KloColors.bgSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(KloColors.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
    }

    // MARK: - Pane indicator
    //
    // Names the Privacy pane the user is currently on. Replaces the
    // previous "Step 1 of 2" counter — the runtime-denial path is a
    // single permission at a time, and the onboarding chained flow
    // already has its own step indicator in the reminder pill.

    private var paneIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KloColors.olive)
                .frame(width: 6, height: 6)
                .modifier(KloFireGlow(active: true, radius: 6))
            Text(state.current.label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(KloColors.fg60)
                .id(state.current)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: state.current)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Instruction card
    //
    // Replaces the drag-into-list affordance. On macOS 14+ klo is
    // automatically added to the Privacy list the first time it
    // requests the permission; the user's action is to flip the
    // existing toggle. Drag was the wrong metaphor and confused users
    // when klo was already listed. This card guides them to the
    // toggle with an icon, an arrow, and a one-line instruction.

    private var instructionCard: some View {
        HStack(spacing: 10) {
            // klo app icon (black squircle + white klo) — static, not
            // draggable. Icon serves as a visual identifier so the user
            // can find the matching row in Settings's app list.
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

            Image(systemName: "arrow.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))

            VStack(alignment: .leading, spacing: 2) {
                Text("Toggle klo on")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("in System Settings")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KloColors.olive)
        )
    }

    // MARK: - Subhead — what the permission unlocks (per service)

    private var subhead: some View {
        Text(subheadCopy)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(KloColors.fg60)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subheadCopy: String {
        switch state.current {
        case .accessibility:
            return "Lets klo click and type for you."
        case .screenRecording:
            return "Lets klo see your screen during a task."
        case .chromeExtension:
            return "Install the klo extension to drive your browser."
        case .googleSignIn:
            return "Sign in to start using klo."
        }
    }
}
