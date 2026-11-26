import AIProxy
import Foundation

/// Evidence from finite caller-supplied input. Successful sends mean local transport acceptance.
@available(watchOS 10.5, *)
nonisolated public struct LiveInputEvidence: Sendable {
    public fileprivate(set) var completedChunks: UInt64 = 0
    public fileprivate(set) var completedBytes: UInt64 = 0
    public fileprivate(set) var failure: (any Error)?
}

/// Counts only. The harness retains no audio, transcripts, raw events or backend results.
@available(watchOS 10.5, *)
nonisolated public struct LiveEventEvidence: Sendable {
    public fileprivate(set) var receivedEvents: UInt64 = 0
    public fileprivate(set) var outputAudioBytes: UInt64 = 0
    public fileprivate(set) var decodeDiagnostics: UInt64 = 0
    public fileprivate(set) var unknownEvents: UInt64 = 0
    public fileprivate(set) var providerErrors: UInt64 = 0
    /// Receive or caller-callback failure. Provider error events reach the callback unchanged.
    public fileprivate(set) var failure: (any Error)?
}

@available(watchOS 10.5, *)
nonisolated public struct LiveValidationReport: Sendable {
    public let finalization: OpenAILiveFinalization
    public let input: LiveInputEvidence
    public let events: LiveEventEvidence
}

@available(watchOS 10.5, *)
nonisolated private enum LiveWorkerEvidence: Sendable {
    case input(LiveInputEvidence)
    case events(LiveEventEvidence)
}

/// Opt-in service validation using only the public AIProxy API.
///
/// Supply an already configured service and finite raw chunks matching the session format.
/// Pacing and the post-input observation interval are caller choices, in nanoseconds.
/// The callback runs sequentially on the sole event consumer and may use the supplied session
/// for caller-directed commands. It must return promptly and cooperate with cancellation.
///
/// Configuration/setup errors throw. Once workers start, their errors are retained in the
/// returned evidence; inspect both failure fields and finalization.isConfirmed. Cancellation
/// aborts the session and can discard unread events. No retries, tools or content logging occur.
@available(watchOS 10.5, *)
nonisolated public func validateLiveSession(
    service: OpenAIService,
    configuration: OpenAILiveSessionConfiguration,
    inputChunks: [Data],
    options: OpenAILiveSessionOptions = .init(),
    chunkIntervalNanoseconds: UInt64 = 0,
    observationNanosecondsAfterInput: UInt64 = 0,
    consume: @escaping @Sendable (OpenAILiveSession, OpenAILiveEvent) async throws -> Void
) async throws -> LiveValidationReport {
    try Task.checkCancellation()
    let session = try await service.makeLiveSession(configuration: configuration, options: options)
    let events = try await session.events()

    return await withTaskGroup(of: LiveWorkerEvidence.self) { group in
        group.addTask {
            var evidence = LiveEventEvidence()
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    evidence.receivedEvents += 1
                    if event.diagnostic != nil { evidence.decodeDiagnostics += 1 }
                    if case .outputAudio(let audio) = event.payload {
                        evidence.outputAudioBytes += UInt64(audio.audio?.count ?? 0)
                    }
                    if case .unknown = event.payload { evidence.unknownEvents += 1 }
                    if case .error = event.payload { evidence.providerErrors += 1 }
                    try await consume(session, event)
                }
            } catch {
                evidence.failure = error
                await session.abort()
            }
            return .events(evidence)
        }

        group.addTask {
            var evidence = LiveInputEvidence()
            do {
                _ = try await session.start()
                for (index, bytes) in inputChunks.enumerated() {
                    try Task.checkCancellation()
                    if index > 0, chunkIntervalNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: chunkIntervalNanoseconds)
                    }
                    try await session.appendAudio(bytes)
                    evidence.completedChunks += 1
                    evidence.completedBytes += UInt64(bytes.count)
                }
                if observationNanosecondsAfterInput > 0 {
                    try await Task.sleep(nanoseconds: observationNanosecondsAfterInput)
                }
                _ = await session.close()
            } catch {
                evidence.failure = error
                await session.abort()
            }
            return .input(evidence)
        }

        var inputEvidence = LiveInputEvidence()
        var eventEvidence = LiveEventEvidence()
        for await result in group {
            switch result {
            case .input(let evidence):
                inputEvidence = evidence
                // Normal close keeps the consumer alive to drain accepted and terminal events.
                if evidence.failure != nil { group.cancelAll() }
            case .events(let evidence):
                eventEvidence = evidence
                // The stream ended or its consumer failed. Stop remaining input/pacing work.
                group.cancelAll()
            }
        }

        // Both workers finished. This reads the retained outcome; it does not open another stream.
        let finalization = await session.close()
        return LiveValidationReport(finalization: finalization, input: inputEvidence, events: eventEvidence)
    }
}
