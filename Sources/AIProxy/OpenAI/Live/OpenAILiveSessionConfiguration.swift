import Foundation

/// Startup configuration for the Live primary WebSocket. Omitted fields use provider defaults.
/// Use the JSON initializer for additional provider settings or explicit nullable values.
@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveSessionConfiguration: Encodable, Sendable {
    public let json: [String: AIProxyJSONValue]

    public init(
        model: String,
        instructions: String? = nil,
        audio: Audio? = nil,
        store: Bool? = nil,
        delegation: Delegation? = nil,
        input: [InitialMessage]? = nil
    ) {
        var fields: [String: AIProxyJSONValue] = ["model": .string(model)]
        if let instructions { fields["instructions"] = .string(instructions) }
        if let audio { fields["audio"] = .object(audio.json) }
        if let store { fields["store"] = .bool(store) }
        if let delegation { fields["delegation"] = delegation.json }
        if let input { fields["input"] = .array(input.map { .object($0.json) }) }
        self.json = fields
    }

    /// Passes the supplied session object without rewriting or locally validating provider settings.
    public init(json: [String: AIProxyJSONValue]) {
        self.json = json
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    public struct Audio: Sendable {
        public let format: AudioFormat?
        public let voice: String?
        public let customVoiceID: String?

        public init(format: AudioFormat? = nil, voice: String? = nil) {
            self.format = format
            self.voice = voice
            self.customVoiceID = nil
        }

        public init(format: AudioFormat? = nil, customVoiceID: String) {
            self.format = format
            self.voice = nil
            self.customVoiceID = customVoiceID
        }

        fileprivate var json: [String: AIProxyJSONValue] {
            var result: [String: AIProxyJSONValue] = [:]
            if let format { result["format"] = .object(format.json) }
            if let voice { result["output"] = .object(["voice": .string(voice)]) }
            if let customVoiceID {
                result["output"] = .object(["voice": .object(["id": .string(customVoiceID)])])
            }
            return result
        }
    }

    /// Delegation ownership is fixed at startup. Responses settings are passed through verbatim.
    public enum Delegation: Sendable {
        case client
        case responses([String: AIProxyJSONValue])
        case null

        fileprivate var json: AIProxyJSONValue {
            switch self {
            case .client: return .object(["type": "client"])
            case .responses(let settings):
                return .object(["type": "responses", "responses": .object(settings)])
            case .null: return nil
            }
        }
    }

    /// A text-only startup history item. The provider enforces the 128-item and 8,192-token limits.
    /// Use the configuration's JSON initializer for optional item IDs, status or additional fields.
    public struct InitialMessage: Sendable {
        public enum Role: String, Sendable { case developer, user, assistant }
        public let role: Role
        public let text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }

        fileprivate var json: [String: AIProxyJSONValue] {
            ["role": .string(role.rawValue),
             "content": .array([.object(["type": .string(role == .assistant ? "output_text" : "input_text"),
                                         "text": .string(text)])])]
        }
    }

    /// One format applies to both input and output. The SDK never converts audio.
    public enum AudioFormat: Sendable {
        case pcm16kHz, pcm24kHz, g711Ulaw, g711Alaw

        fileprivate var json: [String: AIProxyJSONValue] {
            switch self {
            case .pcm16kHz: return ["type": "audio/pcm", "rate": 16000]
            case .pcm24kHz: return ["type": "audio/pcm", "rate": 24000]
            case .g711Ulaw: return ["type": "audio/pcmu", "rate": 8000]
            case .g711Alaw: return ["type": "audio/pcma", "rate": 8000]
            }
        }
    }
}

/// Finite transport budgets. These defaults are SDK policies, not provider limits.
@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveSessionOptions: Sendable {
    public let startupTimeout: TimeInterval
    public let closeTimeout: TimeInterval
    public let writeTimeout: TimeInterval
    public let maximumIncomingMessageBytes: Int
    public let maximumPendingEvents: Int
    public let maximumPendingEventBytes: Int
    public let maximumPendingWrites: Int
    public let maximumPendingWriteBytes: Int

    public init(
        startupTimeout: TimeInterval = 30,
        closeTimeout: TimeInterval = 15,
        writeTimeout: TimeInterval = 15,
        maximumIncomingMessageBytes: Int = 256 * 1024,
        maximumPendingEvents: Int = 128,
        maximumPendingEventBytes: Int = 512 * 1024,
        maximumPendingWrites: Int = 8,
        maximumPendingWriteBytes: Int = 128 * 1024
    ) {
        self.startupTimeout = startupTimeout
        self.closeTimeout = closeTimeout
        self.writeTimeout = writeTimeout
        self.maximumIncomingMessageBytes = maximumIncomingMessageBytes
        self.maximumPendingEvents = maximumPendingEvents
        self.maximumPendingEventBytes = maximumPendingEventBytes
        self.maximumPendingWrites = maximumPendingWrites
        self.maximumPendingWriteBytes = maximumPendingWriteBytes
    }

    func validate() throws {
        let durations = [startupTimeout, closeTimeout, writeTimeout]
        guard durations.allSatisfy({ $0.isFinite && $0 > 0 && $0 < Double(UInt64.max) / 1_000_000_000 }),
              UInt(exactly: ceil(startupTimeout)) != nil,
              [maximumIncomingMessageBytes, maximumPendingEvents, maximumPendingEventBytes,
               maximumPendingWrites, maximumPendingWriteBytes].allSatisfy({ $0 > 0 }) else {
            throw OpenAILiveError.invalidOptions
        }
    }
}
