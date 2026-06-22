import SwiftUI

/// Settings → Schedules section. Lists the user's active schedules
/// (single-prompt nudges + multi-step routines, both live in
/// `scheduled_tasks` after the 2.0.0 always-confirm flow promotes
/// them out of `pending_schedules`).
///
/// Each row offers: Run-now (debug fire), Delete. Edit lands when the
/// routine builder ships (Phase 5) — the Pencil button opens
/// RoutineBuilderView pre-filled. The "+ New routine" button at the
/// section header opens a fresh builder sheet.
///
/// State source of truth: `SchedulesManager.shared` (started in
/// AppDelegate; polls every 15s while the app is foregrounded).
struct SchedulesSection: View {
    let account: AccountManager
    @ObservedObject private var manager = SchedulesManager.shared
    @State private var hoveredID: String?
    @State private var showingBuilder: Bool = false
    @State private var prefilledRoutine: ScheduledTask? = nil
    @State private var deleteConfirmID: String? = nil
    // klo 2.1 Track D — one-time migration banner. Existing routines
    // need to be re-authorized after the allowed_actions migration
    // (default = []) since they now draft-fallback every destructive
    // action. Banner shows until the user dismisses it OR has no
    // active routines at all.
    @AppStorage("klo.routines.preAuthBannerDismissed")
    private var preAuthBannerDismissed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if shouldShowPreAuthBanner {
                preAuthBanner
            }

            if activeRows.isEmpty {
                emptyState
            } else {
                rows
            }

            if !manager.suggestions.isEmpty {
                suggestionsBlock
            }

            // klo 2.1 Track C: completed one-shot rows for the audit
            // trail. Hidden when none exist so we never bloat the
            // section for users who don't use one-time tasks.
            if !completedOneShots.isEmpty {
                completedBlock
            }
        }
        .padding(.top, 20)
        .task {
            await manager.refresh()
        }
        .sheet(isPresented: $showingBuilder) {
            // RoutineBuilderView lands in Phase 5; for now this sheet
            // is a placeholder that closes itself + tells the user to
            // dictate the routine via the notch.
            RoutineBuilderView(
                prefill: prefilledRoutine,
                account: account,
                onDismiss: { showingBuilder = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("schedules")
                .kloEyebrow()
            Spacer()
            Button {
                prefilledRoutine = nil
                showingBuilder = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("new routine")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(KloColors.fg80)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(KloColors.fg.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .help("Build a multi-step routine")
        }
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(manager.active) { task in
                row(task)
            }
        }
        .padding(.horizontal, -8)
    }

    private func row(_ task: ScheduledTask) -> some View {
        let isHovered = hoveredID == task.id
        let isOffline = (task.status == "mac_offline")

        return HStack(alignment: .center, spacing: 10) {
            // Icon — routine vs single
            Image(systemName: task.isRoutine ? "list.number" : "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOffline ? KloColors.orange : KloColors.olive)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KloColors.fg80)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(task.cadenceLabel)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(KloColors.fg60)
                    if let scope = task.scoped_service, !scope.isEmpty {
                        Text("· /\(scope)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(KloColors.fg45)
                    }
                    if isOffline {
                        Text("· mac offline")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(KloColors.orange.opacity(0.85))
                    } else if task.delivered_count > 0 {
                        Text("· \(task.delivered_count) run\(task.delivered_count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(KloColors.fg45)
                    }
                }
            }

            Spacer(minLength: 8)

            if isHovered {
                rowActions(task)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? KloColors.fg.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? task.id : (hoveredID == task.id ? nil : hoveredID)
        }
    }

    @ViewBuilder
    private func rowActions(_ task: ScheduledTask) -> some View {
        HStack(spacing: 4) {
            // Run-now — useful to test a schedule without waiting for
            // its cadence to come around.
            Button {
                Task { _ = await manager.runNow(task.id) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KloColors.olive)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Run now (test fire)")

            // Edit — opens the builder pre-filled. Single-prompt
            // schedules also open the builder; user can convert to a
            // routine by adding steps.
            Button {
                prefilledRoutine = task
                showingBuilder = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(KloColors.fg60)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit")

            // Delete — confirms inline. Two-tap pattern matches
            // ConversationHistoryView's delete affordance.
            Button {
                if deleteConfirmID == task.id {
                    Task {
                        _ = await manager.deleteActive(task.id)
                        deleteConfirmID = nil
                    }
                } else {
                    deleteConfirmID = task.id
                    // Auto-cancel the confirm after 3s if user doesn't
                    // commit, so the X doesn't sit there forever.
                    let id = task.id
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if deleteConfirmID == id { deleteConfirmID = nil }
                    }
                }
            } label: {
                Image(systemName: deleteConfirmID == task.id ? "checkmark" : "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(deleteConfirmID == task.id
                                     ? KloColors.orange
                                     : KloColors.fg45)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(deleteConfirmID == task.id ? "Tap again to confirm delete" : "Delete")
        }
    }

    // MARK: - Track C completed rows

    /// Active rows we show in the main list — exclude completed
    /// one-shots so they don't muddy the "what's scheduled" surface.
    private var activeRows: [ScheduledTask] {
        manager.active.filter { ($0.status ?? "active") != "completed" }
    }

    /// One-shot tasks that have already fired. Kept around for ~7d
    /// for an audit trail; the cloud may clean them up later via a
    /// daily job.
    private var completedOneShots: [ScheduledTask] {
        manager.active.filter { ($0.status ?? "") == "completed" }
    }

    private var completedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("recently fired")
                .kloEyebrow()
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(completedOneShots) { t in
                    completedRow(t)
                }
            }
            .padding(.horizontal, -8)
        }
    }

    private func completedRow(_ task: ScheduledTask) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(KloColors.olive.opacity(0.7))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(KloColors.fg60)
                    .lineLimit(1)
                Text("fired \(task.last_run_at ?? "recently")")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(KloColors.fg45)
            }
            Spacer()
            Button {
                Task { _ = await manager.deleteActive(task.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(KloColors.fg45)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete record")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(KloColors.fg.opacity(0.02))
        )
    }

    // MARK: - Pre-auth migration banner (Track D)

    /// Show the migration banner only when the user actually has
    /// routines that would be affected. New users (no routines yet)
    /// don't need to be warned about something that doesn't apply
    /// to them.
    private var shouldShowPreAuthBanner: Bool {
        !preAuthBannerDismissed && !manager.active.isEmpty
    }

    private var preAuthBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KloColors.olive)
            VStack(alignment: .leading, spacing: 4) {
                Text("Heads up: your routines now ask before doing anything destructive.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KloColors.fg80)
                Text("Send / post / delete steps will draft to chat for review instead of running automatically. Open a routine and set what it can do to let it run unattended again.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(KloColors.fg60)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                preAuthBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KloColors.fg45)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KloColors.olive.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(KloColors.olive.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Suggestions subsection

    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("suggested by klo")
                    .kloEyebrow()
                Spacer()
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manager.suggestions) { s in
                    suggestionRow(s)
                }
            }
            .padding(.horizontal, -8)
        }
    }

    private func suggestionRow(_ s: RoutineSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KloColors.olive)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KloColors.fg80)
                    Text("\(s.cadenceLabel) · \(s.steps.count) step\(s.steps.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(KloColors.fg60)
                }
                Spacer()
                confidenceBadge(s.confidence)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Preview") {
                    Task { _ = await manager.previewSuggestion(s.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(KloColors.fg80)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(KloColors.fg.opacity(0.06)))

                Button("Schedule") {
                    Task { _ = await manager.acceptSuggestion(s.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(KloColors.olive))

                Button {
                    Task { _ = await manager.dismissSuggestion(s.id, reason: "dont_want") }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(KloColors.fg45)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KloColors.olive.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(KloColors.olive.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    private func confidenceBadge(_ c: Double) -> some View {
        let pct = Int(c * 100)
        return Text("\(pct)%")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(KloColors.olive.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(KloColors.olive.opacity(0.1)))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing scheduled yet.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(KloColors.fg60)
            Text("Ask klo to run something on a cadence — e.g. \"every weekday at 9am, brief me on my calendar\" — or build a multi-step routine.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(KloColors.fg45)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(KloColors.fg.opacity(0.03))
        )
    }
}
