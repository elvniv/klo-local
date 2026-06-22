import Foundation

/// Mirror of klo-cloud's `PendingScheduleOut` (klo_cloud/pending_schedules.py).
/// A schedule that's been drafted but is waiting for explicit user
/// confirmation before being promoted into `scheduled_tasks` (the
/// always-confirm gate for indirect creation paths shipped in 2.0.0).
///
/// Identified by `id` so SwiftUI can diff queues; equatable so the
/// notch overlay can animate transitions between consecutive pending
/// rows when the user confirms one and another is waiting behind it.
struct PendingSchedule: Codable, Identifiable, Equatable {
    let id: String
    let user_phrase: String       // human cadence the user typed ("every hour")
    let cadence: String           // canonical form ("1h")
    let prompt: String            // for single, the prompt; for routine, a brief description
    let scoped_service: String?
    let kind: String              // "single" | "routine"
    let name: String?
    let steps: [PendingScheduleStep]?
    let created_via: String       // "agent_tool" | "manual" | "suggestion"
    let suggestion_id: String?
    let created_at: String
    let expires_at: String

    /// True iff this pending row represents a multi-step routine.
    /// View code branches on this to render the step list instead of
    /// the single-prompt block.
    var isRoutine: Bool { kind == "routine" && (steps?.isEmpty == false) }

    /// Human-friendly cadence label. The canonical cadence ("1h" / "30m"
    /// / "2d") gets unpacked into something a person can read at a
    /// glance on the confirm card. Mirrors what the user typed when
    /// possible — falls back to the canonical if user_phrase is blank.
    var cadenceLabel: String {
        if !user_phrase.trimmingCharacters(in: .whitespaces).isEmpty {
            return user_phrase
        }
        return Self.humanizeCadence(cadence)
    }

    static func humanizeCadence(_ canon: String) -> String {
        // Canonical forms are like "5m", "1h", "2d". Strip the suffix
        // and produce a readable phrase.
        guard let unit = canon.last,
              let n = Int(canon.dropLast()) else {
            return canon
        }
        let word: String
        switch unit {
        case "m": word = n == 1 ? "minute" : "minutes"
        case "h": word = n == 1 ? "hour"   : "hours"
        case "d": word = n == 1 ? "day"    : "days"
        default:  return canon
        }
        return "every \(n) \(word)"
    }
}

/// One step within a routine pending_schedule. Mirrors the JSON shape
/// the cloud expects (see `klo_cloud/pending_schedules.py` step
/// validation in `create_pending_schedule`).
struct PendingScheduleStep: Codable, Equatable, Identifiable {
    /// Stable id for SwiftUI diffing. The cloud doesn't always assign
    /// one (we only require `prompt`), so synthesize from the index +
    /// prompt prefix when missing.
    var id: String { _id ?? "\(prompt.prefix(20))" }
    private let _id: String?

    let prompt: String
    let scoped_service: String?
    let requires_approval: Bool?
    let stop_on_failure: Bool?

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case prompt
        case scoped_service
        case requires_approval
        case stop_on_failure
    }
}
