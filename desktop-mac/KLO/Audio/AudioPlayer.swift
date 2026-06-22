import AVFoundation
import Foundation

/// Audio playback wrapper with two channels:
///   - `player`: the one-shot cinematic sound (launch-ceremony.mp3,
///     ~12s). Plays once at cinematic start, fades out at end.
///   - `ambientPlayer`: an ethereal looping ambient bed
///     (onboarding-ambient.mp3, ~60s) that plays under the demo tour
///     and onboarding card. Loops indefinitely; fades in at start
///     of demo tour, fades out when onboarding completes/dismisses.
///
/// Both channels use AVAudioPlayer so we can control volume / fade.
@MainActor
final class CeremonyAudio {

    static let shared = CeremonyAudio()
    private init() {}

    // MARK: - One-shot channel (cinematic)

    private var player: AVAudioPlayer?
    private var fadeTimer: Timer?

    /// Loads the named bundle resource and plays it from the start.
    func play(named name: String, ext: String = "mp3", volume: Float = 1.0) {
        fadeTimer?.invalidate()
        fadeTimer = nil

        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            NSLog("KLO Audio: missing bundled resource \(name).\(ext)")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = volume
            p.prepareToPlay()
            p.play()
            self.player = p
        } catch {
            NSLog("KLO Audio: failed to play \(name).\(ext): \(error)")
        }
    }

    /// Ramps the playing one-shot to zero over `seconds`, then stops.
    func fadeOut(over seconds: TimeInterval) {
        guard let p = player, p.isPlaying else { return }
        fadeTimer?.invalidate()

        let steps = max(1, Int(seconds * 30))
        let interval = seconds / TimeInterval(steps)
        let startVolume = p.volume
        var i = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            i += 1
            let progress = Float(i) / Float(steps)
            let next = max(0, startVolume * (1 - progress))
            Task { @MainActor in
                self?.player?.volume = next
                if i >= steps {
                    timer.invalidate()
                    self?.player?.stop()
                    self?.player = nil
                    self?.fadeTimer = nil
                }
            }
        }
    }

    /// Hard stop the one-shot.
    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        player?.stop()
        player = nil
    }

    // MARK: - Ambient channel (loops under demo tour + onboarding)

    private var ambientPlayer: AVAudioPlayer?
    private var ambientFadeTimer: Timer?

    /// Loads the named bundle resource and plays it on a loop, fading
    /// in to `targetVolume` over `fadeIn` seconds. Idempotent — if the
    /// ambient track is already playing, this is a no-op (so you can
    /// call it on every phase entry without restarting the bed).
    func playAmbient(
        named name: String,
        ext: String = "mp3",
        targetVolume: Float = 0.4,
        fadeIn: TimeInterval = 1.5
    ) {
        // Already playing — leave it alone so the loop stays
        // continuous through phase changes.
        if let existing = ambientPlayer, existing.isPlaying {
            return
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            NSLog("KLO Audio: missing bundled ambient \(name).\(ext)")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1     // infinite loop
            p.volume = 0.0
            p.prepareToPlay()
            p.play()
            self.ambientPlayer = p
            rampAmbientVolume(to: targetVolume, over: fadeIn)
        } catch {
            NSLog("KLO Audio: failed to play ambient \(name).\(ext): \(error)")
        }
    }

    /// Fade ambient to silence over `seconds`, then stop. Safe to call
    /// when nothing is playing.
    func stopAmbient(fadeOut seconds: TimeInterval = 1.0) {
        guard let p = ambientPlayer, p.isPlaying else {
            ambientPlayer = nil
            return
        }
        rampAmbientVolume(to: 0.0, over: seconds, stopAfter: true)
    }

    /// Internal: linearly ramp the ambient volume over `seconds`.
    private func rampAmbientVolume(to target: Float, over seconds: TimeInterval, stopAfter: Bool = false) {
        guard let p = ambientPlayer else { return }
        ambientFadeTimer?.invalidate()

        let steps = max(1, Int(seconds * 30))
        let interval = seconds / TimeInterval(steps)
        let startVolume = p.volume
        let delta = target - startVolume
        var i = 0

        ambientFadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            i += 1
            let progress = Float(i) / Float(steps)
            let next = max(0, startVolume + delta * progress)
            Task { @MainActor in
                self?.ambientPlayer?.volume = next
                if i >= steps {
                    timer.invalidate()
                    self?.ambientFadeTimer = nil
                    if stopAfter {
                        self?.ambientPlayer?.stop()
                        self?.ambientPlayer = nil
                    }
                }
            }
        }
    }

    // MARK: - Synthesized SFX (procedural tones)

    /// Procedural-tone channel for tiny UI moments — ⌘K presses, scene
    /// transitions, success pings. Synthesized in-process via
    /// AVAudioEngine + an AVAudioPlayerNode so we don't ship audio
    /// files for every micro-interaction. Output sits ON TOP of the
    /// ambient bed (separate node graph) so the loop doesn't duck.
    private let synthEngine = AVAudioEngine()
    private let synthPlayer = AVAudioPlayerNode()
    private var synthEngineStarted = false
    private let synthSampleRate: Double = 44_100

    private func ensureSynthEngineStarted() {
        guard !synthEngineStarted else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: synthSampleRate, channels: 1) else { return }
        synthEngine.attach(synthPlayer)
        synthEngine.connect(synthPlayer, to: synthEngine.mainMixerNode, format: format)
        do {
            try synthEngine.start()
            synthPlayer.play()
            synthEngineStarted = true
        } catch {
            NSLog("KLO Audio: synth engine failed to start: \(error)")
        }
    }

    /// Synthesize a chime — sum of sine waves at the given frequencies,
    /// shaped by a quick linear attack and exponential release. Use
    /// for short, pitched UI tones.
    func playChime(
        frequencies: [Double],
        duration: TimeInterval = 0.35,
        attack: TimeInterval = 0.005,
        release: TimeInterval = 0.30,
        peakAmp: Float = 0.18
    ) {
        ensureSynthEngineStarted()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: synthSampleRate, channels: 1) else { return }
        let frameCount = AVAudioFrameCount(duration * synthSampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        guard let channel = buffer.floatChannelData?[0] else { return }
        let attackEnd = max(0.001, attack)
        let releaseStart = max(0, duration - release)
        let count = Double(frequencies.count)

        for i in 0..<Int(frameCount) {
            let t = Double(i) / synthSampleRate
            let env: Double
            if t < attackEnd {
                env = t / attackEnd
            } else if t > releaseStart && release > 0 {
                let x = (t - releaseStart) / release
                env = exp(-x * 4)
            } else {
                env = 1.0
            }
            var sample: Double = 0
            for f in frequencies {
                sample += sin(2 * .pi * f * t)
            }
            sample /= count
            channel[i] = Float(sample * env) * peakAmp
        }

        synthPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Synthesize a frequency-glide swoosh — fundamental sweeps from
    /// `from` to `to` Hz across the duration. Use for scene
    /// transitions to give a subtle "moving forward" feel.
    func playGlide(
        from: Double,
        to: Double,
        duration: TimeInterval = 0.30,
        peakAmp: Float = 0.10
    ) {
        ensureSynthEngineStarted()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: synthSampleRate, channels: 1) else { return }
        let frameCount = AVAudioFrameCount(duration * synthSampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        guard let channel = buffer.floatChannelData?[0] else { return }
        let attackEnd = 0.04
        let releaseStart = max(0, duration - 0.15)
        let dt = 1.0 / synthSampleRate

        // Integrate phase across the time-varying frequency so we don't
        // get clicks from frequency jumps.
        var phase: Double = 0

        for i in 0..<Int(frameCount) {
            let t = Double(i) * dt
            let progress = duration > 0 ? t / duration : 0
            let freq = from + (to - from) * progress
            phase += 2 * .pi * freq * dt
            let sample = sin(phase)

            let env: Double
            if t < attackEnd {
                env = t / attackEnd
            } else if t > releaseStart {
                let x = (t - releaseStart) / 0.15
                env = exp(-x * 3)
            } else {
                env = 1.0
            }
            channel[i] = Float(sample * env) * peakAmp
        }

        synthPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Convenience SFX presets

    /// ⌘K trigger in the demo tour — rising C5→E5 chord chime.
    func playKeyPress() {
        playChime(frequencies: [523.25, 659.25], duration: 0.32, attack: 0.003, release: 0.28, peakAmp: 0.16)
    }

    /// Demo-scene boundary — short upward swoosh.
    func playSceneSwoosh() {
        playGlide(from: 380, to: 720, duration: 0.30, peakAmp: 0.10)
    }

    /// Permission granted / success moment — bell-like A5+E6.
    func playSuccessPing() {
        playChime(frequencies: [880, 1318.5], duration: 0.55, attack: 0.005, release: 0.50, peakAmp: 0.13)
    }
}
