import SwiftUI

/// "klo wants to schedule something for you." Surfaced in the notch
/// when a pending_schedules row is waiting for explicit user
/// confirmation (the always-confirm gate shipped in 2.0.0). Shows
/// cadence + the prompt or step list + scoped service, with Confirm
/// (olive primary) and Dismiss (ghost) buttons.
///
/// Source paths that land here:
///   - The agent's `schedule_task` tool drafted a schedule from
///     natural-language prose.
///   - The future Mac UI's "New Schedule" form (manual create).
///   - An accepted routine suggestion (Phase 7) after its preview run.
///
/// Dismissed with Esc → Cancel (no reason captured, treated as quiet
/// dismiss). Confirm fires the cloud POST, the row promotes into
/// scheduled_tasks, and the polling SchedulesManager picks up the
/// next pending row from the queue (chained automatically).
struct ScheduleConfirmCard: View {
    let pending: PendingSchedule
    @ObservedObject var state: KLOState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            bodyContent
            Spacer(minLength: 0)
            actionBar
        }
        .frame(width: 760, height: 480)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .onExitCommand {
            Task { await state.rejectPendingSchedule(pending) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(KloColors.olive)
                .frame(width: 8, height: 8)
                .shadow(color: KloColors.olive.opacity(0.6), radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(pending.isRoutine ? "klo wants to set up a routine"
                                       : "klo wants to schedule this")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(originLabel)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.white.opacity(0.42))
                    .textCase(.uppercase)
            }
            Spacer(minLength: 0)
            cadenceChip
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
    }

    private var originLabel: String {
        switch pending.created_via {
        case "agent_tool":  return "from your prompt"
        case "manual":      return "from settings"
        case "suggestion":  return "klo suggested this"
        default:            return pending.created_via
        }
    }

    private var cadenceChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(KloColors.olive)
            Text(pending.cadenceLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Capsule().stroke(KloColors.olive.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyContent: some View {
        if pending.isRoutine {
            routineBody
        } else {
            singleBody
        }
    }

    private var singleBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Prompt")
                Text(pending.prompt)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.04))
                    )

                if let scope = pending.scoped_service, !scope.isEmpty {
                    sectionTitle("Scoped to")
                    Text("/\(scope)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(KloColors.olive)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.white.opacity(0.04))
                        )
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }

    private var routineBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let name = pending.name, !name.isEmpty {
                    sectionTitle("Routine")
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                sectionTitle("Steps (\(pending.steps?.count ?? 0))")
                ForEach(Array((pending.steps ?? []).enumerated()), id: \.offset) { idx, step in
                    stepRow(index: idx + 1, step: step)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }

    private func stepRow(index: Int, step: PendingScheduleStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(KloColors.olive)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(KloColors.olive.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 6) {
                Text(step.prompt)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if let scope = step.scoped_service, !scope.isEmpty {
                        Text("/\(scope)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(KloColors.olive.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.white.opacity(0.04))
                            )
                    }
                    if step.requires_approval == true {
                        Text("ASKS BEFORE RUNNING")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(KloColors.cream.opacity(0.65))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.white.opacity(0.04))
                            )
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
        )
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("klo won't activate this until you tap Confirm.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.45))
                // klo 2.1 Track B2: only suggestion-derived pendings
                // get the "don't suggest again" affordance. Agent-
                // tool-derived rows are explicit user asks; manual-
                // create rows are also explicit. Both have no
                // pattern to teach the detector NOT to propose.
                if pending.created_via == "suggestion" {
                    Button {
                        Task {
                            await state.rejectPendingSchedule(
                                pending,
                                reason: "dont_want",
                            )
                        }
                    } label: {
                        Text("Don't suggest like this again")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(KloColors.fg45.opacity(0.9))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("klo won't propose routines like this again")
                }
            }
            Spacer()
            Button {
                Task { await state.rejectPendingSchedule(pending) }
            } label: {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Dismiss without scheduling")

            Button {
                Task { await state.confirmPendingSchedule(pending) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Confirm")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(KloColors.olive)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Activate this schedule  •  ⌘⏎")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(Color.white.opacity(0.08)),
                    alignment: .top,
                )
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(Color.white.opacity(0.42))
    }
}
