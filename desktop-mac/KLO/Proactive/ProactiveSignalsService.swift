import AppKit
import Foundation

/// Builds the row of proactive pills that sits beneath the notch's
/// chat input. The row mixes two flavors:
///
///   1. **Live signals** — calendar + screen. These come first when
///      they exist, so the most-context-aware pill is always leftmost.
///   2. **Connector starters** — the same featured Composio toolkits
///      the iOS app pushes in chat (PromptSuggestions.swift), ranked
///      so the user's actually-connected toolkits float to the front.
///
/// The service is non-blocking and entirely anchored to the user's
/// ⌘K. Live signals are gathered concurrently; connector pills are
/// pure data. Total snapshot time is bounded by the slower of the
/// two live probes.
@MainActor
final class ProactiveSignalsService {
    static let shared = ProactiveSignalsService()

    /// Composio toolkit slug for Google Calendar. The pill flow is
    /// Google-Calendar-only by design (covers the vast majority);
    /// users on Outlook/iCloud can still connect those toolkits from
    /// Settings → Integrations and the agent will use them when
    /// invoked directly, just without a dedicated proactive pill.
    private static let calendarToolkit = "googlecalendar"

    private init() {}

    /// Build the current row. Connected-toolkits is passed in so the
    /// calendar pill and the connector ranking both reflect live state
    /// from AccountManager without this service having to hold a
    /// reference to it.
    ///
    /// klo 2.1 layered ordering (leading → trailing):
    ///   1. runningSchedule  (most urgent — klo is acting right now)
    ///   2. routineSuggestion (klo's best new idea for you)
    ///   3. routineTip       (day-1 discovery — only when nothing else)
    ///   4. calendar         (live signal)
    ///   5. screen           (live signal)
    ///   6. connectors       (curated starters)
    func snapshot(connectedToolkits: Set<String>) async -> [ProactiveSignal] {
        async let calendarPill = calendarSignal(connectedToolkits: connectedToolkits)
        async let screenPill   = screenSignal()
        let live = await [calendarPill, screenPill].compactMap { $0 }

        // klo 2.1 Track A + B: derived from SchedulesManager state.
        // Pulled at compute time (no observers needed) so the snapshot
        // function stays pure-pull. The host re-snapshots on notch open
        // and on relevant state changes already; that's enough cadence.
        let sm = SchedulesManager.shared
        var leaders: [ProactiveSignal] = []
        if let running = runningPill(activeRuns: sm.activeRuns) {
            leaders.append(running)
        }
        if let suggestion = suggestionPill(suggestions: sm.suggestions) {
            leaders.append(suggestion)
        }
        // Day-1 tip only when the user has nothing going on yet AND
        // hasn't dismissed it. Once shown a single time per session it
        // rotates copy on next open via a different example each tick.
        if sm.active.isEmpty && sm.suggestions.isEmpty {
            if let tip = routineTipPill() {
                leaders.append(tip)
            }
        }

        return leaders + live + connectorPills(connected: connectedToolkits)
    }

    // MARK: - Schedule-derived pills (Track A + B)

    /// Single pill for the highest-priority in-flight scheduled run.
    /// When multiple runs are active concurrently the pill collapses
    /// into a count: "▸ 3 routines running".
    private func runningPill(activeRuns: [ActiveScheduledRun]) -> ProactiveSignal? {
        guard let first = activeRuns.first else { return nil }
        let label: String
        if activeRuns.count == 1 {
            label = "▸ running: \(first.pillLabel)"
        } else {
            label = "▸ \(activeRuns.count) routines running"
        }
        return ProactiveSignal(
            id: UUID(),
            kind: .runningSchedule,
            label: label,
            prompt: ProactiveSignal.runningPillPrefix + first.id,
            icon: .sfSymbol("play.circle.fill"),
            accent: .olive,
        )
    }

    /// Highest-confidence pending suggestion (>= 0.7). Skipped when
    /// no qualifying row exists so we don't fill the row with weak
    /// proposals. Cap of one suggestion pill at a time keeps the row
    /// uncluttered.
    private func suggestionPill(suggestions: [RoutineSuggestion]) -> ProactiveSignal? {
        guard let top = suggestions.sorted(by: { $0.confidence > $1.confidence }).first,
              top.confidence >= 0.7 else { return nil }
        return ProactiveSignal(
            id: UUID(),
            kind: .routineSuggestion,
            label: "routine: \(top.name)?",
            prompt: ProactiveSignal.suggestionPromptPrefix + top.id,
            icon: .sfSymbol("lightbulb.fill"),
            accent: .olive,
        )
    }

    /// Day-1 discovery tip. Rotates through example prompts so the
    /// same one doesn't show every open. Hides after the user has
    /// dismissed it OR has ever created a schedule.
    private func routineTipPill() -> ProactiveSignal? {
        if UserDefaults.standard.bool(forKey: "klo.routineTipDismissed") {
            return nil
        }
        let examples = [
            "every weekday at 9am, brief me on my calendar",
            "every Friday afternoon, summarize my week in linear",
            "every hour, check if anything's blocked in linear",
            "every morning at 8, what should I focus on today?",
        ]
        // Stable per-day pick so the pill doesn't change while the
        // notch is open — variety comes day-to-day, not minute-to-
        // minute.
        let day = Int(Date().timeIntervalSince1970 / 86400)
        let idx = abs(day) % examples.count
        let phrase = examples[idx]
        return ProactiveSignal(
            id: UUID(),
            kind: .routineTip,
            label: "try: \(phrase)",
            prompt: phrase,
            icon: .sfSymbol("sparkles"),
            accent: .olive,
        )
    }

    // MARK: - Live · Calendar (Composio Google Calendar)
    //
    // The pill is a connect CTA only. Once any googlecalendar account
    // is connected, this signal returns nil — the existing connector
    // pill for googlecalendar ("today's events") slides to the front
    // of the row and represents Calendar from then on. No duplication,
    // no native EventKit dependency, no TCC dialog.
    //
    // Multi-account UX lives in Settings → Integrations: there the
    // user can see each connected account by email and add/remove
    // individuals. Keeping that off the pill keeps the notch surface
    // narrow — its job is "what can klo do right now", not account
    // management.

    private func calendarSignal(connectedToolkits: Set<String>) async -> ProactiveSignal? {
        if connectedToolkits.contains(Self.calendarToolkit) {
            return nil
        }
        return ProactiveSignal(
            id: UUID(),
            kind: .calendar,
            label: "connect calendar",
            prompt: ProactiveSignal.connectCalendarPrompt,
            icon: .sfSymbol("calendar.badge.plus"),
            accent: .olive,
        )
    }

    // MARK: - Live · Screen

    /// Reads the frontmost app + browser window title (when in a
    /// browser). For browsers the pill becomes "summarize <page>" —
    /// the page name is the consent signal. For known apps with
    /// a curated verb, the pill mirrors that. Unknown apps get no
    /// pill — better silence than fake helpfulness.
    ///
    /// Internal (was private) so IdleWhisperProvider can reuse it
    /// for the single-line empty-state whisper without re-implementing
    /// the frontmost-app probe.
    func screenSignal() async -> ProactiveSignal? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? ""

        // Sensitive apps — visibly omit the pill. The pill row's job
        // is positive affordance; the "klo doesn't look here" message
        // doesn't fit a pill and would confuse the row's rhythm.
        let sensitive: Set<String> = [
            "com.agilebits.onepassword7",
            "com.1password.1password7",
            "com.1password.1password",
            "com.lastpass.LastPass",
            "com.dashlane.Dashlane",
            "com.bitwarden.desktop",
            "com.apple.keychainaccess",
            "com.intuit.QuickBooks",
        ]
        if sensitive.contains(bundleID) { return nil }

        // klo's own surfaces — don't push pills about ourselves.
        if bundleID.hasPrefix("com.klo") || bundleID == "com.klo.KLO" {
            return nil
        }

        let name = app.localizedName ?? "this app"

        // Browser path: read the window title and craft a "summarize
        // <page>" pill. Screen Recording perm is required for
        // kCGWindowName on modern macOS — klo holds it already.
        let browserIDs: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "company.thebrowser.Browser",      // Arc
            "company.thebrowser.dia",          // Dia
            "org.mozilla.firefox",
            "com.brave.Browser",
            "com.brave.Browser.beta",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
        ]
        if browserIDs.contains(bundleID) {
            guard let page = currentBrowserPageTitle(pid: app.processIdentifier, appName: name) else {
                return nil
            }
            let short = page.count > 22 ? String(page.prefix(20)) + "…" : page
            return ProactiveSignal(
                id: UUID(),
                kind: .screen,
                label: "summarize \(short.lowercased())",
                prompt: "summarize the page open in \(name.lowercased()) titled \"\(page)\" — give me the gist plus anything worth quoting",
                icon: .sfSymbol("doc.text"),
                accent: .copper,
            )
        }

        // Curated app verbs. Same table the previous card design used.
        let perApp: [String: (label: String, prompt: String, sf: String)] = [
            "com.tinyspeck.slackmacgap": (
                "summarize this slack",
                "summarize the slack channel i'm looking at — what happened, who needs a reply, anything time-sensitive",
                "bubble.left.and.bubble.right.fill",
            ),
            "notion.id": (
                "action items from this",
                "read the notion page open in front of me and pull out concrete next actions with owners and dates if i mentioned any",
                "list.bullet.rectangle",
            ),
            "com.apple.mail": (
                "draft a reply",
                "draft a short, warm reply to the email thread i'm reading — match my voice from earlier in the thread",
                "envelope.fill",
            ),
            "com.readdle.smartemail-Mac": (
                "draft a reply",
                "draft a reply to the email thread i'm looking at in spark — keep it short",
                "envelope.fill",
            ),
            "com.microsoft.VSCode": (
                "explain this file",
                "explain the file open in vs code in plain english, then point out anything risky or unfinished",
                "chevron.left.forwardslash.chevron.right",
            ),
            "com.todesktop.230313mzl4w4u92": (
                "walk me through cursor",
                "look at the cursor window i'm in — what file is this, what changed recently, what's risky",
                "chevron.left.forwardslash.chevron.right",
            ),
            "com.linear": (
                "what to ship today",
                "look at my linear and tell me which 2-3 issues are the right ones to push on today",
                "checkmark.circle.fill",
            ),
            "com.figma.Desktop": (
                "walk me through figma",
                "walk me through the figma file i have open — frames, the flow, anything that looks half-finished",
                "rectangle.3.group.fill",
            ),
            "com.apple.Terminal": (
                "explain last command",
                "look at my terminal and explain what the last command did and what the output means",
                "terminal.fill",
            ),
            "com.googlecode.iterm2": (
                "explain last command",
                "look at my terminal and explain what the last command did and what the output means",
                "terminal.fill",
            ),
        ]
        if let v = perApp[bundleID] {
            return ProactiveSignal(
                id: UUID(),
                kind: .screen,
                label: v.label,
                prompt: v.prompt,
                icon: .sfSymbol(v.sf),
                accent: .copper,
            )
        }
        return nil
    }

    private func currentBrowserPageTitle(pid: pid_t, appName: String) -> String? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for win in raw {
            guard let owner = win[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            if let layer = win[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            let title = (win[kCGWindowName as String] as? String) ?? ""
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }
            return stripBrowserSuffix(cleaned, appName: appName)
        }
        return nil
    }

    private func stripBrowserSuffix(_ title: String, appName: String) -> String {
        for sep in [" - \(appName)", " — \(appName)", " | \(appName)"] {
            if title.hasSuffix(sep) {
                return String(title.dropLast(sep.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        for sep in [" - ", " — ", " | "] {
            if let range = title.range(of: sep, options: .backwards) {
                let head = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if head.count >= 3 { return String(head) }
            }
        }
        return title
    }

    // MARK: - Connector starters
    //
    // Mirror of the iOS `PromptSuggestions.featured` set. Same slugs,
    // same labels, same starter prompts — the two surfaces should
    // feel like the same product when a user moves between them.
    // Connected toolkits float to the front so the row reflects what
    // the user actually has available right now.

    private struct ConnectorIdea {
        let slug: String
        let label: String
        let prompt: String
    }

    private static let featuredConnectors: [ConnectorIdea] = [
        .init(slug: "gmail",           label: "search Gmail",
              prompt: "/gmail what are my last 3 emails?"),
        .init(slug: "googlecalendar",  label: "today's events",
              prompt: "/googlecalendar what's on my calendar today?"),
        .init(slug: "slack",           label: "recent Slack",
              prompt: "/slack what are my latest messages?"),
        .init(slug: "notion",          label: "Notion pages",
              prompt: "/notion list my recent pages"),
        .init(slug: "linear",          label: "my issues",
              prompt: "/linear what's assigned to me?"),
        .init(slug: "github",          label: "open PRs",
              prompt: "/github what PRs am I reviewing?"),
        .init(slug: "asana",           label: "due this week",
              prompt: "/asana what tasks are due this week?"),
        .init(slug: "googledrive",     label: "find a doc",
              prompt: "/googledrive find my latest doc"),
    ]

    /// Synchronous public view of the connector pill set. Used by
    /// `ProactiveTextHost.onAppear` so the row is non-empty on the
    /// first paint — live signals slide in on the next beat once the
    /// async `snapshot(…)` returns.
    func connectorPillsOnly(connected: Set<String>) -> [ProactiveSignal] {
        connectorPills(connected: connected)
    }

    private func connectorPills(connected: Set<String>) -> [ProactiveSignal] {
        let sorted = Self.featuredConnectors.sorted { lhs, rhs in
            let lc = connected.contains(lhs.slug)
            let rc = connected.contains(rhs.slug)
            if lc != rc { return lc && !rc }
            return lhs.label.count < rhs.label.count
        }
        return sorted.map { idea in
            ProactiveSignal(
                id: UUID(),
                kind: .connector,
                label: idea.label,
                prompt: idea.prompt,
                icon: .composio(slug: idea.slug),
                accent: .brand,
            )
        }
    }
}
