import SwiftUI

/// Multi-step routine composer. Sheet over Settings → Schedules.
///
/// Builds a routine that lands in `pending_schedules` with
/// `kind="routine"` + `steps` jsonb, then surfaces via the standard
/// always-confirm card in the notch on Save (which routes through
/// SchedulesManager → POST /pending_schedules → bridge_state pushes
/// → notch pops the card).
///
/// `prefill` lets the Edit button on SchedulesSection rows hand the
/// builder an existing routine so user can tweak instead of building
/// from scratch.
struct RoutineBuilderView: View {
    let prefill: ScheduledTask?
    let account: AccountManager
    let onDismiss: () -> Void

    @ObservedObject private var manager = SchedulesManager.shared

    @State private var name: String = ""
    @State private var cadencePhrase: String = "daily"
    @State private var steps: [DraftStep] = [DraftStep()]
    @State private var saving: Bool = false
    @State private var lastError: String? = nil
    // klo 2.1 Track C: one-time mode + the DatePicker's selection.
    // Default = tomorrow 9am local so the picker doesn't expose a
    // "right now" pitfall on first open.
    @State private var isOneTime: Bool = false
    @State private var oneTimeDate: Date = {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }()

    /// In-progress step in the builder. UUID-keyed so SwiftUI ForEach
    /// diffs cleanly when the user reorders or removes a row.
    struct DraftStep: Identifiable, Equatable {
        let id: UUID = UUID()
        var prompt: String = ""
        var scoped_service: String = ""
        var requires_approval: Bool = false
        // klo 2.1 Track D: per-step authorization. Each scoped service
        // gets its own allowlist editor. Emails and Slack channels are
        // chip lists; other services are just enabled/disabled toggles.
        // Empty list = draft to chat instead of executing. Carried into
        // the cloud's allowed_actions field on save.
        var emailAllowedTo: [String] = []        // gmail send_email recipients
        var slackAllowedChannels: [String] = []  // slack post_message channels
        var allowOtherWrites: Bool = false       // catch-all for connector writes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    cadenceField
                    stepsList
                    addStepButton
                    if let err = lastError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(KloColors.orange)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            actionBar
        }
        .frame(width: 560, height: 600)
        .background(KloColors.bg)
        .onAppear { applyPrefill() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(prefill == nil ? "New routine" : "Edit routine")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(KloColors.fg)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KloColors.fg45)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Name")
            TextField("Morning brief", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(KloColors.fg.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(KloColors.border, lineWidth: 0.5)
                        )
                )
        }
    }

    // MARK: - Cadence

    private var cadenceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Cadence")
            HStack(spacing: 8) {
                ForEach(["hourly", "daily", "every 30m", "every 4h", "every 2d"], id: \.self) { chip in
                    Button {
                        isOneTime = false
                        cadencePhrase = chip
                    } label: {
                        Text(chip)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(cadencePhrase == chip && !isOneTime ? Color.black : KloColors.fg80)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(cadencePhrase == chip && !isOneTime
                                               ? KloColors.olive
                                               : KloColors.fg.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
                // klo 2.1 Track C: one-time chip swaps the cadence
                // input for a DatePicker. Posts as "on YYYY-MM-DD at
                // HH:MM" which the cloud parses into once(<ISO>).
                Button {
                    isOneTime = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 9, weight: .semibold))
                        Text("one-time")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(isOneTime ? Color.black : KloColors.fg80)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isOneTime
                                       ? KloColors.olive
                                       : KloColors.fg.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }
            if isOneTime {
                oneTimePicker
            } else {
                TextField("or type a cadence — every 30m / every 2h / weekdays at 9am", text: $cadencePhrase)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(KloColors.fg60)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(KloColors.fg.opacity(0.03))
                    )
            }
        }
        .onChange(of: oneTimeDate) { _, _ in syncOneTimePhrase() }
        .onChange(of: isOneTime) { _, newValue in
            if newValue { syncOneTimePhrase() }
        }
    }

    /// Combined date + time picker for one-time scheduling. Stays
    /// inside the builder sheet; defaults to "tomorrow 9am local" so
    /// the first tap doesn't accidentally schedule "30 seconds from
    /// now" because the picker is still on the current minute.
    private var oneTimePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            DatePicker(
                "",
                selection: $oneTimeDate,
                in: Date()...Date().addingTimeInterval(60 * 60 * 24 * 365),
                displayedComponents: [.date, .hourAndMinute],
            )
            .datePickerStyle(.field)
            .labelsHidden()
            Text("Fires once at this exact moment, then completes. Klo deletes the schedule after the run.")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(KloColors.fg45)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(KloColors.fg.opacity(0.03))
        )
    }

    private func syncOneTimePhrase() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let datePart = fmt.string(from: oneTimeDate)
        let tFmt = DateFormatter()
        tFmt.dateFormat = "HH:mm"
        let timePart = tFmt.string(from: oneTimeDate)
        cadencePhrase = "on \(datePart) at \(timePart)"
    }

    // MARK: - Steps

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Steps (\(steps.count))")
            ForEach($steps) { $step in
                stepCard(step: $step, index: steps.firstIndex(of: step) ?? 0)
            }
        }
    }

    private func stepCard(step: Binding<DraftStep>, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(KloColors.olive)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(KloColors.olive.opacity(0.12)))
                Spacer()
                if steps.count > 1 {
                    Button {
                        steps.removeAll { $0.id == step.wrappedValue.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(KloColors.fg45)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove step")
                }
            }
            TextEditor(text: step.prompt)
                .font(.system(size: 12))
                .frame(minHeight: 48)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(KloColors.fg.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(KloColors.border, lineWidth: 0.5)
                        )
                )
            HStack(spacing: 8) {
                Text("/scope")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(KloColors.fg60)
                TextField("gmail / linear / notion (optional)", text: step.scoped_service)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(KloColors.fg80)
                Spacer()
                Toggle(isOn: step.requires_approval) {
                    Text("ask before running")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(KloColors.fg60)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            // Per-step pre-authorization — what destructive actions
            // this step is allowed to take. Empty list = drafts to chat.
            allowlistEditor(step: step)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(KloColors.fg.opacity(0.04))
        )
    }

    /// "What can it do?" block. Only shown when the step has a scope
    /// that supports destructive actions (gmail, slack, anything with
    /// writes). Read-only scopes (briefings, summaries) don't surface
    /// this — the allowlist defaults make their case automatically.
    @ViewBuilder
    private func allowlistEditor(step: Binding<DraftStep>) -> some View {
        let scope = step.scoped_service.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        if scope == "gmail" {
            allowlistBlock(
                title: "Can email:",
                placeholder: "alice@example.com",
                hint: "Leave empty to draft every email for review instead of sending.",
                chips: step.emailAllowedTo
            )
        } else if scope == "slack" {
            allowlistBlock(
                title: "Can post to:",
                placeholder: "#my-team",
                hint: "Leave empty to draft every message for review instead of posting.",
                chips: step.slackAllowedChannels
            )
        } else if !scope.isEmpty {
            // Generic write-toggle for everything else (notion, linear,
            // calendar, docs). Unconstrained when ON, drafts when OFF.
            HStack(spacing: 8) {
                Image(systemName: "shield")
                    .font(.system(size: 10))
                    .foregroundStyle(KloColors.fg45)
                Toggle(isOn: step.allowOtherWrites) {
                    Text("can write to \(scope) (otherwise drafts to chat)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(KloColors.fg60)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
    }

    /// Chip-list editor for email / Slack allowlists.
    private func allowlistBlock(
        title: String,
        placeholder: String,
        hint: String,
        chips: Binding<[String]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(KloColors.olive)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KloColors.fg60)
            }
            ChipListField(
                placeholder: placeholder,
                chips: chips
            )
            Text(hint)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(KloColors.fg45)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(KloColors.olive.opacity(0.04))
        )
    }

    private var addStepButton: some View {
        Button {
            steps.append(DraftStep())
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add step")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(KloColors.fg80)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().strokeBorder(KloColors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack {
            if saving {
                Text("Saving…")
                    .font(.system(size: 11))
                    .foregroundStyle(KloColors.fg60)
            } else {
                Text("Klo will draft this and ask you to confirm in the notch.")
                    .font(.system(size: 11))
                    .foregroundStyle(KloColors.fg45)
            }
            Spacer()
            Button("Cancel", action: onDismiss)
                .buttonStyle(.kloGhost)
            Button(prefill == nil ? "Draft" : "Re-draft") {
                Task { await save() }
            }
            .buttonStyle(.kloPrimary)
            .disabled(!canSave || saving)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(KloColors.fg.opacity(0.03))
                .overlay(
                    Rectangle().frame(height: 0.5).foregroundStyle(KloColors.border),
                    alignment: .top,
                )
        )
    }

    private var canSave: Bool {
        !cadencePhrase.trimmingCharacters(in: .whitespaces).isEmpty
            && steps.contains { !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Prefill (Edit)

    /// Collapse per-step allowlist editors into the cloud's
    /// `allowed_actions` jsonb shape. One entry per (toolkit, action)
    /// pair the user authorized across any step in the routine.
    private func buildAllowedActions(from validSteps: [DraftStep]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for s in validSteps {
            let scope = s.scoped_service.trimmingCharacters(in: .whitespaces).lowercased()
            switch scope {
            case "gmail":
                let to = s.emailAllowedTo
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !to.isEmpty {
                    out.append(["toolkit": "gmail", "action": "send_email", "to": to])
                }
            case "slack":
                let channels = s.slackAllowedChannels
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !channels.isEmpty {
                    out.append(["toolkit": "slack", "action": "post_message", "channels": channels])
                }
            case "":
                continue
            default:
                if s.allowOtherWrites {
                    // Unconstrained write to this toolkit. Cloud's
                    // allowlist matcher treats missing constraints as
                    // "allow any params" for the (toolkit, action) pair.
                    // We can't enumerate every action — use the common
                    // write verbs the agent might pick.
                    let commonWrites = ["create", "update", "delete", "send", "post", "add", "remove"]
                    for verb in commonWrites {
                        out.append(["toolkit": scope, "action": verb])
                    }
                }
            }
        }
        return out
    }

    private func applyPrefill() {
        guard let pre = prefill else { return }
        name = pre.name ?? ""
        cadencePhrase = pre.user_phrase.isEmpty ? pre.cadence : pre.user_phrase
        if let preSteps = pre.steps, !preSteps.isEmpty {
            steps = preSteps.map { p in
                DraftStep(
                    prompt: p.prompt,
                    scoped_service: p.scoped_service ?? "",
                    requires_approval: p.requires_approval ?? false,
                )
            }
        } else {
            // Single-prompt schedule converted to single-step draft.
            steps = [DraftStep(
                prompt: pre.prompt,
                scoped_service: pre.scoped_service ?? "",
                requires_approval: false,
            )]
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        lastError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let cadence = cadencePhrase.trimmingCharacters(in: .whitespaces)
        let validSteps = steps.filter {
            !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let cleanSteps = validSteps.map { s -> [String: Any] in
            var d: [String: Any] = ["prompt": s.prompt.trimmingCharacters(in: .whitespaces)]
            let scope = s.scoped_service.trimmingCharacters(in: .whitespaces).lowercased()
            if !scope.isEmpty { d["scoped_service"] = scope }
            if s.requires_approval { d["requires_approval"] = true }
            return d
        }
        // klo 2.1 Track D — build the pre-auth allowlist from each
        // step's editor state. Empty arrays / disabled toggles mean
        // "draft to chat, don't execute" at fire time.
        let allowedActions = buildAllowedActions(from: validSteps)

        let body: [String: Any] = [
            "user_phrase": cadence,
            "prompt": trimmedName.isEmpty ? "Routine: \(cleanSteps.first?["prompt"] as? String ?? "")" : trimmedName,
            "kind": cleanSteps.count > 1 ? "routine" : "single",
            "name": trimmedName,
            "steps": cleanSteps.count > 1 ? cleanSteps : nil as Any? as Any,
            "created_via": "manual",
            "tz_name": TimeZone.current.identifier,
            "allowed_actions": allowedActions,
        ].compactMapValues { $0 }

        guard let token = await account.withFreshAccessToken() else {
            lastError = "Not signed in"
            return
        }
        let url = AccountManager.cloudBase.appendingPathComponent("pending_schedules")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            lastError = "Could not encode routine"
            return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let detail = dict["detail"] as? [String: Any],
                   let msg = detail["message"] as? String {
                    lastError = msg
                } else {
                    lastError = "Could not save routine"
                }
                return
            }
            // Refresh so SchedulesManager.pending has the new row
            // and KLOState's subscription pops the confirm card.
            await manager.refresh()
            onDismiss()
        } catch {
            lastError = "Network error saving routine"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(KloColors.fg45)
    }
}


/// Editable horizontal chip list. Each chip is a pill with an X to
/// remove; the trailing text field adds a new chip on Return.
/// Used by the routine builder's allowlist editor (Track D) for
/// gmail recipients and slack channels. Pure value-binding — caller
/// owns the array via @State / @Binding.
struct ChipListField: View {
    let placeholder: String
    @Binding var chips: [String]
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chips.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { idx, chip in
                        chipView(chip: chip, index: idx)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(KloColors.fg80)
                    .onSubmit { commitDraft() }
                Button {
                    commitDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(draft.isEmpty ? KloColors.fg45 : KloColors.olive)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(KloColors.fg.opacity(0.04))
            )
        }
    }

    private func chipView(chip: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(chip)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(KloColors.fg80)
            Button {
                chips.remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(KloColors.fg45)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(KloColors.olive.opacity(0.12))
                .overlay(Capsule().strokeBorder(KloColors.olive.opacity(0.25), lineWidth: 0.5))
        )
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !chips.contains(trimmed) else {
            draft = ""
            return
        }
        chips.append(trimmed)
        draft = ""
    }
}


/// Minimal flow layout for chip wrapping. SwiftUI doesn't ship one
/// natively below macOS 13, and the chip count here will be small
/// (<10 typical) so a custom layout is cheaper than pulling in a dep.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var lineW: CGFloat = 0
        var lineH: CGFloat = 0
        var totalH: CGFloat = 0
        var totalW: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if lineW + size.width > maxW, lineW > 0 {
                totalH += lineH + lineSpacing
                totalW = max(totalW, lineW - spacing)
                lineW = 0
                lineH = 0
            }
            lineW += size.width + spacing
            lineH = max(lineH, size.height)
        }
        totalH += lineH
        totalW = max(totalW, lineW - spacing)
        return CGSize(width: totalW, height: totalH)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxW = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxW, x > bounds.minX {
                y += lineH + lineSpacing
                x = bounds.minX
                lineH = 0
            }
            sv.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height),
            )
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}
