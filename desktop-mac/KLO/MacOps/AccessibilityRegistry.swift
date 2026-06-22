import AppKit
import ApplicationServices
import CoreGraphics
import CuaDriverCore
import Foundation

/// Thin Swift bridge over cua's `AppStateEngine`. Holds one shared
/// engine instance so the per-(pid, windowId) element_index cache
/// persists across HTTP calls — `window_state` walks the AX tree once,
/// `press_indexed` reuses the cached AXUIElement handle directly
/// (identity-based, no re-walk). That's the reliability win over the
/// Python `accessibility.actionable_index` + `accessibility.press`
/// path: AXPerformAction lands on the same node the snapshot indexed,
/// not whichever node happens to occupy slot N after a re-enumeration.
@MainActor
final class AccessibilityRegistry {
    static let shared = AccessibilityRegistry()
    private init() {}

    private let engine = AppStateEngine()
    private let windowCapture = WindowCapture()

    /// Walk the AX tree of `pid` (resolved from `appName` if provided,
    /// frontmost app otherwise), scoped to its frontmost window unless
    /// `windowId` is explicit. Returns the markdown tree dump + element
    /// count; the per-(pid, windowId) element cache is updated as a
    /// side effect so subsequent `clickElement` calls can resolve by
    /// index. When `includeScreenshot` is true, also captures the window
    /// and returns its base64 PNG — this is the "SoM mode" surface: the
    /// model sees the screenshot side-by-side with the indexed AX tree
    /// and picks an `element_index` to click. Matches Hermes' capture
    /// mode `som` semantics (no numbered overlays on the PNG; the
    /// markdown index is the surface that names the elements).
    func windowState(
        appName: String?,
        windowId: UInt32?,
        includeScreenshot: Bool,
        maxElements: Int = 100
    ) async throws -> [String: Any] {
        let pid = try resolvePid(appName: appName)
        let wid = try resolveWindowId(pid: pid, override: windowId)
        let snap = try await engine.snapshot(pid: pid, windowId: wid)
        let cap = max(1, min(maxElements, 1000))

        // Electron-class apps publish 500+ AX nodes per window (Cursor,
        // VS Code, Slack, Discord). Without a cap, one window_state call
        // can blow conversation context. Truncate the markdown tree at
        // `cap` element lines (lines beginning "[N]" — the renderer's
        // element-index marker). Non-element lines (containers, headers,
        // structural padding) flow through and don't count toward the
        // cap so the truncated tree stays structurally readable.
        let originalTree = snap.treeMarkdown
        var trimmedTree = originalTree
        var truncated = false
        var emittedElementCount = snap.elementCount
        if snap.elementCount > cap {
            var seen = 0
            var out: [String] = []
            for line in originalTree.split(
                separator: "\n", omittingEmptySubsequences: false
            ) {
                let trimmed = line.drop(while: { $0 == " " || $0 == "-" || $0 == "\t" })
                if trimmed.first == "[" {
                    if seen >= cap {
                        truncated = true
                        continue
                    }
                    seen += 1
                }
                out.append(String(line))
            }
            if truncated {
                out.append(
                    "[truncated: showing \(cap) of \(snap.elementCount) "
                        + "elements. Narrow via app_name= or raise max_elements (cap 1000).]"
                )
                trimmedTree = out.joined(separator: "\n")
                emittedElementCount = cap
            }
        }

        var result: [String: Any] = [
            "ok": true,
            "pid": Int(pid),
            "window_id": Int(wid),
            "bundle_id": snap.bundleId ?? "",
            "app_name": snap.name ?? "",
            "tree_markdown": trimmedTree,
            "element_count": emittedElementCount,
            "total_elements": snap.elementCount,
            "truncated": truncated,
            "turn_id": snap.turnId,
            "mode": includeScreenshot ? "som" : "text",
        ]
        if includeScreenshot {
            if let shot = try? await windowCapture.captureWindow(
                windowID: wid, format: .png, quality: 95
            ) {
                // SOM overlay pass — draw numbered [N] labels on top of
                // each indexed AX element so the model sees the index
                // floating ON the actual control, not in a separate
                // markdown tree. This is the parity move with Hermes /
                // cua-driver: the screenshot itself becomes the
                // pickable surface. Without it, the model has to
                // mentally map between two windows (markdown vs image)
                // and picks the wrong element constantly.
                let windowOrigin = Self.windowOriginInScreenSpace(windowId: wid)
                    ?? CGPoint.zero
                let elementsToDraw = await collectElementBounds(
                    pid: pid,
                    windowId: wid,
                    upTo: emittedElementCount,
                    windowOrigin: windowOrigin,
                    imageScaleFactor: shot.scaleFactor,
                    imageSize: CGSize(width: shot.width, height: shot.height)
                )
                if let annotatedPng = Self.drawSomOverlay(
                    pngData: shot.imageData, elements: elementsToDraw
                ) {
                    result["base64_png"] = annotatedPng.base64EncodedString()
                } else {
                    result["base64_png"] = shot.imageData.base64EncodedString()
                }
                result["image_w"] = shot.width
                result["image_h"] = shot.height
                result["scale_factor"] = shot.scaleFactor
                result["som_elements_drawn"] = elementsToDraw.count
            } else {
                result["screenshot_error"] = "window capture failed"
            }
        }
        return result
    }

    /// One labeled SOM box — image-space pixel rect + the index drawn on it.
    private struct SomElement {
        let index: Int
        let rect: CGRect
    }

    /// Walk the cached AX session, looking up each element's screen-space
    /// AXPosition + AXSize, translating to image-space pixels relative to
    /// the captured window. Drops elements that fall outside the image
    /// (off-screen, no bounds) and elements whose bounds are absurdly
    /// large (would visually swamp the whole image — typically Window-
    /// level containers).
    private func collectElementBounds(
        pid: Int32,
        windowId: UInt32,
        upTo elementCount: Int,
        windowOrigin: CGPoint,
        imageScaleFactor: Double,
        imageSize: CGSize
    ) async -> [SomElement] {
        var out: [SomElement] = []
        out.reserveCapacity(elementCount)
        for idx in 1...max(1, elementCount) {
            guard let element = try? await engine.lookup(
                pid: pid, windowId: windowId, elementIndex: idx
            ) else { continue }
            guard let rectScreen = Self.boundingRect(of: element) else { continue }
            // Translate from screen-space (top-left origin, points) to
            // image-space (top-left origin, pixels).
            let x = (rectScreen.minX - windowOrigin.x) * imageScaleFactor
            let y = (rectScreen.minY - windowOrigin.y) * imageScaleFactor
            let w = rectScreen.width * imageScaleFactor
            let h = rectScreen.height * imageScaleFactor
            // Clip to image bounds. If the element is fully outside,
            // skip; it's a hidden / off-screen control the user can't
            // see anyway.
            let imageRect = CGRect(origin: .zero, size: imageSize)
            let pixelRect = CGRect(x: x, y: y, width: w, height: h).intersection(imageRect)
            if pixelRect.isNull || pixelRect.width < 4 || pixelRect.height < 4 {
                continue
            }
            // Drop "window-sized" elements — the AXWindow itself often
            // reports as covering the whole image. A box larger than
            // 85% of the image both width AND height is almost always
            // the window container, not an actionable control.
            if pixelRect.width > imageSize.width * 0.85,
               pixelRect.height > imageSize.height * 0.85 {
                continue
            }
            out.append(SomElement(index: idx, rect: pixelRect))
        }
        return out
    }

    /// Top-left screen-space origin (in points) of the window we
    /// captured, used to translate screen-space AX coordinates into
    /// image-space pixels. Sourced from CGWindowListCopyWindowInfo
    /// which reports kCGWindowBounds in the same global flipped-Y
    /// coord space AX uses.
    private static func windowOriginInScreenSpace(windowId: UInt32) -> CGPoint? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let info = CGWindowListCopyWindowInfo(options, windowId) as? [[String: Any]],
              let entry = info.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Read screen-space AXPosition + AXSize off an element. Same
    /// approach cua-driver uses internally.
    private static func boundingRect(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeValue) == .success,
            let posValue, let sizeValue,
            CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Render numbered SOM labels onto a PNG. Each element gets a small
    /// rounded rectangle anchored at its top-left with its index
    /// printed inside, plus a thin outline around the full element bounds.
    /// Returns the re-encoded PNG bytes; nil on any draw failure (caller
    /// falls back to the un-annotated image).
    private static func drawSomOverlay(pngData: Data, elements: [SomElement]) -> Data? {
        guard !elements.isEmpty,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = cg.width
        let height = cg.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Image-space is top-left origin; CGContext is bottom-left.
        // We draw with a flipped Y so element rects line up.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // After drawing the image, drawing text/shapes via CGContext
        // happens in the flipped space. We unflip to text by re-flipping
        // around each label position so glyphs aren't upside-down.
        let outlineColor = CGColor(red: 1.00, green: 0.584, blue: 0.0, alpha: 0.85)   // KloColors.orange
        let labelFill   = CGColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 0.92) // KloColors.ink
        let labelText   = CGColor(red: 0.945, green: 0.925, blue: 0.898, alpha: 1.0)  // KloColors.cream

        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(outlineColor)

        for el in elements {
            // Outline around the element's bounds.
            ctx.stroke(el.rect)

            // Numbered label box at top-left of the element. Width
            // scales mildly with digit count so [100] doesn't crop.
            let label = "\(el.index)"
            let digits = max(1, label.count)
            let labelW = max(18.0, 11.0 + 8.0 * Double(digits))
            let labelH = 16.0
            let labelOrigin = CGPoint(
                x: el.rect.minX,
                y: el.rect.minY
            )
            let labelRect = CGRect(
                x: labelOrigin.x,
                y: labelOrigin.y,
                width: labelW,
                height: labelH
            )
            ctx.setFillColor(labelFill)
            ctx.fill(labelRect)
            ctx.setStrokeColor(outlineColor)
            ctx.stroke(labelRect)

            // Draw the digit text. CoreGraphics doesn't have a one-liner
            // text-draw at a point, so we use CTLine. Coord space is
            // flipped, so flip locally around the label's baseline.
            ctx.saveGState()
            ctx.translateBy(x: labelRect.minX + 4, y: labelRect.minY + labelH - 3)
            ctx.scaleBy(x: 1, y: -1)
            let font = CTFontCreateWithName(
                "SFMono-Bold" as CFString, 11, nil
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(cgColor: labelText) ?? NSColor.white,
            ]
            let attr = NSAttributedString(string: label, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            // Reset stroke for next outline
            ctx.setStrokeColor(outlineColor)
        }

        guard let annotated = ctx.makeImage() else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, annotated, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    /// AXPerformAction on the element at `elementIndex` for the cached
    /// (pid, windowId) snapshot. Default action is AXPress; callers
    /// can pass AXShowMenu, AXConfirm, etc. The cache must already be
    /// populated via `windowState` for the same (pid, windowId) — call
    /// fails with a typed error if not.
    func clickElement(
        appName: String?,
        windowId: UInt32?,
        elementIndex: Int,
        action: String
    ) async throws -> [String: Any] {
        let pid = try resolvePid(appName: appName)
        let wid = try resolveWindowId(pid: pid, override: windowId)
        let element = try await engine.lookup(
            pid: pid, windowId: wid, elementIndex: elementIndex
        )
        try AXInput.performAction(action, on: element)
        return [
            "ok": true,
            "pid": Int(pid),
            "window_id": Int(wid),
            "element_index": elementIndex,
            "action": action,
        ]
    }

    /// AXSetAttributeValue on the cached element. Used for popup
    /// buttons, comboboxes, sliders, checkboxes, contenteditable text
    /// — anything where the right action is "set this value directly"
    /// rather than "click-then-pick-from-menu". Avoids the focus-steal
    /// + visual-targeting failure mode of opening a native popup and
    /// asking the model to identify the right option visually.
    ///
    /// AXAttribute defaults to AXValue (covers ~90% of cases). For
    /// AXPopUpButton on macOS, AXValue accepts the display label of
    /// the option (e.g. "Blue"). For sliders, pass a numeric string.
    /// For checkboxes, pass "1" or "0".
    func setValue(
        appName: String?,
        windowId: UInt32?,
        elementIndex: Int,
        attribute: String,
        value: String
    ) async throws -> [String: Any] {
        let pid = try resolvePid(appName: appName)
        let wid = try resolveWindowId(pid: pid, override: windowId)
        let element = try await engine.lookup(
            pid: pid, windowId: wid, elementIndex: elementIndex
        )
        try AXInput.setAttribute(attribute, on: element, value: value as CFString)
        return [
            "ok": true,
            "pid": Int(pid),
            "window_id": Int(wid),
            "element_index": elementIndex,
            "attribute": attribute,
            "value": value,
        ]
    }

    // MARK: - Private resolvers

    private func resolvePid(appName: String?) throws -> pid_t {
        let running = NSWorkspace.shared.runningApplications
        if let raw = appName?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let target = raw.lowercased()
            if let hit = running.first(where: {
                ($0.localizedName ?? "").lowercased() == target
                || ($0.bundleIdentifier ?? "").lowercased() == target
            }) {
                return hit.processIdentifier
            }
            throw MacOpsError("no running app matches '\(raw)'")
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            return front.processIdentifier
        }
        throw MacOpsError("no frontmost app to target")
    }

    private func resolveWindowId(pid: pid_t, override: UInt32?) throws -> UInt32 {
        if let w = override { return w }
        if let wid = WindowEnumerator.frontmostWindowID(forPid: pid) {
            return UInt32(wid)
        }
        throw MacOpsError("pid \(pid) has no frontmost window")
    }
}
