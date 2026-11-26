import Foundation
import Dispatch

/// A single Live primary WebSocket. Start explicitly, consume one event sequence, then close or abort.
/// The session owns transport only; capture, playback and audio-session activation belong to the caller.
@available(watchOS 10.5, *)
@AIProxyActor public final class OpenAILiveSession {
    private enum State { case idle, starting, ready, closing, terminal }
    private enum WriteKind { case start, ordinary, close }
    private struct Write {
        let id: UUID
        let kind: WriteKind
        let text: String
        let continuation: CheckedContinuation<Void, any Error>?
        let emissionPermit: OpenAILiveOneShotPermit?
    }

    private let configuration: OpenAILiveSessionConfiguration
    private let options: OpenAILiveSessionOptions
    private let dependencies: OpenAILiveDependencies
    private var state = State.idle
    private var transport: (any OpenAILiveTransport)?
    private var requestTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var startupTimer: Task<Void, Never>?
    private var closeTimer: Task<Void, Never>?
    private var writeTimer: Task<Void, Never>?
    private var startupWaiter: CheckedContinuation<OpenAILiveSessionResource, any Error>?
    private var closeWaiters: [CheckedContinuation<OpenAILiveFinalization, Never>] = []
    private var startEventID: String?
    private var startWriteCompleted = false
    private var readyResource: OpenAILiveSessionResource?
    private var activeWrite: Write?
    private var activeWriteIsEmitting = false
    private var pendingWrites: [Write] = []
    private var pendingWriteBytes = 0
    private var closeEnqueued = false
    private var pendingEvents: [OpenAILiveEvent] = []
    private var pendingEventBytes = 0
    private var terminalEvent: OpenAILiveEvent?
    private var streamError: (any Error)?
    private var streamErrorDelivered = false
    private var subscribed = false
    private var iteratorID: UUID?
    private var eventWaiter: CheckedContinuation<OpenAILiveEvent?, any Error>?

    public private(set) var finalization: OpenAILiveFinalization?
    public private(set) var latestUsage: OpenAILiveUsage?

    /// Bounded storage/continuation evidence only. Task-handle state does not establish worker exit.
    nonisolated struct ResourceSnapshot: Sendable {
        let pendingWriteCount: Int
        let pendingWriteBytes: Int
        let hasActiveWrite: Bool
        let pendingEventCount: Int
        let pendingEventBytes: Int
        let terminalRecordBytes: Int
        let eventWaiterCount: Int
        let startWaiterCount: Int
        let closeWaiterCount: Int
    }

    var resourceSnapshot: ResourceSnapshot {
        .init(pendingWriteCount: pendingWrites.count, pendingWriteBytes: pendingWriteBytes,
              hasActiveWrite: activeWrite != nil, pendingEventCount: pendingEvents.count,
              pendingEventBytes: pendingEventBytes, terminalRecordBytes: terminalEvent?.rawMessage.byteCount ?? 0,
              eventWaiterCount: eventWaiter == nil ? 0 : 1, startWaiterCount: startupWaiter == nil ? 0 : 1,
              closeWaiterCount: closeWaiters.count)
    }

    init(configuration: OpenAILiveSessionConfiguration, options: OpenAILiveSessionOptions,
         dependencies: OpenAILiveDependencies) {
        self.configuration = configuration
        self.options = options
        self.dependencies = dependencies
    }

    deinit {
        let connection = transport
        Task { @AIProxyActor in connection?.cancel() }
        requestTask?.cancel()
        receiverTask?.cancel()
        writerTask?.cancel()
        startupTimer?.cancel()
        closeTimer?.cancel()
        writeTimer?.cancel()
    }

    /// Returns only after the start write succeeds and a valid `session.started` is received.
    /// The deadline includes authentication/request construction and the WebSocket upgrade.
    /// Task cancellation throws the standard `CancellationError`.
    public func start(eventID: String? = nil) async throws -> OpenAILiveSessionResource {
        try Task.checkCancellation()
        try options.validate()
        guard state == .idle else { throw OpenAILiveError.alreadyStarted }
        let eventID = eventID ?? UUID().uuidString
        let text = try encode(["type": "session.start", "event_id": .string(eventID),
                               "session": .object(configuration.json)])
        state = .starting
        startEventID = eventID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startupWaiter = continuation
                startupTimer = deadline(options.startupTimeout, phase: .startup)
                let makeRequest = dependencies.makeRequest
                requestTask = Task { [weak self] in
                    do {
                        let request = try await makeRequest()
                        try Task.checkCancellation()
                        self?.open(request: request, startText: text)
                    } catch {
                        self?.fail(error)
                    }
                }
            }
        } onCancel: {
            Task { @AIProxyActor [weak self] in self?.cancelSession() }
        }
    }

    /// Reserves the sole subscriber. Consume it during the session; this is not a replay API.
    /// A second iterator fails when it first calls `next()` instead of replacing the receiver.
    /// If iteration is stopped early while retaining the session, explicitly close or abort it.
    public func events() throws -> OpenAILiveEventSequence {
        guard !subscribed else { throw OpenAILiveError.subscriberAlreadyExists }
        subscribed = true
        return OpenAILiveEventSequence(session: self)
    }

    /// Sends bytes unchanged in the startup-selected format. PCM callers must supply complete
    /// 16-bit samples. Empty or odd-sized chunks are not repaired, rejected or converted here.
    /// Completion means the socket write succeeded, not provider acceptance or playback.
    public func appendAudio(_ bytes: Data, eventID: String? = nil) async throws {
        var fields: [String: AIProxyJSONValue] = ["type": "session.input_audio.append",
                                                 "audio": .string(bytes.base64EncodedString())]
        if let eventID { fields["event_id"] = .string(eventID) }
        try await send(fields)
    }

    /// Sends input mute. Acceptance is exposed by `inputMuted`; output delivery continues.
    @discardableResult
    public func muteInput(eventID: String? = nil) async throws -> String {
        try await sendCommand("session.input_audio.mute", eventID: eventID)
    }

    /// Sends input unmute. Acceptance is exposed by `inputUnmuted`.
    @discardableResult
    public func unmuteInput(eventID: String? = nil) async throws -> String {
        try await sendCommand("session.input_audio.unmute", eventID: eventID)
    }

    /// Appends plain instruction text. The provider enforces the 500-token limit.
    /// A nil delegation ID is encoded as explicit null for general session context.
    /// Write completion is not a context-delivery or playback acknowledgment.
    @discardableResult
    public func appendInstructions(_ content: String, delegationID: String? = nil,
                                   eventID: String? = nil) async throws -> String {
        try await appendContext("session.instructions.append", content: content,
                                delegationID: delegationID, eventID: eventID)
    }

    /// Appends plain thinking context (up to 500 provider-counted tokens).
    /// This context may influence later speech; it is not a secrecy boundary.
    @discardableResult
    public func appendThinking(_ content: String, delegationID: String? = nil,
                               eventID: String? = nil) async throws -> String {
        try await appendContext("session.thinking.append", content: content,
                                delegationID: delegationID, eventID: eventID)
    }

    /// Appends plain commentary context (up to 500 provider-counted tokens).
    /// The provider may paraphrase it; write success does not establish speech or playback.
    @discardableResult
    public func appendCommentary(_ content: String, delegationID: String? = nil,
                                 eventID: String? = nil) async throws -> String {
        try await appendContext("session.commentary.append", content: content,
                                delegationID: delegationID, eventID: eventID)
    }

    /// Sends sparse delegation settings. The resolved configuration arrives in `updated`.
    @discardableResult
    public func updateSession(_ update: OpenAILiveSessionUpdate,
                              eventID: String? = nil) async throws -> String {
        try await sendCommand("session.update", fields: ["session": .object(update.json)], eventID: eventID)
    }

    /// Adds the caller's item to a Responses backend. This has no separate success acknowledgment
    /// and does not execute tools or automatically request a continuation.
    @discardableResult
    public func createResponseItem(_ item: [String: AIProxyJSONValue],
                                   eventID: String? = nil) async throws -> String {
        try await sendCommand("response.item.create", fields: ["item": .object(item)], eventID: eventID)
    }

    /// Explicitly runs or continues the Responses backend using its session configuration.
    /// This command has no standalone Responses request body.
    @discardableResult
    public func createResponse(eventID: String? = nil) async throws -> String {
        try await sendCommand("response.create", eventID: eventID)
    }

    private func appendContext(_ type: String, content: String, delegationID: String?,
                               eventID: String?) async throws -> String {
        try await sendCommand(type, fields: ["content": .string(content),
                                            "delegation_id": delegationID.map { .string($0) } ?? nil],
                              eventID: eventID)
    }

    private func sendCommand(_ type: String, fields: [String: AIProxyJSONValue] = [:],
                             eventID: String?) async throws -> String {
        let id = eventID ?? UUID().uuidString
        var fields = fields
        fields["type"] = .string(type)
        fields["event_id"] = .string(id)
        try await send(fields)
        return id
    }

    /// Rejects new and queued work, finishes an already-emitting write, then requests finalization.
    /// Repeated calls await the same result. Cancellation aborts any unconfirmed session.
    public func close() async -> OpenAILiveFinalization {
        if let finalization { return finalization }
        if Task.isCancelled { cancelSession(); return finalization! }
        if state == .idle || state == .starting {
            fail(CancellationError(), discardEvents: true)
            return finalization!
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
                if state != .closing {
                    state = .closing
                    rejectQueuedWrites(with: OpenAILiveError.closed)
                    closeTimer = deadline(options.closeTimeout, phase: .close)
                    if !activeWriteIsEmitting {
                        let selected = activeWrite
                        activeWrite = nil
                        selected?.continuation?.resume(throwing: OpenAILiveError.closed)
                        enqueueClose()
                    }
                }
            }
        } onCancel: {
            Task { @AIProxyActor [weak self] in self?.cancelSession() }
        }
    }

    /// Stops transport work and discards unconsumed events. Confirmed finalization stays confirmed.
    public func abort() {
        discardEvents()
        if finalization == nil { fail(OpenAILiveError.aborted, discardEvents: true) }
        else { settleEventWaiter() }
    }

    private func cancelSession() {
        discardEvents()
        if finalization == nil { fail(CancellationError(), discardEvents: true) }
        else { settleEventWaiter() }
    }

    private func open(request: URLRequest, startText: String) {
        guard state == .starting else { return }
        requestTask = nil
        let connection = dependencies.makeTransport(request, options.maximumIncomingMessageBytes)
        transport = connection
        connection.resume()
        // Install receive ownership before any application write can finish.
        receiverTask = Task { [weak self, connection] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    guard !Task.isCancelled else { return }
                    self?.received(message)
                    if self == nil { connection.cancel(); return }
                }
            } catch {
                self?.transportFailed(error)
            }
        }
        do {
            try admit(Write(id: UUID(), kind: .start, text: startText, continuation: nil, emissionPermit: nil))
        } catch {
            fail(error)
        }
    }

    private func send(_ fields: [String: AIProxyJSONValue]) async throws {
        try Task.checkCancellation()
        guard state == .ready else {
            throw state == .idle || state == .starting ? OpenAILiveError.notReady : .closed
        }
        let text = try encode(fields)
        let id = UUID()
        let emissionPermit = OpenAILiveOneShotPermit()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    try admit(Write(id: id, kind: .ordinary, text: text, continuation: continuation,
                                    emissionPermit: emissionPermit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Record cancellation before the actor-hop cleanup can be delayed by the writer.
            _ = emissionPermit.claim()
            Task { @AIProxyActor [weak self] in self?.cancelWrite(id) }
        }
    }

    private func admit(_ write: Write) throws {
        let size = write.text.utf8.count
        guard size <= options.maximumPendingWriteBytes else {
            let error = OpenAILiveError.limitExceeded(.pendingWriteBytes)
            fail(error)
            throw error
        }
        if activeWrite == nil {
            activeWrite = write
            startWriter()
            return
        }
        guard pendingWrites.count < options.maximumPendingWrites else {
            let error = OpenAILiveError.limitExceeded(.pendingWrites)
            fail(error)
            throw error
        }
        guard size <= options.maximumPendingWriteBytes - pendingWriteBytes else {
            let error = OpenAILiveError.limitExceeded(.pendingWriteBytes)
            fail(error)
            throw error
        }
        pendingWrites.append(write)
        pendingWriteBytes += size
    }

    private func startWriter() {
        guard writerTask == nil, let connection = transport else { return }
        writerTask = Task { [weak self, connection] in
            while let write = self?.activeWrite, !Task.isCancelled {
                if write.kind == .ordinary, let beforeOrdinaryWrite = self?.dependencies.beforeOrdinaryWrite {
                    await beforeOrdinaryWrite()
                }
                guard !Task.isCancelled, self?.beginWriteEmission(write.id) == true else { continue }
                do {
                    try await connection.send(write.text)
                    self?.writeCompleted(write.id)
                } catch {
                    self?.transportFailed(error)
                    return
                }
            }
            self?.writerTask = nil
        }
    }

    private func beginWriteEmission(_ id: UUID) -> Bool {
        guard finalization == nil, let write = activeWrite, write.id == id else { return false }
        if write.kind == .ordinary {
            guard state == .ready else {
                activeWrite = nil
                write.continuation?.resume(throwing: OpenAILiveError.closed)
                advanceWrite()
                return false
            }
            guard write.emissionPermit?.claim() == true else {
                cancelWrite(id)
                return false
            }
        }
        // No suspension occurs between this transition and the transport.send invocation.
        activeWriteIsEmitting = true
        writeTimer = deadline(options.writeTimeout, phase: .write)
        return true
    }

    private func writeCompleted(_ id: UUID) {
        guard finalization == nil, let write = activeWrite, write.id == id else { return }
        writeTimer?.cancel()
        writeTimer = nil
        activeWrite = nil
        activeWriteIsEmitting = false
        write.continuation?.resume()
        if write.kind == .start {
            startWriteCompleted = true
            completeReadinessIfPossible()
        }
        advanceWrite()
    }

    private func advanceWrite() {
        if state == .closing {
            enqueueClose()
        } else if !pendingWrites.isEmpty {
            activeWrite = pendingWrites.removeFirst()
            pendingWriteBytes -= activeWrite!.text.utf8.count
        }
    }

    private func enqueueClose() {
        guard !closeEnqueued, finalization == nil else { return }
        closeEnqueued = true
        do {
            let text = try encode(["type": "session.close"])
            try admit(Write(id: UUID(), kind: .close, text: text, continuation: nil, emissionPermit: nil))
        } catch { fail(error) }
    }

    private func cancelWrite(_ id: UUID) {
        guard finalization == nil else { return }
        if let write = activeWrite, write.id == id {
            if activeWriteIsEmitting {
                // The transport may have accepted bytes: terminate without retrying uncertain delivery.
                cancelSession()
            } else {
                activeWrite = nil
                write.continuation?.resume(throwing: CancellationError())
                advanceWrite()
            }
        } else if let index = pendingWrites.firstIndex(where: { $0.id == id }) {
            let write = pendingWrites.remove(at: index)
            pendingWriteBytes -= write.text.utf8.count
            write.continuation?.resume(throwing: CancellationError())
        }
    }

    private func received(_ message: OpenAILiveRawMessage) {
        guard finalization == nil else { return }
        guard message.byteCount <= options.maximumIncomingMessageBytes else {
            fail(OpenAILiveError.limitExceeded(.incomingMessage))
            return
        }
        let event = OpenAILiveEvent.decode(message)
        if case .closed(let closed) = event.payload {
            terminalEvent = event
            latestUsage = closed.usage
            finish(.init(isConfirmed: true, session: closed.session, reason: closed.reason,
                         usage: closed.usage, cause: nil), error: nil)
            return
        }
        guard appendEvent(event) else { return }
        switch event.payload {
        case .started(let started) where state == .starting:
            readyResource = started.session
            completeReadinessIfPossible()
        case .usage(let update): latestUsage = update.usage
        case .error(let event) where state == .starting:
            if event.error.clientEventID == startEventID || event.clientEventID == startEventID {
                fail(OpenAILiveError.provider(event.error))
            }
        default: break
        }
    }

    private func completeReadinessIfPossible() {
        guard state == .starting, startWriteCompleted, let readyResource else { return }
        state = .ready
        startupTimer?.cancel()
        startupTimer = nil
        let waiter = startupWaiter
        startupWaiter = nil
        waiter?.resume(returning: readyResource)
    }

    private func appendEvent(_ event: OpenAILiveEvent) -> Bool {
        if let waiter = eventWaiter {
            eventWaiter = nil
            waiter.resume(returning: event)
            return true
        }
        guard pendingEvents.count < options.maximumPendingEvents else {
            fail(OpenAILiveError.limitExceeded(.pendingEvents))
            return false
        }
        let size = event.rawMessage.byteCount
        guard size <= options.maximumPendingEventBytes - pendingEventBytes else {
            fail(OpenAILiveError.limitExceeded(.pendingEventBytes))
            return false
        }
        pendingEvents.append(event)
        pendingEventBytes += size
        return true
    }

    fileprivate func nextEvent(iteratorID requestedID: UUID) async throws -> OpenAILiveEvent? {
        if let iteratorID, iteratorID != requestedID { throw OpenAILiveError.subscriberAlreadyExists }
        iteratorID = requestedID
        if Task.isCancelled { cancelSession(); throw CancellationError() }
        guard eventWaiter == nil else { throw OpenAILiveError.concurrentReceive }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                eventWaiter = continuation
                settleEventWaiter()
            }
        } onCancel: {
            Task { @AIProxyActor [weak self] in self?.cancelSession() }
        }
    }

    private func settleEventWaiter() {
        guard let waiter = eventWaiter else { return }
        if !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            pendingEventBytes -= event.rawMessage.byteCount
            eventWaiter = nil
            waiter.resume(returning: event)
        } else if let event = terminalEvent {
            terminalEvent = nil
            eventWaiter = nil
            waiter.resume(returning: event)
        } else if finalization != nil {
            eventWaiter = nil
            if let streamError, !streamErrorDelivered {
                streamErrorDelivered = true
                waiter.resume(throwing: streamError)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    private func deadline(_ seconds: TimeInterval, phase: OpenAILiveError.Phase) -> Task<Void, Never> {
        let sleep = dependencies.sleep
        return Task { [weak self] in
            do {
                try await sleep(seconds)
                try Task.checkCancellation()
                self?.fail(OpenAILiveError.timeout(phase))
            } catch is CancellationError {
                // Cancellation ends a deadline that no longer owns a lifecycle transition.
            } catch {
                self?.fail(error)
            }
        }
    }

    private func transportFailed(_ error: any Error) {
        guard finalization == nil else { return }
        if case OpenAILiveError.limitExceeded(.incomingMessage) = error {
            fail(error)
            return
        }
        fail(OpenAILiveError.transport(.init(underlyingError: error, response: transport?.response,
                                               closeCode: transport?.closeCode, closeReason: transport?.closeReason)))
    }

    private func fail(_ error: any Error, discardEvents: Bool = false) {
        guard finalization == nil else { return }
        if discardEvents { self.discardEvents() }
        finish(.init(isConfirmed: false, session: readyResource, reason: nil,
                     usage: latestUsage, cause: error), error: error)
    }

    private func finish(_ result: OpenAILiveFinalization, error: (any Error)?) {
        guard finalization == nil else { return }
        finalization = result
        state = .terminal
        streamError = error
        transport?.cancel()
        transport = nil
        requestTask?.cancel(); requestTask = nil
        receiverTask?.cancel(); receiverTask = nil
        writerTask?.cancel(); writerTask = nil
        startupTimer?.cancel(); startupTimer = nil
        closeTimer?.cancel(); closeTimer = nil
        writeTimer?.cancel(); writeTimer = nil
        let pendingError = error ?? OpenAILiveError.closed
        let startWaiter = startupWaiter
        startupWaiter = nil
        startWaiter?.resume(throwing: pendingError)
        let writing = activeWrite
        activeWrite = nil
        activeWriteIsEmitting = false
        writing?.continuation?.resume(throwing: pendingError)
        rejectQueuedWrites(with: pendingError)
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        settleEventWaiter()
    }

    private func rejectQueuedWrites(with error: any Error) {
        let rejected = pendingWrites
        pendingWrites.removeAll()
        pendingWriteBytes = 0
        for write in rejected { write.continuation?.resume(throwing: error) }
    }

    private func discardEvents() {
        pendingEvents.removeAll()
        pendingEventBytes = 0
        terminalEvent = nil
    }

    private func encode(_ fields: [String: AIProxyJSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }
}

/// A single-consumer bounded sequence. Cancelling a pending receive aborts its session.
@available(watchOS 10.5, *)
nonisolated public struct OpenAILiveEventSequence: AsyncSequence, Sendable {
    public typealias Element = OpenAILiveEvent
    private let session: OpenAILiveSession
    private let iteratorPermit = OpenAILiveOneShotPermit()

    fileprivate init(session: OpenAILiveSession) { self.session = session }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(session: session, ownsSubscription: iteratorPermit.claim())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let session: OpenAILiveSession
        private let id = UUID()
        private let ownsSubscription: Bool
        fileprivate init(session: OpenAILiveSession, ownsSubscription: Bool) {
            self.session = session
            self.ownsSubscription = ownsSubscription
        }
        public mutating func next() async throws -> OpenAILiveEvent? {
            guard ownsSubscription else { throw OpenAILiveError.subscriberAlreadyExists }
            return try await session.nextEvent(iteratorID: id)
        }
    }
}

/// A synchronous, nonblocking one-shot claim for iterator ownership or write emission.
/// Dispatch owns all synchronized state; no task waits for a permit to become available.
nonisolated private final class OpenAILiveOneShotPermit: Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func claim() -> Bool { semaphore.wait(timeout: .now()) == .success }

    // Balance a successful claim before libdispatch disposes of the semaphore.
    deinit { semaphore.signal() }
}
