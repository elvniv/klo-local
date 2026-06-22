import AVFoundation
import Foundation
import NaturalLanguage
import RealtimeAPI
import SwiftUI

/// Voice transport for the OpenAI Realtime API path.
///
/// Mirrors `VapiBridge`'s public surface (`start`, `stop`, `inCall`)
/// so call sites don't care which provider is in play. The cloud
/// config flag `voice_provider` (vapi | realtime) decides which one
/// is instantiated by `KLOWindowController`.
///
/// Compared to VapiBridge:
///   - No WKWebView. Native WebRTC via the `RealtimeAPI` Swift package
///     (m1guelpf/swift-realtime-openai), which handles mic capture +
///     speaker playback + WebRTC peer negotiation in-process.
///   - Single LLM connection (gpt-realtime-2) does STT + reasoning +
///     TTS in one stream. No separate Deepgram, no ElevenLabs.
///   - Tool calls (klo_run) appear as `Item.functionCall` entries on
///     the Conversation; we poll the @Observable entries list, dispatch
///     each new completed call via the existing AgentClient run
///     submission machinery, and return the result via
///     `Conversation.send(result:)`. The model narrates while the tool
///     runs (built-in gpt-realtime-2 capability).
///
/// Lifecycle:
///   ⌘⇧K → KLOWindowController flips voice mode → start()
///   ↳ POST /voice/realtime/ephemeral-key → ephemeral token
///   ↳ Conversation(configuring: { tools = [klo_run] })
///   ↳ Conversation.connect(ephemeralKey:) — mic + speaker auto-attach
///   User speaks → model responds with audio
///   Model calls klo_run → handleFunctionCall → AgentClient.dispatchFromRealtime
///   AgentClient finishes → posts .kloRealtimeRunComplete
///   ↳ send(result:) + createResponse → model speaks the result
///   ⌥⇧K or panel dismiss → stop() → drop Conversation, releases WebRTC
@MainActor
final class RealtimeBridge: ObservableObject {

    // ─── Published state — mirrors VapiBridge so views can swap ────────
    @Published private(set) var inCall: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var connecting: Bool = false

    private let account: AccountManager
    private weak var agentClient: AgentClient?

    private var conversation: Conversation?
    private var observerTask: Task<Void, Never>?
    private var notificationToken: NSObjectProtocol?
    /// Function-call IDs we've already dispatched to the agent. Keyed
    /// on `Item.FunctionCall.callId`. Prevents the polling observer
    /// from re-firing the same call when entries are repopulated.
    private var dispatchedCallIDs: Set<String> = []
    /// Subset of dispatchedCallIDs whose AgentClient run is still in
    /// flight. The run-complete notification handler uses this to
    /// decide whether the incoming notification is one we care about.
    private var inFlightCallIDs: Set<String> = []

    /// Client-side mic gate. Tap-based RMS+ZCR+EnvVar discriminator
    /// against TV / podcast / background-music bleed. When the gate is
    /// CLOSED, we set `convo.muted = true` so no RTP packets reach
    /// OpenAI — the server VAD never fires, no transcription happens,
    /// no language drift can cascade. The gate is the decisive layer.
    private let micGate = MicLevelGate()

    /// Mirrors `micGate.isOpen` for SwiftUI binding (the "LISTENING /
    /// MIC OFF" dot on the voice overlay). Published separately so
    /// views can observe RealtimeBridge directly without reaching into
    /// the gate object.
    @Published private(set) var micUnmuted: Bool = false

    /// Per-response-id transcript accumulator for the early language-
    /// drift detector. We feed NLLanguageRecognizer at 8 / 12 / 20
    /// chars with tiered confidence; on non-English detection we send
    /// .cancelResponse and inject a corrective system item before the
    /// audio renders past the first syllable.
    private var driftAccum: [String: String] = [:]
    private var driftCancelled: Set<String> = []

    /// Tracks the most recent `sendFunctionCallOutput` so the raw-event
    /// handler can correlate inbound API errors (`{"type":"error", ...}`)
    /// with the send that probably triggered them. Today's hallucination
    /// fix (item.id 33-char cap) is the exact failure mode this catches:
    /// OpenAI rejected the function_call_output, we never noticed, the
    /// model confabulated. If an error fires within ~3s of one of these
    /// sends, we know the tool result was probably lost and the user
    /// should see a "something went wrong, please retry" surface.
    private var lastFunctionCallOutputSentAt: Date?
    private var lastFunctionCallOutputCallID: String?

    /// Wall-clock start of the current Realtime session. Set when the
    /// WebRTC connection comes up; consumed (and nilled) by `stop()`
    /// to report seconds_used to klo-cloud's session-end endpoint,
    /// which debits the Starter tier's daily voice budget. nil while
    /// no session is live, so the idempotent stop() can't double-bill.
    private var sessionStartedAt: Date?

    /// When we last forwarded a mid-run user utterance to the agent
    /// as a steer (either from the transcription event or from a
    /// redundant klo_run call). Used to dedupe the two paths — see
    /// handleFunctionCall's in-flight branch.
    private var lastSteerSentAt: Date = .distantPast

    init(account: AccountManager) {
        self.account = account
    }

    /// Inject the AgentClient lazily — RealtimeBridge is created at
    /// app-launch time when AgentClient also exists. Made explicit so
    /// the dependency arrow is obvious to readers.
    func attach(agentClient: AgentClient) {
        self.agentClient = agentClient
    }

    // MARK: - Lifecycle

    /// Open the Realtime WebRTC connection. Errors flow through
    /// `lastError` so the UI can surface them.
    func start() {
        guard !inCall, !connecting else { return }
        connecting = true
        lastError = nil
        Task { @MainActor in
            do {
                NSLog("KLO Realtime: fetching ephemeral key from klo-cloud")
                let ephemeralKey = try await fetchEphemeralKey()
                NSLog("KLO Realtime: ephemeral key OK (len=\(ephemeralKey.count)), opening WebRTC conversation")
                try await openConversation(ephemeralKey: ephemeralKey)
                NSLog("KLO Realtime: openConversation returned, polling status")
                inCall = true
                connecting = false
                sessionStartedAt = Date()
                startStatusPoller()
            } catch {
                NSLog("KLO Realtime: start failed — \(error)")
                // Use the cloudErrorMessage helper for network-shape
                // errors (timed out, offline, cloud unreachable) — gives
                // the user something actionable instead of the previous
                // `String(describing: error)` which leaked Foundation
                // error descriptions to the UI. Non-URLError shapes
                // (RealtimeBridgeError.notSignedIn, .subscriptionRequired)
                // pass through with their existing LocalizedError strings.
                if error is URLError {
                    lastError = AccountManager.cloudErrorMessage(for: error)
                } else {
                    lastError = (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                }
                inCall = false
                connecting = false
                conversation = nil
            }
        }
    }

    /// Runs while inCall=true. Logs conversation lifecycle signals so
    /// we can tell from a trace whether the data channel opened, audio
    /// flowed, and the model produced any output — without having to
    /// attach a debugger or read swift `print()` output (which is
    /// dropped for sandboxed apps).
    private var statusPollerTask: Task<Void, Never>?
    private func startStatusPoller() {
        statusPollerTask?.cancel()
        statusPollerTask = Task { @MainActor [weak self] in
            var lastEntries = -1
            var lastStatus: String = ""
            var ticks = 0
            while !Task.isCancelled {
                guard let self = self, let convo = self.conversation else { return }
                let entriesCount = convo.entries.count
                let statusStr = String(describing: convo.status)
                let muted = convo.muted
                if statusStr != lastStatus {
                    NSLog("KLO Realtime: status=\(statusStr) muted=\(muted) entries=\(entriesCount)")
                    lastStatus = statusStr
                }
                if entriesCount != lastEntries {
                    NSLog("KLO Realtime: entries=\(entriesCount) status=\(statusStr)")
                    lastEntries = entriesCount
                    // Log a brief description of the LATEST entry
                    if let last = convo.entries.last {
                        NSLog("KLO Realtime: latest entry = \(String(describing: last).prefix(160))")
                    }
                }
                ticks += 1
                // Every 5s also dump a heartbeat so we can tell if the
                // poller itself is alive and the user is genuinely
                // getting silence (vs the poller having died).
                if ticks % 10 == 0 {
                    NSLog("KLO Realtime: heartbeat — status=\(statusStr) muted=\(muted) entries=\(entriesCount)")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Tear down the connection cleanly. Idempotent.
    ///
    /// Order matters: mute the audio track BEFORE dropping the
    /// Conversation reference. ARC release of Conversation fires its
    /// deinit which calls client.disconnect(), but that release isn't
    /// guaranteed to be synchronous — a stray strong reference (a
    /// pending Task, an in-flight Combine subscription) can stretch
    /// the lifetime by seconds. Muting first guarantees the mic
    /// stops sampling immediately even if the deinit is delayed.
    func stop() {
        NSLog("KLO Realtime: stop()")
        // Report the session length to klo-cloud FIRST (fire-and-
        // forget — the Task never blocks teardown). Every teardown
        // path funnels through stop(), so user-ended, error, and
        // drift-cancel sessions all get billed. Consuming
        // sessionStartedAt here keeps the idempotent re-entry from
        // double-reporting.
        if let startedAt = sessionStartedAt {
            sessionStartedAt = nil
            reportSessionEnd(startedAt: startedAt)
        }
        observerTask?.cancel()
        observerTask = nil
        statusPollerTask?.cancel()
        statusPollerTask = nil
        if let token = rawEventToken {
            NotificationCenter.default.removeObserver(token)
            rawEventToken = nil
        }
        if let token = notificationToken {
            NotificationCenter.default.removeObserver(token)
            notificationToken = nil
        }
        // Stop the mic gate FIRST so no more "open gate" callbacks
        // can flip convo.muted on a half-torn-down peer.
        micGate.onGateChange = nil
        micGate.stop()
        micUnmuted = false

        // Hand off any in-flight klo_run calls to the chat-panel
        // path BEFORE we drop the Conversation — otherwise the run
        // finishes, the .kloRealtimeRunComplete notification fires,
        // sendFunctionCallOutput finds conversation=nil and silently
        // drops the result. Detaching tells AgentClient: "treat the
        // pending realtime callID as untracked from now on"; the
        // next final_message routes to state.showCompleted instead
        // of being ferried back to a dead Realtime conversation.
        handOffPendingCalls()

        // Mute the mic track + cancel any in-flight model response.
        // Both operations target the live WebRTC connection so they
        // take effect even if the Conversation object survives a
        // little longer than expected.
        if let convo = conversation {
            convo.muted = true
            do {
                try convo.send(event: .cancelResponse(eventId: nil, responseId: nil))
            } catch {
                // Cancel-response failures are non-fatal — we're tearing
                // down anyway. Just note it for debugging.
                NSLog("KLO Realtime: cancelResponse on stop threw — \(error)")
            }
        }
        // Now drop the Conversation. ARC fires deinit → client.disconnect()
        // → connection.close(). The library uses Task.detached
        // {[weak self] ...}, so the internal event-loop task doesn't
        // retain self — no leak chain.
        conversation = nil
        driftAccum.removeAll()
        driftCancelled.removeAll()
        dispatchedCallIDs.removeAll()
        inFlightCallIDs.removeAll()
        inCall = false
        connecting = false
    }

    // MARK: - Ephemeral key

    private func fetchEphemeralKey() async throws -> String {
        guard let token = await account.withFreshAccessToken() else {
            throw RealtimeBridgeError.notSignedIn
        }
        let url = AccountManager.cloudBase.appendingPathComponent("voice/realtime/ephemeral-key")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Empty body — let klo-cloud use the cloud-config defaults for
        // model/voice/system_prompt. Per-session overrides go here later
        // if we add a settings UI.
        req.httpBody = "{}".data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw RealtimeBridgeError.upstreamFailed("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            NSLog("KLO Realtime: ephemeral-key HTTP \(http.statusCode) body=\(String(data: data, encoding: .utf8) ?? "<binary>")")
            if http.statusCode == 402 {
                throw RealtimeBridgeError.subscriptionRequired
            }
            throw RealtimeBridgeError.upstreamFailed("HTTP \(http.statusCode)")
        }
        guard
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let key = body["ephemeral_key"] as? String,
            !key.isEmpty
        else {
            throw RealtimeBridgeError.upstreamFailed("malformed ephemeral-key response")
        }
        return key
    }

    // MARK: - Session-end billing

    /// POST the session's wall-clock duration to klo-cloud's
    /// /voice/realtime/session-end so the Starter tier's daily voice
    /// budget gets debited (Pro is a no-op server-side, Free never
    /// gets a session). Best-effort by design — one retry, then give
    /// up; an unrecorded session under-bills, which the cloud
    /// explicitly accepts as the trade.
    private func reportSessionEnd(startedAt: Date) {
        let seconds = max(1, Int(Date().timeIntervalSince(startedAt).rounded()))
        let account = self.account
        Task {
            for attempt in 1...2 {
                do {
                    let (_, http) = try await account.authedPOST(
                        path: "voice/realtime/session-end",
                        body: ["seconds_used": seconds],
                    )
                    if (200..<300).contains(http.statusCode) {
                        NSLog("KLO Realtime: session-end recorded (%ds)", seconds)
                        return
                    }
                    NSLog("KLO Realtime: session-end HTTP %d (attempt %d)", http.statusCode, attempt)
                } catch {
                    NSLog("KLO Realtime: session-end failed (attempt %d) — %@", attempt, String(describing: error))
                }
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    // MARK: - Conversation open

    private func openConversation(ephemeralKey: String) async throws {
        // Configure the Session up-front via the `configuring` callback;
        // the library will fold these into the first session.update
        // event after the WebRTC connection is established.
        // We set instructions + tools here (NOT during klo-cloud's
        // session-mint POST) because OpenAI's GA shape rejects most
        // session-create fields beyond `model`. Setting them via
        // session.update over the WebRTC channel is the supported path.
        let now = Self.currentContext()
        let convo = Conversation { session in
            session.instructions = Self.systemPrompt + "\n\n" + now
            session.tools = [Self.kloRunTool()]
            // VAD tuning — defaults are too aggressive for TV / open-room
            // mic conditions:
            //   - Semantic VAD with eagerness=.low waits for the user to
            //     genuinely finish a thought before deciding the turn is
            //     done. Background TV chatter, throat clearing, "um" etc.
            //     no longer cancel klo's in-flight responses.
            //   - createResponse stays true so klo still answers when the
            //     user genuinely finishes speaking.
            //   - interruptResponse=true: barge-in. The user can talk
            //     over klo's TTS and the in-flight response is cut so
            //     the new utterance gets handled immediately — phone-
            //     call behavior, not walkie-talkie. Semantic VAD with
            //     eagerness=.low is what keeps noise spikes from
            //     triggering this: the server only treats it as a turn
            //     when it hears genuine speech, so the old "TV chatter
            //     cancels klo mid-sentence" failure the false setting
            //     guarded against stays covered by the VAD tier.
            session.audio.input.turnDetection = .semanticVad(
                createResponse: true,
                eagerness: .low,
                idleTimeout: nil,
                interruptResponse: true,
            )
            // Tell the server-side ASR that the user is speaking English.
            // Without this, ambient sound on the first frame can bias the
            // transcription model toward another language (we saw it pick
            // Korean once). ISO-639-1 hint is documented to "improve
            // accuracy and latency" per the OpenAI Realtime docs.
            session.audio.input.transcription = .init(model: .gpt4o, language: "en", prompt: nil)
            // Klo's WKWebView and the user's laptop mic are pretty far
            // from a podcast-quality close-talker, so apply far-field
            // noise reduction. Drops TV / fan / aircon energy.
            session.audio.input.noiseReduction = .farField
        }
        try await convo.connect(ephemeralKey: ephemeralKey)
        self.conversation = convo
        // Mic gate is OPT-IN. Custom client-side RMS / ZCR / EnvVar
        // gating is much worse than Apple's system-level Voice
        // Isolation (Control Center → Mic Mode → Voice Isolation,
        // which the user can enable once and forget). Voice Isolation
        // uses on-device ML to suppress everything except the user's
        // voice; LiveKit's WebRTC engine adopts AUVoiceIO (confirmed
        // by AUVoiceIOChatFlavor in the system log), so klo gets the
        // benefit automatically when the user enables it.
        //
        // The custom gate is gated behind a UserDefaults flag so we
        // can re-enable it for tuning / users who can't / won't use
        // Voice Isolation. Off by default = voice mode just works.
        let useCustomGate = UserDefaults.standard.bool(forKey: "klo.voice.gate.customEnabled")
        if useCustomGate {
            NSLog("KLO Realtime: custom mic gate ENABLED (UserDefaults override)")
            micGate.onGateChange = { [weak self] open in
                guard let self = self else { return }
                self.micUnmuted = open
                self.conversation?.muted = !open
            }
            self.conversation?.muted = true
            self.micUnmuted = false
            do {
                try micGate.start()
            } catch {
                NSLog("KLO Realtime: micGate.start failed — %@. Falling back to ungated audio.", String(describing: error))
                self.conversation?.muted = false
                self.micUnmuted = true
            }
        } else {
            // Default path — trust AUVoiceIO + Apple Voice Isolation
            // (if user enabled) + the semantic VAD + drift detector
            // for noise rejection. Mic is open from the start.
            self.conversation?.muted = false
            self.micUnmuted = true
            NSLog("KLO Realtime: custom mic gate disabled (default) — relying on AUVoiceIO + semantic VAD + drift detector")
        }
        wireFunctionCallObserver(convo)
        wireRunCompletionObserver()
        logVoiceIsolationState()
    }

    /// Read the system mic mode and log whether Voice Isolation is
    /// active. If not, we just note it — we can't enable it
    /// programmatically (only the user can via Control Center →
    /// Mic Mode). Useful for diagnosing "why is voice picking up TV"
    /// — first thing to check is whether the user has Voice Isolation
    /// turned on.
    private func logVoiceIsolationState() {
        if #available(macOS 12.0, *) {
            let mode = AVCaptureDevice.preferredMicrophoneMode
            let active = AVCaptureDevice.activeMicrophoneMode
            let name: (AVCaptureDevice.MicrophoneMode) -> String = { m in
                switch m {
                case .standard: return "standard"
                case .voiceIsolation: return "voiceIsolation"
                case .wideSpectrum: return "wideSpectrum"
                @unknown default: return "unknown(\(m.rawValue))"
                }
            }
            NSLog("KLO Realtime: mic mode — preferred=%@ active=%@", name(mode), name(active))
            if active != .voiceIsolation {
                NSLog("KLO Realtime: TIP — for best noise rejection, enable Voice Isolation in Control Center → Mic Mode while klo is the active audio app.")
            }
        }
    }

    /// klo's voice persona. Loaded from cloud config eventually, but
    /// hardcoded for v1 — keeps the bridge self-contained and avoids a
    /// network round-trip on every voice mode entry. Mirror of the
    /// `realtime.system_prompt` in klo_cloud/config.py.
    private static let systemPrompt = """
    You are klo, a Mac voice assistant. Phone-call vibe — talk like a friend.

    LANGUAGE & NOISE HANDLING — read carefully, this is non-negotiable:
    - You ALWAYS respond in English. The user is an English speaker named Elvin.
    - **Do not respond when the latest audio is silence, background noise, hold music, TV audio, podcast audio, or side conversation.** That is not the user talking to you — it's the room. Stay silent and wait for the user's actual voice. (This is the single most important rule. Most "voice mode talking when it shouldn't" failures come from violating it.)
    - The mic can pick up background audio mixed with the user's actual voice. The mixed audio may sound like other languages (Korean, German, Spanish, French, Japanese, anything). IT IS NOT THE USER. It is background noise leaking into the mic. Discard it; do not respond.
    - NEVER respond in a non-English language. If you transcribed something that looks like another language, that was almost certainly noise — discard it.
    - If you genuinely can't make out what the user said in English but there's a clear attempt to address you, ask in English: "sorry, didn't catch that — say again?" — but ONLY once, briefly. Don't keep asking if the next turn is also unclear (probably more noise).
    - If the user audio is clearly NOT addressed to you (e.g. they're talking to someone else in the room), stay silent.

    STYLE: one short sentence by default. No markdown.

    YOUR ONLY TOOL: klo_run(task: string) — dispatches the full klo agent to do ANYTHING on the user's Mac (apps, files, browser, screen, calendar, email, weather, scripts, anything live or agentic). Use it constantly.

    DISPATCH RULES — call klo_run whenever the user wants something done on their machine OR wants live data you don't have. Default to dispatching. Examples that ALWAYS dispatch:
    - "open / quit / switch to X" / "play X" / "search for X"
    - "what's on my screen / window / tab"
    - "next meeting / unread email / weather / news / stock / score"
    - "send / reply / draft / message X"
    - browser anything, file anything, shell anything

    DON'T dispatch klo_run for these (just speak):
    - "hey klo", "thanks", "cool", "ok" — chitchat
    - questions about you ("what can you do", "are you a bot") — you are klo
    - current time/date — read from GROUNDING
    - clarifying questions back at the user

    DISPATCH PATTERN — this is a strict protocol, follow every step:
    1. **MANDATORY VERBAL ACK** before EVERY klo_run call. Speak a short ack (1-4 words: "On it." / "Pulling up." / "Looking now." / "One sec." / "Checking."). NEVER dispatch silently — even fast tools deserve an ack. Silence at this step is the #1 thing that makes the user feel klo is broken.
    2. Immediately call klo_run with a clear specific task (write it like a sentence — what to do, what to return).
    3. You'll get system messages "[klo agent status] now X" mid-run — speak one short sentence per state change so the user hears you working. Be conversational ("looking at your screen now…", "found it, reading the page…"). Never just stay silent during a long-running tool.
    4. When klo_run returns, you'll get an explicit "[speak result now]" system instruction. SPEAK THE RESULT. Do not stay silent. Summarize in 1-2 short sentences for short answers; for long structured results (lists, breakdowns), give the top 2-3 bullets verbally, then say "I've also put the full breakdown in the chat panel."

    Examples:
    - "open spotify" → "On it." → klo_run("open Spotify and bring it to the front")
    - "what's on my screen" → "Looking." → klo_run("take a screenshot and describe what's on the user's screen")
    - "what's my next meeting" → "Checking." → klo_run("read Calendar and report the next upcoming event")
    - "hey klo" → "Hey, what's up?" (no dispatch)
    - "what time is it" → "It's quarter past 11." (no dispatch)

    Never name the model behind you (no "GPT", "OpenAI", "Realtime"). You are klo.
    """

    /// Current local time + timezone, injected into the system prompt
    /// every time voice mode starts. Without this the model invents a
    /// plausible-sounding time when asked ("it's about 3 PM") — which
    /// is one of the worst kinds of hallucination because it's
    /// confidently wrong AND the user will believe it.
    private static func currentContext() -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        df.locale = Locale(identifier: "en_US")
        let now = df.string(from: Date())
        return """
        GROUNDING (refresh point — true at the moment this session started)
        - Current local time: \(now)
        - If the user asks "what time is it" or "what's today's date", answer from this line directly. Use the time format that fits the question (e.g. "it's a quarter past 11" for casual, "11:15 AM" for precise).
        - For anything else time-sensitive (weather, calendar, email, stock prices, news, anything happening "now"), call klo_run — the agent will pull live data from the user's Mac.
        """
    }

    // MARK: - klo_run tool definition

    /// Matches the schema voice_brain.py's `_KLO_RUN_TOOL` exposes for
    /// the Vapi path. Keeping this in sync by hand is acceptable for v1
    /// (the schema doesn't change often); a future refactor could pull
    /// the canonical definition from the sidecar's `/config/sidecar`.
    private static func kloRunTool() -> Tool {
        let function = Tool.Function(
            name: "klo_run",
            description: (
                "Dispatch a task to the klo agent, which has full Mac and browser " +
                "control. Returns the agent's final result string when complete. " +
                "Use for anything agentic — apps, files, web actions, system control. " +
                "Do not use for conversational chitchat or quick factual answers."
            ),
            parameters: .object(
                properties: [
                    "task": .string(
                        pattern: nil,
                        format: nil,
                        description: "The task for klo to execute. Be specific and action-oriented.",
                    ),
                ],
                description: nil,
            ),
        )
        return .function(function)
    }

    // MARK: - Function-call routing

    /// Conversation is `@Observable` (the new observation framework).
    /// The library populates `entries` with `Item.functionCall(...)`
    /// as `response.function_call_arguments.done` events arrive. We
    /// poll the array on a short interval, dedupe by `callId`, and
    /// dispatch each new completed call to the agent.
    ///
    /// A push-based observer would be cleaner but `withObservationTracking`
    /// is one-shot and re-arming inside a class is awkward; a 200ms poll
    /// is cheap (couple of array scans per second) and adequate.
    private func wireFunctionCallObserver(_ convo: Conversation) {
        // Two-channel observation:
        //   1. Subscribe to raw DC events posted by WebRTCConnector.
        //      Catches function_call_arguments.done immediately —
        //      this is the reliable path. The library's Conversation
        //      .entries observable doesn't surface function_call items
        //      reliably (empirically: response.done fires, args land,
        //      entries stays empty), so we route off raw events.
        //   2. Keep the entries poller as a backstop — if the library
        //      ever does populate entries correctly, dedupedCallIDs
        //      stops us double-dispatching.
        rawEventToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("KLORealtimeServerEventRaw"),
            object: nil,
            queue: .main,
        ) { [weak self] note in
            guard let self = self,
                  let data = note.userInfo?["data"] as? Data else { return }
            Task { @MainActor in
                self.handleRawServerEvent(data: data)
            }
        }

        observerTask?.cancel()
        observerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self, let convo = self.conversation else { return }
                for entry in convo.entries {
                    guard case .functionCall(let fc) = entry else { continue }
                    guard fc.status == .completed else { continue }
                    guard !self.dispatchedCallIDs.contains(fc.callId) else { continue }
                    self.dispatchedCallIDs.insert(fc.callId)
                    NSLog("KLO Realtime: function call complete (poller) name=\(fc.name) callId=\(fc.callId)")
                    self.handleFunctionCall(fc)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Parse a raw data-channel JSON payload, look for
    /// `response.function_call_arguments.done`, and dispatch klo_run
    /// directly. This is the dispatch path that actually works (the
    /// Conversation.entries observable doesn't fire reliably for
    /// function-call items in the current realtime-openai library).
    @MainActor
    private func handleRawServerEvent(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let type = json["type"] as? String else { return }

        // 1. Function-call dispatch (the reliable path — see comment
        //    above on why we don't trust convo.entries for this).
        if type == "response.function_call_arguments.done" {
            guard let callId = json["call_id"] as? String else { return }
            let name = (json["name"] as? String) ?? "klo_run"
            let arguments = (json["arguments"] as? String) ?? ""
            if dispatchedCallIDs.contains(callId) { return }
            dispatchedCallIDs.insert(callId)
            NSLog("KLO Realtime: function call complete (raw) name=\(name) callId=\(callId) args=\(arguments.prefix(200))")
            let fc = Item.FunctionCall(
                id: "item_\(callId)",
                status: .completed,
                callId: callId,
                name: name,
                arguments: arguments,
            )
            // Seed lastProgressLabel so the first real step_progress
            // from the agent (often something generic like
            // "running…") doesn't get deduped if the model already
            // narrated similar. Also resets the throttle clock so
            // the first agent beat fires immediately, not after 2.5s.
            // NOTE: we intentionally DON'T synthesize a noteAgentProgress
            // here — the model's prompt-enforced pre-dispatch ack
            // ("On it." / "Looking now.") IS the first verbal beat.
            // Firing createResponse here would conflict with the
            // in-flight response that's currently emitting the
            // function-call args.
            lastProgressEmittedAt = .distantPast
            lastProgressLabel = ""
            handleFunctionCall(fc)
            return
        }

        // 2. User speech finished transcribing WHILE a klo_run is in
        //    flight — the user is talking over an active run. Don't
        //    end the session, don't spawn a parallel run: forward the
        //    utterance to the running agent as a steer (same WS frame
        //    the WebPaneView's ⏎ input sends; the agent drains it at
        //    its next turn boundary). The Realtime model still hears
        //    the utterance and will respond conversationally — the
        //    system note below stops it from ALSO dispatching a second
        //    klo_run for the same words.
        if type == "conversation.item.input_audio_transcription.completed" {
            guard !inFlightCallIDs.isEmpty else { return }
            let transcript = ((json["transcript"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip one-or-two-char fragments ("ok", noise hits) — not
            // worth steering the agent over.
            guard transcript.count > 2 else { return }
            NSLog("KLO Realtime: user spoke mid-run — steering agent with %@", String(transcript.prefix(120)))
            agentClient?.sendInterrupt(transcript, kind: .steer)
            lastSteerSentAt = Date()
            if let convo = conversation {
                let id = "klo_fwd_\(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000)"
                let note = Item.Message(
                    id: id,
                    status: .completed,
                    role: .system,
                    content: [.inputText("(The user's last words were already forwarded to the in-flight klo agent as updated guidance. Do NOT call klo_run for them — briefly acknowledge in English and keep waiting for the agent's result.)")],
                )
                do {
                    try convo.send(event: .createConversationItem(after: nil, .message(note)))
                } catch {
                    NSLog("KLO Realtime: steer note injection failed — \(error)")
                }
            }
            return
        }

        // 3. Early language-drift detection on the model's audio
        //    transcript. We accumulate the streaming transcript per
        //    response_id and check at 8 / 12 / 20 chars with tiered
        //    confidence. NLLanguageRecognizer (built into Foundation)
        //    is a small statistical n-gram model — runs in <1ms on
        //    short strings, no ML overhead. Catches the drift before
        //    audio synthesis accumulates past a syllable or two.
        //
        //    Why three tiers: very-short strings (≤8 chars) can look
        //    like other languages for legitimate English ("ok", "wait",
        //    "yes") — we only fire at low char counts when confidence
        //    is high. As more text arrives, accept lower confidence.
        if type == "response.output_audio_transcript.delta" {
            guard let responseId = json["response_id"] as? String,
                  let delta = json["delta"] as? String,
                  !delta.isEmpty else { return }
            if driftCancelled.contains(responseId) { return }  // already cancelled this response
            let updated = (driftAccum[responseId] ?? "") + delta
            driftAccum[responseId] = updated
            let len = updated.count
            // Tiered confidence checks. NLLanguageRecognizer is the
            // standard Apple text language identifier (CFStringTokenize
            // family — no ML model files needed).
            let confidenceThreshold: Double? = {
                if len == 8 { return 0.85 }
                if len == 12 { return 0.7 }
                if len == 20 { return 0.55 }
                return nil
            }()
            if let threshold = confidenceThreshold {
                if let dominant = detectNonEnglish(updated, minConfidence: threshold) {
                    NSLog("KLO Realtime: language drift detected (%@) in response %@ — cancelling. transcript=%@",
                          dominant, responseId, updated)
                    driftCancelled.insert(responseId)
                    cancelDriftedResponse(responseId: responseId, detectedLanguage: dominant)
                }
            }
            return
        }

        // 4. API error from OpenAI Realtime. Before this branch existed,
        //    errors were silently swallowed — the model would then
        //    hallucinate because (e.g.) a function_call_output had been
        //    rejected with `string_above_max_length` on item.id but we
        //    never knew. The 1.1.1 hallucination fix patched the
        //    specific 33-char bug; this branch makes the WHOLE error
        //    class visible so the next bug of this shape shows up in
        //    logs and (when correlated with a recent tool ferry-back)
        //    surfaces a user-visible error instead of silent confabulation.
        if type == "error" {
            let err = (json["error"] as? [String: Any]) ?? [:]
            let errType = (err["type"] as? String) ?? "unknown"
            let errCode = (err["code"] as? String) ?? "unknown"
            let errMessage = (err["message"] as? String) ?? "no message"
            let errParam = (err["param"] as? String) ?? ""
            let eventId = (json["event_id"] as? String) ?? ""
            NSLog(
                "KLO Realtime API error — type=%@ code=%@ param=%@ event_id=%@ message=%@",
                errType, errCode, errParam, eventId, errMessage,
            )
            // Correlate with a recent function_call_output send. If the
            // error landed within 3s, the tool result almost certainly
            // never reached the model — that's the silent-hallucination
            // failure mode. Surface to UI so the user knows something
            // went wrong instead of trusting a fabricated answer.
            if let sentAt = lastFunctionCallOutputSentAt,
               Date().timeIntervalSince(sentAt) < 3.0 {
                let callID = lastFunctionCallOutputCallID ?? "<unknown>"
                NSLog(
                    "KLO Realtime: ⚠️ API error within 3s of function_call_output (callID=%@) — tool result likely lost",
                    callID,
                )
                lastError = "klo lost a tool result mid-run (\(errCode)). Please ask again."
                // Clear the tracking so a later unrelated error doesn't
                // re-surface this message.
                lastFunctionCallOutputSentAt = nil
                lastFunctionCallOutputCallID = nil
            } else {
                // Non-tool-related error (session.update rejection, rate
                // limit, etc.). Still log; surface only if it's clearly
                // fatal (rate_limit_exceeded, invalid_api_key).
                if errCode == "rate_limit_exceeded" || errCode == "invalid_api_key" {
                    lastError = "klo voice unavailable: \(errMessage)"
                }
            }
            return
        }

        // 5. Response done — clean up accumulator for that response_id
        //    so the map doesn't grow unbounded.
        if type == "response.done" {
            if let resp = json["response"] as? [String: Any],
               let respId = resp["id"] as? String {
                driftAccum.removeValue(forKey: respId)
                driftCancelled.remove(respId)
            }
            return
        }
    }

    /// Run NLLanguageRecognizer on the accumulated transcript. Returns
    /// the dominant language code if it's non-English AND meets the
    /// confidence threshold; nil otherwise.
    nonisolated private func detectNonEnglish(_ text: String, minConfidence: Double) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        // Build sorted [(NLLanguage, confidence)] descending.
        let sorted = hypotheses.sorted { $0.value > $1.value }
        guard let top = sorted.first else { return nil }
        if top.key == .english { return nil }
        if top.value < minConfidence { return nil }
        // Extra guard: if English is the SECOND-most-likely with
        // confidence > 0.3, don't cancel — the model is probably just
        // speaking accented or technical English that the recognizer
        // got confused on. Bias toward keeping legitimate replies.
        if let englishConf = hypotheses[.english], englishConf > 0.3 { return nil }
        return top.key.rawValue
    }

    /// Send `cancelResponse` for the drifted response_id + inject a
    /// corrective system item so the next turn has the context.
    /// Doesn't await — best-effort.
    private func cancelDriftedResponse(responseId: String, detectedLanguage: String) {
        guard let convo = conversation else { return }
        do {
            try convo.send(event: .cancelResponse(eventId: nil, responseId: responseId))
        } catch {
            NSLog("KLO Realtime: drift cancelResponse failed — \(error)")
        }
        // Corrective system item — tells the model "the last response
        // was junk, English only". Per-turn reinforcement using the
        // same pattern as the English reminder before tool ferry-back.
        let reminder = Item.Message(
            id: "klo_drift_\(responseId.suffix(8))",
            status: .completed,
            role: .system,
            content: [.inputText("(Previous response (\(detectedLanguage)) was discarded — that audio was probably background noise. Respond in English only.)")],
        )
        do {
            try convo.send(event: .createConversationItem(after: nil, .message(reminder)))
        } catch {
            NSLog("KLO Realtime: drift reminder injection failed — \(error)")
        }
    }

    private var rawEventToken: NSObjectProtocol?

    /// Hand off any in-flight klo_run dispatches to the chat-panel
    /// path before we tear down the Conversation. Called from `stop()`
    /// so a user who closes voice mode mid-run still gets the answer —
    /// it appears in the same chat surface the text mode (⌘K) uses.
    ///
    /// Without this, the sequence is:
    ///   1. user dispatches klo_run via voice
    ///   2. user presses ⌘⇧K → stop() → conversation=nil
    ///   3. agent finishes ~10s later → .kloRealtimeRunComplete posts
    ///   4. observer calls sendFunctionCallOutput
    ///   5. sendFunctionCallOutput does `guard let convo = conversation`
    ///   6. conversation is nil → guard fails → result silently dropped
    ///
    /// The handoff inverts this: detaching the realtime call IDs from
    /// AgentClient.pendingRealtimeCallID means the final_message takes
    /// the regular text path (state.showCompleted) — user sees the
    /// answer in the chat panel.
    private func handOffPendingCalls() {
        guard !inFlightCallIDs.isEmpty else { return }
        let ids = Array(inFlightCallIDs)
        NSLog("KLO Realtime: handing off %d in-flight call(s) to chat panel — %@", ids.count, ids.joined(separator: ","))
        agentClient?.detachRealtimeCalls(ids: ids)
        inFlightCallIDs.removeAll()
    }

    // MARK: - Progress narration (klo_run runs in flight)

    private var lastProgressEmittedAt: Date = .distantPast
    private var lastProgressLabel: String = ""

    /// AgentClient forwards `step_progress` events here whenever a
    /// klo_run dispatched from voice mode produces tool activity. We
    /// inject the label into the conversation as a `role=system` item
    /// and trigger a brief response so the Realtime model can speak
    /// what's happening — eliminating the 5-15s of dead air that made
    /// the user feel voice mode was broken.
    ///
    /// Throttled to ≥ 5 seconds between narrations (so even a 20-tool
    /// run produces at most 3-4 verbal updates), and skipped on
    /// identical labels (so a sequence of 3 screenshots in a row
    /// narrates once, not three times).
    @MainActor
    func noteAgentProgress(label: String) {
        guard inCall, let convo = conversation else { return }
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != lastProgressLabel else { return }
        let now = Date()
        // 2.5s throttle (was 5s). 5s left too much silence on
        // ~10s runs (1-2 narrations at best); 2.5s gives 4-5 verbal
        // updates so klo feels actively present. If the model gets
        // interrupted mid-sentence in real-world testing, raise.
        if now.timeIntervalSince(lastProgressEmittedAt) < 2.5 { return }
        lastProgressEmittedAt = now
        lastProgressLabel = clean

        let id = "klo_status_\(Int(now.timeIntervalSince1970 * 1000) % 1_000_000_000)"
        let item = Item.Message(
            id: id,
            status: .completed,
            role: .system,
            content: [.inputText("[klo agent status] now \(clean). In English, briefly say what's happening to the user — 1 short sentence max. Do not announce the final result yet.")]
        )
        do {
            try convo.send(event: .createConversationItem(after: nil, .message(item)))
        } catch {
            NSLog("KLO Realtime: progress inject failed — \(error)")
            return
        }
        do {
            try convo.send(event: .createResponse(eventId: nil, response: nil))
            NSLog("KLO Realtime: narrating progress: \(clean)")
        } catch {
            // Likely "response already in progress" — fine, next beat will retry.
            NSLog("KLO Realtime: response.create skipped (probably in flight) — \(error)")
        }
    }

    private func handleFunctionCall(_ fc: Item.FunctionCall) {
        guard fc.name == "klo_run" else {
            NSLog("KLO Realtime: ignoring unknown tool call \(fc.name)")
            sendFunctionCallOutput(callID: fc.callId, output: "{\"error\":\"unknown tool\"}")
            return
        }
        guard
            let data = fc.arguments.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let task = parsed["task"] as? String,
            !task.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            NSLog("KLO Realtime: klo_run call has malformed/missing task — args=\(fc.arguments)")
            sendFunctionCallOutput(callID: fc.callId, output: "{\"error\":\"missing task\"}")
            return
        }
        guard let agentClient = agentClient else {
            NSLog("KLO Realtime: klo_run dispatch failed — no AgentClient attached")
            sendFunctionCallOutput(callID: fc.callId, output: "{\"error\":\"agent unavailable\"}")
            return
        }
        // A klo_run is already executing — don't spawn a parallel run
        // (AgentClient tracks one run at a time; a second POST /runs
        // would orphan the first). Steer the running agent with the
        // new task instead, unless the transcription path already
        // forwarded this same utterance moments ago (lastSteerSentAt
        // dedupe — both paths fire off the same user turn).
        if !inFlightCallIDs.isEmpty {
            if Date().timeIntervalSince(lastSteerSentAt) > 10 {
                NSLog("KLO Realtime: klo_run while run in flight — steering instead (callId=\(fc.callId))")
                agentClient.sendInterrupt(task, kind: .steer)
                lastSteerSentAt = Date()
            } else {
                NSLog("KLO Realtime: klo_run while run in flight — already steered, closing call \(fc.callId)")
            }
            sendFunctionCallOutput(
                callID: fc.callId,
                output: "{\"result\":\"A klo task is already running — this request was forwarded to it as updated guidance. Tell the user you've updated the running task; its result will follow.\"}",
            )
            return
        }
        NSLog("KLO Realtime: dispatching klo_run task=\(task.prefix(120)) callId=\(fc.callId)")
        inFlightCallIDs.insert(fc.callId)
        // Reset progress throttle so the first step_progress for THIS run
        // fires immediately (instead of being skipped if we narrated for a
        // prior run < 5s ago).
        lastProgressEmittedAt = .distantPast
        lastProgressLabel = ""
        agentClient.dispatchFromRealtime(task: task, callID: fc.callId)
    }

    /// One observer for the bridge's lifetime; routes every
    /// `.kloRealtimeRunComplete` notification to the matching in-flight
    /// call (or ignores it if the call_id is unknown). Cleaner than
    /// arming per-call observers — a single sink handles concurrent
    /// in-flight calls without observer-ID juggling.
    private func wireRunCompletionObserver() {
        if notificationToken != nil { return }
        notificationToken = NotificationCenter.default.addObserver(
            forName: .kloRealtimeRunComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard
                    let self = self,
                    let info = note.userInfo,
                    let callID = info["call_id"] as? String,
                    self.inFlightCallIDs.contains(callID)
                else { return }
                let output = info["output"] as? String ?? "{\"ok\":true}"
                self.sendFunctionCallOutput(callID: callID, output: output)
                self.inFlightCallIDs.remove(callID)
            }
        }
    }

    private func sendFunctionCallOutput(callID: String, output: String) {
        guard let convo = conversation else { return }
        // Mark this send so the raw-event handler can correlate any
        // inbound `{"type":"error", ...}` payload that lands within 3s
        // with the function_call_output that probably triggered it. See
        // the error branch in handleRawServerEvent — this is the silent-
        // hallucination guard.
        lastFunctionCallOutputSentAt = Date()
        lastFunctionCallOutputCallID = callID
        do {
            // item.id must be ≤32 chars (OpenAI Realtime cap). The full
            // call_id is ~21 chars and `klo_run_out_` is 12, which puts
            // the literal concat at 33 and the entire function_call_output
            // gets silently rejected — the model then hallucinates because
            // there is no tool result in the conversation to ground on.
            // Use the same .suffix(8) pattern as the reminder item below.
            try convo.send(result: Item.FunctionCallOutput(
                id: "klo_run_out_\(callID.suffix(8))",
                callId: callID,
                output: output,
            ))
            // Forceful speak-result instruction. The model has a
            // tendency to stay silent after a tool result lands
            // (interprets the tool output as "done, no need to speak")
            // which is the wrong UX in voice mode — the user is
            // literally waiting to HEAR the answer. Hard-pin: speak
            // right now, in English, in a phone-call voice. For long
            // structured results, summarize verbally + acknowledge the
            // chat panel.
            //
            // System-role conversation item is simpler + more SDK-
            // stable than building a full Response.Config every time
            // (Response.Config has ~10 required fields per
            // Response.swift:43 that the model would otherwise inherit
            // from the session).
            let reminder = Item.Message(
                id: "klo_lang_\(callID.suffix(8))",
                status: .completed,
                role: .system,
                content: [.inputText("[speak result now] Speak this tool result to the user immediately, in English, like you're on a phone call with them. Do NOT stay silent — the user is waiting. For short answers, give 1-2 sentences. For long / structured results (lists, breakdowns), give the top 2-3 bullets verbally, then say 'I've also put the full breakdown in the chat panel.' Do not read raw markdown.")],
            )
            // The reminder used to be `try?` (swallow). Now it's
            // do/catch — if the reminder fails the model may stay silent
            // post-tool, and we'd rather know about it than chase a
            // "klo went quiet" report later.
            do {
                try convo.send(event: .createConversationItem(after: nil, .message(reminder)))
            } catch {
                NSLog("KLO Realtime: speak-result reminder send failed — \(error)")
            }
            // Trigger the model to consume the tool result and continue
            // speaking. Without this the function_call_output sits in
            // the conversation but the model doesn't proactively respond.
            try convo.send(event: .createResponse(eventId: nil, response: nil))
        } catch {
            NSLog("KLO Realtime: send function_call_output failed — \(error)")
            // Surface to UI so the user doesn't sit in confused silence
            // waiting for an answer that will never come. This catch
            // covers the FunctionCallOutput send + the createResponse
            // send — both critical for voice continuity.
            lastError = "klo couldn't return a tool result to the voice model. Please ask again."
        }
    }
}

// MARK: - Errors

enum RealtimeBridgeError: LocalizedError {
    case notSignedIn
    case subscriptionRequired
    case upstreamFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:           return "Sign in to use voice mode."
        // Cloud gates voice at Starter and above (free tier blocked) —
        // keep this in sync with klo_cloud/realtime.py's tier gate.
        case .subscriptionRequired:  return "Voice mode is part of klo Starter. Upgrade to talk to klo."
        case .upstreamFailed(let s): return "Voice service unavailable (\(s))."
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by AgentClient when a Realtime-dispatched run completes.
    /// userInfo: { "call_id": String, "output": String }.
    static let kloRealtimeRunComplete = Notification.Name("klo.realtime.runComplete")
}
