import Foundation

@available(watchOS 10.5, *)
nonisolated public enum OpenAILiveError: Error, Sendable {
    case invalidOptions
    case alreadyStarted
    case notReady
    case closed
    case subscriberAlreadyExists
    case concurrentReceive
    case timeout(Phase)
    case limitExceeded(Limit)
    case aborted
    case provider(OpenAILiveProviderError)
    case transport(OpenAILiveTransportError)

    public enum Phase: Sendable { case startup, write, close }
    public enum Limit: Sendable { case incomingMessage, pendingEvents, pendingEventBytes, pendingWrites, pendingWriteBytes }
}

/// A transport error and only the HTTP metadata actually supplied by the transport.
@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveTransportError: Error, Sendable {
    public let underlyingError: any Error
    public let statusCode: Int?
    public let headers: [String: String]?
    public let closeCode: Int?
    public let closeReason: Data?

    init(underlyingError: any Error, response: HTTPURLResponse?, closeCode: Int?, closeReason: Data?) {
        self.underlyingError = underlyingError
        self.statusCode = response?.statusCode
        self.headers = response?.readableHeaders
        self.closeCode = closeCode
        self.closeReason = closeReason
    }
}

@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveProviderError: Decodable, Error, Sendable {
    public let type: String
    public let code: String?
    public let message: String
    public let param: String?
    public let clientEventID: String?

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try fields.decode(String.self, forKey: .type)
        // The reference requires code; the session guide additionally documents explicit null.
        self.code = try fields.decode(String?.self, forKey: .code)
        self.message = try fields.decode(String.self, forKey: .message)
        self.param = try fields.decodeIfPresent(String.self, forKey: .param)
        self.clientEventID = try fields.decodeIfPresent(String.self, forKey: .clientEventID)
    }

    enum CodingKeys: String, CodingKey {
        case type, code, message, param
        case clientEventID = "client_event_id"
    }
}

/// Final usage is confirmed only after a valid `session.closed` event.
@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveFinalization: Sendable {
    public let isConfirmed: Bool
    public let session: OpenAILiveSessionResource?
    public let reason: String?
    public let usage: OpenAILiveUsage?
    public let cause: (any Error)?
}
