import AIProxy
import Foundation

/// These helpers construct configurations without connecting to a service.
@available(watchOS 10.5, *)
nonisolated public enum LiveExampleConfigurations {
    /// Optional settings remain absent so the provider resolves its defaults.
    public static var providerDefaults: OpenAILiveSessionConfiguration {
        .init(model: "gpt-live-1")
    }

    public static func client(
        format: OpenAILiveSessionConfiguration.AudioFormat
    ) -> OpenAILiveSessionConfiguration {
        .init(model: "gpt-live-1", audio: .init(format: format), delegation: .client)
    }

    /// The caller supplies the backend model and any tools/settings it has chosen.
    public static func responses(
        format: OpenAILiveSessionConfiguration.AudioFormat,
        backendSettings: [String: AIProxyJSONValue]
    ) -> OpenAILiveSessionConfiguration {
        .init(model: "gpt-live-1", audio: .init(format: format), delegation: .responses(backendSettings))
    }
}

/// Main-actor call site. The callback can hop explicitly to MainActor for caller-owned UI work.
@available(watchOS 10.5, *)
@MainActor public func validateLiveFromMainActor(
    service: OpenAIService,
    configuration: OpenAILiveSessionConfiguration,
    inputChunks: [Data],
    chunkIntervalNanoseconds: UInt64,
    consume: @escaping @Sendable (OpenAILiveSession, OpenAILiveEvent) async throws -> Void
) async throws -> LiveValidationReport {
    try await validateLiveSession(
        service: service,
        configuration: configuration,
        inputChunks: inputChunks,
        chunkIntervalNanoseconds: chunkIntervalNanoseconds,
        consume: consume
    )
}

/// Separate actor call site using the same public SDK surface.
@available(watchOS 10.5, *)
public actor LiveValidationWorker {
    public init() {}

    public func validate(
        service: OpenAIService,
        configuration: OpenAILiveSessionConfiguration,
        inputChunks: [Data],
        chunkIntervalNanoseconds: UInt64,
        consume: @escaping @Sendable (OpenAILiveSession, OpenAILiveEvent) async throws -> Void
    ) async throws -> LiveValidationReport {
        try await validateLiveSession(
            service: service,
            configuration: configuration,
            inputChunks: inputChunks,
            chunkIntervalNanoseconds: chunkIntervalNanoseconds,
            consume: consume
        )
    }
}
