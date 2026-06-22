import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import CuaDriverCore

/// Implements the TCC-restricted primitive operations: screenshot,
/// click, mouse move, drag, type, paste, key, hold key, scroll, cursor
/// position. Reference impl is `api/core/screenshot.py` +
/// `api/core/input.py` (Python). All calls run in the Mac app's
/// process — TCC trust check + actual OS dispatch happen here.
@MainActor
final class MacOpsExecutor {

    static let shared = MacOpsExecutor()
    private init() {}

    /// Shared cua-driver WindowCapture actor. Holds no per-call state;
    /// reused so we don't pay actor-init each screenshot.
    private let windowCapture = WindowCapture()

    /// Background-mode toggle for cua MouseInput. When true, even
    /// frontmost-target clicks route via SkyLight pid-pinned post —
    /// the system cursor stays where the user put it. The few apps
    /// that require cghidEventTap (Blender, Unity viewports, etc.)
    /// won't see those clicks; klo's targets are browsers, Gmail,
    /// Notion, Linear, Slack — all happy with pid-routed delivery.
    private static let useBackgroundMode = true

    // MARK: - Screenshot

    /// `scope == "window"` captures only the frontmost (or named) app's
    /// windows via cua's `WindowCapture` (window-cropped, correct
    /// multi-display scaleFactor). Otherwise full primary display via
    /// SCShareableContent so we can exclude klo's own panels from the
    /// shot — without this, the notch panel + chat overlay end up in
    /// every screenshot and the model treats its own UI as a target.
    /// Returns `{ok, base64_png, geometry}` matching
    /// `api.core.screenshot.Screenshot`'s shape, plus `scale_factor` in
    /// geometry for callers that want explicit pixel↔point ratio.
    func screenshot(scope: String?, appName: String?) async throws -> [String: Any] {
        let useWindowScope = (scope ?? "desktop") == "window"

        if useWindowScope, let pid = resolveAppPid(byName: appName) {
            if let result = try await screenshotWindowCua(pid: pid) {
                return result
            }
            // Window-scope had no captureable window for this app — fall
            // through to desktop scope. Same defense as before.
        }

        // Desktop scope (or window-scope fallback): keep SCShareableContent
        // path because cua's captureMainDisplay doesn't expose an
        // excluding-apps filter and we need to filter out klo's panels.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw MacOpsError("ScreenCaptureKit reported no displays")
        }
        let excludedApps = kloRunningApp(in: content).map { [$0] } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.showsCursor = true
        config.width = display.width
        config.height = display.height

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let logical = Self.mainLogicalSize()
        let scale = imageWidth > 0 && logical.width > 0
            ? Double(imageWidth) / Double(logical.width) : 1.0

        let withCursor = drawCursorCrosshair(
            cgImage: cgImage,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            logicalWidth: logical.width,
            logicalHeight: logical.height
        ) ?? cgImage

        let png = try Self.pngData(from: withCursor)
        let base64 = png.base64EncodedString()

        return [
            "ok": true,
            "base64_png": base64,
            "geometry": [
                "image_w": imageWidth,
                "image_h": imageHeight,
                "logical_w": logical.width,
                "logical_h": logical.height,
                "scale_factor": scale,
            ],
        ]
    }

    /// Window-scope screenshot via cua. Returns nil if the pid has no
    /// captureable window so the caller can fall through to desktop.
    /// Image is window-cropped — geometry's logical_w/h reflect the
    /// window's frame in points, NOT the display.
    private func screenshotWindowCua(pid: pid_t) async throws -> [String: Any]? {
        guard let target = WindowCapture.selectFrontmostWindow(forPid: pid) else {
            return nil
        }
        let shot: Screenshot
        do {
            shot = try await windowCapture.captureWindow(
                windowID: UInt32(target.id), format: .png, quality: 95
            )
        } catch CaptureError.windowNotFound {
            return nil
        }
        // Decode → draw crosshair → re-encode so the model still sees
        // where the cursor is relative to the window.
        guard let provider = CGDataProvider(data: shot.imageData as CFData),
              let cgImage = CGImage(
                pngDataProviderSource: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            // Fall back to the raw bytes if decode fails.
            return [
                "ok": true,
                "base64_png": shot.imageData.base64EncodedString(),
                "geometry": [
                    "image_w": shot.width,
                    "image_h": shot.height,
                    "logical_w": target.bounds.width,
                    "logical_h": target.bounds.height,
                    "scale_factor": shot.scaleFactor,
                ],
            ]
        }
        let withCursor = drawCursorCrosshairForWindow(
            cgImage: cgImage,
            imageWidth: shot.width,
            imageHeight: shot.height,
            windowBounds: target.bounds
        ) ?? cgImage
        let png = try Self.pngData(from: withCursor)
        return [
            "ok": true,
            "base64_png": png.base64EncodedString(),
            "geometry": [
                "image_w": shot.width,
                "image_h": shot.height,
                "logical_w": target.bounds.width,
                "logical_h": target.bounds.height,
                "scale_factor": shot.scaleFactor,
            ],
        ]
    }

    /// Resolve appName (case-insensitive) to a pid. Falls back to the
    /// frontmost app's pid when name is empty/nil.
    private func resolveAppPid(byName name: String?) -> pid_t? {
        let running = NSWorkspace.shared.runningApplications
        if let raw = name?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let target = raw.lowercased()
            if let hit = running.first(where: { ($0.localizedName ?? "").lowercased() == target }) {
                return hit.processIdentifier
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Capture a region of the screen centered on (x, y) at `zoomFactor`.
    /// Returns the cropped image in the same shape as `screenshot()`. The
    /// model uses this to inspect a tight region at higher visual density
    /// when the full screenshot is too zoomed out for precise targeting.
    ///
    /// Coordinates are IMAGE-SPACE pixels (same space the model sees in
    /// regular screenshots). zoomFactor>=1.0 — factor 2.0 crops a window
    /// half the screen's pixel dimensions; factor 4.0 crops a quarter.
    /// If x/y aren't provided, defaults to screen center.
    func zoom(x: Int?, y: Int?, zoomFactor: Double) async throws -> [String: Any] {
        // Reuse the full-display capture. Pass scope=nil so the existing
        // path picks the desktop-scope filter (which already excludes
        // klo's own windows).
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw MacOpsError("ScreenCaptureKit reported no displays")
        }
        let klo = kloRunningApp(in: content)
        let excludedApps = klo.map { [$0] } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.showsCursor = true
        config.width = display.width
        config.height = display.height
        let fullImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        let fullW = fullImage.width
        let fullH = fullImage.height
        // Clamp zoom_factor — too low isn't a zoom (just downsample), too
        // high produces a single-pixel crop. 1.5x..8x covers the useful range.
        let factor = max(1.5, min(8.0, zoomFactor))
        let regionW = max(1, Int(Double(fullW) / factor))
        let regionH = max(1, Int(Double(fullH) / factor))
        // Default center: middle of the screen. If model supplied coords,
        // they're in image-space, so use them directly.
        let cx = x ?? (fullW / 2)
        let cy = y ?? (fullH / 2)
        // Clamp the region origin so we don't crop off the screen.
        let originX = max(0, min(fullW - regionW, cx - regionW / 2))
        let originY = max(0, min(fullH - regionH, cy - regionH / 2))
        let cropRect = CGRect(x: originX, y: originY, width: regionW, height: regionH)
        guard let cropped = fullImage.cropping(to: cropRect) else {
            throw MacOpsError("CGImage.cropping returned nil for rect \(cropRect)")
        }

        // Don't draw the cursor crosshair on a zoom output — the user
        // didn't ask for that, and the crosshair would land at the
        // post-crop location which doesn't represent the real cursor.
        let png = try Self.pngData(from: cropped)
        let base64 = png.base64EncodedString()
        let logical = Self.mainLogicalSize()

        return [
            "ok": true,
            "base64_png": base64,
            // Geometry block describes the CROPPED image's pixel size
            // (which is what the model is looking at) plus the original
            // screen's logical dims. Click coordinates the model emits
            // after seeing this should still be in the full-screen
            // image-space — the zoom is a visual aid, not a new coord
            // system. The model uses its current screenshot's geometry
            // for clicks; this geometry block just describes this image.
            "geometry": [
                "image_w": cropped.width,
                "image_h": cropped.height,
                "logical_w": logical.width,
                "logical_h": logical.height,
            ],
        ]
    }

    // MARK: - Mouse

    /// Input is already in screen LOGICAL points (top-left origin) —
    /// the Python `mac_ops_client._point()` does declared→logical
    /// scaling on the sidecar side before it POSTs here. This function
    /// just clamps to the screen and forwards. The historical
    /// `backingScaleFactor` divide that lived here was double-scaling
    /// against the Python fix and pulled every click into the top-left
    /// quadrant on Retina displays (user-reported "random spot, doesn't
    /// land on the button").
    private static func imageToLogical(x: Int, y: Int) -> CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: x, y: y)
        }
        let bounds = screen.frame.size
        let clampedX = min(max(CGFloat(x), 0), bounds.width - 1)
        let clampedY = min(max(CGFloat(y), 0), bounds.height - 1)
        if clampedX != CGFloat(x) || clampedY != CGFloat(y) {
            NSLog(
                "KLO MacOps: click coord out of bounds — in=(%d,%d) clamped=(%.1f,%.1f) screen=%@",
                x, y, clampedX, clampedY, NSStringFromSize(bounds),
            )
        }
        return CGPoint(x: clampedX, y: clampedY)
    }

    func click(x: Int, y: Int, button: String, clicks: Int) async throws -> [String: Any] {
        let pos = Self.imageToLogical(x: x, y: y)

        // AX hit-test BEFORE CGEvent. The model's pixel estimate is
        // typically off by 10-50px from the visual target's center;
        // by resolving (x,y) to the AXUIElement under that point and
        // running AXPress instead of a synthesized mouse click, that
        // error is absorbed by the element's hit-test bounds. Falls
        // back to the cua MouseInput path on canvas/no-AX surfaces
        // and on right-click / multi-click which aren't AXPress.
        var hitMethod = "mouse_cua"
        var hitTarget: String? = nil
        if button == "left" && max(1, clicks) == 1 {
            if let elem = try? AXInput.elementAt(pos),
               Self.tryAXPress(element: elem) {
                hitMethod = "ax_press"
                let desc = AXInput.describe(elem)
                hitTarget = desc.title ?? desc.description ?? desc.role
                Task { @MainActor in
                    WispPresenter.shared.actionFired(at: pos)
                }
                var result: [String: Any] = ["ok": true, "method": hitMethod]
                if let t = hitTarget { result["target"] = t }
                return result
            }
        }

        // Fallback: cua MouseInput pid-routed click (chunk 2 path).
        let pid = Self.pidAt(screenPoint: pos)
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            ?? 0
        let btn: MouseInput.Button = (button == "right") ? .right : .left
        try MouseInput.click(
            at: pos,
            toPid: pid,
            button: btn,
            count: max(1, clicks),
            useFrontmostHIDPath: !Self.useBackgroundMode
        )
        Task { @MainActor in
            WispPresenter.shared.actionFired(at: pos)
        }
        return ["ok": true, "method": hitMethod]
    }

    /// Run an identity action on the element if it advertises one we
    /// know how to dispatch. Preference order: AXPress (buttons / links
    /// / menu items / checkboxes), then AXShowMenu (menu bar status
    /// items, popup buttons). Returns true on success — caller skips
    /// the synthesized click. False means "no usable action" or
    /// "action threw" — caller should fall back to a mouse click.
    private static func tryAXPress(element: AXUIElement) -> Bool {
        let actions = AXInput.advertisedActionNames(of: element)
        for candidate in ["AXPress", "AXShowMenu"] {
            guard actions.contains(candidate) else { continue }
            do {
                try AXInput.performAction(candidate, on: element)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    func mouseMove(x: Int, y: Int) async throws -> [String: Any] {
        let pos = Self.imageToLogical(x: x, y: y)
        CursorControl.move(to: pos)
        return ["ok": true]
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws -> [String: Any] {
        let from = Self.imageToLogical(x: fromX, y: fromY)
        let to = Self.imageToLogical(x: toX, y: toY)
        // Resolve target pid from the drag-start point. If the drag
        // crosses windows, cua's drag still routes to the start window's
        // pid — matches user-intent (drags originate at the source).
        let pid = Self.pidAt(screenPoint: from)
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            ?? 0
        try MouseInput.drag(
            from: from,
            to: to,
            toPid: pid,
            button: .left,
            durationMs: 500,
            steps: 20
        )
        return ["ok": true]
    }

    /// Resolve the pid of the topmost on-screen window containing the
    /// given screen point. Falls back to nil if no window contains it
    /// (the caller fills in frontmost-pid as a last resort). Mirrors the
    /// hit-test rule used in cua's recording/AppState modules: visible
    /// layer-0 windows, lowest zIndex (topmost rendered) wins.
    private static func pidAt(screenPoint p: CGPoint) -> pid_t? {
        let windows = WindowEnumerator.visibleWindows()
            .filter { $0.layer == 0 }
            .filter {
                p.x >= $0.bounds.x && p.x < $0.bounds.x + $0.bounds.width
                    && p.y >= $0.bounds.y && p.y < $0.bounds.y + $0.bounds.height
            }
            .sorted { $0.zIndex < $1.zIndex }
        return windows.first?.pid
    }

    func cursorPosition() -> (x: Int, y: Int) {
        // NSEvent.mouseLocation is in screen-bottom-left coords; convert
        // to image-top-left.
        let logical = Self.mainLogicalSize()
        let pt = NSEvent.mouseLocation
        let x = max(0, min(logical.width - 1, pt.x))
        let y = max(0, min(logical.height - 1, logical.height - pt.y))
        return (Int(x.rounded()), Int(y.rounded()))
    }

    // MARK: - Keyboard

    /// Type literal text. Long text or text with newlines goes through
    /// the paste path (faster + more reliable for editor-like contexts).
    /// Short text uses unicode keystrokes.
    func type(text: String) async throws -> [String: Any] {
        if text.count > 12 || text.contains("\n") {
            return try await paste(text: text)
        }
        for ch in text {
            try postUnicodeKeystroke(String(ch))
        }
        // Pulse the wisp at the current cursor location so typing has
        // a visible signal even though there's no explicit click coord.
        let cur = cursorPosition()
        Task { @MainActor in
            WispPresenter.shared.actionFired(at: CGPoint(x: cur.x, y: cur.y))
        }
        return ["ok": true]
    }

    func paste(text: String) async throws -> [String: Any] {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Multi-representation pasteboard. Each destination app picks
        // the richest format it understands:
        //
        //   .rtf     → Notes, Pages, Mail, TextEdit, Word, Keynote
        //   .html    → Notion (web + desktop), Gmail web, Google Docs,
        //              Linear, GitHub web composer, Slack rich field
        //   .string  → terminal, VS Code, plain-text fields, iMessage,
        //              Slack code blocks (universal fallback)
        //
        // The model's prose is interpreted as Markdown via
        // AttributedString — so "## Heading\n\n- bullet" becomes a
        // real heading and a real bullet at the destination.
        //
        // Paragraph-break upgrade: plain prose with single `\n`
        // separators (a list of timestamped notes, transcribed bullet
        // points, anything line-per-thought) used to collapse into a
        // wall of text because markdown treats `\n` as a SOFT line
        // break — RTF/HTML render the lines as one paragraph. We
        // upgrade single newlines to paragraph breaks (`\n\n`) when
        // the input clearly intends paragraphs (every-other-line is
        // non-empty) and no `\n\n` is already present. Code-fenced
        // sections are preserved verbatim so embedded snippets don't
        // get mangled.
        //
        // Parsing failures (text isn't well-formed markdown — rare
        // but possible) fall through gracefully: only `.string` ends
        // up on the pasteboard, matching the previous behavior.
        let prepared = Self.paragraphizePlainProse(text)
        if let attr = try? AttributedString(
            markdown: prepared,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            let ns = NSAttributedString(attr)
            let range = NSRange(location: 0, length: ns.length)
            if let rtf = try? ns.data(
                from: range,
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.rtf
                ]
            ) {
                pasteboard.setData(rtf, forType: .rtf)
            }
            if let html = try? ns.data(
                from: range,
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html
                ]
            ) {
                pasteboard.setData(html, forType: .html)
            }
        }
        // Plain-string fallback uses the paragraphized text too, so
        // dumb editors (iMessage, plain Notes fields) still see real
        // paragraph breaks instead of a single wall.
        pasteboard.setString(prepared, forType: .string)

        _ = try await key(combo: "cmd+v")
        return ["ok": true]
    }

    /// Upgrade single-newline-separated prose to paragraph breaks
    /// (`\n\n`) so markdown / RTF / HTML render it as paragraphs.
    /// No-op when the input already uses `\n\n` separators or contains
    /// code fences (markdown's verbatim region — never touch the
    /// inside of those).
    private static func paragraphizePlainProse(_ text: String) -> String {
        if text.contains("\n\n") { return text }
        if text.contains("```") { return text }
        // Flat-markdown repair. Some models emit a multi-section doc as
        // one continuous string with `## ` heading sigils embedded
        // mid-text but no newlines between sections — the entire doc
        // then pastes as a wall with literal `##` characters visible
        // in plain-text destinations (Notes plain notes, iMessage,
        // chat fields). When we see that exact shape — zero newlines
        // + 2+ heading sigils — restore line structure before the
        // regular paragraphizer takes over.
        if !text.contains("\n"),
           text.components(separatedBy: "## ").count - 1 >= 2 {
            return repairFlatMarkdown(text)
        }
        // Heuristic: only upgrade when most non-empty lines look like
        // their own thought / sentence / bullet, not when the text is
        // genuinely a single paragraph wrapped at column N.
        let lines = text.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 2 else { return text }
        // If lines are long-prose (avg > 100 chars), assume hard-wrap
        // and leave them alone — joining them with \n\n would create
        // jarring paragraph breaks mid-sentence.
        let avgLen = nonEmpty.map(\.count).reduce(0, +) / max(nonEmpty.count, 1)
        if avgLen > 100 { return text }
        // Each non-empty line becomes its own paragraph. Empty input
        // lines (already blank-row separators) are preserved so the
        // join doesn't double them up.
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Restore line structure to markdown that was emitted as a single
    /// flat string. Splits before every heading sigil (`# ` through
    /// `#### `) and horizontal rule, so `"# Title ## Section body ##
    /// Other ..."` becomes a well-formed multi-paragraph document.
    /// Bullets are intentionally left alone — ` - ` collides with
    /// dashes-as-ranges in prose ("Day 1-2", "9-10 AM") too often to
    /// repair safely without context.
    private static func repairFlatMarkdown(_ text: String) -> String {
        var out = text
        // Longest-first so `#### ` matches before `## ` and a deeper
        // heading doesn't get partial-matched as a shallower one.
        for sigil in ["#### ", "### ", "## ", "# "] {
            let pieces = out.components(separatedBy: " " + sigil)
            if pieces.count > 1 {
                out = pieces.enumerated().map { i, p in
                    i == 0 ? p : "\n\n" + sigil + p
                }.joined()
            }
        }
        // Horizontal rule gets blank lines on both sides so it reads
        // as a real section break rather than three loose hyphens.
        out = out.replacingOccurrences(of: " --- ", with: "\n\n---\n\n")
        return out
    }

    /// Modifier-aware key combo, e.g. "cmd+s", "cmd+shift+t", "return".
    /// Mirrors `api.core.input.key_press`.
    func key(combo: String) async throws -> [String: Any] {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.isEmpty else { throw MacOpsError("empty key combo") }

        var modifiers: [String] = []
        var keyName = parts.last ?? ""
        if parts.count > 1 {
            modifiers = parts.dropLast().map { Self.modifierAlias($0) }
        }
        keyName = Self.keyAlias(keyName)

        let mask = Self.flagsMask(for: modifiers)

        // Press all modifiers first (no-op for our held-state — flags
        // are applied via CGEventSetFlags on each event)
        if let code = Self.keyCode(for: keyName) {
            try postKeyboard(virtualCode: code, keyDown: true, flags: mask)
            try postKeyboard(virtualCode: code, keyDown: false, flags: mask)
        } else if keyName.count == 1 {
            // Single non-mapped char — unicode keystroke with flags
            try postUnicodeKeystroke(keyName, flags: mask)
        } else {
            throw MacOpsError("unknown key name: \(keyName)")
        }
        return ["ok": true]
    }

    /// Hold a key for a duration (modifier or named key).
    func holdKey(key: String, duration: Double) async throws -> [String: Any] {
        let normalized = Self.keyAlias(Self.modifierAlias(key.lowercased().replacingOccurrences(of: " ", with: "_")))
        let mask = Self.flagsMask(for: [normalized])
        let isModifier = mask.rawValue != 0
        let dur = max(0, min(duration, 30))
        if isModifier {
            // Holding a pure modifier alone is approximated by sleeping
            // for the duration — modifiers typically only matter as
            // flags on a paired key event. Most callers want hold for
            // a non-modifier key.
            if let code = Self.keyCode(for: normalized) {
                try postKeyboard(virtualCode: code, keyDown: true, flags: [])
                try await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
                try postKeyboard(virtualCode: code, keyDown: false, flags: [])
            } else {
                try await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
            }
            return ["ok": true]
        }
        guard let code = Self.keyCode(for: normalized) else {
            throw MacOpsError("unknown key for hold: \(normalized)")
        }
        try postKeyboard(virtualCode: code, keyDown: true, flags: [])
        try await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
        try postKeyboard(virtualCode: code, keyDown: false, flags: [])
        return ["ok": true]
    }

    func scroll(dx: Int, dy: Int) async throws -> [String: Any] {
        guard dx != 0 || dy != 0 else { return ["ok": true] }
        let event: CGEvent?
        if dx != 0 {
            event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                            wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        } else {
            event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: Int32(dy), wheel2: 0, wheel3: 0)
        }
        guard let e = event else { throw MacOpsError("CGEventCreateScrollWheelEvent failed") }
        e.post(tap: .cghidEventTap)
        return ["ok": true]
    }

    // MARK: - Internal: CGEvent posting

    private func post(mouseEventType: CGEventType, point: CGPoint, button: CGMouseButton, clickState: Int) throws {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: mouseEventType, mouseCursorPosition: point, mouseButton: button) else {
            throw MacOpsError("CGEvent (mouse) creation failed")
        }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.post(tap: .cghidEventTap)
    }

    private func postKeyboard(virtualCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) throws {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: keyDown) else {
            throw MacOpsError("CGEvent (keyboard) creation failed")
        }
        if flags.rawValue != 0 { e.flags = flags }
        e.post(tap: .cghidEventTap)
    }

    private func postUnicodeKeystroke(_ text: String, flags: CGEventFlags = []) throws {
        for chunk in text.unicodeScalars.map({ String($0) }) {
            for keyDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                    throw MacOpsError("CGEvent (keyboard unicode) creation failed")
                }
                let utf16 = Array(chunk.utf16)
                utf16.withUnsafeBufferPointer { ptr in
                    e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr.baseAddress)
                }
                if flags.rawValue != 0 { e.flags = flags }
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Helpers (key map, modifier map — mirrors api/core/input.py)

    private static let modifierMap: [String: String] = [
        "command": "cmd", "option": "alt", "control": "ctrl",
    ]
    private static let keyAliasMap: [String: String] = [
        "return": "return", "enter": "return",
        "escape": "esc", "esc": "esc",
        "space": "space", "tab": "tab",
        "delete": "delete", "backspace": "delete",
        "up": "arrow-up", "down": "arrow-down",
        "left": "arrow-left", "right": "arrow-right",
        "pageup": "page-up", "pagedown": "page-down",
        "page_up": "page-up", "page_down": "page-down",
        "arrow_up": "arrow-up", "arrow_down": "arrow-down",
        "arrow_left": "arrow-left", "arrow_right": "arrow-right",
    ]
    private static let virtualKeyCodes: [String: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "esc": 53, "escape": 53,
        "arrow-up": 126, "arrow-down": 125, "arrow-left": 123, "arrow-right": 124,
        "page-up": 116, "page-down": 121, "home": 115, "end": 119,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static func modifierAlias(_ name: String) -> String {
        modifierMap[name] ?? name
    }

    private static func keyAlias(_ name: String) -> String {
        keyAliasMap[name.replacingOccurrences(of: " ", with: "_")] ?? name
    }

    private static func keyCode(for name: String) -> CGKeyCode? {
        virtualKeyCodes[name.lowercased()]
    }

    private static func flagsMask(for modifiers: [String]) -> CGEventFlags {
        var mask: UInt64 = 0
        for mod in modifiers {
            switch mod {
            case "cmd":   mask |= CGEventFlags.maskCommand.rawValue
            case "shift": mask |= CGEventFlags.maskShift.rawValue
            case "alt":   mask |= CGEventFlags.maskAlternate.rawValue
            case "ctrl":  mask |= CGEventFlags.maskControl.rawValue
            case "fn":    mask |= CGEventFlags.maskSecondaryFn.rawValue
            default:      break
            }
        }
        return CGEventFlags(rawValue: mask)
    }

    // MARK: - Helpers (screenshot)

    private static func mainLogicalSize() -> (width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return (0, 0) }
        return (screen.frame.size.width, screen.frame.size.height)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw MacOpsError("PNG encoding failed")
        }
        return png
    }

    /// Draw a red cursor crosshair at the current cursor position.
    /// Same visual contract as `_draw_cursor_crosshair` in Python.
    private func drawCursorCrosshair(
        cgImage: CGImage,
        imageWidth: Int,
        imageHeight: Int,
        logicalWidth: CGFloat,
        logicalHeight: CGFloat
    ) -> CGImage? {
        let cursor = cursorPosition()
        let imageX = Int(round(Double(cursor.x) * Double(imageWidth) / max(1, Double(logicalWidth))))
        let imageY = Int(round(Double(cursor.y) * Double(imageHeight) / max(1, Double(logicalHeight))))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: imageWidth, height: imageHeight,
            bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        ctx.setStrokeColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.setLineWidth(3.0)
        let size = 22

        ctx.move(to: CGPoint(x: max(0, imageX - size), y: imageY))
        ctx.addLine(to: CGPoint(x: min(imageWidth - 1, imageX + size), y: imageY))
        ctx.move(to: CGPoint(x: imageX, y: max(0, imageY - size)))
        ctx.addLine(to: CGPoint(x: imageX, y: min(imageHeight - 1, imageY + size)))
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// Crosshair for a window-cropped screenshot. Translates the global
    /// cursor position into window-local pixels (cursor_in_window_px =
    /// (cursor_screen_pt − window_origin_pt) × window_scale).
    private func drawCursorCrosshairForWindow(
        cgImage: CGImage,
        imageWidth: Int,
        imageHeight: Int,
        windowBounds: WindowBounds
    ) -> CGImage? {
        let cursor = NSEvent.mouseLocation
        let logical = Self.mainLogicalSize()
        // NSEvent.mouseLocation is bottom-left origin; CG screen coords are
        // top-left. Convert before window-local subtraction.
        let cursorTopLeft = CGPoint(x: cursor.x, y: logical.height - cursor.y)
        let scaleX = windowBounds.width > 0
            ? Double(imageWidth) / windowBounds.width : 1.0
        let scaleY = windowBounds.height > 0
            ? Double(imageHeight) / windowBounds.height : 1.0
        let localX = Int(round((Double(cursorTopLeft.x) - windowBounds.x) * scaleX))
        let localY = Int(round((Double(cursorTopLeft.y) - windowBounds.y) * scaleY))
        // Cursor is outside this window — don't draw a crosshair that
        // points at a window-corner; just return the original image.
        if localX < 0 || localY < 0 || localX >= imageWidth || localY >= imageHeight {
            return cgImage
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: imageWidth, height: imageHeight,
            bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        ctx.setStrokeColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.setLineWidth(3.0)
        let size = 22
        ctx.move(to: CGPoint(x: max(0, localX - size), y: localY))
        ctx.addLine(to: CGPoint(x: min(imageWidth - 1, localX + size), y: localY))
        ctx.move(to: CGPoint(x: localX, y: max(0, localY - size)))
        ctx.addLine(to: CGPoint(x: localX, y: min(imageHeight - 1, localY + size)))
        ctx.strokePath()
        return ctx.makeImage()
    }

    // Klo's own SCRunningApplication, if visible to ScreenCaptureKit. Matched
    // by bundle ID for precision (applicationName can be localized). Kept in
    // sync with `_KLO_BUNDLE_ID` in agent2/active_apps.py and
    // api/core/accessibility.py — the AX layer uses the same constant to
    // filter klo out of every walk.
    private static let kloBundleID = "com.klo.KLO"

    private func kloRunningApp(in content: SCShareableContent) -> SCRunningApplication? {
        return content.applications.first(where: { $0.bundleIdentifier == Self.kloBundleID })
    }
}
