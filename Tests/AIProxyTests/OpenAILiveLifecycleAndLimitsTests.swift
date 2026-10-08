import Foundation
import Testing
@testable import AIProxy

/// Documented SDK lifecycle policies. Synthetic payloads obey independently captured public schemas.
/// These scripted checks do not establish actual URLSession/TLS/device behavior.
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveLifecycleAndLimitsTests {
    @Test
    func S06_4_S10_3_appendRejectionDuringCloseIsVisibleAndCloseIsShared() async throws {
        let peer = LiveProbePeer(); peer.automaticallyClose = false
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        _ = try await session.appendCommentary("Context.", eventID: "append_a")
        let close1 = Task { await session.close() }; await peer.waitForSentCount(3)
        let close2 = Task { await session.close() }
        do { _ = try await session.createResponse(); Issue.record("Closing must reject new work") }
        catch OpenAILiveError.closed {}
        let rejection = #"{"type":"error","event_id":"append_rejected","error":{"type":"invalid_request_error","code":"session_closing","message":"Synthetic pending append rejection.","client_event_id":"append_a"}}"#
        peer.emit(.text(rejection)); #expect(try await events.next()?.rawMessage == .text(rejection))
        #expect(session.finalization == nil)
        peer.emit(.text(LiveProbeFixtures.closed))
        let first = await close1.value; let second = await close2.value
        #expect(first.isConfirmed); #expect(second.isConfirmed); #expect(first.usage?.seconds == second.usage?.seconds)
        #expect(peer.sent.count == 3)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: [false, true])
    func S10_2_closeTimeoutOrEOFLeavesUsageUnconfirmed(_ useTimeout: Bool) async throws {
        let peer = LiveProbePeer(); peer.automaticallyClose = false
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock, options: .init(closeTimeout: 9))
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        peer.emit(.text(#"{"type":"session.usage.updated","event_id":"usage","usage":{"seconds":12.5}}"#)); _ = try await events.next()
        let close = Task { await session.close() }; await peer.waitForSentCount(2)
        if useTimeout { await clock.waitForDeadline(9); await clock.expire(9) }
        else { peer.failReceive(URLError(.networkConnectionLost)) }
        let result = await close.value
        #expect(!result.isConfirmed); #expect(result.usage?.seconds == 12.5)
        if useTimeout {
            guard case .timeout(.close)? = result.cause as? OpenAILiveError else { Issue.record("Expected close timeout"); return }
        } else {
            guard case .transport(let error)? = result.cause as? OpenAILiveError else { Issue.record("Expected transport failure"); return }
            #expect((error.underlyingError as? URLError)?.code == .networkConnectionLost)
        }
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S10_1_S11_2_closeWaitsOnlyForEmittingWriteAndSendReturnsAfterTransport() async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        let write = Task { try await session.appendAudio(Data([0, 1]), eventID: "audio") }
        await peer.waitForHeldWrite()
        let close = Task { await session.close() }
        await clock.waitForDeadline(15)
        // The emitting write has not completed, so no session.close can be emitted yet.
        #expect(peer.sent.count == 2)
        peer.finishHeldWrite()
        try await write.value
        let result = await close.value
        #expect(result.isConfirmed); #expect(peer.sent.count == 3)
        try liveExpectJSON(Data(peer.sent[2].utf8), #"{"type":"session.close"}"#)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S10_2_closeDeadlineIncludesAlreadyEmittingWrite() async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock, options: .init(closeTimeout: 7, writeTimeout: 19))
        _ = try await session.start()
        let write = Task { try await session.appendAudio(Data([0, 1])) }
        await peer.waitForHeldWrite()
        let close = Task { await session.close() }
        await clock.waitForDeadline(7); await clock.expire(7)
        let result = await close.value
        #expect(!result.isConfirmed)
        guard case .timeout(.close)? = result.cause as? OpenAILiveError else { Issue.record("Expected close deadline"); return }
        do { try await write.value; Issue.record("Emitting write must settle as failure") }
        catch OpenAILiveError.timeout(.close) {}
        #expect(peer.sent.count == 2)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S11_3_cancelEmittingWriteAbortsWithoutReplay() async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        let write = Task { try await session.appendAudio(Data([0, 1])) }
        await peer.waitForHeldWrite(); write.cancel()
        do { try await write.value; Issue.record("Cancelled emitting write must fail") }
        catch is CancellationError {}
        #expect(session.finalization?.isConfirmed == false); #expect(peer.sent.count == 2)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S12_1_singleOversizeOutgoingMessageFailsBeforeEmission() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, options: .init(maximumPendingWriteBytes: 256))
        _ = try await session.start(eventID: "start")
        do { _ = try await session.appendInstructions(String(repeating: "x", count: 256), eventID: "large"); Issue.record("Oversized command must fail") }
        catch OpenAILiveError.limitExceeded(.pendingWriteBytes) {}
        #expect(peer.sent.count == 1); #expect(session.finalization?.isConfirmed == false)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: [false, true])
    func S12_2_eventMessageAndUTF8ByteBudgetsPreserveAcceptedBacklog(_ byteBudget: Bool) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let options = OpenAILiveSessionOptions(maximumPendingEvents: byteBudget ? 10 : 2, maximumPendingEventBytes: byteBudget ? 240 : 1024)
        let session = liveProbeSession(peer: peer, clock: clock, options: options)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        await peer.waitForReceiveCalls(2)
        let prefix = #"{"type":"provider.future","delta":"🧪"}"#
        let raw = prefix + String(repeating: " ", count: 120 - prefix.utf8.count)
        #expect(raw.utf8.count == 120)
        peer.emit(.text(raw)); peer.emit(.text(raw))
        await peer.waitForReceiveCalls(4)
        peer.emit(.text(#"{"type":"provider.future"}"#))
        await peer.waitForCancellation()
        let result = try #require(session.finalization)
        #expect(!result.isConfirmed)
        if byteBudget { guard case .limitExceeded(.pendingEventBytes)? = result.cause as? OpenAILiveError else { Issue.record("Expected byte limit"); return } }
        else { guard case .limitExceeded(.pendingEvents)? = result.cause as? OpenAILiveError else { Issue.record("Expected count limit"); return } }
        #expect(try await events.next()?.rawMessage == .text(raw)); #expect(try await events.next()?.rawMessage == .text(raw))
        do { _ = try await events.next(); Issue.record("Stream must finish with limit error after backlog") }
        catch OpenAILiveError.limitExceeded {}
        #expect(try await events.next() == nil)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S10_4_terminalEventBypassesFullPendingBudgetWithoutErasingEvents() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, options: .init(maximumPendingEvents: 2, maximumPendingEventBytes: 240))
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        await peer.waitForReceiveCalls(2)
        peer.emit(.text(LiveProbeFixtures.output)); peer.emit(.text(LiveProbeFixtures.output)); await peer.waitForReceiveCalls(4)
        #expect(session.resourceSnapshot.pendingEventCount == 2)
        #expect(session.resourceSnapshot.pendingEventBytes == 2 * LiveProbeFixtures.output.utf8.count)
        peer.emit(.text(LiveProbeFixtures.closed)); await peer.waitForCancellation()
        #expect(session.resourceSnapshot.pendingEventCount == 2)
        #expect(session.resourceSnapshot.terminalRecordBytes == LiveProbeFixtures.closed.utf8.count)
        #expect(session.resourceSnapshot.startWaiterCount == 0)
        #expect(session.resourceSnapshot.closeWaiterCount == 0)
        #expect(session.finalization?.isConfirmed == true); #expect(session.finalization?.usage?.seconds == 15.25)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.closed))
        #expect(try await events.next() == nil)
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [256, 257])
    func S12_2_scriptedIncomingMessageByteBoundary(_ size: Int) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, options: .init(maximumIncomingMessageBytes: 256))
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        let prefix = #"{"type":"provider.future"}"#
        let raw = prefix + String(repeating: " ", count: size - prefix.utf8.count)
        peer.emit(.text(raw))
        if size == 256 {
            #expect(try await events.next()?.rawMessage == .text(raw)); #expect(session.finalization == nil); session.abort()
        } else {
            await peer.waitForCancellation()
            guard case .limitExceeded(.incomingMessage)? = session.finalization?.cause as? OpenAILiveError else { Issue.record("Expected incoming message limit"); return }
        }
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S12_4_secondSubscriberAndIteratorCannotStealBufferedEvents() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        let sequence = try session.events(); var first = sequence.makeAsyncIterator(); var second = sequence.makeAsyncIterator()
        do { _ = try session.events(); Issue.record("Second subscriber must reject") }
        catch OpenAILiveError.subscriberAlreadyExists {}
        _ = try await session.start(); _ = try await first.next()
        peer.emit(.text(LiveProbeFixtures.output))
        do { _ = try await second.next(); Issue.record("Second iterator must reject") }
        catch OpenAILiveError.subscriberAlreadyExists {}
        #expect(try await first.next()?.rawMessage == .text(LiveProbeFixtures.output))
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S02_6_closeDuringStartupAbortsLocally() async throws {
        let peer = LiveProbePeer(); peer.startMessages = []
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        let start = Task { try await session.start() }; await peer.waitForSentCount(1)
        let result = await session.close(); #expect(!result.isConfirmed)
        do { _ = try await start.value; Issue.record("Close should cancel startup") } catch is CancellationError {}
        #expect(peer.sent.count == 1)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S12_5_oneHundredSessionsReleaseInjectedOperationsAndFinalOwner() async throws {
        for index in 0..<100 {
            let peer = LiveProbePeer(); let clock = LiveProbeClock()
            weak var observed: OpenAILiveSession?
            do {
                let session = liveProbeSession(peer: peer, clock: clock); observed = session
                var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
                peer.emit(.text(LiveProbeFixtures.output))
                await peer.waitForReceiveCalls(3)
                #expect(session.resourceSnapshot.pendingEventCount == 1)
                #expect(session.resourceSnapshot.pendingEventBytes == LiveProbeFixtures.output.utf8.count)
                if index.isMultiple(of: 2) {
                    let result = await session.close(); #expect(result.isConfirmed)
                    #expect(session.resourceSnapshot.pendingEventCount == 1)
                    #expect(session.resourceSnapshot.terminalRecordBytes == LiveProbeFixtures.closed.utf8.count)
                    while try await events.next() != nil {}
                } else { session.abort() }
                await clock.waitUntilIdle(); await peer.waitUntilIdle()
                #expect(peer.activeWrites == 0); #expect(peer.activeReceivers == 0)
                #expect(await clock.activeSleeps == 0)
                liveExpectEmptyResources(session.resourceSnapshot)
            }
            #expect(observed == nil)
        }
    }

    @Test
    func S02_5_noncooperativeExternalRequestCannotCreateALateTransport() async throws {
        let held = HeldLiveRequest(); let clock = LiveProbeClock(); let peer = LiveProbePeer()
        var transportCreations = 0
        let session = OpenAILiveSession(configuration: .init(model: "gpt-live-1"), options: .init(), dependencies: .init(
            makeRequest: { await held.request() },
            makeTransport: { _, _ in transportCreations += 1; return peer },
            sleep: { seconds in try await clock.sleep(seconds) }
        ))
        let start = Task { try await session.start() }; await held.entered.wait()
        start.cancel()
        do { _ = try await start.value; Issue.record("Cancelled startup must settle") } catch is CancellationError {}
        #expect(session.finalization?.isConfirmed == false)
        // An arbitrary external async dependency cannot be forcibly terminated by the SDK.
        // The owned credential callback bridge is tested separately for actual worker exit.
        #expect(held.activeRequests == 1)
        held.completeLate()
        await held.exited.wait()
        #expect(transportCreations == 0)
        await clock.waitUntilIdle()
    }
}

@AIProxyActor
private final class HeldLiveRequest {
    let entered = LiveProbeSignal(); let exited = LiveProbeSignal()
    private(set) var activeRequests = 0
    private var continuation: CheckedContinuation<URLRequest, Never>?
    func request() async -> URLRequest {
        activeRequests += 1; defer { activeRequests -= 1; exited.signal() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation; entered.signal()
        }
    }
    func completeLate() {
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: URLRequest(url: URL(string: "wss://example.invalid/v1/live/sessions")!))
    }
}
