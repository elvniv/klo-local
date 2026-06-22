import Foundation

/// Visual-QA hook for the long-horizon harness cards. Fires fake data
/// into KLOState so the design language can be inspected in a running
/// klo before the Python sidecar bridge is wired.
///
/// Usage from the terminal:
///   open "klo-desktop://preview/workspace-init"
///   open "klo-desktop://preview/workspace-approval"
///
/// AppDelegate's `application(_:open:)` routes any `klo-desktop://preview/<action>`
/// URL here. Unrecognized actions are no-ops. Both fakes use the
/// meal-tracking CMO brief so the cards read like a real first-encounter
/// rather than placeholder text.
@MainActor
enum KLOWorkspacePreview {
    static func fire(action: String, state: KLOState) {
        switch action {
        case "workspace-init":
            state.surfaceWorkspaceInitiated(.meallTrackingFake)
        case "workspace-approval":
            state.surfaceWorkspaceApproval(.publishYouTubeFake)
        default:
            print("[workspace-preview] unknown action: \(action)")
        }
    }
}

// MARK: - Fixtures

extension KLOState.WorkspaceSnapshot {
    /// Meal-tracking CMO brief — the example from the long-horizon
    /// research session. Matches the canonical first-encounter shape
    /// the user would see if they typed "be my CMO for meal tracking"
    /// into the live klo panel.
    static let meallTrackingFake = KLOState.WorkspaceSnapshot(
        slug: "meal-tracking-launch-2026-06-18",
        brief: "be my CMO for meal tracking for the next 30 days. product is a camera-based calorie scanner. budget $200/mo.",
        rootPath: "~/Library/Application Support/com.klorah.klo/workspaces/meal-tracking-launch-2026-06-18",
        initSteps: [
            "drafted a 4-week plan",
            "delegated research to 2 workers — TikTok + Reddit",
            "scheduled a weekly KPI review for monday 8am",
        ],
        cadence: "every monday",
        files: [
            KLOState.WorkspaceFile(name: "brief.md",     bytes: 233,  glyph: "B"),
            KLOState.WorkspaceFile(name: "plan.md",      bytes: 1247, glyph: "P"),
            KLOState.WorkspaceFile(name: "log.md",       bytes: 513,  glyph: "L"),
            KLOState.WorkspaceFile(name: "decisions.md", bytes: 168,  glyph: "D"),
            KLOState.WorkspaceFile(name: "pending.json", bytes: 2,    glyph: "·"),
        ]
    )
}

extension KLOState.WorkspaceApproval {
    /// Publish-to-YouTube gate — the canonical first external action
    /// the user encounters once the meal-tracking campaign moves into
    /// production phase.
    static let publishYouTubeFake = KLOState.WorkspaceApproval(
        clearanceId: "clr_preview",
        workspaceSlug: "meal-tracking-launch-2026-06-18",
        reason: "publishing to YouTube",
        ask: "approve YT Short #1 for publish?",
        payload: [
            KLOState.WorkspacePayloadEntry(key: "title",
                value: "POV: ADHD and you actually want to eat healthy"),
            KLOState.WorkspacePayloadEntry(key: "file",
                value: "~/Movies/meal-tracking-finished/2026-06-23-shorts-1.mp4"),
            KLOState.WorkspacePayloadEntry(key: "publish_time",
                value: "Wed 7am"),
            KLOState.WorkspacePayloadEntry(key: "duration",
                value: "0:42 (within Shorts limit)"),
        ]
    )
}
