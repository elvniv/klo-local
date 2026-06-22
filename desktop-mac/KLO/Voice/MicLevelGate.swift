import AVFoundation
import Foundation

/// Client-side mic gate that decides whether to transmit audio to
/// OpenAI Realtime. This is the decisive layer against TV / podcast /
/// roommate audio bleed.
///
/// Why client-side and not server-side: once PCM reaches OpenAI's
/// Realtime endpoint, server-side VAD treats it as intentional user
/// speech and the model responds. Tuning VAD thresholds, language
/// hints, and system prompts can't fully undo that — TVs easily clear
/// any reasonable VAD threshold. The only place we can decisively
/// reject background audio is BEFORE it reaches the WebRTC transport.
///
/// Mechanism:
///   - AVAudioEngine taps the system mic on a parallel channel (does
///     not interfere with LiveKit-WebRTC's mic capture — both can
///     monitor the same inputNode).
///   - For each 1024-frame buffer (~21ms at 48kHz), we compute three
///     features:
///       1. RMS → dBFS (loudness)
///       2. Zero-crossing rate (ZCR) — count of sign changes / frame
///          length. Human voiced speech: 0.04-0.28. Compressed
///          broadcast / music: typically 0.05-0.10 with low variance.
///       3. Envelope variance — variance of windowed RMS over the
///          last ~250ms. Speech has transient modulation (consonants,
///          breath, pauses). TV/music is flatter.
///   - Hysteresis-gated state machine flips a Bool that the caller
///     (RealtimeBridge) binds to convo.muted.
///
/// Tuning: thresholds ship hard-coded with defaults that work for a
/// MacBook built-in mic at typical sitting distance. They live in
/// UserDefaults keys (`klo.voice.gate.*`) so power users can override
/// without code change.
@MainActor
final class MicLevelGate: ObservableObject {

    /// Emitted whenever the gate transitions open ↔ closed.
    /// RealtimeBridge binds this to `convo.muted` and a UI indicator.
    @Published private(set) var isOpen: Bool = false

    /// Latest dBFS reading (for UI / calibration). Smoothed with a
    /// 200ms exponential filter so the UI doesn't flicker.
    @Published private(set) var smoothedDbfs: Float = -60

    /// Callback fired on every gate transition. Use this for the
    /// convo.muted toggle so the WebRTC track flips immediately on the
    /// audio-tap thread (we marshal to main actor before publishing).
    var onGateChange: ((Bool) -> Void)?

    // MARK: - Tunables (UserDefaults-overridable)

    private struct Thresholds {
        var openDbfs: Float
        var zcrMin: Float
        var zcrMax: Float
        var envVarMin: Float
        var openMs: Int    // must satisfy all conditions for this long to open
        var closeMs: Int   // must fail any condition for this long to close
    }

    private static func loadThresholds() -> Thresholds {
        let d = UserDefaults.standard
        return Thresholds(
            // -42 dBFS picks up softer speech from typical sitting
            // distance to a MacBook built-in mic. TV at 2m is around
            // -50 dBFS, so this still rejects ambient TV cleanly.
            openDbfs:  d.object(forKey: "klo.voice.gate.openDbfs")  as? Float ?? -42,
            // ZCR — voiced English is 0.04-0.16; consonants push to
            // 0.28. Loosen the floor a touch to admit very low-pitched
            // speakers without affecting noise rejection.
            zcrMin:    d.object(forKey: "klo.voice.gate.zcrMin")    as? Float ?? 0.03,
            zcrMax:    d.object(forKey: "klo.voice.gate.zcrMax")    as? Float ?? 0.30,
            // Envelope variance — human speech has clear transient
            // modulation. Lowering from 0.0008 → 0.0004 admits softer
            // speakers; TV/music sits around 0.0001-0.0003.
            envVarMin: d.object(forKey: "klo.voice.gate.envVarMin") as? Float ?? 0.0004,
            openMs:    d.object(forKey: "klo.voice.gate.openMs")    as? Int ?? 80,
            closeMs:   d.object(forKey: "klo.voice.gate.closeMs")   as? Int ?? 700,
        )
    }

    // MARK: - Engine + state

    private let engine = AVAudioEngine()
    private var running = false

    /// Recent RMS samples for envelope-variance computation. ~10
    /// buffers (≈210ms at 48k/1024) is the right window — long enough
    /// for one syllable, short enough to react to silence quickly.
    private var rmsWindow: [Float] = []
    private static let windowSize = 10

    /// State-machine timing — when the open/close condition started
    /// being continuously satisfied / unsatisfied. Computed on the
    /// audio thread.
    private var openConditionSince: Date?
    private var closeConditionSince: Date?

    private let thresholds: Thresholds

    init() {
        self.thresholds = Self.loadThresholds()
    }

    // MARK: - Lifecycle

    /// Install the mic tap and start the engine. Idempotent — safe to
    /// call twice; second call is a no-op.
    func start() throws {
        guard !running else { return }
        // Reset state on every start so a previous session's stale
        // window doesn't bias the new session's gate.
        rmsWindow.removeAll(keepingCapacity: true)
        openConditionSince = nil
        closeConditionSince = nil
        isOpen = false

        let input = engine.inputNode
        // Use the input node's NATIVE format — coercing to a custom
        // format here can fail on certain mic devices (USB / BT
        // headsets) where the hardware sample rate doesn't match what
        // AVAudioFormat would default to.
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        try engine.start()
        running = true
        NSLog("KLO MicGate: started — format=%@ thresholds=dbfs:%.1f zcr:%.2f-%.2f envVar:%.4f open:%dms close:%dms",
              "\(format)",
              Double(thresholds.openDbfs),
              Double(thresholds.zcrMin), Double(thresholds.zcrMax),
              Double(thresholds.envVarMin),
              thresholds.openMs, thresholds.closeMs)
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        // Force closed on stop — so the UI binding settles to OFF.
        if isOpen {
            isOpen = false
            onGateChange?(false)
        }
        NSLog("KLO MicGate: stopped")
    }

    // MARK: - Per-buffer feature extraction (audio thread)

    nonisolated private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // RMS — mean squared, sqrt, → dBFS
        var sumSquares: Float = 0
        var prev: Float = 0
        var zeroCrossings = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sumSquares += sample * sample
            if i > 0 && (prev >= 0) != (sample >= 0) { zeroCrossings += 1 }
            prev = sample
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        let dbfs = 20 * log10(max(rms, 1e-7))  // clamp to avoid -inf
        let zcr = Float(zeroCrossings) / Float(frameLength)

        Task { @MainActor [weak self] in
            self?.update(rms: rms, dbfs: dbfs, zcr: zcr)
        }
    }

    private func update(rms: Float, dbfs: Float, zcr: Float) {
        // Smooth dBFS for UI (exponential, alpha ≈ 0.15 → 200ms
        // half-life at 50Hz buffer rate).
        smoothedDbfs = smoothedDbfs * 0.85 + dbfs * 0.15

        // Maintain rolling RMS window for envelope variance.
        rmsWindow.append(rms)
        if rmsWindow.count > Self.windowSize {
            rmsWindow.removeFirst(rmsWindow.count - Self.windowSize)
        }
        let envVar = Self.variance(rmsWindow)

        // Decide raw open/close condition for this buffer.
        let conditionOpen = (
            dbfs > thresholds.openDbfs
            && zcr >= thresholds.zcrMin
            && zcr <= thresholds.zcrMax
            && envVar > thresholds.envVarMin
        )

        let now = Date()
        if conditionOpen {
            closeConditionSince = nil
            if openConditionSince == nil {
                openConditionSince = now
            }
            let elapsedMs = Int(now.timeIntervalSince(openConditionSince!) * 1000)
            if elapsedMs >= thresholds.openMs && !isOpen {
                isOpen = true
                NSLog("KLO MicGate: OPEN  (dbfs=%.1f zcr=%.2f envVar=%.4f after %dms)",
                      Double(dbfs), Double(zcr), Double(envVar), elapsedMs)
                onGateChange?(true)
            }
        } else {
            openConditionSince = nil
            if closeConditionSince == nil {
                closeConditionSince = now
            }
            let elapsedMs = Int(now.timeIntervalSince(closeConditionSince!) * 1000)
            if elapsedMs >= thresholds.closeMs && isOpen {
                isOpen = false
                NSLog("KLO MicGate: CLOSE (silent for %dms; last dbfs=%.1f zcr=%.2f envVar=%.4f)",
                      elapsedMs, Double(dbfs), Double(zcr), Double(envVar))
                onGateChange?(false)
            }
        }
    }

    private static func variance(_ xs: [Float]) -> Float {
        guard xs.count >= 2 else { return 0 }
        let mean = xs.reduce(0, +) / Float(xs.count)
        var s: Float = 0
        for x in xs { s += (x - mean) * (x - mean) }
        return s / Float(xs.count)
    }
}
