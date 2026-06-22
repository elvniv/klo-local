import Foundation

// The single seam between the Swift UI and the Python desktop_api on :8787.
//
// Two paths:
//   • TEXT mode  — POST /runs, open WS /ws/runs/{id}, render final_message
//                  in the result panel.
//   • VOICE mode — OpenAI Realtime API directly via RealtimeBridge.
//                  The model handles STT + reasoning + TTS in one WebRTC
//                  stream. When it emits a klo_run tool call, we dispatch
//                  via dispatchFromRealtime → submitQuery → /runs → agent;
//                  the result is ferried back into the Realtime conversation
//                  via .kloRealtimeRunComplete.
@MainActor
final class AgentClient: ObservableObject {

    private let httpBase = URL(string: "http://127.0.0.1:8787")!
    private let wsBase = URL(string: "ws://127.0.0.1:8787")!
    private let hostedMode = ProcessInfo.processInfo.environment["KLO_MODE"] == "hosted"

    private weak var state: KLOState?
    private weak var account: AccountManager?
    private weak var realtimeBridge: RealtimeBridge?

    // Text-mode run tracking
    private var currentRunID: String?
    private var currentQuery: String?
    private var wsTask: URLSessionWebSocketTask?

    // Realtime-dispatched run tracking. When non-nil, the currently
    // streaming run was triggered by RealtimeBridge in response to a
    // model function_call (klo_run). On completion we post
    // .kloRealtimeRunComplete with this call_id so the bridge can ferry
    // the result back into the Realtime conversation as a
    // function_call_output.
    private var pendingRealtimeCallID: String?

    private var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600  // klo runs can be long
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init(state: KLOState, account: AccountManager? = nil) {
        self.state = state
        self.account = account
    }

    /// Wire the RealtimeBridge once both exist. The bridge calls
    /// `dispatchFromRealtime` when the model emits a klo_run function
    /// call; we run the task through the normal text-mode pipeline and
    /// post the result back via .kloRealtimeRunComplete.
    func attach(realtimeBridge: RealtimeBridge) {
        self.realtimeBridge = realtimeBridge
        realtimeBridge.attach(agentClient: self)
    }

    /// Entry point used by RealtimeBridge for a model-issued klo_run call.
    /// Forwards into submitQuery and tags this run with the Realtime
    /// call_id so the completion path can post the right notification.
    func dispatchFromRealtime(task: String, callID: String) {
        pendingRealtimeCallID = callID
        submitQuery(task)
    }

    /// Called by RealtimeBridge.stop() when voice mode closes while a
    /// klo_run is still running. Clears the pendingRealtimeCallID so
    /// the eventual final_message routes through the regular text path
    /// (`state.appendAssistantMessage` + `state.showCompleted`) instead
    /// of being silently dropped by `sendFunctionCallOutput`'s
    /// `guard let convo = conversation` against a nil conversation.
    ///
    /// Result of this fix: user can close voice mode immediately after
    /// dispatching a task, then come back ~10s later to find the
    /// agent's answer in the same chat surface text mode uses. The
    /// user's original spoken question (already appended in
    /// `submitQuery` via `dispatchFromRealtime`) is also in the
    /// transcript, so the conversation reads coherently.
    func detachRealtimeCalls(ids: [String]) {
        guard let pending = pendingRealtimeCallID, ids.contains(pending) else { return }
        NSLog("KLO Agent: detaching realtime callID \(pending) — result will land in chat panel")
        pendingRealtimeCallID = nil
    }

    // MARK: - Voice lifecycle

    func startVoiceCapture() {
        NSLog("KLO Voice: starting Realtime transport")
        realtimeBridge?.start()
    }

    @discardableResult
    func stopVoiceCapture() -> String {
        realtimeBridge?.stop()
        return ""
    }

    // MARK: - Text path (unchanged contract: POST /runs + WS)

    func submitQuery(_ text: String, scopedService: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSLog("KLO: submitQuery (text) → \(trimmed.prefix(100))\(scopedService.map { " [scope=\($0)]" } ?? "")")

        // Auth + subscription gate. If the user isn't .signedInActive,
        // surface either the small sign-in island OR the (still-big)
        // paywall card depending on what's blocking.
        if hostedMode, let account = account, !account.isReady {
            let reason = Self.paywallReason(for: account.status)
            NSLog("KLO: gated text submit — \(reason)")
            if reason == .signInRequired {
                // Small sign-in island, not the giant paywall card.
                // User asked for an "island, not a list" UX.
                state?.requireSignIn(draftPrompt: trimmed)
                // Auto-start OAuth so the user doesn't have to click
                // through an extra button.
                if case .signedOut = account.status {
                    Task { await account.startSignInWithGoogle() }
                }
            } else {
                // Subscribe / billing / expired — keep the paywall
                // card; these need clickable Stripe Checkout / Portal
                // CTAs and aren't suited to a tiny island.
                state?.requirePaywall(reason: reason, draftPrompt: trimmed)
                account.recheck()
            }
            return
        }

        // No Mac-side permission preflight here. The agent owns the
        // decision via the `request_permission` tool — if it actually
        // needs SR/AX/AppleEvents to complete the user's task, it
        // calls the tool, which returns a structured `permission_denied`
        // payload, captured by the desktop_api hook and surfaced to
        // `handleMessage`'s status_change branch (which routes to the
        // orchestrator). This avoids the false-positive loop a
        // Mac-side preflight produces under cdhash drift, where the
        // running process reads "untrusted" even though the user has
        // already granted in Settings (TCC binds trust per-cdhash;
        // every Debug rebuild gets a new one).

        currentQuery = trimmed
        // Snapshot the prior conversation BEFORE we append the new
        // user turn — that way the just-typed prompt only ever lives
        // in the request's `prompt` field, not duplicated in
        // `prior_messages`. The agent's run() prepends its own system
        // prompt and treats `prior_messages` as the conversation tail.
        let priorSnapshot = state?.messages ?? []
        state?.appendUserMessage(trimmed, scopedService: scopedService)
        // CRITICAL: Don't flip state.mode to .working when the run was
        // dispatched from voice mode. The mode flip tears down
        // VoiceInputView (different content branch), which fires
        // onDisappear → realtimeBridge.stop() → voice session dies
        // before the model can narrate progress or speak the result.
        // The mic + WebRTC conversation MUST stay alive through the
        // whole agent run so the Realtime model can ferry the result
        // back via sendFunctionCallOutput. Voice mode shows the work
        // via its own currentAction indicator + verbal narration.
        //
        // For text-mode runs, startWorking is still correct — that's
        // what surfaces the working pill UI for the user.
        if pendingRealtimeCallID == nil {
            state?.startWorking(query: trimmed)
        } else {
            // Voice-dispatched: track the activity (so the voice panel's
            // currentAction indicator can show "looking at your screen…")
            // without changing mode. Reset action ledger for a clean
            // run.
            state?.clearToolActivity()
            state?.workingStartedAt = Date()
            NSLog("KLO Agent: voice-dispatched run, keeping mode=%@", "\(state?.mode ?? .idle)")
        }

        Task { [weak self] in
            await self?.postRunAndOpenStream(prompt: trimmed,
                                             priorMessages: priorSnapshot,
                                             scopedService: scopedService)
        }
    }

    /// Maps AccountManager.Status → KLOState.PaywallReason. Anything
    /// that isn't .signedInActive maps to one of the four paywall
    /// CTAs.
    private static func paywallReason(for status: AccountManager.Status) -> KLOState.PaywallReason {
        switch status {
        case .signedInUnsubscribed:     return .subscribeRequired
        case .signedInPastDue:          return .updateBillingRequired
        case .signedInExpired:          return .resubscribeRequired
        case .signedInActive:           return .subscribeRequired // unreachable — caught above
        case .unknown, .signedOut, .awaitingOAuth:
            return .signInRequired
        }
    }

    /// Type the user types into WebPaneView's bottom input row while
    /// the agent is running. Two kinds:
    ///   - .steer   ("⏎")  abandon current plan, pursue this instead
    ///   - .inject  ("⌘⏎") additive context, keep current plan
    /// Sent as a WS frame to the active run; the Python agent drains
    /// the inbox at the next turn boundary. No-op if there's no run.
    enum InterruptKind: String { case steer, inject }

    func sendInterrupt(_ text: String, kind: InterruptKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let task = wsTask, task.state == .running else {
            NSLog("KLO: sendInterrupt — no active WS, dropping")
            return
        }
        let payload: [String: Any] = [
            "type": "inject_message",
            "payload": ["text": trimmed, "kind": kind.rawValue],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            NSLog("KLO: sendInterrupt — failed to encode")
            return
        }
        // Append to the local conversation transcript so the user can see
        // their interrupt landed (and so prior_messages on a future submit
        // includes it). Tagged as a user message, same shape as the
        // initial prompt.
        state?.appendUserMessage(trimmed)
        task.send(.string(str)) { err in
            if let err {
                NSLog("KLO: sendInterrupt WS send failed: \(err)")
            }
        }
    }

    /// Pause the running agent loop — user clicked TAKE OVER in the
    /// web pane. The loop suspends at its next turn boundary and the
    /// user is free to drive the WKWebView directly. Returns
    /// immediately; the pause takes effect within ~250ms.
    func pauseRun() {
        guard let runID = currentRunID else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.postRunAction(runID: runID, action: "pause")
            if !ok {
                // WebPaneView flipped isPaused optimistically — revert
                // so the UI doesn't claim a pause that never landed.
                self.state?.isPaused = false
                self.state?.showTransientNotice("Couldn't pause klo — it's still working")
            }
        }
    }

    /// Resume the paused agent loop — user clicked HAND BACK. The loop
    /// picks up at the next 250ms poll cycle with full conversation
    /// history intact. Anything the user did to the page in between
    /// is visible to the agent's next read (web.screenshot/text).
    func resumeRun() {
        guard let runID = currentRunID else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.postRunAction(runID: runID, action: "resume")
            if !ok {
                // Keep the UI truthful: klo is still paused server-side.
                self.state?.isPaused = true
                self.state?.showTransientNotice("Couldn't hand back to klo — try again")
            }
        }
    }

    func cancelCurrentRun() {
        let runID = currentRunID
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        if let runID {
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.postRunAction(runID: runID, action: "cancel")
                if !ok {
                    // The panel already collapsed — the honest move is
                    // a brief notice that the stop may not have landed.
                    self.state?.showTransientNotice("Couldn't stop the task — it may still finish")
                }
            }
        }
        currentRunID = nil
        currentQuery = nil
        state?.collapseToIdle()
    }

    /// Shared POST helper for run control actions (pause/resume/cancel/
    /// confirm). Returns whether the sidecar accepted the request so
    /// callers can revert optimistic UI and surface a transient notice
    /// — a failed pause/resume used to leave the UI saying "paused"
    /// while the agent kept running, with only an NSLog to show for it.
    @discardableResult
    private func postRunAction(runID: String, action: String, body: Data? = nil) async -> Bool {
        let url = httpBase.appendingPathComponent("runs/\(runID)/\(action)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        do {
            let (_, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                NSLog("KLO RunAction: \(action) run=\(runID) status=\(status) OK")
                return true
            }
            NSLog("KLO RunAction: \(action) run=\(runID) status=\(status) FAILED — sidecar rejected the request")
            return false
        } catch {
            NSLog("KLO RunAction: \(action) run=\(runID) network FAILED — \(error.localizedDescription)")
            return false
        }
    }

    /// Resolve a pending `confirm_action` tool call. Routed from the
    /// inline `ConfirmActionView` (and from the global ESC handler on
    /// reject). Sends the decision to the sidecar so the agent's
    /// blocked tool call unblocks; we also flip state back to
    /// `.working` so the user sees the run resume instead of the
    /// panel snapping shut. The sidecar will emit the next event
    /// (tool result → progress → completed/failed) which the WS
    /// stream surfaces as usual.
    func submitConfirm(approved: Bool) {
        guard let runID = currentRunID else {
            NSLog("KLO: submitConfirm with no active run — ignoring")
            return
        }
        let query = currentQuery ?? ""
        // Snapshot the pending confirm payload so a failed POST can
        // re-pose the question instead of leaving the agent blocked
        // behind a "working" pill forever.
        let pendingPayload: KLOState.ConfirmPayload? = {
            if case .confirmingAction(let payload) = state?.mode { return payload }
            return nil
        }()
        Task { [weak self] in
            guard let self else { return }
            // JSON encoding of `["approved": approved]` cannot actually
            // fail for a Bool — but the previous try? swallowed it
            // regardless. Use the do/catch to make that explicit.
            let body: Data
            do {
                body = try JSONSerialization.data(withJSONObject: ["approved": approved])
            } catch {
                NSLog("KLO: submitConfirm JSON encode failed (impossible?) — \(error)")
                return
            }
            let ok = await self.postRunAction(runID: runID, action: "confirm", body: body)
            if !ok {
                // The agent is still blocked on the confirm — bring
                // the question back rather than faking progress.
                if let pendingPayload {
                    self.state?.requireConfirmation(payload: pendingPayload)
                }
                self.state?.showTransientNotice("Couldn't send your answer — try again")
            }
        }
        // Drop back into the working pill — the run continues on the
        // sidecar regardless of approve/reject. If rejected, the
        // agent will report the cancellation cleanly via the next
        // final_message.
        Task { @MainActor in
            self.state?.startWorking(query: query)
        }
    }

    private func postRunAndOpenStream(prompt: String,
                                       priorMessages: [KLOState.Message],
                                       scopedService: String? = nil) async {
        let url = httpBase.appendingPathComponent("runs")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Wire the multi-turn conversation. agent2's Agent.run takes
        // `prior_messages` as a list of {role, content} dicts and
        // inserts them after the system prompt, before the new
        // `prompt`. Sending an empty array is fine (single-turn).
        let priorPayload: [[String: String]] = priorMessages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        var payload: [String: Any] = [
            "prompt": prompt,
            "mode": "auto",
            "browser_mode": "klo_chrome",
            "prior_messages": priorPayload,
        ]
        if let scope = scopedService, !scope.isEmpty {
            payload["scoped_service"] = scope
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                // Sidecar's create_run now pre-flights /usage/task_start
                // against klo-cloud. Map structured statuses to UI:
                //   402 → trial exhausted (or subscription required) →
                //         existing paywall card flow with the original
                //         prompt preserved as the draft.
                //   401 → session rejected by cloud → sign-in island.
                //   anything else → generic backend-error failure.
                NSLog("KLO: POST /runs failed (\(status)): \(body.prefix(200))")
                if status == 402 {
                    // Refresh AccountManager so /auth/me's fresh counters
                    // populate before the paywall renders (so the
                    // subscribe block reads the right copy).
                    await self.account?.refreshNow()
                    // Parse the cloud's structured error code so the
                    // paywall can show the right story:
                    //   "daily_limit_reached" → soft, "more tomorrow"
                    //   "trial_expired"       → final, "trial ended"
                    //   anything else         → generic subscribe block
                    // Falls back to .subscribeRequired on any parse
                    // failure (legacy 402 envelopes still work).
                    let reason = Self.paywallReason(fromBody: data)
                    await MainActor.run {
                        self.state?.requirePaywall(reason: reason,
                                                   draftPrompt: prompt)
                    }
                    return
                }
                if status == 401 {
                    await self.account?.refreshNow()
                    await MainActor.run {
                        self.state?.requireSignIn(draftPrompt: prompt)
                    }
                    return
                }
                await MainActor.run { self.state?.showFailed(query: prompt, error: "klo hit a problem starting that task. Try again in a moment.") }
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runID = json["id"] as? String else {
                NSLog("KLO: POST /runs returned malformed JSON")
                await MainActor.run { self.state?.showFailed(query: prompt, error: "klo hit a problem starting that task. Try again in a moment.") }
                return
            }
            await MainActor.run { self.currentRunID = runID }
            // The sidecar echoes the post-claim trial counters in the
            // /runs response. Push them into AccountManager so the usage
            // strip in Settings stays in sync without waiting on the
            // next /auth/me poll.
            if let mode = json["access_mode"] as? String, mode == "trial" {
                let used = (json["trial_runs_used"] as? Int) ?? self.account?.trialRunsUsed ?? 0
                let limit = (json["trial_runs_limit"] as? Int) ?? self.account?.trialRunsLimit ?? 0
                await self.account?.updateTrialCounters(used: used, limit: limit, mode: mode)
            }
            // Refresh the time-trial chip state too. /usage/today returns
            // the new fields (chats_today, days_left, trial_expires_at)
            // that aren't in the /runs response. Fires-and-forgets — the
            // chip lags by one HTTP round trip (~100ms), which is
            // imperceptible.
            if let account = self.account {
                Task { await account.refreshUsageToday() }
            }
            NSLog("KLO: opened run \(runID), connecting WS")
            openWebSocket(runID: runID, prompt: prompt)
        } catch {
            // The POST goes to 127.0.0.1 — a network throw here means
            // the LOCAL sidecar is down, not the cloud. Distinct copy
            // from the cloud-unreachable case (upstream_unreachable).
            NSLog("KLO: POST /runs threw: \(error)")
            await MainActor.run { self.state?.showFailed(query: prompt, error: "klo's agent isn't running — quit and reopen klo.") }
        }
    }

    private func openWebSocket(runID: String, prompt: String) {
        let wsURL = wsBase.appendingPathComponent("ws/runs/\(runID)")
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: "local")]

        let task = session.webSocketTask(with: components.url!)
        wsTask = task
        task.resume()
        NSLog("KLO: WS connected to \(components.url!) [runID=\(runID)]")
        receiveNext(task: task, prompt: prompt, ownRunID: runID)
    }

    private func receiveNext(task: URLSessionWebSocketTask, prompt: String, ownRunID: String) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor in
                    if self.currentRunID != ownRunID {
                        NSLog("KLO: ignored stale WS failure for runID=\(ownRunID)")
                        return
                    }
                    NSLog("KLO: WS receive failed [runID=\(ownRunID)]: \(error)")
                    // Show user-visible failure for chat-mode runs. For
                    // voice runs (mode=.voiceExpanded) the result still
                    // arrives via the Realtime channel + final_message
                    // → kloRealtimeRunComplete path, so a WS drop isn't
                    // user-fatal there and surfacing an error would
                    // interfere with the voice UI. Previous code only
                    // showed the error for `.working` mode, which meant
                    // a WS drop with the chat panel collapsed (mode =
                    // anything else with a run still in flight) was
                    // completely silent. Now we explicitly enumerate.
                    if case .working = self.state?.mode {
                        self.state?.showFailed(query: prompt, error: "klo lost track of that task — try again.")
                    } else if case .voiceExpanded = self.state?.mode {
                        // Voice path — silent UI is correct, but log
                        // distinctly so we can find this in incidents.
                        NSLog("KLO: WS dropped during voice run [runID=\(ownRunID)] — Realtime ferry-back will deliver the result if the run completes")
                    } else {
                        // Any other mode (idle/completed/etc.) with a
                        // run that thought it was current: the run is
                        // probably already terminal. Log it but don't
                        // splash a stale error onto the user.
                        NSLog("KLO: WS dropped for run [runID=\(ownRunID)] state=\(String(describing: self.state?.mode)) — no UI surface; likely terminal")
                    }
                    self.currentRunID = nil
                }
                return
            case .success(let message):
                Task { @MainActor in
                    if self.currentRunID != ownRunID { return }
                    self.handleMessage(message, prompt: prompt)
                }
                if task.state == .running {
                    self.receiveNext(task: task, prompt: prompt, ownRunID: ownRunID)
                }
            }
        }
    }

    @MainActor
    private func handleMessage(_ message: URLSessionWebSocketTask.Message, prompt: String) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let payload = text.data(using: .utf8) else {
            NSLog("KLO: WS message UTF-8 conversion failed — len=\(text.count) head=\(text.prefix(80))")
            return
        }
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                NSLog("KLO: WS message parsed but not a JSON object — head=\(text.prefix(120))")
                return
            }
            json = parsed
        } catch {
            // Used to be `try?`-swallowed. Now: distinct NSLog so we can
            // grep for "WS JSON parse" in user incidents. A burst of
            // these means the sidecar started emitting non-JSON events
            // (e.g., binary frames, partial messages, schema break).
            NSLog("KLO: WS JSON parse failed — \(error.localizedDescription); head=\(text.prefix(120))")
            return
        }
        let type = (json["type"] as? String) ?? ""
        let body = (json["payload"] as? [String: Any]) ?? [:]
        switch type {
        case "final_message":
            let response = (body["text"] as? String) ?? "(no text)"
            NSLog("KLO: final_message — \(response.prefix(120))")
            // Realtime-dispatched run completed: forward the response
            // text back to the Realtime conversation as a
            // function_call_output so the model can incorporate the
            // result into its next spoken reply. We do this BEFORE
            // the existing TCC / paywall handling because the Realtime
            // model needs the function-call closure regardless of
            // what UI we surface to the user.
            if let callID = pendingRealtimeCallID {
                pendingRealtimeCallID = nil
                // Encode {"result": response} for the Realtime ferry.
                // Used to be try? with a "{\"result\":\"\"}" fallback —
                // a silently empty result is WORSE than not sending,
                // because the Realtime model would then "speak the
                // result" of an empty string and report success. If
                // encoding fails (e.g., `response` contains characters
                // that JSONSerialization can't handle), log distinctly
                // and skip the ferry so RealtimeBridge's drift /
                // hallucination guards can catch the missing result.
                let outputJSON: String
                do {
                    let data = try JSONSerialization.data(withJSONObject: ["result": response])
                    outputJSON = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    NSLog("KLO: final_message JSON encode FAILED for callID=\(callID) — \(error); voice ferry skipped")
                    return
                }
                if outputJSON.isEmpty {
                    NSLog("KLO: final_message JSON encoded to empty string for callID=\(callID); voice ferry skipped")
                    return
                }
                NotificationCenter.default.post(
                    name: .kloRealtimeRunComplete,
                    object: nil,
                    userInfo: ["call_id": callID, "output": outputJSON],
                )
                // STRICT MODALITY MATCH — voice asks, voice answers.
                //
                // We do NOT call state.appendAssistantMessage and we do
                // NOT call state.showCompleted here. Both would flip
                // state.mode away from .voiceExpanded, which fires
                // VoiceInputView.onDisappear → realtimeBridge.stop(),
                // which kills the WebRTC conversation before
                // sendFunctionCallOutput can ferry the tool result to
                // the Realtime model and trigger the spoken reply.
                //
                // Empirically confirmed: previous build that DID call
                // these flipped voice → chat panel, and the user heard
                // silence instead of an answer because the conversation
                // died at the wrong moment.
                //
                // The Realtime conversation owns the entire deliverable
                // surface for voice runs. The user heard the answer;
                // there's no need to also surface it as text in the
                // notch panel. If the user wants a written record they
                // can ask the same question in text mode (⌘K).
                //
                // Teardown happens on the terminal status_change (the
                // sidecar emits it right after final_message) — see the
                // status_change branch below for why we keep the WS
                // open through final_message.
                return
            }
            // If the agent finalized with a TCC-denial excuse instead
            // of doing the task, route to the FULL grant flow (Settings
            // pane + drag island + auto-retry on grant) — not just the
            // in-notch permission island. The user wants the
            // hand-holding, not a refusal.
            if let service = Self.detectPermissionDenial(in: response),
               let monitorService = PermissionMonitor.Service(service)
            {
                NSLog("KLO: final_message contained TCC denial for \(service.displayName) — opening grant flow")
                let queryToRetry = prompt
                let weakSelf = self
                PermissionGrantOrchestrator.shared.request(service: monitorService) {
                    weakSelf.submitQuery(queryToRetry)
                }
                state?.requirePermission(query: prompt, service: service)
            } else {
                // Append to the conversation so the next submitQuery
                // includes this assistant turn in `prior_messages`.
                // Done BEFORE `showCompleted` so the @Published
                // animations from showCompleted can settle on a
                // consistent state snapshot.
                state?.appendAssistantMessage(response)
                state?.showCompleted(query: prompt, response: response)
            }
            // DON'T tear down the WS here. The sidecar emits the
            // terminal status_change immediately AFTER final_message,
            // and that event can carry error_code (e.g.
            // "extension_not_connected" on a run where the agent
            // gracefully replied without the tool). Cancelling the WS
            // now — and nilling currentRunID, which makes receiveNext
            // drop every later frame as stale — meant the terminal
            // event was lost and the branded extension card never
            // showed for "completed" runs. The status_change branch
            // below owns teardown for terminal statuses.
        case "error":
            let raw = (body["message"] as? String) ?? "Unknown error"
            NSLog("KLO: error — \(raw)")
            state?.showFailed(query: prompt, error: humanizeRunError(raw))
            wsTask?.cancel(with: .normalClosure, reason: nil)
            wsTask = nil
            currentRunID = nil
        case "status_change":
            let status = (body["status"] as? String) ?? ""
            let errorCode = body["error_code"] as? String
            // pause/resume notifications. The Mac state mirrors the
            // server-side `paused` flag so WebPaneView can swap its
            // working pill for the HAND BACK control without any
            // separate state-machine plumbing.
            if let isPausedFlag = body["paused"] as? Bool {
                state?.isPaused = isPausedFlag
            }

            // STRUCTURED permission-denied signal from the sidecar.
            // The sidecar's tool dispatcher preflights TCC trust and
            // emits this code when the SIDECAR's own AXIsProcessTrusted
            // returns false — which is the actual gate, not the Mac
            // app's TCC view. Wire directly to the orchestrator: the
            // user gets the right Privacy entry deep-link + drag
            // island + auto-retry, no regex prose-matching.
            if errorCode == "permission_denied",
               let svcRaw = body["permission_service"] as? String,
               let service = PermissionMonitor.Service(rawValue: svcRaw)
            {
                NSLog("KLO: structured permission_denied for \(service.displayName) — routing to orchestrator")
                // Tell the monitor immediately so any other observers
                // see the .notGranted flip before the next poll.
                PermissionMonitor.shared.noteDenialFromSidecar(service)
                let queryToRetry = prompt
                let weakSelf = self
                PermissionGrantOrchestrator.shared.request(service: service) {
                    // BEFORE re-running the query, flip state into the
                    // brief `.resuming` mode so the notch reappears
                    // carrying a "Continuing your request…" pill (M5).
                    // submitQuery's startWorking transition then morphs
                    // into the working chat surface naturally.
                    weakSelf.state?.noteAutoRetry(query: queryToRetry)
                    weakSelf.submitQuery(queryToRetry)
                }
                // INTENTIONAL: do not also flip state to .permissionRequired
                // here. The orchestrator owns the runtime grant UI (Settings
                // deep-link + instruction card below Settings + auto-retry
                // on grant). Putting the notch in .permissionRequired in
                // parallel makes its 1000×700pt panel interactive
                // (ignoresMouse=false in that mode) — the panel then eats
                // clicks on the Accessibility toggle in Settings since it
                // floats above the upper screen. KLOWindowController hides
                // the panel entirely while orchestrator.phase == .awaiting
                // (see bindGrantPhase), so we just leave state where it is
                // and let the orchestrator drive the user experience.
                //
                // error_code only ever rides a terminal status_change
                // (desktop_api attaches it to the completed/failed
                // payloads), so close the WS before bailing — the
                // shared teardown below is unreachable past this return.
                if ["completed", "failed", "cancelled", "needs_review"].contains(status) {
                    wsTask?.cancel(with: .normalClosure, reason: nil)
                    wsTask = nil
                    currentRunID = nil
                }
                return
            }

            // The sidecar tags any tool failure that came from a
            // missing Chrome extension with this code, even on
            // "completed" runs (the agent might have replied
            // gracefully without the tool — but the user still asked
            // for a browser action).
            //
            // ONLY flip to the branded ".failedExtensionMissing" card
            // when the run is still in `.working` — i.e. the agent
            // never produced a final reply. On a run where
            // `final_message` already arrived and mode is
            // `.completed`, the user's reply is the answer they
            // asked for. Flashing the branded card on top of a
            // streaming response was the "agent replied, then a
            // little failure error appeared, then it closed" bug
            // reported on Vercel deployment checks (and anything
            // where the agent successfully answered via shell/applescript
            // after a transient extension hiccup). Keep the response
            // visible; surface the extension nudge as a transient
            // notice the user can dismiss without losing the answer.
            if errorCode == "extension_not_connected" {
                if case .working = state?.mode {
                    state?.showFailedExtensionMissing(query: prompt)
                } else if case .completed = state?.mode {
                    state?.showTransientNotice(
                        "Chrome extension wasn't connected — install it for browser tasks.",
                        duration: 5.0
                    )
                }
            } else if status == "failed" || status == "cancelled" {
                if case .working = state?.mode {
                    let rawReason = (body["reason"] as? String) ?? "Run \(status) without a final message."
                    state?.showFailed(query: prompt, error: humanizeRunError(rawReason))
                }
            }

            // Terminal status — the sidecar's WS loop breaks right
            // after sending this, so close our side and clear the run
            // tracking. (final_message no longer tears down — see
            // comment there.)
            if ["completed", "failed", "cancelled", "needs_review"].contains(status) {
                wsTask?.cancel(with: .normalClosure, reason: nil)
                wsTask = nil
                currentRunID = nil
            }
        case "step_progress":
            // Tool-call activity. Sidecar emits these for every
            // computer.*, accessibility.*, applescript, shell, etc.
            // KLOState translates name+action+detail into a human label
            // ("looking at your screen", "clicking the menu") which
            // the working-mode overlay renders as the active subtitle
            // line + ticker.
            let name = (body["name"] as? String) ?? "?"
            let action = body["action"] as? String
            let detailRaw = body["detail"] as? String
            let detail: String? = (detailRaw?.isEmpty == false) ? detailRaw : nil
            state?.noteToolActivity(name: name, action: action, detail: detail)
            // If this run was dispatched FROM voice mode, also forward
            // the progress label to RealtimeBridge so the Realtime
            // model can narrate it back to the user mid-run. Without
            // this, the user gets dead air during the 5-15s the agent
            // takes per run — voice mode feels broken. RealtimeBridge
            // throttles so we don't spam the conversation.
            if pendingRealtimeCallID != nil,
               let bridge = realtimeBridge,
               let labelSrc = state?.currentAction
            {
                bridge.noteAgentProgress(label: labelSrc)
            }
        case "injection_acknowledged":
            // Server ack of an inject_message frame the user typed in
            // the WebPaneView input row. The agent will actually drain
            // and respond at its next turn boundary; this just confirms
            // the message arrived so the UI can show the brief toast.
            let kind = (body["kind"] as? String) ?? "inject"
            let text = (body["text"] as? String) ?? ""
            NotificationCenter.default.post(
                name: .kloInjectionAcknowledged,
                object: nil,
                userInfo: ["kind": kind, "text": text],
            )
        case "confirm_request":
            // Agent called the `confirm_action` tool for a destructive
            // / sending / money / system-changes action. Surface the
            // inline ConfirmActionView. The user's response is routed
            // back through `submitConfirm(approved:)` → POST
            // /runs/<id>/confirm, which unblocks the agent's pending
            // tool call. Until then the run is paused.
            let summary = (body["summary"] as? String) ?? ""
            let irreversible = (body["irreversible"] as? Bool) ?? true
            let danger = (body["danger"] as? String)
            let payload = KLOState.ConfirmPayload(
                summary: summary,
                irreversible: irreversible,
                danger: (danger?.isEmpty == false) ? danger : nil,
                query: prompt
            )
            state?.requireConfirmation(payload: payload)
        default:
            break
        }
    }

    /// Convert a raw sidecar/cloud error message into something safe
    /// to render in the notch-panel error bubble.
    ///
    /// Two layers:
    ///   1. Stable codes (`upstream_overloaded`, `upstream_billing`,
    ///      `upstream_blocked`, `upstream_timeout`, `upstream_error`)
    ///      from agent2's _classify_run_error → friendly text.
    ///   2. Catch-all sanitizer regex — if a raw upstream string
    ///      somehow slips past the server-side classifier (Render
    ///      WAF block, future code path that forgets to map, etc.),
    ///      detect HTML/upstream-leak patterns and replace with a
    ///      generic "Something went wrong" message. Raw text still
    ///      goes to NSLog for devs.
    ///
    /// Mirrors the Chrome extension's humanizeError at
    /// extension/background.js — keep them in sync.
    @MainActor
    private func humanizeRunError(_ raw: String) -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case "upstream_overloaded": return "klo is overloaded right now. Try again in a moment."
        case "upstream_timeout":    return "klo took too long. Try again."
        case "upstream_billing":    return "Having trouble right now. Try again in a sec."
        case "upstream_blocked":    return "Couldn't reach klo right now. Try again."
        case "upstream_error":      return "Having trouble right now. Try again in a sec."
        case "upstream_unreachable": return "klo can't reach the cloud — check your internet connection."
        default:
            break
        }

        // Catch-all: if the message looks anything like raw upstream
        // text (HTML tags, multi-line, very long, or contains
        // infrastructure / vendor names that shouldn't be shown to
        // end users), suppress to a generic message.
        let htmlPattern = #"<\s*html|<\s*body|<\s*head|<!DOCTYPE|<\s*script|<\s*style"#
        let leakPattern = #"(?i)render|waf|request id|request_id|anthropic|openai|ratelimit|firewall|forbidden|http\s+\d{3}|powered by"#
        let looksRaw = code.contains("\n")
            || code.count > 120
            || code.range(of: htmlPattern, options: .regularExpression) != nil
            || code.range(of: leakPattern, options: .regularExpression) != nil
        if looksRaw {
            NSLog("KLO Agent: suppressing raw error from UI: %@", String(code.prefix(400)))
            return "Something went wrong. Try again."
        }
        return code
    }

    // MARK: - TCC denial detection

    /// Scan a final_message text for signals that the agent stopped
    /// because of a macOS TCC permission denial. If found, returns
    /// which service is blocked so the UI can route to the right
    /// permission island and System Settings deep link.
    ///
    /// Pattern is heuristic — agent2's final messages aren't
    /// structured, they're natural-language. Matches are case-
    /// insensitive substring hits against well-known phrases the
    /// agent uses when surfacing TCC failures (e.g. "screen-capture
    /// permission was denied", "TCC error -3801", "Accessibility
    /// permission for this assistant was declined"). Errs toward
    /// false-negatives (treat as completed run) rather than false-
    /// positives (block a successful task on a substring hit).
    static func detectPermissionDenial(in text: String) -> KLOState.PermissionService? {
        let s = text.lowercased()

        // Screen Recording — most common signal. The "-3801" error code
        // is unambiguous; the phrase matches too. Also catch the
        // model's "polite refusal" phrasing where it claims it can't
        // see the screen without ever calling the screenshot tool.
        if s.contains("-3801")
            || s.contains("screen-capture permission")
            || s.contains("screen capture permission")
            || s.contains("screen recording permission")
            || s.contains("screen recording access")
            || s.contains("screen recording isn't")
            || s.contains("screen recording is not")
            || (s.contains("screen recording") && (s.contains("hasn't") || s.contains("not granted") || s.contains("not enabled") || s.contains("turned off")))
            || (s.contains("see your screen") && (s.contains("can't") || s.contains("cannot") || s.contains("not able") || s.contains("unable")))
            || (s.contains("see the screen") && (s.contains("can't") || s.contains("cannot") || s.contains("not able") || s.contains("unable")))
            || (s.contains("view your screen") && (s.contains("can't") || s.contains("cannot") || s.contains("not able") || s.contains("unable")))
            || (s.contains("screen") && s.contains("permission") && s.contains("denied"))
            || (s.contains("screencapturekit") && s.contains("declined"))
        {
            return .screenRecording
        }

        // Accessibility — match a wider set of phrasings the model
        // tends to use when politely surfacing the failure. "blocked"
        // and "no permission" join the older denied/declined/not-granted
        // hits.
        if s.contains("accessibility permission")
            || s.contains("accessibility access")
            || (s.contains("axisprocesstrusted") && s.contains("false"))
            || (s.contains("accessibility") && (
                    s.contains("denied")
                    || s.contains("declined")
                    || s.contains("not granted")
                    || s.contains("hasn't granted")
                    || s.contains("blocked")
                    || s.contains("no permission")
                    || s.contains("isn't enabled")
                    || s.contains("isn't allowed")
                    || s.contains("not enabled")
                    || s.contains("not allowed")
                    || s.contains("turned off")
               ))
        {
            return .accessibility
        }

        // AppleEvents (Automation)
        if s.contains("apple events permission")
            || s.contains("appleevents permission")
            || s.contains("not allowed to send apple events")
            || s.contains("automation permission")
            || (s.contains("apple events") && (s.contains("denied") || s.contains("not authorized")))
        {
            return .appleEvents
        }

        return nil
    }

    // MARK: - 402 → PaywallReason mapping

    /// Map klo-cloud's 402 `detail.error` code to a PaywallReason. The
    /// FastAPI shape is `{"detail": {"error": "<code>", ...}}`. Falls
    /// back to `.subscribeRequired` for legacy or malformed responses so
    /// the user always sees A paywall instead of a hang.
    ///
    /// Codes emitted by klo_cloud/usage.py:/usage/task_start (post-
    /// time-trial rollout):
    ///   - "daily_limit_reached"  → hit 5 today, trial still active
    ///   - "trial_expired"        → past day 7 of the trial window
    ///   - "subscription_required" / "trial_exhausted" → legacy fallbacks
    private static func paywallReason(fromBody data: Data) -> KLOState.PaywallReason {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = body["detail"] as? [String: Any] else {
            return .subscribeRequired
        }
        // Canonical envelope puts the discriminator in `code`
        // (`error` is always "payment_required"); older servers put
        // it in `error` directly.
        let code = (detail["code"] as? String) ?? (detail["error"] as? String) ?? ""
        switch code {
        case "daily_limit_reached":  return .dailyLimitReached
        case "trial_expired":        return .trialExpired
        case "subscription_required": return .subscribeRequired
        case "trial_exhausted":      return .subscribeRequired
        default:                     return .subscribeRequired
        }
    }
}
