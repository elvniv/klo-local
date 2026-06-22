import AppKit
import Darwin   // socket(), connect()

/// Owns the lifetime of the bundled `klo-sidecar` Python process.
///
/// Two operating modes:
///
///   1. **Shipped app** (Release build, end-user install). The PyInstaller
///      bundle ships inside `KLO.app/Contents/Resources/klo-sidecar/`. On
///      app launch, we exec it as a child process. On app quit, we
///      SIGTERM it. End users never see Python.
///
///   2. **Dev workflow** (Debug build, repo clone). Devs run the sidecar
///      externally via `uv run python -m agent2.desktop_api` — so it
///      hot-reloads on code changes. SidecarLauncher detects that
///      something is already listening on :8787 and stays out of the way.
///
/// Either way, by the time `applicationDidFinishLaunching` returns, the
/// sidecar is reachable on `127.0.0.1:8787` (or we've logged that it
/// isn't and the rest of the app surfaces a useful error).
@MainActor
final class SidecarLauncher: ObservableObject {

    /// Singleton so the Developer card in Settings can call `relaunch()`
    /// without threading a reference all the way through SwiftUI. Real
    /// owner is still AppDelegate's `sidecarLauncher` property; both
    /// resolve to this same instance.
    static let shared = SidecarLauncher()

    /// Port the sidecar binds (mirrors agent2.desktop_api).
    static let sidecarPort: UInt16 = 8787

    /// How long we'll wait for the sidecar to come up after launching.
    static let bootTimeout: TimeInterval = 8.0

    /// Rapid-restart budget. After this many consecutive failed boots /
    /// crashes the watchdog stops retrying and `health` flips to
    /// `.failed` — the notch surfaces "klo agent unavailable — Retry".
    ///
    /// Bumped from 3 → 8 because the lower budget kept burning out
    /// during transient port-conflict states (e.g. a stale sidecar
    /// from a previous KLO instance still releasing the bind, a
    /// zombie sidecar that takes a beat to die after SIGTERM). 8
    /// gives ~30s of recovery with the exponential backoff and is
    /// still well below "we'll silently retry forever" territory.
    static let maxRapidRestarts = 8

    /// Uptime that counts as "sustained healthy" — a crash after this
    /// long earns the full rapid-restart budget back.
    static let healthyUptimeReset: TimeInterval = 60

    /// Observable sidecar health, surfaced in the notch UI
    /// (KLOOverlayView) while the agent is down.
    enum Health: Equatable {
        case starting
        case healthy
        case restarting
        case failed
    }

    @Published private(set) var health: Health = .starting

    private var process: Process?
    private var restartAttempts = 0
    private var healthySince: Date?
    private var expectingTermination = false
    private var bootMonitor: Task<Void, Never>?

    /// Cloud URL to pass to the sidecar via `KLO_CLOUD_URL`. Nil =
    /// inherit the Mac app's environment (the default). The Developer-
    /// card override that used to set this is gone; pass it via
    /// `relaunch(cloudURL:)` from a dev hook if needed.
    private var pendingCloudURL: String?

    // MARK: - Public API

    /// Called from AppDelegate at app start. If a sidecar is already
    /// running (dev workflow), this is a no-op. Otherwise we launch the
    /// bundled binary if it exists.
    func startIfNeeded() {
        // Reap any stale klo-sidecar processes left over from a previous
        // KLO.app install. Without this, a zombie sidecar can survive
        // for days (observed in production: a sidecar started 3 days
        // before tonight's testing held :8767 through every
        // wipe+reinstall cycle, while today's fresh sidecar bound :8787
        // — the two had independent `bridge` singletons, so the
        // extension connected to the zombie but /health on the new
        // sidecar reported "disconnected"). Always run first so the
        // port-check below sees a clean slate.
        Self.reapStaleSidecars(ours: process?.processIdentifier)

        if isPortListening(Self.sidecarPort) {
            NSLog("KLO Sidecar: already running on :\(Self.sidecarPort) — skipping launch")
            health = .healthy
            healthySince = Date()
            return
        }

        health = restartAttempts > 0 ? .restarting : .starting

        guard let exe = bundledSidecarURL() else {
            NSLog("KLO Sidecar: no bundled binary at Contents/Resources/klo-sidecar/ — expecting external sidecar (dev workflow)")
            // No process to watchdog — but still poll for the external
            // sidecar so health (and the notch banner) stays honest.
            monitorBoot()
            return
        }

        let p = Process()
        p.executableURL = exe
        // Inherit stdout/stderr — sidecar logs land in the app's stdout,
        // which is captured by macOS's unified logging system. `log show
        // --process KLO` will surface them alongside Swift NSLog output.
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        // Pass-through env, plus the Developer-override cloud URL if
        // set. Without the override, the sidecar inherits the Mac app's
        // env (which is what end-users always get).
        var env = ProcessInfo.processInfo.environment
        if let cloudURL = pendingCloudURL, !cloudURL.isEmpty {
            env["KLO_CLOUD_URL"] = cloudURL
            NSLog("KLO Sidecar: launching with KLO_CLOUD_URL=\(cloudURL)")
        }
        p.environment = env
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }

        do {
            try p.run()
            process = p
            NSLog("KLO Sidecar: launched \(exe.path) (PID=\(p.processIdentifier))")
        } catch {
            NSLog("KLO Sidecar: failed to launch — \(error)")
            scheduleRestart()
            return
        }

        monitorBoot()
    }

    /// User-initiated retry from the notch's "klo agent unavailable"
    /// banner. Resets the rapid-restart budget and tries again.
    func retry() {
        NSLog("KLO Sidecar: user retry")
        restartAttempts = 0
        startIfNeeded()
    }

    /// Stop the running sidecar (if any) and relaunch it with the given
    /// `KLO_CLOUD_URL` override. Pass nil to clear the override and
    /// inherit the Mac app's env. Called from the Developer card in
    /// Settings when the user picks Production / Local / a custom URL.
    ///
    /// Why we need to relaunch: the Python sidecar reads `KLO_CLOUD_URL`
    /// at import time (cloud_auth.py module-level). Changing the env
    /// of the running process doesn't propagate — we have to spawn a
    /// fresh one.
    func relaunch(cloudURL: String?) {
        NSLog("KLO Sidecar: relaunch with cloudURL=\(cloudURL ?? "<inherit>")")
        pendingCloudURL = cloudURL
        stop()
        restartAttempts = 0
        // Brief gap so the port is released before we re-check it.
        Thread.sleep(forTimeInterval: 0.5)
        startIfNeeded()
    }

    /// Called from AppDelegate at terminate. SIGTERM the sidecar so it
    /// shuts down cleanly (FastAPI runs lifespan handlers, the Chrome
    /// extension bridge closes, etc.). If we just exit() the Mac app,
    /// macOS will reap orphan children via the process group, but a
    /// graceful shutdown is friendlier.
    func stop() {
        bootMonitor?.cancel()
        guard let p = process, p.isRunning else { return }
        expectingTermination = true
        p.terminate()
        // Give it 2s to exit gracefully before we move on.
        let deadline = Date().addingTimeInterval(2.0)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            // Last resort — kill -9.
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
    }

    // MARK: - Helpers

    /// Path to the bundled klo-sidecar binary, or nil if this build
    /// doesn't include one (dev / debug builds).
    private func bundledSidecarURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources
            .appendingPathComponent("klo-sidecar")
            .appendingPathComponent("klo-sidecar")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Kill any `klo-sidecar` process that we don't own. Stale sidecars
    /// from previous KLO.app installs can survive across re-installs
    /// and across `pkill -f` (the matching is unreliable on signed
    /// bundles whose cdhash has drifted). When the new sidecar tries
    /// to start, the zombie still holds one of our two ports (8787 or
    /// 8767), forcing the new one to either fail or — worse — bind
    /// only the other port. The result is a port-split state where the
    /// extension connects to the zombie's bridge while /health is
    /// served by the new sidecar with its own empty bridge singleton,
    /// reporting "disconnected" forever.
    ///
    /// Synchronous on purpose. Adds ~50ms to launch (one `pgrep` +
    /// up to two `kill`s) — small enough to keep in the startup
    /// critical path so the next operation (binding ports) sees a
    /// clean slate.
    private static func reapStaleSidecars(ours: Int32?) {
        // `pgrep -f "klo-sidecar/klo-sidecar"` matches the executable
        // path, not just the process name — narrower than just
        // "klo-sidecar" which would also match this Swift method name
        // in any stray shell pipeline.
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "klo-sidecar/klo-sidecar"]
        let outPipe = Pipe()
        pgrep.standardOutput = outPipe
        pgrep.standardError = Pipe()  // suppress "no processes matched"
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            NSLog("KLO Sidecar: reap pgrep failed — \(error)")
            return
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return }
        let pids = text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let stale = pids.filter { $0 != ours }
        guard !stale.isEmpty else { return }
        NSLog("KLO Sidecar: reaping \(stale.count) stale sidecar(s): \(stale)")
        for pid in stale {
            _ = kill(pid, SIGTERM)
        }
        // Brief grace window for clean shutdown, then SIGKILL anything
        // that didn't take the hint. 0.5s is enough for the FastAPI
        // lifespan shutdown to run; longer would noticeably delay
        // launch.
        Thread.sleep(forTimeInterval: 0.5)
        for pid in stale where kill(pid, 0) == 0 {
            NSLog("KLO Sidecar: SIGKILL stale pid \(pid)")
            _ = kill(pid, SIGKILL)
        }
    }

    /// Quick TCP check — is anything listening on `localhost:port`?
    /// Uses a non-blocking connect with a tiny timeout so we don't stall
    /// the launch sequence when nothing's there.
    private func isPortListening(_ port: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Poll (without blocking the main thread) until the sidecar is
    /// reachable or `bootTimeout` expires. A fresh PyInstaller bundle
    /// typically comes up in 600–900 ms on Apple silicon. On timeout
    /// the attempt counts as a failed boot and the watchdog's backoff
    /// applies.
    private func monitorBoot() {
        bootMonitor?.cancel()
        bootMonitor = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.bootTimeout)
            while Date() < deadline {
                if Task.isCancelled { return }
                guard let self else { return }
                if self.isPortListening(Self.sidecarPort) {
                    NSLog("KLO Sidecar: reachable on :\(Self.sidecarPort)")
                    self.health = .healthy
                    self.healthySince = Date()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            NSLog("KLO Sidecar: still not reachable after \(Self.bootTimeout)s")
            self.handleBootTimeout()
        }
    }

    /// The process launched but never bound the port (or the external
    /// dev sidecar never appeared). Treat as a failed attempt so the
    /// backoff + budget apply.
    private func handleBootTimeout() {
        if let p = process, p.isRunning {
            expectingTermination = true
            p.terminate()
        }
        process = nil
        scheduleRestart()
    }

    /// terminationHandler trampoline. Expected exits (stop / relaunch /
    /// boot-timeout kill) are consumed quietly; anything else is an
    /// unexpected crash and goes through the watchdog.
    private func handleTermination(status: Int32) {
        process = nil
        if expectingTermination {
            expectingTermination = false
            NSLog("KLO Sidecar: process exited (expected) status=\(status)")
            return
        }
        NSLog("KLO Sidecar: process exited unexpectedly with status \(status)")
        bootMonitor?.cancel()
        scheduleRestart()
    }

    /// Bounded exponential backoff: 0.5s, 1s, 2s — then give up and
    /// surface `.failed` until the user retries. A sidecar that stayed
    /// healthy for `healthyUptimeReset` before crashing earns the full
    /// budget back, so a one-off crash days in doesn't count against
    /// the rapid-crash-loop guard.
    private func scheduleRestart() {
        if let since = healthySince, Date().timeIntervalSince(since) > Self.healthyUptimeReset {
            restartAttempts = 0
        }
        healthySince = nil
        guard restartAttempts < Self.maxRapidRestarts else {
            health = .failed
            NSLog("KLO Sidecar: giving up after \(restartAttempts) failed restarts — waiting for user retry")
            return
        }
        restartAttempts += 1
        health = .restarting
        let delay = min(0.5 * pow(2.0, Double(restartAttempts - 1)), 8.0)
        NSLog("KLO Sidecar: restart attempt \(restartAttempts)/\(Self.maxRapidRestarts) in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startIfNeeded()
        }
    }
}
