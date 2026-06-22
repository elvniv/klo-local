import Foundation
import SwiftUI
import Combine

/// Owns the Mac client's view of klo-cloud schedules — both the
/// always-confirm `pending_schedules` queue and the active
/// `scheduled_tasks` list. Polls the cloud so the notch can pop a
/// confirm card and the Settings → Schedules section can list active
/// rows without needing a persistent WS connection (the Mac client
/// historically doesn't hold a WS to klo-cloud directly — schedules
/// are out-of-band events that previously had no Mac surface at all).
///
/// Polling cadence:
///   - Every 15s while the app is in the foreground (background ticks
///     pause to spare battery + Render request budget).
///   - On notch open (so opening klo immediately picks up any pending
///     row that arrived while the timer was paused).
///   - On explicit refresh from views (e.g. Settings → Schedules pull
///     to refresh, or just-after-Confirm to remove the resolved row).
@MainActor
final class SchedulesManager: ObservableObject {

    static let shared = SchedulesManager()

    @Published private(set) var pending: [PendingSchedule] = []
    @Published private(set) var active: [ScheduledTask] = []
    @Published private(set) var suggestions: [RoutineSuggestion] = []
    /// klo 2.1 Track A: currently-executing scheduled runs surfaced
    /// in the notch's leading proactive pill ("▸ running: <name>").
    /// Updated every poll from GET /schedules/active.
    @Published private(set) var activeRuns: [ActiveScheduledRun] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String? = nil

    /// Bumps every time a poll cycle completes — observers can listen
    /// to know when the latest snapshot is on screen.
    @Published private(set) var lastPolledAt: Date? = nil

    /// Injected by AppDelegate once the AccountManager exists. Lets
    /// SchedulesManager be a singleton (so views can observe its
    /// Publishers) without a chicken-and-egg dependency at the type
    /// level. The polling loop early-returns when account is nil.
    private weak var account: AccountManager?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 15

    /// Called once from AppDelegate.bootHeavyState after accountManager
    /// is created. Subsequent calls overwrite (harmless during dev).
    func attach(account: AccountManager) {
        self.account = account
    }

    // MARK: - Polling lifecycle

    /// Start the background polling loop. Idempotent — calling more
    /// than once is a no-op. The loop only runs while signed in;
    /// sign-out cancels the loop until the next call to `start()`.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 15) * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One-shot refresh — called by notch-open + Settings + after
    /// resolve. Best-effort; silent failure on auth / network. The
    /// next scheduled poll will retry.
    func refresh() async {
        guard let account, let token = await account.withFreshAccessToken() else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        async let pendingResult:     [PendingSchedule]    = fetchPending(token: token)
        async let activeResult:      [ScheduledTask]      = fetchActive(token: token)
        async let suggestionsResult: [RoutineSuggestion]  = fetchSuggestions(token: token)
        async let activeRunsResult:  [ActiveScheduledRun] = fetchActiveRuns(token: token)

        let newPending     = await pendingResult
        let newActive      = await activeResult
        let newSuggestions = await suggestionsResult
        let newActiveRuns  = await activeRunsResult

        self.pending     = newPending
        self.active      = newActive
        self.suggestions = newSuggestions
        self.activeRuns  = newActiveRuns
        self.lastPolledAt = Date()
    }

    /// Cancel an in-flight scheduled run. The schedule itself stays
    /// active for the next cadence fire; this only aborts the
    /// invocation that's running right now. Wired to the running
    /// pill's expanded panel.
    @discardableResult
    func cancelActiveRun(_ taskId: String) async -> Bool {
        guard let account, let token = await account.withFreshAccessToken() else { return false }
        let url = AccountManager.cloudBase.appendingPathComponent("schedules/\(taskId)/cancel-active")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "Could not cancel run"
                return false
            }
            await refresh()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Suggestion actions

    /// klo 2.1.1: typed outcome of a preview request so callers can
    /// surface specific UX (notch transient notices, drop the working
    /// state if the Mac is offline, etc) instead of swallowing every
    /// failure as a generic "did not work."
    enum PreviewOutcome: Equatable {
        case dispatched        // cloud accepted; result will arrive via mirror frame
        case macOffline        // cloud returned 409 — sidecar isn't connected
        case subscriptionRequired
        case notFound          // suggestion id missing / already resolved
        case networkError
        case other(String)

        var humanMessage: String {
            switch self {
            case .dispatched:            return "previewing now…"
            case .macOffline:            return "couldn't preview — klo's sidecar isn't running"
            case .subscriptionRequired:  return "preview is a Pro feature — upgrade to try"
            case .notFound:              return "that suggestion is no longer available"
            case .networkError:          return "network glitch — try again in a sec"
            case .other(let m):          return m
            }
        }
    }

    /// Fire a one-shot preview of a suggested routine. Cloud runs
    /// every step once and posts a stitched [Preview] mirror frame
    /// to the user's Mac (handled by AppDelegate's klo.cloud.mirror
    /// observer). Returns a typed outcome so callers can surface
    /// specific feedback to the user.
    func previewSuggestion(_ suggestionId: String) async -> PreviewOutcome {
        guard let account, let token = await account.withFreshAccessToken() else {
            return .other("not signed in")
        }
        let url = AccountManager.cloudBase.appendingPathComponent("suggestions/\(suggestionId)/preview")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 90  // routines can take a minute+
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .networkError
            }
            switch http.statusCode {
            case 200..<300: return .dispatched
            case 402:       return .subscriptionRequired
            case 404:       return .notFound
            case 409:       return .macOffline
            default:        return .other("preview failed (\(http.statusCode))")
            }
        } catch {
            return .networkError
        }
    }

    /// Accept the suggestion — moves it to pending_schedules. The
    /// notch's standard always-confirm card will then pop because
    /// SchedulesManager.pending will gain a new row on next poll.
    @discardableResult
    func acceptSuggestion(_ suggestionId: String) async -> Bool {
        guard let account, let token = await account.withFreshAccessToken() else { return false }
        let url = AccountManager.cloudBase.appendingPathComponent("suggestions/\(suggestionId)/accept")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "Could not accept routine"
                return false
            }
            await refresh()
            return true
        } catch {
            lastError = "Network error accepting routine"
            return false
        }
    }

    @discardableResult
    func dismissSuggestion(_ suggestionId: String, reason: String? = nil) async -> Bool {
        guard let account, let token = await account.withFreshAccessToken() else { return false }
        var components = URLComponents(
            url: AccountManager.cloudBase.appendingPathComponent("suggestions/\(suggestionId)"),
            resolvingAgainstBaseURL: false,
        )
        if let reason {
            components?.queryItems = [URLQueryItem(name: "reason", value: reason)]
        }
        guard let url = components?.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            await refresh()
            return true
        } catch {
            return false
        }
    }

    private func fetchSuggestions(token: String) async -> [RoutineSuggestion] {
        let url = AccountManager.cloudBase.appendingPathComponent("suggestions")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        struct Envelope: Decodable { let suggestions: [RoutineSuggestion] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return suggestions
            }
            return (try? JSONDecoder().decode(Envelope.self, from: data).suggestions) ?? []
        } catch {
            return suggestions
        }
    }

    // MARK: - Mutations

    /// Confirm a pending schedule. On success the row moves out of
    /// `pending` and into `active`. Returns the resolved active row
    /// id or nil on failure.
    @discardableResult
    func confirm(_ pendingId: String) async -> String? {
        guard let account, let token = await account.withFreshAccessToken() else { return nil }
        let url = AccountManager.cloudBase
            .appendingPathComponent("pending_schedules/\(pendingId)/confirm")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                lastError = "Could not confirm schedule"
                return nil
            }
            // Refresh to pick up the moved row (cheap; one round-trip).
            await refresh()
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = dict["id"] as? String {
                return id
            }
            return nil
        } catch {
            lastError = "Network error confirming schedule"
            return nil
        }
    }

    /// Reject a pending schedule. Optional reason feeds the
    /// suggestion detector's negative-signal loop when the pending
    /// row was created from a suggestion (Phase 7).
    @discardableResult
    func reject(_ pendingId: String, reason: String? = nil) async -> Bool {
        guard let account, let token = await account.withFreshAccessToken() else { return false }
        var components = URLComponents(
            url: AccountManager.cloudBase.appendingPathComponent("pending_schedules/\(pendingId)"),
            resolvingAgainstBaseURL: false,
        )
        if let reason {
            components?.queryItems = [URLQueryItem(name: "reason", value: reason)]
        }
        guard let url = components?.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                lastError = "Could not dismiss schedule"
                return false
            }
            await refresh()
            return true
        } catch {
            lastError = "Network error dismissing schedule"
            return false
        }
    }

    /// Pause/resume an active scheduled task. Uses the same PATCH
    /// pattern the iOS app uses against /schedules — we hit Supabase
    /// directly via the service-role isn't exposed to the client, so
    /// this routes through a cloud endpoint. (For now, pause = delete;
    /// proper pause/resume lands when we add the PATCH route in Phase
    /// 4. This stub returns false so the UI knows pause-by-delete
    /// isn't available yet.)
    @discardableResult
    func deleteActive(_ taskId: String) async -> Bool {
        guard let account, let token = await account.withFreshAccessToken() else { return false }
        let url = AccountManager.cloudBase.appendingPathComponent("schedules/\(taskId)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                lastError = "Could not delete schedule"
                return false
            }
            await refresh()
            return true
        } catch {
            lastError = "Network error deleting schedule"
            return false
        }
    }

    /// Fire one immediate run of an active schedule for testing. Bypasses
    /// the cadence tick. Returns true on the cloud's ack.
    @discardableResult
    func runNow(_ taskId: String) async -> Bool {
        guard let account, let token = await account.withFreshAccessToken() else { return false }
        let url = AccountManager.cloudBase.appendingPathComponent("schedules/\(taskId)/run-now")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private GETs

    private func fetchPending(token: String) async -> [PendingSchedule] {
        let url = AccountManager.cloudBase.appendingPathComponent("pending_schedules")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        struct Envelope: Decodable { let pending: [PendingSchedule] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return pending  // keep existing on transient failure
            }
            return (try? JSONDecoder().decode(Envelope.self, from: data).pending) ?? []
        } catch {
            return pending
        }
    }

    private func fetchActive(token: String) async -> [ScheduledTask] {
        let url = AccountManager.cloudBase.appendingPathComponent("schedules")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        struct Envelope: Decodable { let schedules: [ScheduledTask] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return active
            }
            return (try? JSONDecoder().decode(Envelope.self, from: data).schedules) ?? []
        } catch {
            return active
        }
    }

    private func fetchActiveRuns(token: String) async -> [ActiveScheduledRun] {
        let url = AccountManager.cloudBase.appendingPathComponent("schedules/active")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        struct Envelope: Decodable { let active: [ActiveScheduledRun] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return activeRuns
            }
            return (try? JSONDecoder().decode(Envelope.self, from: data).active) ?? []
        } catch {
            return activeRuns
        }
    }
}


/// Mirror of klo-cloud's `ActiveRunOut`. One scheduled task in
/// flight. Surfaced as the "▸ running: <name>" pill on the leading
/// edge of the proactive pills row when SchedulesManager.activeRuns
/// is non-empty.
struct ActiveScheduledRun: Codable, Identifiable, Equatable {
    let id: String              // scheduled_task_id
    let name: String
    let started_at: String      // ISO
    let kind: String            // "single" | "routine"
    let step_index: Int?
    let step_total: Int?

    /// Compact label for the pill. Routine in step 2/3 shows
    /// "morning brief (2/3)"; single just shows the name.
    var pillLabel: String {
        if let i = step_index, let t = step_total, t > 1 {
            return "\(name) (\(i + 1)/\(t))"
        }
        return name
    }
}


/// Mirror of klo-cloud's `RoutineSuggestionOut`. A routine the
/// detector proposed based on observed patterns. Pending until user
/// accepts (→ pending_schedules → scheduled_tasks) or dismisses.
struct RoutineSuggestion: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let cadence: String
    let steps: [PendingScheduleStep]
    let confidence: Double
    let evidence_message_ids: [String]?
    let proposed_at: String

    var cadenceLabel: String { PendingSchedule.humanizeCadence(cadence) }
}


/// Mirror of klo-cloud's `ScheduledTaskOut`. Active schedule row.
struct ScheduledTask: Codable, Identifiable, Equatable {
    let id: String
    let user_phrase: String
    let cadence: String
    let prompt: String
    let scoped_service: String?
    let enabled: Bool
    let silent_count: Int
    let delivered_count: Int
    let missed_count: Int?
    let status: String?              // "active" | "mac_offline"
    let last_run_at: String?
    let next_run_at: String
    let created_at: String
    // New for 2.0.0 — only present on rows the user confirmed after
    // the migration. Older rows decode with these nil.
    let kind: String?                // "single" | "routine"
    let name: String?
    let steps: [PendingScheduleStep]?

    var isRoutine: Bool { (kind == "routine") && (steps?.isEmpty == false) }
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no prompt)" : String(trimmed.prefix(60))
    }
    var cadenceLabel: String {
        if !user_phrase.trimmingCharacters(in: .whitespaces).isEmpty {
            return user_phrase
        }
        return PendingSchedule.humanizeCadence(cadence)
    }
}
