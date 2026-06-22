import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Network

/// Loopback HTTP server that the sidecar calls into for TCC-restricted
/// operations (screenshot, mouse, keyboard, scroll). Lives in the Mac
/// app's process so the OS attributes Accessibility / Screen Recording
/// trust to `com.klo.KLO` — the binary the user actually granted.
///
/// The sidecar (a separate PyInstaller binary with its own ad-hoc
/// code-signing identity) was historically the TCC consumer. That meant
/// granting "klo" in System Settings only trusted the parent app, not
/// the sidecar inside it — the user got stuck in a perpetual grant
/// loop. Moving these operations into the Mac app dissolves the
/// cross-process gap: ONE process touches TCC, granted ONCE.
///
/// Wire format mirrors `api.core.input` + `api.core.screenshot` so the
/// Python proxy (`agent2/mac_ops_client.py`) is a thin translation
/// layer.
@MainActor
final class MacOpsServer {

    static let shared = MacOpsServer()

    /// Distinct from the sidecar's :8787. The sidecar still serves the
    /// agent run lifecycle there; this server is the parallel callback
    /// channel for TCC operations.
    static let port: UInt16 = 8788

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.klo.MacOpsServer", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        NSLog("KLO MacOps: starting listener on port \(Self.port)…")
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // No `requiredLocalEndpoint` — that's for outbound clients,
            // not listeners. NWListener with `on: port` binds to all
            // interfaces; we filter incoming connections by peer below
            // (only allow loopback). In practice the sidecar always
            // connects from 127.0.0.1.
            guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                NSLog("KLO MacOps: invalid port \(Self.port)")
                return
            }
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("KLO MacOps: ✓ listening on 127.0.0.1:\(Self.port)")
                case .failed(let err):
                    NSLog("KLO MacOps: ✗ listener failed — \(err)")
                case .cancelled:
                    NSLog("KLO MacOps: listener cancelled")
                case .waiting(let err):
                    NSLog("KLO MacOps: listener waiting — \(err)")
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("KLO MacOps: failed to create listener — \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection)
    }

    /// Read the full HTTP request (headers + body) before dispatching.
    /// Loops `receive` until we've consumed `Content-Length` bytes.
    private func readRequest(connection: NWConnection, accumulator: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                NSLog("KLO MacOps: receive error — \(error)")
                connection.cancel()
                return
            }
            var buffer = accumulator
            if let chunk = data {
                buffer.append(chunk)
            }
            // Parse — if we have full headers + body, dispatch. Else recurse.
            if let req = HTTPRequest.parse(buffer) {
                Task { @MainActor in
                    let response = await self.handle(req)
                    self.write(connection: connection, response: response)
                }
            } else if isComplete {
                self.write(connection: connection, response: .badRequest)
            } else {
                self.readRequest(connection: connection, accumulator: buffer)
            }
        }
    }

    private func write(connection: NWConnection, response: HTTPResponse) {
        let payload = response.encode()
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func handle(_ req: HTTPRequest) async -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/v1/health"):
            // AXIsProcessTrusted() caches in-process on macOS — once it
            // returns false at startup, subsequent calls return the SAME
            // stale value even after the user toggles the permission on.
            // The grant flow's polling then never sees the flip.
            // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt
            // = false bypasses the cache and reads live from TCC.
            let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            let body: [String: Any] = [
                "ok": true,
                "ax_trusted": AXIsProcessTrustedWithOptions(axOpts),
                "sr_trusted": CGPreflightScreenCaptureAccess(),
            ]
            return .json(body)
        case ("POST", "/v1/screenshot"):
            return await dispatch(req, srNeeded: true) { params in
                try await MacOpsExecutor.shared.screenshot(
                    scope: params["scope"] as? String,
                    appName: params["app_name"] as? String
                )
            }
        case ("POST", "/v1/zoom"):
            // x/y are optional (executor defaults to screen center if missing).
            return await dispatch(req, srNeeded: true) { params in
                let x = params["x"] as? Int
                let y = params["y"] as? Int
                let factor = (params["zoom_factor"] as? Double) ?? 2.0
                return try await MacOpsExecutor.shared.zoom(
                    x: x, y: y, zoomFactor: factor
                )
            }
        case ("POST", "/v1/click"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.click(
                    x: try Self.intParam(params, "x"),
                    y: try Self.intParam(params, "y"),
                    button: (params["button"] as? String) ?? "left",
                    clicks: (params["clicks"] as? Int) ?? 1
                )
            }
        case ("POST", "/v1/mouse_move"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.mouseMove(
                    x: try Self.intParam(params, "x"),
                    y: try Self.intParam(params, "y")
                )
            }
        case ("POST", "/v1/drag"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.drag(
                    fromX: try Self.intParam(params, "from_x"),
                    fromY: try Self.intParam(params, "from_y"),
                    toX: try Self.intParam(params, "to_x"),
                    toY: try Self.intParam(params, "to_y")
                )
            }
        case ("POST", "/v1/type"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.type(
                    text: (params["text"] as? String) ?? ""
                )
            }
        case ("POST", "/v1/paste"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.paste(
                    text: (params["text"] as? String) ?? ""
                )
            }
        case ("POST", "/v1/key"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.key(
                    combo: (params["combo"] as? String) ?? (params["text"] as? String) ?? ""
                )
            }
        case ("POST", "/v1/hold_key"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.holdKey(
                    key: (params["key"] as? String) ?? (params["text"] as? String) ?? "",
                    duration: (params["duration"] as? Double) ?? 1.0
                )
            }
        case ("POST", "/v1/scroll"):
            return await dispatch(req, axNeeded: true) { params in
                try await MacOpsExecutor.shared.scroll(
                    dx: (params["dx"] as? Int) ?? 0,
                    dy: (params["dy"] as? Int) ?? 0
                )
            }
        case ("POST", "/v1/cursor_position"):
            return await dispatch(req) { _ in
                let pos = MacOpsExecutor.shared.cursorPosition()
                return ["ok": true, "x": pos.x, "y": pos.y]
            }

        // ─── cua-driver AX element_index path ──────────────────────────
        // window_state walks the target window's AX tree once and caches
        // AXUIElement handles per (pid, window_id). press_indexed then
        // performs AXAction directly on the cached handle — identity-
        // based, immune to re-enumeration drift. Preferred path for
        // Gmail, Notion, Linear, Slack and other AX-rich web apps.
        case ("POST", "/v1/ax/window_state"):
            return await dispatch(req, axNeeded: true) { params in
                let appName = params["app_name"] as? String
                let widRaw = params["window_id"] as? Int
                let wid: UInt32? = widRaw.map { UInt32($0) }
                let mode = (params["mode"] as? String) ?? "text"
                let maxEl = (params["max_elements"] as? Int) ?? 100
                return try await AccessibilityRegistry.shared.windowState(
                    appName: appName, windowId: wid,
                    includeScreenshot: mode == "som",
                    maxElements: maxEl
                )
            }
        case ("POST", "/v1/ax/click_element"):
            return await dispatch(req, axNeeded: true) { params in
                let appName = params["app_name"] as? String
                let widRaw = params["window_id"] as? Int
                let wid: UInt32? = widRaw.map { UInt32($0) }
                let idx = try Self.intParam(params, "element_index")
                let action = (params["action"] as? String) ?? "AXPress"
                return try await AccessibilityRegistry.shared.clickElement(
                    appName: appName, windowId: wid,
                    elementIndex: idx, action: action
                )
            }
        case ("POST", "/v1/ax/set_value"):
            return await dispatch(req, axNeeded: true) { params in
                let appName = params["app_name"] as? String
                let widRaw = params["window_id"] as? Int
                let wid: UInt32? = widRaw.map { UInt32($0) }
                let idx = try Self.intParam(params, "element_index")
                let value = (params["value"] as? String) ?? ""
                let attribute = (params["attribute"] as? String) ?? "AXValue"
                return try await AccessibilityRegistry.shared.setValue(
                    appName: appName, windowId: wid,
                    elementIndex: idx, attribute: attribute, value: value
                )
            }

        // ─── web (WKWebView) routes ────────────────────────────────────
        // All web actions route to WebViewManager.shared which owns the
        // in-process WKWebView. CDP is gone — this is native WebKit.
        case ("POST", "/v1/web/open"):
            return await dispatch(req) { params in
                let urlStr = (params["url"] as? String) ?? ""
                guard let url = URL(string: urlStr) else {
                    return ["ok": false, "error": "invalid_url", "url": urlStr]
                }
                let timeout = (params["timeout"] as? Double) ?? 12.0
                do {
                    try await WebViewManager.shared.open(url: url, timeout: timeout)
                    let summary = WebViewManager.shared.urlSummary()
                    // Also surface the panel so the user sees what klo
                    // is doing. KLOState observes web activity and
                    // transitions into .webPane mode.
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .kloShowWebPane, object: nil,
                            userInfo: ["url": urlStr]
                        )
                    }
                    return summary
                } catch {
                    return ["ok": false, "error": "\(error.localizedDescription)", "url": urlStr]
                }
            }
        case ("POST", "/v1/web/click"):
            return await dispatch(req) { params in
                let selector = params["selector"] as? String
                let text = params["text"] as? String
                let nth = (params["nth"] as? Int) ?? 0
                do {
                    return try await WebViewManager.shared.clickElement(
                        selector: selector, text: text, nth: nth
                    )
                } catch {
                    return ["ok": false, "error": "\(error.localizedDescription)"]
                }
            }
        case ("POST", "/v1/web/type"):
            return await dispatch(req) { params in
                let selector = (params["selector"] as? String) ?? ""
                let text = (params["text"] as? String) ?? ""
                let submit = (params["submit"] as? Bool) ?? false
                let clearFirst = (params["clear_first"] as? Bool) ?? true
                do {
                    return try await WebViewManager.shared.typeText(
                        selector: selector, text: text,
                        submit: submit, clearFirst: clearFirst
                    )
                } catch {
                    return ["ok": false, "error": "\(error.localizedDescription)"]
                }
            }
        case ("POST", "/v1/web/text"):
            return await dispatch(req) { params in
                let selector = params["selector"] as? String
                let max = (params["max"] as? Int) ?? 4000
                do {
                    return try await WebViewManager.shared.readText(
                        selector: selector, max: max
                    )
                } catch {
                    return ["ok": false, "error": "\(error.localizedDescription)"]
                }
            }
        case ("POST", "/v1/web/evaluate"):
            return await dispatch(req) { params in
                let expr = (params["expression"] as? String) ?? ""
                do {
                    let value = try await WebViewManager.shared.evaluate(expr)
                    // Coerce to a JSON-safe payload. NSNumber + String pass through;
                    // dictionaries from JS get NSDictionary which is fine.
                    return [
                        "ok": true,
                        "value": Self.jsonSafe(value) ?? NSNull(),
                    ]
                } catch {
                    return ["ok": false, "error": "\(error.localizedDescription)"]
                }
            }
        case ("POST", "/v1/web/wait_for"):
            return await dispatch(req) { params in
                let selector = (params["selector"] as? String) ?? ""
                let timeout = (params["timeout"] as? Double) ?? 8.0
                do {
                    return try await WebViewManager.shared.waitFor(
                        selector: selector, timeout: timeout
                    )
                } catch {
                    return ["ok": false, "error": "\(error.localizedDescription)"]
                }
            }
        case ("POST", "/v1/web/url"):
            return await dispatch(req) { _ in
                return WebViewManager.shared.urlSummary()
            }
        case ("POST", "/v1/web/snapshot"):
            // Indexed AX-tree snapshot of every visible interactive
            // element. The model uses this to pick targets by idx
            // instead of guessing CSS selectors. See WebViewManager
            // .snapshot for the W3C-ANC-1.1-subset algorithm.
            return await dispatch(req) { _ in
                return try await WebViewManager.shared.snapshot()
            }
        case ("POST", "/v1/web/press"):
            // Click by snapshot idx. Stale-snapshot detection returns
            // a typed error the agent dispatcher surfaces as a retry-
            // with-snapshot prompt.
            return await dispatch(req) { body in
                guard let idx = body["idx"] as? Int ?? (body["idx"] as? NSNumber)?.intValue else {
                    return ["ok": false, "error": "idx required"]
                }
                let sid = body["snapshot_id"] as? String
                return try await WebViewManager.shared.pressIdx(idx, snapshotId: sid)
            }
        case ("POST", "/v1/web/fill"):
            // Focus by snapshot idx + insertText. Same trusted-keys
            // pipeline as type(selector).
            return await dispatch(req) { body in
                guard let idx = body["idx"] as? Int ?? (body["idx"] as? NSNumber)?.intValue else {
                    return ["ok": false, "error": "idx required"]
                }
                let text = (body["text"] as? String) ?? ""
                let submit = (body["submit"] as? Bool) ?? false
                let clearFirst = (body["clear_first"] as? Bool) ?? true
                let sid = body["snapshot_id"] as? String
                return try await WebViewManager.shared.fillIdx(idx, text: text, submit: submit, clearFirst: clearFirst, snapshotId: sid)
            }
        case ("POST", "/v1/web/screenshot"):
            // Visual grounding for the agent. WKWebView.takeSnapshot
            // composes the current paint into an NSImage; we PNG it
            // and base64 the result. See WebViewManager.screenshot.
            return await dispatch(req) { body in
                let maxW = (body["max_width"] as? NSNumber)?.doubleValue ?? 1280
                return try await WebViewManager.shared.screenshot(maxWidth: CGFloat(maxW))
            }
        case ("POST", "/v1/web/wait_settled"):
            // Block until document.readyState is complete AND in-flight
            // fetch+XHR is zero for 2 consecutive polls. Used by the
            // agent before reading text or clicking on freshly-loaded
            // pages where the SPA is still hydrating.
            return await dispatch(req) { body in
                let t = (body["timeout"] as? NSNumber)?.doubleValue ?? 4.0
                await WebViewManager.shared.waitForSettled(timeout: t)
                return ["ok": true]
            }
        case ("POST", "/v1/web/autofill"):
            // Try klo's own credential store for the active page.
            // Triggers Touch ID if a matching item exists. Klo never
            // auto-submits — fills the form + focuses the password
            // field, user reviews and presses Enter. See
            // WebViewManager.autofill for the JS replay.
            return await dispatch(req) { body in
                let host = (body["host"] as? String) ?? ""
                return await WebViewManager.shared.autofill(host: host)
            }
        case ("GET", "/v1/keychain/list"):
            // Metadata-only enumeration of klo-owned credentials.
            // Used by the eventual settings UI. Doesn't trigger Touch
            // ID since it doesn't expose password bodies.
            return await dispatch(req) { _ in
                let entries = KloKeychain.list().map { e -> [String: Any] in
                    return [
                        "host": e.host,
                        "username": e.username,
                        "updated_at": ISO8601DateFormatter().string(from: e.updatedAt),
                    ]
                }
                return ["ok": true, "items": entries]
            }
        case ("DELETE", "/v1/keychain/item"):
            // Remove a credential. Used by the eventual settings UI's
            // delete affordance.
            return await dispatch(req) { body in
                let host = (body["host"] as? String) ?? ""
                let user = (body["username"] as? String) ?? ""
                let ok = KloKeychain.delete(host: host, username: user)
                return ["ok": ok]
            }

        default:
            return .notFound
        }
    }

    /// Recursively coerce arbitrary JS-evaluate return values into a
    /// payload that JSONSerialization will accept. WKWebView returns
    /// NSString / NSNumber / NSArray / NSDictionary / NSNull for valid
    /// JSON-shaped values; anything else gets stringified.
    private static func jsonSafe(_ value: Any?) -> Any? {
        guard let v = value else { return nil }
        if v is NSNull { return v }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n }
        if let arr = v as? [Any] { return arr.map { jsonSafe($0) ?? NSNull() } }
        if let dict = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, vv) in dict { out[k] = jsonSafe(vv) ?? NSNull() }
            return out
        }
        return "\(v)"
    }

    /// Common dispatch wrapper:
    ///   1. Decodes JSON body into a `[String: Any]` dict (empty if body absent).
    ///   2. Preflights TCC trust if `axNeeded` / `srNeeded` is true.
    ///   3. Runs the operation. Catches MacOpsError and other throws.
    ///   4. Returns the JSON response.
    private func dispatch(
        _ req: HTTPRequest,
        axNeeded: Bool = false,
        srNeeded: Bool = false,
        op: ([String: Any]) async throws -> [String: Any]
    ) async -> HTTPResponse {
        let params: [String: Any]
        if req.body.isEmpty {
            params = [:]
        } else if let parsed = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
            params = parsed
        } else {
            return .badRequest
        }
        // Use the no-prompt variant for a guaranteed fresh non-cached
        // read. `AXIsProcessTrusted()` caches per-process; once it
        // returns false at startup it can keep returning false even
        // after the user grants — which made every post-grant tool
        // call deny in a loop.
        if axNeeded {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) {
                return .json(Self.permissionDeniedPayload(.accessibility))
            }
        }
        if srNeeded && !CGPreflightScreenCaptureAccess() {
            return .json(Self.permissionDeniedPayload(.screenRecording))
        }
        do {
            let body = try await op(params)
            return .json(body)
        } catch let err as MacOpsError {
            return .json(["ok": false, "error": err.message])
        } catch {
            return .json(["ok": false, "error": "\(type(of: error)): \(error.localizedDescription)"])
        }
    }

    // MARK: - Helpers

    private static func intParam(_ params: [String: Any], _ key: String) throws -> Int {
        if let v = params[key] as? Int { return v }
        if let v = params[key] as? Double { return Int(v) }
        if let v = params[key] as? String, let i = Int(v) { return i }
        throw MacOpsError("missing or invalid integer param: \(key)")
    }

    enum PermissionService: String {
        case accessibility
        case screenRecording = "screen_recording"
    }

    static func permissionDeniedPayload(_ service: PermissionService) -> [String: Any] {
        let pretty: String
        switch service {
        case .accessibility:    pretty = "Accessibility"
        case .screenRecording:  pretty = "Screen Recording"
        }
        return [
            "ok": false,
            "error": "\(pretty) access is required for this action.",
            "error_code": "permission_denied",
            "permission_service": service.rawValue,
        ]
    }
}


// MARK: - Errors

struct MacOpsError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}


// MARK: - HTTP request/response (minimal — just what the sidecar sends)

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil if the buffer doesn't yet contain a complete request.
    /// Returns a request with the full body when Content-Length bytes are present.
    static func parse(_ data: Data) -> HTTPRequest? {
        // Find header/body boundary
        let crlfcrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let boundary = data.range(of: Data(crlfcrlf)) else { return nil }
        let headerData = data.subdata(in: 0..<boundary.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = boundary.upperBound
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else { return nil }  // body not fully arrived
        let body = data.subdata(in: bodyStart..<bodyEnd)

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

private struct HTTPResponse {
    let status: Int
    let statusText: String
    let body: Data
    let contentType: String

    static let notFound = HTTPResponse(status: 404, statusText: "Not Found", body: Data("not found".utf8), contentType: "text/plain")
    static let badRequest = HTTPResponse(status: 400, statusText: "Bad Request", body: Data("bad request".utf8), contentType: "text/plain")

    static func json(_ obj: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, statusText: "OK", body: data, contentType: "application/json")
    }

    func encode() -> Data {
        var out = Data()
        let head = "HTTP/1.1 \(status) \(statusText)\r\n" +
                   "Content-Type: \(contentType)\r\n" +
                   "Content-Length: \(body.count)\r\n" +
                   "Connection: close\r\n" +
                   "\r\n"
        out.append(Data(head.utf8))
        out.append(body)
        return out
    }
}
