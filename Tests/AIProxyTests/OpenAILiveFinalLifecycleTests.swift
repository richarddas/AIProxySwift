import Foundation
import Testing
@testable import AIProxy

/// Independent SDK lifecycle assertions. Protocol payload provenance is in OpenAILiveStarterTests.
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveFinalLifecycleTests {
    @Test(arguments: [false, true])
    func S12_1_pendingCountAndBytesFillExactlyBeforeExplicitOverload(_ byteLimit: Bool) async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, options: .init(maximumPendingWrites: byteLimit ? 8 : 2, maximumPendingWriteBytes: byteLimit ? 240 : 1024))
        _ = try await session.start(eventID: "start")
        let active = Task { try await session.appendAudio(Data([0, 1])) }; await peer.waitForHeldWrite()
        let template = #"{"type":"session.instructions.append","event_id":"queued_a","delegation_id":null,"content":""}"#
        let content = String(repeating: "x", count: 120 - template.utf8.count)
        let q1 = Task { try await session.appendInstructions(content, eventID: "queued_a") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 1 }
        let q2 = Task { try await session.appendInstructions(content, eventID: "queued_b") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 2 }
        #expect(session.resourceSnapshot.pendingWriteBytes == 240)
        #expect(peer.sent.count == 2); #expect(peer.activeWrites == 1)
        do { _ = try await session.createResponse(eventID: "overflow"); Issue.record("Full queue must reject excess") }
        catch {
            if byteLimit { guard case .limitExceeded(.pendingWriteBytes)? = error as? OpenAILiveError else { Issue.record("Expected byte overload"); return } }
            else { guard case .limitExceeded(.pendingWrites)? = error as? OpenAILiveError else { Issue.record("Expected message overload"); return } }
        }
        do { try await active.value; Issue.record("Active write must fail") } catch OpenAILiveError.limitExceeded {}
        for queued in [q1, q2] { do { _ = try await queued.value; Issue.record("Queued write must fail") } catch OpenAILiveError.limitExceeded {} }
        #expect(peer.sent.count == 2)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test
    func S11_1_writesCompleteOnlyInAdmissionOrder() async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2, 3, 4]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        let active = Task { try await session.appendAudio(Data([0, 1]), eventID: "audio") }; await peer.waitForHeldWrite()
        let q1 = Task { try await session.createResponse(eventID: "first") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 1 }
        let q2 = Task { try await session.createResponse(eventID: "second") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 2 }
        #expect(peer.sent.count == 2); #expect(peer.activeWrites == 1)
        peer.finishHeldWrite(); try await active.value
        await peer.waitForSentCount(3); #expect(peer.activeWrites == 1)
        try liveExpectJSON(Data(peer.sent[2].utf8), #"{"type":"response.create","event_id":"first"}"#)
        peer.finishHeldWrite(); #expect(try await q1.value == "first")
        await peer.waitForSentCount(4); #expect(peer.activeWrites == 1)
        try liveExpectJSON(Data(peer.sent[3].utf8), #"{"type":"response.create","event_id":"second"}"#)
        peer.finishHeldWrite(); #expect(try await q2.value == "second")
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [false, true])
    func S10_1_S11_3_queuedWorkIsRemovedBeforeEmission(_ closeInstead: Bool) async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        let active = Task { try await session.appendAudio(Data([0, 1])) }; await peer.waitForHeldWrite()
        let queued = Task { try await session.createResponse(eventID: "never_emitted") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 1 }
        let close: Task<OpenAILiveFinalization, Never>?
        if closeInstead {
            close = Task { await session.close() }
            try await liveWaitUntil { session.resourceSnapshot.closeWaiterCount == 1 }
        } else { close = nil; queued.cancel() }
        do { _ = try await queued.value; Issue.record("Removed write must reject") }
        catch {
            if closeInstead { guard case .closed? = error as? OpenAILiveError else { Issue.record("Expected closing rejection"); return } }
            else { #expect(error is CancellationError) }
        }
        #expect(session.resourceSnapshot.pendingWriteCount == 0); #expect(session.resourceSnapshot.pendingWriteBytes == 0)
        #expect(session.finalization == nil); #expect(peer.sent.count == 2)
        peer.finishHeldWrite(); try await active.value
        if let close { #expect(await close.value.isConfirmed); #expect(peer.sent.count == 3) }
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [false, true])
    func S11_2_writeFailureAndDeadlineFailAllCallersWithoutReplay(_ timeout: Bool) async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock, options: .init(writeTimeout: 19))
        _ = try await session.start()
        let active = Task { try await session.appendAudio(Data([0, 1])) }; await peer.waitForHeldWrite()
        let queued = Task { try await session.createResponse() }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 1 }
        if timeout { await clock.waitForDeadline(19); await clock.expire(19) }
        else { peer.finishHeldWrite(failing: true) }
        do { try await active.value; Issue.record("Failed write must propagate") }
        catch {
            if timeout { guard case .timeout(.write)? = error as? OpenAILiveError else { Issue.record("Expected write timeout"); return } }
            else {
                guard case .transport(let transport)? = error as? OpenAILiveError else { Issue.record("Expected transport error"); return }
                #expect(transport.underlyingError is LiveProbeFailure)
                #expect(transport.statusCode == nil); #expect(transport.headers == nil)
                #expect(transport.closeCode == nil); #expect(transport.closeReason == nil)
            }
        }
        do { _ = try await queued.value; Issue.record("Queued caller must fail") } catch {}
        #expect(peer.sent.count == 2); #expect(session.finalization?.isConfirmed == false)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [false, true])
    func S08_5_malformedReadinessCannotSatisfyStartupGate(_ timeout: Bool) async throws {
        let malformed = #"{"type":"session.started","session":{"id":"live_bad","model":"gpt-live-1","status":"active"}}"#
        let peer = LiveProbePeer(); peer.startMessages = [.text(malformed)]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock, options: .init(startupTimeout: 23))
        var events = try session.events().makeAsyncIterator()
        let start = Task { try await session.start() }; await peer.waitForSentCount(1)
        let bad = try #require(try await events.next()); #expect(bad.rawMessage == .text(malformed)); #expect(bad.diagnostic != nil)
        #expect(session.resourceSnapshot.startWaiterCount == 1)
        do { try await session.appendAudio(Data([0, 1])); Issue.record("Malformed readiness must not open command gate") } catch OpenAILiveError.notReady {}
        if timeout {
            await clock.waitForDeadline(23); await clock.expire(23)
            do { _ = try await start.value; Issue.record("Missing valid readiness must time out") } catch OpenAILiveError.timeout(.startup) {}
        } else { peer.emit(.text(LiveProbeFixtures.started)); _ = try await start.value }
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [false, true])
    func S08_5_malformedFinalizationCannotConfirmClose(_ timeout: Bool) async throws {
        let malformed = #"{"type":"session.closed","reason":"close_requested","session":{"id":"live_bad","model":"gpt-live-1","status":"active"},"usage":{"seconds":15.25}}"#
        let peer = LiveProbePeer(); peer.automaticallyClose = false
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock, options: .init(closeTimeout: 7))
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        let close = Task { await session.close() }; await peer.waitForSentCount(2)
        peer.emit(.text(malformed)); let bad = try #require(try await events.next())
        #expect(bad.rawMessage == .text(malformed)); #expect(bad.diagnostic != nil); #expect(session.finalization == nil)
        #expect(session.resourceSnapshot.closeWaiterCount == 1)
        if timeout { await clock.waitForDeadline(7); await clock.expire(7) }
        else { peer.emit(.text(LiveProbeFixtures.closed)) }
        #expect(await close.value.isConfirmed == !timeout)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [false, true])
    func S02_5_cancelledStartupWhileUpgradeOrReadinessWaits(_ heldStartWrite: Bool) async throws {
        let peer = LiveProbePeer(); peer.startMessages = []; peer.holdStartWrite = heldStartWrite
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        let start = Task { try await session.start() }
        if heldStartWrite { await peer.waitForHeldWrite() } else { await peer.waitForReceiveCalls(1) }
        start.cancel()
        do { _ = try await start.value; Issue.record("Cancelled startup must reject") } catch is CancellationError {}
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
        peer.emit(.text(LiveProbeFixtures.started)); peer.finishHeldWrite()
        #expect(session.finalization?.isConfirmed == false); #expect(peer.sent.count <= 1)
        liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: [false, true], [false, true])
    func S10_5_abortOrCancelledCloseKeepsConfirmedResultStable(_ confirmed: Bool, _ useAbort: Bool) async throws {
        let peer = LiveProbePeer(); peer.automaticallyClose = false
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        let close = Task { await session.close() }; await peer.waitForSentCount(2)
        let otherClose = Task { await session.close() }
        try await liveWaitUntil { session.resourceSnapshot.closeWaiterCount == 2 }
        if confirmed { peer.emit(.text(LiveProbeFixtures.closed)); await peer.waitForCancellation() }
        if useAbort { session.abort() } else { close.cancel() }
        let result = await close.value; let shared = await otherClose.value
        #expect(result.isConfirmed == confirmed); #expect(shared.isConfirmed == confirmed)
        if confirmed { #expect(result.usage?.seconds == 15.25); #expect(result.reason == "close_requested") }
        else if useAbort { guard case .aborted? = result.cause as? OpenAILiveError else { Issue.record("Expected abort"); return } }
        else { #expect(result.cause is CancellationError) }
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
        peer.emit(.text(LiveProbeFixtures.closed)); peer.failReceive(URLError(.networkConnectionLost))
        #expect(session.finalization?.isConfirmed == confirmed)
        session.abort(); liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test(arguments: ["event", "failure", "close"])
    func S11_4_twoSessionsKeepIndependentEventsStateAndTransport(_ action: String) async throws {
        let peerA = LiveProbePeer(); let peerB = LiveProbePeer(); let clockA = LiveProbeClock(); let clockB = LiveProbeClock()
        let a = liveProbeSession(peer: peerA, clock: clockA, configuration: .init(model: "gpt-live-1", instructions: "A"))
        let b = liveProbeSession(peer: peerB, clock: clockB, configuration: .init(model: "gpt-live-1", instructions: "B"))
        var ea = try a.events().makeAsyncIterator(); var eb = try b.events().makeAsyncIterator()
        _ = try await a.start(); _ = try await b.start(); _ = try await ea.next(); _ = try await eb.next()
        if action == "event" { peerA.emit(.text(LiveProbeFixtures.output)); #expect(try await ea.next()?.rawMessage == .text(LiveProbeFixtures.output)) }
        else if action == "failure" { peerA.failReceive(URLError(.networkConnectionLost)); await peerA.waitForCancellation() }
        else { #expect(await a.close().isConfirmed) }
        #expect(b.finalization == nil); #expect(peerB.cancelCount == 0); #expect(peerB.sent.count == 1)
        #expect(b.resourceSnapshot.pendingEventCount == 0)
        peerB.emit(.text(#"{"type":"provider.future","source":"B"}"#))
        #expect(try await eb.next()?.rawMessage == .text(#"{"type":"provider.future","source":"B"}"#))
        try await b.appendAudio(Data([9])); #expect(peerB.sent.count == 2)
        a.abort(); b.abort(); await clockA.waitUntilIdle(); await clockB.waitUntilIdle(); await peerA.waitUntilIdle(); await peerB.waitUntilIdle()
        liveExpectEmptyResources(a.resourceSnapshot); liveExpectEmptyResources(b.resourceSnapshot)
    }

    @Test
    func S12_optionsRejectNonfiniteNonpositiveAndUnrepresentableBudgets() throws {
        let invalid: [OpenAILiveSessionOptions] = [
            .init(startupTimeout: 0), .init(startupTimeout: -1), .init(startupTimeout: .infinity), .init(startupTimeout: .nan),
            .init(closeTimeout: 0), .init(closeTimeout: .infinity), .init(writeTimeout: -1), .init(writeTimeout: .nan),
            .init(writeTimeout: Double(UInt64.max) / 1_000_000_000), .init(startupTimeout: Double(UInt.max) + 1024),
            .init(maximumIncomingMessageBytes: 0), .init(maximumPendingEvents: -1), .init(maximumPendingEventBytes: 0),
            .init(maximumPendingWrites: 0), .init(maximumPendingWriteBytes: -1)
        ]
        for options in invalid {
            do { try options.validate(); Issue.record("Invalid transport option must reject") } catch OpenAILiveError.invalidOptions {}
        }
        let architecturalBoundary = OpenAILiveSessionOptions(startupTimeout: 5_000_000_000)
        #if arch(arm64_32) || arch(arm) || arch(i386)
            do { try architecturalBoundary.validate(); Issue.record("Startup request timeout exceeds UInt32") } catch OpenAILiveError.invalidOptions {}
        #else
        try architecturalBoundary.validate()
        #endif
        try OpenAILiveSessionOptions(startupTimeout: 0.001, closeTimeout: 0.001, writeTimeout: 0.001,
            maximumIncomingMessageBytes: 1, maximumPendingEvents: 1, maximumPendingEventBytes: 1, maximumPendingWrites: 1, maximumPendingWriteBytes: 1).validate()
    }

    @Test
    func S12_4_secondIteratorCannotTakeOwnershipByCallingNextFirst() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        let sequence = try session.events()
        var first = sequence.makeAsyncIterator(); var second = sequence.makeAsyncIterator()
        _ = try await session.start()
        do {
            _ = try await second.next()
            Issue.record("Second iterator stole the first iterator's reserved events")
            session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
            return
        } catch OpenAILiveError.subscriberAlreadyExists {}
        #expect(try await first.next()?.rawMessage == .text(LiveProbeFixtures.started))
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }


    @Test
    func S11_3_cancelledQueuedCallerCannotBePromotedBeforeItsCancellationHandlerRuns() async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        let active = Task { try await session.appendAudio(Data([0, 1])) }; await peer.waitForHeldWrite()
        let queued = Task { try await session.createResponse(eventID: "cancel_before_emission") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 1 }
        #expect(peer.sent.count == 2)
        // Both operations occur on this uninterrupted actor turn. The queued caller is cancelled
        // before the resumed writer can run, although the actor-hop cancellation handler may lag it.
        peer.finishHeldWrite()
        queued.cancel()
        try await active.value
        do { _ = try await queued.value; Issue.record("Known-unsent cancelled command returned success") }
        catch is CancellationError {}
        #expect(peer.sent.count == 2, "A command cancelled before transport emission must not be sent")
        #expect(session.finalization == nil, "Cancelling known-unsent work must leave the ready session usable")
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }


    @Test
    func S10_1_closeRejectsSelectedOrdinaryWriteBeforeTransportEmission() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let gate = LiveBeforeEmissionGate()
        let session = OpenAILiveSession(configuration: .init(model: "gpt-live-1"), options: .init(), dependencies: .init(
            makeRequest: { URLRequest(url: URL(string: "wss://example.invalid/v1/live/sessions")!) },
            makeTransport: { _, _ in peer }, sleep: { try await clock.sleep($0) },
            beforeOrdinaryWrite: { await gate.holdFirstWrite() }
        ))
        defer { gate.release(); session.abort() }
        _ = try await session.start()
        let selected = Task { try await session.appendAudio(Data([0, 1]), eventID: "selected_unsent") }
        await gate.entered.wait(); #expect(peer.sent.count == 1)
        let queued = Task { try await session.createResponse(eventID: "queued_unsent") }
        try await liveWaitUntil { session.resourceSnapshot.pendingWriteCount == 1 }
        let close = Task { await session.close() }
        try await liveWaitUntil { session.resourceSnapshot.closeWaiterCount == 1 || session.finalization != nil }
        do { _ = try await queued.value; Issue.record("Close must reject queued work") } catch OpenAILiveError.closed {}
        gate.release()
        do { try await selected.value; Issue.record("Close allowed selected but known-unsent audio to complete") }
        catch OpenAILiveError.closed {}
        #expect(await close.value.isConfirmed)
        #expect(peer.sent.count == 2, "Only startup and close may be emitted")
        if let last = peer.sent.last { try liveExpectJSON(Data(last.utf8), #"{"type":"session.close"}"#) }
        #expect(!peer.sent.contains { $0.contains("selected_unsent") || $0.contains("queued_unsent") })
        await gate.exited.wait(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        session.abort(); liveExpectEmptyResources(session.resourceSnapshot)
    }

    @Test
    func S11_3_cancelSelectedOrdinaryWriteBeforeTransportEmissionKeepsSessionReady() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let gate = LiveBeforeEmissionGate()
        let session = OpenAILiveSession(configuration: .init(model: "gpt-live-1"), options: .init(), dependencies: .init(
            makeRequest: { URLRequest(url: URL(string: "wss://example.invalid/v1/live/sessions")!) },
            makeTransport: { _, _ in peer }, sleep: { try await clock.sleep($0) },
            beforeOrdinaryWrite: { await gate.holdFirstWrite() }
        ))
        defer { gate.release(); session.abort() }
        _ = try await session.start()
        let selected = Task { try await session.appendAudio(Data([0, 1]), eventID: "cancelled_unsent") }
        await gate.entered.wait(); #expect(peer.sent.count == 1)
        selected.cancel()
        do { try await selected.value; Issue.record("Cancelled caller must fail") } catch is CancellationError {}
        #expect(session.finalization == nil, "Known-unsent cancellation must remove the write without aborting the session")
        #expect(peer.cancelCount == 0)
        gate.release(); await gate.exited.wait()
        if session.finalization == nil {
            _ = try await session.createResponse(eventID: "after_cancellation")
            #expect(peer.sent.count == 2)
            try liveExpectJSON(Data(peer.sent[1].utf8), #"{"type":"response.create","event_id":"after_cancellation"}"#)
        }
        #expect(!peer.sent.contains { $0.contains("cancelled_unsent") })
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }


    @Test
    func S04_4_outputRemainsFIFOWhileOrdinaryInputWriteIsHeld() async throws {
        let peer = LiveProbePeer(); peer.holdWriteNumbers = [2]
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock,
            configuration: .init(model: "gpt-live-1", audio: .init(format: .pcm24kHz)))
        var events = try session.events().makeAsyncIterator()
        _ = try await session.start(); _ = try await events.next()
        let input = Task { try await session.appendAudio(Data([0, 0, 255, 127]), eventID: "held_input") }
        await peer.waitForHeldWrite()
        let frames: [(String, Data)] = [
            (#"{"type":"session.output_audio.delta","delta":"AAABAA=="}"#, Data([0, 0, 1, 0])),
            (#"{"type":"session.output_audio.delta","delta":"//8AgA=="}"#, Data([255, 255, 0, 128])),
            (#"{"type":"session.output_audio.delta","delta":"/38AAA=="}"#, Data([255, 127, 0, 0]))
        ]
        for (raw, _) in frames { peer.emit(.text(raw)) }
        for (raw, bytes) in frames {
            let event = try #require(try await events.next())
            #expect(event.rawMessage == .text(raw))
            guard case .outputAudio(let output) = event.payload else { Issue.record("Expected output while input is held"); session.abort(); return }
            #expect(output.audio == bytes)
            #expect(peer.activeWrites == 1); #expect(peer.sent.count == 2)
            #expect(session.finalization == nil)
        }
        peer.finishHeldWrite(); try await input.value
        #expect(await session.close().isConfirmed)
        while try await events.next() != nil {}
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
        liveExpectEmptyResources(session.resourceSnapshot)
    }

}


/// A test-owned pause before any ordinary bytes reach the transport; it holds only the first write.
@AIProxyActor
private final class LiveBeforeEmissionGate {
    let entered = LiveProbeSignal(); let exited = LiveProbeSignal()
    private var hasEntered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdFirstWrite() async {
        guard !hasEntered else { return }
        hasEntered = true; entered.signal()
        defer { exited.signal() }
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        let waiting = continuation; continuation = nil; waiting?.resume()
    }
}
