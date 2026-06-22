public enum Model: RawRepresentable, Equatable, Hashable, Codable, Sendable {
	case gptRealtime
	case gptRealtimeMini
	case custom(String)

	public var rawValue: String {
		switch self {
			case .gptRealtime: return "gpt-realtime"
			case .gptRealtimeMini: return "gpt-realtime-mini"
			case let .custom(value): return value
		}
	}

	public init?(rawValue: String) {
		switch rawValue {
			case "gpt-realtime": self = .gptRealtime
			case "gpt-realtime-mini": self = .gptRealtimeMini
			default: self = .custom(rawValue)
		}
	}
}

public extension Model {
	enum Transcription: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
		case whisper = "whisper-1"
		// Was "gpt-4o-transcribe-latest" upstream — OpenAI rejects that
		// value ("invalid_value, Supported values are: 'whisper-1',
		// 'gpt-realtime-whisper', 'gpt-4o-transcribe', ..."). The whole
		// session.update gets bounced when this field is wrong, which
		// silently dropped klo's system prompt + tools and made the
		// session run as the default OpenAI persona. Patched to the
		// canonical "gpt-4o-transcribe" the API actually accepts.
		case gpt4o = "gpt-4o-transcribe"
		case gpt4oMini = "gpt-4o-mini-transcribe"
		case gpt4oDiarize = "gpt-4o-transcribe-diarize"
	}
}
