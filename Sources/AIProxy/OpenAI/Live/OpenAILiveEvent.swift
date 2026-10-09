import Foundation

/// Original WebSocket content. JSON text is retained unchanged alongside decoded fields.
@available(watchOS 10.5, *)
nonisolated public enum OpenAILiveRawMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)

    var byteCount: Int {
        switch self {
        case .text(let text): return text.utf8.count
        case .binary(let bytes): return bytes.count
        }
    }
}

@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveSessionResource: Decodable, Sendable {
    public let id: String
    public let expiresAt: Double
    public let model: String
    public let status: String
    /// Complete resolved configuration, including fields added by the provider.
    public let json: [String: AIProxyJSONValue]

    enum CodingKeys: String, CodingKey {
        case id, model, status
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try fields.decode(String.self, forKey: .id)
        self.expiresAt = try fields.decode(Double.self, forKey: .expiresAt)
        self.model = try fields.decode(String.self, forKey: .model)
        self.status = try fields.decode(String.self, forKey: .status)
        self.json = try [String: AIProxyJSONValue](from: decoder)
    }
}

@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveUsage: Decodable, Sendable {
    /// Cumulative seconds; a later snapshot replaces the previous value.
    public let seconds: Double
}

@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveEvent: Sendable {
    public let rawMessage: OpenAILiveRawMessage
    public let payload: Payload?
    /// A payload decode diagnostic is nonterminal and never includes message content.
    public let diagnostic: DecodeDiagnostic?

    public enum DecodeDiagnostic: Sendable {
        case invalidJSON, invalidEvent, invalidBase64, unexpectedBinary
    }

    public enum Payload: Sendable {
        case started(SessionEvent)
        case updated(SessionEvent)
        case inputTranscript(TranscriptDelta)
        case outputTranscript(TranscriptDelta)
        case inputMuted(Acknowledgment)
        case inputUnmuted(Acknowledgment)
        case instructionsAppended(ContextAppended)
        case thinkingAppended(ContextAppended)
        case commentaryAppended(ContextAppended)
        case delegationCreated(DelegationCreated)
        case responseEvent(ResponseEvent)
        case info(Info)
        case outputAudio(OutputAudio)
        case usage(UsageEvent)
        case closed(ClosedEvent)
        case error(ErrorEvent)
        case unknown(type: String)
    }

    public struct SessionEvent: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let session: OpenAILiveSessionResource
        enum CodingKeys: String, CodingKey {
            case session
            case eventID = "event_id"
            case clientEventID = "client_event_id"
        }
    }

    /// A provider transcript fragment. Offsets and text are exposed without deriving a transcript.
    public struct TranscriptDelta: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let delta: String
        public let startMs: Double
        public let endMs: Double
        enum CodingKeys: String, CodingKey {
            case delta
            case eventID = "event_id"
            case clientEventID = "client_event_id"
            case startMs = "start_ms"
            case endMs = "end_ms"
        }
    }

    public struct Acknowledgment: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case clientEventID = "client_event_id"
        }
    }

    /// Context-delivery estimates do not confirm speech, playback or use of all supplied context.
    public struct ContextAppended: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let startMs: Double
        public let endMs: Double
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case clientEventID = "client_event_id"
            case startMs = "start_ms"
            case endMs = "end_ms"
        }
    }

    public struct DelegationCreated: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let offsetMs: Double
        public let delegation: Delegation

        /// Provider metadata, without SDK task execution or result routing.
        public struct Delegation: Decodable, Sendable {
            public let id: String
            public let type: String
            public let target: String
            public let responseID: String?
            enum CodingKeys: String, CodingKey {
                case id, type, target
                case responseID = "response_id"
            }
        }
        enum CodingKeys: String, CodingKey {
            case delegation
            case eventID = "event_id"
            case clientEventID = "client_event_id"
            case offsetMs = "offset_ms"
        }
    }

    /// A raw nested Responses event. Compact lifecycle snapshots need not match a standalone response.
    public struct ResponseEvent: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let delegationID: String?
        public let event: [String: AIProxyJSONValue]
        enum CodingKeys: String, CodingKey {
            case event
            case eventID = "event_id"
            case clientEventID = "client_event_id"
            case delegationID = "delegation_id"
        }
    }

    public struct Info: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let code: String
        public let message: String
        enum CodingKeys: String, CodingKey {
            case code, message
            case eventID = "event_id"
            case clientEventID = "client_event_id"
        }
    }

    public struct OutputAudio: Decodable, Sendable {
        public let delta: String
        public let audio: Data?
        public let startMs: Double?
        public let endMs: Double?
        enum CodingKeys: String, CodingKey {
            case delta
            case startMs = "start_ms"
            case endMs = "end_ms"
        }
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            self.delta = try fields.decode(String.self, forKey: .delta)
            self.startMs = try fields.decodeIfPresent(Double.self, forKey: .startMs)
            self.endMs = try fields.decodeIfPresent(Double.self, forKey: .endMs)
            self.audio = decodeLiveAudio(delta)
        }
    }

    public struct UsageEvent: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let usage: OpenAILiveUsage
        public let contextWindow: ContextWindow?
        public struct ContextWindow: Decodable, Sendable {
            public let usageRatio: Double
            enum CodingKeys: String, CodingKey { case usageRatio = "usage_ratio" }
        }
        enum CodingKeys: String, CodingKey {
            case usage
            case eventID = "event_id"
            case clientEventID = "client_event_id"
            case contextWindow = "context_window"
        }
    }

    public struct ClosedEvent: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let session: OpenAILiveSessionResource
        public let reason: String
        public let usage: OpenAILiveUsage
        enum CodingKeys: String, CodingKey {
            case session, reason, usage
            case eventID = "event_id"
            case clientEventID = "client_event_id"
        }
    }

    public struct ErrorEvent: Decodable, Sendable {
        public let eventID: String
        public let clientEventID: String?
        public let error: OpenAILiveProviderError
        enum CodingKeys: String, CodingKey {
            case error
            case eventID = "event_id"
            case clientEventID = "client_event_id"
        }
    }

    static func decode(_ raw: OpenAILiveRawMessage) -> Self {
        guard case .text(let text) = raw else {
            return .init(rawMessage: raw, payload: nil, diagnostic: .unexpectedBinary)
        }
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard (try? decoder.decode(AIProxyJSONValue.self, from: data)) != nil else {
            return .init(rawMessage: raw, payload: nil, diagnostic: .invalidJSON)
        }
        struct Header: Decodable { let type: String }
        do {
            let type = try decoder.decode(Header.self, from: data).type
            let payload: Payload
            var diagnostic: DecodeDiagnostic?
            switch type {
            case "session.started": payload = .started(try decoder.decode(SessionEvent.self, from: data))
            case "session.updated": payload = .updated(try decoder.decode(SessionEvent.self, from: data))
            case "session.input_transcript.delta":
                payload = .inputTranscript(try decoder.decode(TranscriptDelta.self, from: data))
            case "session.output_transcript.delta":
                payload = .outputTranscript(try decoder.decode(TranscriptDelta.self, from: data))
            case "session.input_audio.muted": payload = .inputMuted(try decoder.decode(Acknowledgment.self, from: data))
            case "session.input_audio.unmuted": payload = .inputUnmuted(try decoder.decode(Acknowledgment.self, from: data))
            case "session.instructions.appended":
                payload = .instructionsAppended(try decoder.decode(ContextAppended.self, from: data))
            case "session.thinking.appended":
                payload = .thinkingAppended(try decoder.decode(ContextAppended.self, from: data))
            case "session.commentary.appended":
                payload = .commentaryAppended(try decoder.decode(ContextAppended.self, from: data))
            case "session.delegation.created": payload = .delegationCreated(try decoder.decode(DelegationCreated.self, from: data))
            case "response.event": payload = .responseEvent(try decoder.decode(ResponseEvent.self, from: data))
            case "info": payload = .info(try decoder.decode(Info.self, from: data))
            case "session.output_audio.delta":
                let audio = try decoder.decode(OutputAudio.self, from: data)
                payload = .outputAudio(audio)
                if audio.audio == nil { diagnostic = .invalidBase64 }
            case "session.usage.updated": payload = .usage(try decoder.decode(UsageEvent.self, from: data))
            case "session.closed": payload = .closed(try decoder.decode(ClosedEvent.self, from: data))
            case "error": payload = .error(try decoder.decode(ErrorEvent.self, from: data))
            default: payload = .unknown(type: type)
            }
            return .init(rawMessage: raw, payload: payload, diagnostic: diagnostic)
        } catch {
            return .init(rawMessage: raw, payload: nil, diagnostic: .invalidEvent)
        }
    }
}

nonisolated private func decodeLiveAudio(_ value: String) -> Data? {
    var padded = value
    let bytes = Array(value.utf8)
    guard bytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
        (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61 }) else { return nil }
    if !bytes.contains(61) {
        switch bytes.count % 4 {
        case 0: break
        case 2: padded += "=="
        case 3: padded += "="
        default: return nil
        }
    }
    guard let decoded = Data(base64Encoded: padded), decoded.base64EncodedString() == padded else { return nil }
    return decoded
}
