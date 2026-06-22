import AppKit
import Foundation

/// Cleanly restarts the running klo app. Used today only when Screen
/// Recording flips from "not yet" to "granted" mid-session — the
/// running process can't actually capture until it relaunches with a
/// fresh TCC state. macOS itself prompts the user about this; we just
/// follow through so they don't have to chase it.
///
/// The pattern is the standard well-behaved Mac app one (Firefox /
/// Chrome / Discord all do something equivalent):
///
///   1. Spawn a detached `/bin/sh` helper that:
///        - waits for our PID to exit (kill -0 polling),
///        - sleeps a beat for kernel cleanup of TCC state,
///        - opens the .app again.
///   2. Call `NSApp.terminate(nil)` so AppDelegate's
///      `applicationWillTerminate` runs (sidecar SIGTERM, Vapi
///      shutdown — already there).
///
/// The shell child detaches fully (no parent on stdio, doesn't wait
/// on us), so when klo exits it survives and re-opens the .app cleanly.
enum RelaunchService {

    /// Schedule a clean relaunch. Returns immediately; the actual
    /// quit happens on the next runloop tick after the helper is
    /// spawned (so the helper definitely exists before our parent
    /// PID disappears).
    ///
    /// `at:` lets the caller override the app bundle path — used by
    /// the Move-to-Applications flow to relaunch from /Applications/
    /// instead of the original DerivedData path.
    static func relaunch(at overridePath: String? = nil) {
        let parentPID = ProcessInfo.processInfo.processIdentifier
        let resolvedPath = overridePath ?? Bundle.main.bundleURL.path
        guard let appPath = resolvedPath.removingPercentEncoding
            ?? Optional(resolvedPath)
        else {
            NSLog("KLO Relaunch: couldn't resolve app bundle path")
            return
        }

        // Shell quoting: appPath could contain spaces (e.g. "Build
        // Products"), so single-quote and escape any embedded ' as '\''
        let escapedPath = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        ( while kill -0 \(parentPID) 2>/dev/null; do sleep 0.15; done; \
          sleep 0.3; \
          /usr/bin/open -n -a '\(escapedPath)' ) &
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // Detach: don't keep references to the child's pipes or wait
        // on it. The `&` in the script makes the inner watcher
        // background-itself, but launching /bin/sh itself still
        // needs to not block us.
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            NSLog("KLO Relaunch: helper spawned, PID \(process.processIdentifier)")
        } catch {
            NSLog("KLO Relaunch: failed to spawn helper: \(error)")
            return
        }

        // Give the runloop one tick so the spawned process has time
        // to register with the kernel before we tear ourselves down.
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
