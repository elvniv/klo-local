import AVFoundation
import Foundation

// Push-to-talk audio capture. Hold the hotkey → start() begins writing
// the mic to a temp WAV file. Release → stop() flushes and returns the
// URL for upload to STT.
//
// AVAudioRecorder (vs. AVAudioEngine) because:
//   • handles sample-rate conversion + WAV header writing internally
//   • no need for a tap, format converter, or manual disk I/O
//   • works with the existing NSMicrophoneUsageDescription permission
//
// Output format is 16kHz mono int16 PCM in a WAV container — what
// OpenAI's transcription API consumes most efficiently.
@MainActor
final class PushToTalkRecorder: NSObject {

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private(set) var isRecording: Bool = false
    private(set) var lastRecordingDuration: TimeInterval = 0

    /// Start recording into a fresh temp WAV. Throws if the recorder
    /// can't be initialised (almost always permission or device issues).
    func start() throws {
        guard !isRecording else {
            NSLog("KLO PTT: start() called while already recording — ignoring")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("klo-ptt-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = false
        guard rec.prepareToRecord() else {
            throw NSError(domain: "PushToTalkRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "prepareToRecord returned false"])
        }
        guard rec.record() else {
            throw NSError(domain: "PushToTalkRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder.record() returned false"])
        }
        recorder = rec
        fileURL = url
        isRecording = true
        NSLog("KLO PTT: recording → \(url.lastPathComponent)")
    }

    /// Stop recording and return the WAV file URL (or nil if nothing was
    /// captured). The file lives in the temp directory; STT upload is
    /// expected to delete it after consumption.
    func stop() -> URL? {
        guard isRecording, let rec = recorder else { return nil }
        let duration = rec.currentTime
        rec.stop()
        let url = fileURL
        recorder = nil
        fileURL = nil
        isRecording = false
        lastRecordingDuration = duration
        if let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            NSLog("KLO PTT: stopped (\(size) bytes, \(String(format: "%.2f", duration))s)")
        } else {
            NSLog("KLO PTT: stopped (\(String(format: "%.2f", duration))s, file missing)")
        }
        return url
    }

    /// Force-cancel without returning a file. Used when something else
    /// invalidates the recording mid-flight (e.g. user dismissed the
    /// panel before releasing the key).
    func cancel() {
        guard isRecording else { return }
        recorder?.stop()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        fileURL = nil
        isRecording = false
        NSLog("KLO PTT: recording cancelled")
    }
}

extension PushToTalkRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder,
                                                       error: Error?) {
        NSLog("KLO PTT: encode error — \(error?.localizedDescription ?? "?")")
    }
}
