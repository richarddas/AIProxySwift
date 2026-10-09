import Foundation
import Testing
@testable import AIProxy

/// Documented SDK lifecycle policy fixtures; wire values are independently sourced from
/// the primary WebSocket reference (2026-10-08 source hash in OpenAILiveStarterTests).
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveAdversarialSmokeTests {
    @Test(arguments: [
        #"{"type":"error","event_id":"rejected_start","error":{"type":"invalid_request_error","code":"invalid_configuration","message":"Synthetic rejection.","client_event_id":"start_probe"}}"#,
        #"{"type":"error","event_id":"rejected_start","client_event_id":"start_probe","error":{"type":"invalid_request_error","code":null,"message":"Synthetic rejection."}}"#
    ])
    func S02_4_startCorrelatedProviderRejectionSettlesStartup(_ rejection: String) async throws {
        let peer = LiveProbePeer()
        peer.startMessages = [.text(rejection)]
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator()
        do {
            _ = try await session.start(eventID: "start_probe")
            Issue.record("Provider rejection must fail startup")
        } catch OpenAILiveError.provider(let provider) {
            #expect(provider.type == "invalid_request_error")
            #expect(provider.message == "Synthetic rejection.")
        }
        #expect(session.finalization?.isConfirmed == false)
        #expect(try await events.next()?.rawMessage == .text(rejection))
        await clock.waitUntilIdle()
        await peer.waitUntilIdle()
        #expect(peer.cancelCount == 1)
        #expect(peer.sent.count == 1)
    }

    @Test
    func S02_3_controlledStartupDeadlineDoesNotNeedAnotherFrame() async throws {
        let peer = LiveProbePeer()
        peer.startMessages = []
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        let start = Task { try await session.start(eventID: "start_probe") }
        await peer.waitForSentCount(1)
        await clock.waitForDeadline(30)
        await clock.expire(30)
        do {
            _ = try await start.value
            Issue.record("Startup should time out")
        } catch OpenAILiveError.timeout(.startup) {
            #expect(session.finalization?.isConfirmed == false)
        }
        await clock.waitUntilIdle()
        await peer.waitUntilIdle()
        #expect(peer.cancelCount == 1)
        #expect(peer.activeReceivers == 0)
        #expect(peer.activeWrites == 0)
    }

    @Test(arguments: [false, true])
    func S02_1_startedCannotHidePendingStartWriteOutcome(_ failWrite: Bool) async throws {
        let peer = LiveProbePeer()
        peer.holdStartWrite = true
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator()
        let start = Task { try await session.start(eventID: "start_probe") }
        await peer.waitForHeldStartWrite()
        // The received event proves readiness arrived while the start write remains suspended.
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.started))
        do {
            try await session.appendAudio(Data([0, 1]))
            Issue.record("A received started event cannot make an unfinished start write ready")
        } catch OpenAILiveError.notReady {}
        #expect(peer.sent.count == 1)
        peer.finishStartWrite(failing: failWrite)
        if failWrite {
            do {
                _ = try await start.value
                Issue.record("Failed start write must fail startup")
            } catch OpenAILiveError.transport(let failure) {
                #expect(failure.underlyingError is LiveProbeFailure)
            }
            #expect(session.finalization?.isConfirmed == false)
        } else {
            let ready = try await start.value
            #expect(ready.id == "live_probe")
            try await session.appendAudio(Data([0, 1]))
            #expect(peer.sent.count == 2)
            session.abort()
        }
        await clock.waitUntilIdle()
        await peer.waitUntilIdle()
    }

    @Test(arguments: [
        OpenAILiveRawMessage.text("{ invalid"),
        .text(#"{"type":"session.output_audio.delta"}"#),
        .text(#"{"type":"session.started","event_id":"bad_start","session":{"id":"live_probe","model":"gpt-live-1","status":"active"}}"#),
        .text(#"{"type":"session.output_audio.delta","delta":"AA*A"}"#),
        .text(#"{"type":"error","event_id":"bad_error","error":{"type":"invalid_request_error","message":"Synthetic missing required code."}}"#),
        .binary(Data([0, 255, 1]))
    ])
    func S08_4_malformedMessageIsObservableAndFollowingAudioContinues(_ raw: OpenAILiveRawMessage) async throws {
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator()
        _ = try await session.start()
        _ = try await events.next()
        peer.emit(raw)
        peer.emit(.text(LiveProbeFixtures.output))
        let malformed = try #require(try await events.next())
        #expect(malformed.rawMessage == raw)
        #expect(malformed.diagnostic != nil)
        let valid = try #require(try await events.next())
        guard case .outputAudio(let audio) = valid.payload else { Issue.record("Reception must continue after malformed input"); session.abort(); return }
        #expect(audio.audio == Data([0, 1, 2]))
        #expect(session.finalization == nil)
        try await session.appendAudio(Data([1, 0]))
        session.abort()
        await clock.waitUntilIdle()
        await peer.waitUntilIdle()
    }

    @Test
    func S08_1_S08_2_infoUnknownAndAddedFieldsKeepExactRawMessage() async throws {
        let raws = [
            " {\"type\":\"provider.future\",\"nested\":{\"flag\":false,\"values\":[null,1.25,\"x\"]}}\n",
            #"{"type":"info","event_id":"info_probe","code":"data_channel_permissions","message":"Synthetic informational notice."}"#,
            #"{"type":"session.output_audio.delta","delta":"AAEC","future":{"nested":[null,false,2.5]}}"#
        ]
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator()
        _ = try await session.start()
        _ = try await events.next()
        for raw in raws {
            peer.emit(.text(raw))
            let event = try #require(try await events.next())
            #expect(event.rawMessage == .text(raw))
            #expect(event.diagnostic == nil)
        }
        #expect(session.finalization == nil)
        session.abort()
        await clock.waitUntilIdle()
        await peer.waitUntilIdle()
    }

    @Test
    func S12_3_cancelledReceiveSettlesWithoutAnotherPeerFrame() async throws {
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        let sequence = try session.events()
        _ = try await session.start()
        let armed = LiveProbeSignal()
        let receive = Task {
            var events = sequence.makeAsyncIterator()
            _ = try await events.next()
            armed.signal()
            return try await events.next()
        }
        await armed.wait()
        receive.cancel()
        do {
            _ = try await receive.value
            Issue.record("Cancelled receive should fail")
        } catch is CancellationError {}
        #expect(session.finalization?.isConfirmed == false)
        await clock.waitUntilIdle()
        await peer.waitUntilIdle()
        #expect(peer.cancelCount == 1)
        #expect(peer.activeReceivers == 0)
        #expect(peer.activeWrites == 0)
    }

    @Test
    func S12_5_finalOwnerReleaseStopsTransportAndDeadlines() async throws {
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        weak var observed: OpenAILiveSession?
        do {
            let session = liveProbeSession(peer: peer, clock: clock)
            observed = session
            _ = try await session.start()
        }
        await peer.waitForCancellation()
        await peer.waitUntilIdle()
        await clock.waitUntilIdle()
        #expect(observed == nil)
        #expect(peer.cancelCount == 1)
        #expect(peer.activeReceivers == 0)
        #expect(peer.activeWrites == 0)
    }

    @Test
    func S08_1_unknownEventCannotDisappearBeforeFollowingAudioAndTerminal() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        let unknown = #" {"type":"provider.future","nested":{"sentinel":"kept","flag":false}} "#
        peer.emit(.text(unknown)); peer.emit(.text(LiveProbeFixtures.output)); peer.emit(.text(LiveProbeFixtures.closed))
        let first = try #require(try await events.next())
        #expect(first.rawMessage == .text(unknown))
        guard case .unknown(let type) = first.payload else { Issue.record("Unknown event must remain in sequence before later valid events"); session.abort(); return }
        #expect(type == "provider.future")
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.closed))
        #expect(try await events.next() == nil)
        #expect(session.finalization?.isConfirmed == true)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

}
