import Foundation

// OpenAI transcription client. Posts a WAV file to
// /v1/audio/transcriptions and returns the recognised text.
//
// Default model is `gpt-4o-transcribe` — newer than whisper-1, lower
// WER on technical/conversational dictation, same per-minute price.
// Override via `KLO_STT_MODEL` env if you want to A/B against
// `whisper-1` or `gpt-4o-mini-transcribe`.
//
// `prompt` biases the recogniser toward klo-specific vocabulary
// (app names, "klo" itself, technical terms). Per OpenAI docs the
// prompt is treated as preceding context, not transcribed.
final class STTClient {

    enum STTError: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case malformedResponse(String)
        case fileUnreadable(URL)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:        return "OPENAI_API_KEY is not set."
            case .http(let s, let b):   return "OpenAI returned HTTP \(s): \(b.prefix(300))"
            case .malformedResponse(let s): return "Malformed transcription response: \(s.prefix(200))"
            case .fileUnreadable(let u):    return "Could not read audio file at \(u.path)"
            }
        }
    }

    private let session: URLSession
    private let apiKey: String
    private let model: String
    private let promptHint: String?

    init(apiKey: String,
         model: String = "gpt-4o-transcribe",
         promptHint: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.promptHint = promptHint

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        guard !apiKey.isEmpty else { throw STTError.missingAPIKey }
        guard let audioData = try? Data(contentsOf: audioFileURL) else {
            throw STTError.fileUnreadable(audioFileURL)
        }
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "klo-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(&body, boundary: boundary, name: "model", value: model)
        appendField(&body, boundary: boundary, name: "response_format", value: "json")
        if let hint = promptHint, !hint.isEmpty {
            appendField(&body, boundary: boundary, name: "prompt", value: hint)
        }
        appendFile(&body, boundary: boundary,
                   name: "file",
                   filename: audioFileURL.lastPathComponent,
                   mime: "audio/wav",
                   data: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let started = Date()
        let (data, response) = try await session.data(for: req)
        let elapsed = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw STTError.malformedResponse("no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw STTError.http(http.statusCode, bodyText)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw STTError.malformedResponse(raw)
        }
        let bytes = audioData.count
        NSLog("KLO STT: \(bytes) bytes → '\(text.prefix(120))' in \(String(format: "%.2f", elapsed))s")
        return text
    }

    private func appendField(_ body: inout Data,
                             boundary: String,
                             name: String,
                             value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            .data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func appendFile(_ body: inout Data,
                            boundary: String,
                            name: String,
                            filename: String,
                            mime: String,
                            data: Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }
}
