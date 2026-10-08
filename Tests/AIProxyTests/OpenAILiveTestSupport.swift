import Foundation
import Testing
@testable import AIProxy

// Independent official-schema fixtures. Source and hash are recorded in OpenAILiveStarterTests.
nonisolated enum LiveProbeFixtures {
    static let started = #"{"type":"session.started","event_id":"started_probe","session":{"id":"live_probe","expires_at":1788555600,"model":"gpt-live-1","status":"active"}}"#
    static let output = #"{"type":"session.output_audio.delta","delta":"AAEC"}"#
    static let closed = #"{"type":"session.closed","event_id":"closed_probe","reason":"close_requested","session":{"id":"live_probe","expires_at":1788555600,"model":"gpt-live-1","status":"active"},"usage":{"seconds":15.25}}"#
}

nonisolated func liveExpectJSON(_ actual: Data, _ expected: String) throws {
    let actualObject = try JSONSerialization.jsonObject(with: actual) as! NSDictionary
    let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as! NSDictionary
    #expect(actualObject == expectedObject)
}

@AIProxyActor
func liveProbeSession(
    peer: LiveProbePeer,
    clock: LiveProbeClock,
    configuration: OpenAILiveSessionConfiguration = .init(model: "gpt-live-1"),
    options: OpenAILiveSessionOptions = .init()
) -> OpenAILiveSession {
    OpenAILiveSession(configuration: configuration, options: options, dependencies: .init(
        makeRequest: { URLRequest(url: URL(string: "wss://example.invalid/v1/live/sessions")!) },
        makeTransport: { _, _ in peer },
        sleep: { seconds in try await clock.sleep(seconds) }
    ))
}

nonisolated enum LiveProbeFailure: Error { case rejectedWrite }

/// Test-owned barriers expose transport outcomes; they do not dictate SDK helper ordering.
@AIProxyActor
final class LiveProbePeer: OpenAILiveTransport {
    var startMessages: [OpenAILiveRawMessage] = [.text(LiveProbeFixtures.started)]
    var holdStartWrite = false
    var holdWriteNumbers: Set<Int> = []
    var automaticallyClose = true
    private(set) var receiveCalls = 0
    private var receiveCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var incomingFailure: (any Error)?
    private(set) var sent: [String] = []
    private(set) var cancelCount = 0
    private(set) var activeReceivers = 0
    private(set) var activeWrites = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var incoming: [OpenAILiveRawMessage] = []
    private var receiver: CheckedContinuation<OpenAILiveRawMessage, any Error>?
    private var heldWrite: CheckedContinuation<Void, any Error>?
    private var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    var response: HTTPURLResponse? { nil }

    func resume() {}

    func send(_ text: String) async throws {
        activeWrites += 1
        defer { activeWrites -= 1; settleIdle() }
        sent.append(text)
        let waiting = sentWaiters
        sentWaiters.removeAll()
        for (count, waiter) in waiting {
            if sent.count >= count { waiter.resume() }
            else { sentWaiters.append((count, waiter)) }
        }
        let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        if body["type"] as? String == "session.start" {
            for message in startMessages { emit(message) }
            if holdStartWrite || holdWriteNumbers.contains(sent.count) {
                try await withCheckedThrowingContinuation { continuation in
                    heldWrite = continuation
                    let waiting = heldWaiters
                    heldWaiters.removeAll()
                    for waiter in waiting { waiter.resume() }
                }
            }
        } else {
            if body["type"] as? String == "session.close", automaticallyClose {
                emit(.text(LiveProbeFixtures.closed))
            }
            if holdWriteNumbers.contains(sent.count) {
                try await withCheckedThrowingContinuation { continuation in
                    heldWrite = continuation
                    let waiting = heldWaiters
                    heldWaiters.removeAll()
                    for waiter in waiting { waiter.resume() }
                }
            }
        }
    }

    func receive() async throws -> OpenAILiveRawMessage {
        receiveCalls += 1
        let waitingCalls = receiveCallWaiters
        receiveCallWaiters.removeAll()
        for (count, waiter) in waitingCalls {
            if receiveCalls >= count { waiter.resume() }
            else { receiveCallWaiters.append((count, waiter)) }
        }
        activeReceivers += 1
        defer { activeReceivers -= 1; settleIdle() }
        if cancelCount > 0 { throw CancellationError() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        if let incomingFailure { throw incomingFailure }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(receiver == nil)
            receiver = continuation
        }
    }

    func emit(_ message: OpenAILiveRawMessage) {
        if let waiting = receiver {
            receiver = nil
            waiting.resume(returning: message)
        } else {
            incoming.append(message)
        }
    }

    func failReceive(_ error: any Error) {
        if let waiting = receiver {
            receiver = nil
            waiting.resume(throwing: error)
        } else { incomingFailure = error }
    }

    func waitForReceiveCalls(_ count: Int) async {
        if receiveCalls >= count { return }
        await withCheckedContinuation { receiveCallWaiters.append((count, $0)) }
    }

    func waitForHeldWrite() async { await waitForHeldStartWrite() }
    func finishHeldWrite(failing: Bool = false) { finishStartWrite(failing: failing) }

    func cancel() {
        cancelCount += 1
        incoming.removeAll()
        let waiting = receiver
        receiver = nil
        waiting?.resume(throwing: CancellationError())
        let writing = heldWrite
        heldWrite = nil
        writing?.resume(throwing: CancellationError())
        let cancelled = cancelWaiters
        cancelWaiters.removeAll()
        for waiter in cancelled { waiter.resume() }
    }

    func waitForSentCount(_ count: Int) async {
        if sent.count >= count { return }
        await withCheckedContinuation { sentWaiters.append((count, $0)) }
    }

    func waitForHeldStartWrite() async {
        if heldWrite != nil { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func finishStartWrite(failing: Bool) {
        let writing = heldWrite
        heldWrite = nil
        if failing { writing?.resume(throwing: LiveProbeFailure.rejectedWrite) }
        else { writing?.resume() }
    }

    func waitUntilIdle() async {
        if activeReceivers == 0 && activeWrites == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func settleIdle() {
        guard activeReceivers == 0 && activeWrites == 0 else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func waitForCancellation() async {
        if cancelCount > 0 { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
}

/// Manually releases deadlines. A wall-clock delay never establishes a test outcome.
actor LiveProbeClock {
    private struct Sleep {
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var pending: [UUID: Sleep] = [:]
    private(set) var activeSleeps = 0
    private var registrationWaiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        activeSleeps += 1
        defer { activeSleeps -= 1; settleIdle() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Sleep(seconds: seconds, continuation: continuation)
                let waiting = registrationWaiters
                registrationWaiters.removeAll()
                for (duration, waiter) in waiting {
                    if pending.values.contains(where: { $0.seconds == duration }) { waiter.resume() }
                    else { registrationWaiters.append((duration, waiter)) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForDeadline(_ seconds: TimeInterval) async {
        if pending.values.contains(where: { $0.seconds == seconds }) { return }
        await withCheckedContinuation { registrationWaiters.append((seconds, $0)) }
    }

    func expire(_ seconds: TimeInterval) {
        let selected = pending.filter { $0.value.seconds == seconds }
        precondition(!selected.isEmpty, "Deadline must be registered before advancing time")
        for (id, sleep) in selected {
            pending.removeValue(forKey: id)
            sleep.continuation.resume()
        }
        settleIdle()
    }

    func waitUntilIdle() async {
        if pending.isEmpty && activeSleeps == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        settleIdle()
    }

    private func settleIdle() {
        guard pending.isEmpty && activeSleeps == 0 else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

@AIProxyActor
final class LiveProbeSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// A bounded scheduling watchdog, never a wall-clock correctness oracle.
@AIProxyActor
func liveWaitUntil(_ predicate: @AIProxyActor () -> Bool) async throws {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    try #require(predicate(), "Expected actor-observable transition did not occur")
}

@AIProxyActor
func liveExpectEmptyResources(_ snapshot: OpenAILiveSession.ResourceSnapshot) {
    #expect(snapshot.pendingWriteCount == 0)
    #expect(snapshot.pendingWriteBytes == 0)
    #expect(!snapshot.hasActiveWrite)
    #expect(snapshot.pendingEventCount == 0)
    #expect(snapshot.pendingEventBytes == 0)
    #expect(snapshot.terminalRecordBytes == 0)
    #expect(snapshot.eventWaiterCount == 0)
    #expect(snapshot.startWaiterCount == 0)
    #expect(snapshot.closeWaiterCount == 0)
}
