import Foundation
import Testing
@testable import AIProxy

/// Independent fixtures from the OpenAI primary WebSocket reference captured 2026-10-08.
/// Source: https://developers.openai.com/api/reference/resources/live/primary-websocket.md
/// SHA-256: 8b84c091389c659ea77c18e17939fa6c8f04d2cca6fd1afffa5a3f680f2103e0
/// Synthetic identifiers, text and byte vectors are authored for these SDK tests.
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveStarterTests {
    @Test
    func S02_1_minimalImmediateStartedRemainsAvailableToSubscriber() async throws {
        let peer = LiveStarterPeer()
        let session = makeSession(peer: peer)

        let ready = try await session.start(eventID: "start_a")

        #expect(ready.id == "live_a")
        #expect(ready.model == "gpt-live-1")
        #expect(ready.status == "active")
        #expect(ready.expiresAt == 1788555600)
        try expectJSON(peer.sent[0], equals: #"{"type":"session.start","event_id":"start_a","session":{"model":"gpt-live-1"}}"#)
        #expect(peer.sent.count == 1)

        // The peer supplied both frames during start's write, before subscription.
        var events = try session.events().makeAsyncIterator()
        let started = try #require(try await events.next())
        let output = try #require(try await events.next())
        #expect(started.rawMessage == .text(LiveStarterFixtures.started))
        #expect(output.rawMessage == .text(LiveStarterFixtures.output))

        session.abort()
    }

    @Test
    func S04_1_audioWritePreservesIndependentRawByteVector() async throws {
        let peer = LiveStarterPeer()
        let session = makeSession(peer: peer)
        _ = try await session.start(eventID: "start_a")

        try await session.appendAudio(Data([0, 0, 255, 127, 0, 128]))

        #expect(peer.sent.count == 2)
        try expectJSON(peer.sent[1], equals: #"{"type":"session.input_audio.append","audio":"AAD/fwCA"}"#)
        session.abort()
    }

    @Test
    func S09_2_S10_1_explicitCloseConfirmsFinalizationWithActiveSnapshot() async throws {
        let peer = LiveStarterPeer()
        let session = makeSession(peer: peer)
        _ = try await session.start(eventID: "start_a")

        var events = try session.events().makeAsyncIterator()
        let final = await session.close()

        #expect(final.isConfirmed)
        #expect(final.session?.id == "live_a")
        #expect(final.session?.status == "active")
        #expect(final.reason == "close_requested")
        #expect(final.usage?.seconds == 15.25)
        #expect(session.latestUsage?.seconds == 15.25)
        #expect(session.finalization?.isConfirmed == true)
        #expect(peer.sent.count == 2)
        // Close may generate a correlation identifier, but no unrelated command.
        let close = try #require(try JSONSerialization.jsonObject(with: Data(peer.sent[1].utf8)) as? [String: Any])
        #expect(close["type"] as? String == "session.close")
        #expect(Set(close.keys).isSubset(of: ["type", "event_id"]))
        #expect(peer.cancelCount == 1)

        #expect(try await events.next()?.rawMessage == .text(LiveStarterFixtures.started))
        #expect(try await events.next()?.rawMessage == .text(LiveStarterFixtures.output))
        #expect(try await events.next()?.rawMessage == .text(LiveStarterFixtures.closed))
        #expect(try await events.next() == nil)
    }

    private func makeSession(peer: LiveStarterPeer) -> OpenAILiveSession {
        OpenAILiveSession(
            configuration: OpenAILiveSessionConfiguration(model: "gpt-live-1"),
            options: .init(),
            dependencies: .init(
                makeRequest: { URLRequest(url: URL(string: "wss://example.invalid/v1/live/sessions")!) },
                makeTransport: { _, _ in peer },
                sleep: { seconds in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            )
        )
    }

    private func expectJSON(_ actual: String, equals expected: String) throws {
        let actualObject = try JSONSerialization.jsonObject(with: Data(actual.utf8)) as! NSDictionary
        let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as! NSDictionary
        #expect(actualObject == expectedObject)
    }
}

private enum LiveStarterFixtures {
    // Documented minimal session resource: optional configuration is deliberately absent.
    static let started = #"{"type":"session.started","event_id":"started_a","session":{"id":"live_a","expires_at":1788555600,"model":"gpt-live-1","status":"active"}}"#
    // Primary output audio has no required event ID or timestamps.
    static let output = #"{"type":"session.output_audio.delta","delta":"AQD//w=="}"#
    static let closed = #"{"type":"session.closed","event_id":"closed_a","reason":"close_requested","session":{"id":"live_a","expires_at":1788555600,"model":"gpt-live-1","status":"active"},"usage":{"seconds":15.25}}"#
}

/// Only models transport delivery. It derives responses from independent literals,
/// never from encoded SDK event models or a simulated model response.
@AIProxyActor
private final class LiveStarterPeer: OpenAILiveTransport {
    private(set) var sent: [String] = []
    private(set) var cancelCount = 0
    private var pending: [OpenAILiveRawMessage] = []
    private var receiver: CheckedContinuation<OpenAILiveRawMessage, any Error>?
    private var cancelled = false
    var response: HTTPURLResponse? { nil }

    func resume() {}

    func send(_ text: String) async throws {
        sent.append(text)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        switch object["type"] as? String {
        case "session.start":
            emit(.text(LiveStarterFixtures.started))
            emit(.text(LiveStarterFixtures.output))
        case "session.close":
            emit(.text(LiveStarterFixtures.closed))
        default:
            break
        }
    }

    func receive() async throws -> OpenAILiveRawMessage {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        if cancelled {
            throw CancellationError()
        }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(receiver == nil, "Only one transport read may be active")
            receiver = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        cancelled = true
        let waiting = receiver
        receiver = nil
        waiting?.resume(throwing: CancellationError())
    }

    private func emit(_ message: OpenAILiveRawMessage) {
        if let waiting = receiver {
            receiver = nil
            waiting.resume(returning: message)
        } else {
            pending.append(message)
        }
    }
}
