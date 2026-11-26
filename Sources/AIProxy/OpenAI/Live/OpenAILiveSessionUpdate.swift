import Foundation

/// A sparse update within the existing delegation mode. Omitted settings keep their values.
/// Live model, initial instructions, audio and delegation ownership are immutable after startup.
@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveSessionUpdate: Encodable, Sendable {
    public let json: [String: AIProxyJSONValue]

    /// Updates only the supplied Responses backend settings. No model or tool policy is inserted.
    public init(responses: [String: AIProxyJSONValue]) {
        self.json = ["delegation": .object(["type": "responses", "responses": .object(responses)])]
    }

    /// Forwards additional configuration fields; the provider validates supported changes.
    public init(json: [String: AIProxyJSONValue]) {
        self.json = json
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}
