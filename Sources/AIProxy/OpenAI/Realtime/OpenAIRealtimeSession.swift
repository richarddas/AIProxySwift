//
//  RealtimeSession.swift
//
//
//  Created by Lou Zell on 11/28/24.
//

import AVFoundation
import Foundation
import Network

/// How inbound WebSocket frames should be handled before JSON decoding.
package enum OpenAIRealtimeWebSocketFrameDisposition: Sendable, Equatable {
    case decodeTextPayload
    case ignoreControlFrame
    case closeConnection
}

package func openAIRealtimeWebSocketFrameDisposition(
    content: Data?,
    contentContext: NWConnection.ContentContext?
) -> OpenAIRealtimeWebSocketFrameDisposition {
    guard let metadata = contentContext?
        .protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
    else {
        return .decodeTextPayload
    }

    switch metadata.opcode {
    case .ping, .pong:
        return .ignoreControlFrame
    case .close:
        return .closeConnection
    case .binary:
        // Realtime events are JSON text frames; binary payloads are not API events.
        return .ignoreControlFrame
    case .cont, .text:
        return .decodeTextPayload
    @unknown default:
        return .decodeTextPayload
    }
}

/// An internal transport seam for deterministic session lifecycle failures.
@AIProxyActor struct OpenAIRealtimeTestTransport: Sendable {
    let send: @AIProxyActor @Sendable (URLSessionWebSocketTask.Message) async throws -> Void
    let receive: @AIProxyActor @Sendable (@escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) -> Void
    let resume: @AIProxyActor @Sendable () -> Void
    let cancel: @AIProxyActor @Sendable () -> Void
    let closeCode: @AIProxyActor @Sendable () -> URLSessionWebSocketTask.CloseCode
    let closeReason: @AIProxyActor @Sendable () -> Data?
}

@AIProxyActor open class OpenAIRealtimeSession {
    private enum TerminalState: Sendable {
        case finished
        case failed(Error)
    }

    private let connection: NWConnection?
    private let testTransport: OpenAIRealtimeTestTransport?
    private var terminalState: TerminalState?
    private var hasStarted = false
    private var initialUpdateStarted = false
    private var receiveInFlight = false
    private let setupTimeoutNanoseconds: UInt64?
    private var setupTimeoutTask: Task<Void, Never>?
    private let receiverStream: AsyncThrowingStream<OpenAIRealtimeMessage, Error>
    private let continuation: AsyncThrowingStream<OpenAIRealtimeMessage, Error>.Continuation
    let sessionConfiguration: OpenAIRealtimeSessionConfiguration
    private let initialSessionUpdate: OpenAIRealtimeSessionUpdate

    init(
        connection: NWConnection,
        sessionConfiguration: OpenAIRealtimeSessionConfiguration,
        setupTimeout: TimeInterval = 60
    ) {
        let (receiver, continuation) = AsyncThrowingStream<OpenAIRealtimeMessage, Error>.makeStream()
        self.receiverStream = receiver
        self.continuation = continuation
        self.connection = connection
        // URLRequest timeouts are finite in production. Cap conversion at the
        // largest whole-second interval representable by Task.sleep.
        let timeout = setupTimeout.isFinite ? max(0, setupTimeout) : 60
        let capped = min(timeout, TimeInterval(UInt64.max / 1_000_000_000))
        self.setupTimeoutNanoseconds = UInt64(capped * 1_000_000_000)
        self.testTransport = nil
        self.sessionConfiguration = sessionConfiguration
        self.initialSessionUpdate = OpenAIRealtimeSessionUpdate(session: sessionConfiguration)
    }

    init(
        testTransport: OpenAIRealtimeTestTransport,
        sessionConfiguration: OpenAIRealtimeSessionConfiguration
    ) {
        let (receiver, continuation) = AsyncThrowingStream<OpenAIRealtimeMessage, Error>.makeStream()
        self.receiverStream = receiver
        self.continuation = continuation
        self.connection = nil
        self.setupTimeoutNanoseconds = nil
        self.testTransport = testTransport
        self.sessionConfiguration = sessionConfiguration
        self.initialSessionUpdate = OpenAIRealtimeSessionUpdate(session: sessionConfiguration)
        self.start()
    }

    /// Must be called after init to begin the WebSocket connection.
    /// Separated from init because Swift 6 makes global-actor inits nonisolated,
    /// so calling actor-isolated methods from init triggers a runtime executor check.
    func start() {
        guard terminalState == nil, !hasStarted else { return }
        self.hasStarted = true
        self.continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { @AIProxyActor [weak self] in self?.disconnect() }
            }
        }
        if let testTransport {
            testTransport.resume()
            self.scheduleReceiveIfNeeded()
            self.sendInitialSessionUpdate()
            return
        }
        logIf(.info)?.info("AIProxy realtime session starting NWConnection")
        self.setupConnectionHandlers()
        self.startSetupDeadline()
        self.connection?.start(queue: .global(qos: .userInitiated))
    }

    deinit {
        setupTimeoutTask?.cancel()
        continuation.finish()
        if terminalState == nil {
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            if let testTransport {
                Task { @AIProxyActor in testTransport.cancel() }
            }
        }
        logIf(.debug)?.debug("OpenAIRealtimeSession is being freed")
    }

    /// Server events for one receiving task. Provider error events remain message data.
    /// Transport and decoding failures terminate the stream with their cause.
    /// The stream buffers events without a fixed limit until consumed. Start consuming promptly.
    /// Cancelling while awaiting the next event closes the session.
    /// Use `defer { session.disconnect() }` in the receiving task so cancellation
    /// during event handling and early exits also close the session.
    public var receiver: AsyncThrowingStream<OpenAIRealtimeMessage, Error> {
        receiverStream
    }

    /// Completes when serialization and the transport send succeed, without implying
    /// provider acknowledgement. Serialization and send failures are thrown unchanged.
    public func sendMessage(_ encodable: Encodable) async throws {
        guard terminalState == nil else { throw OpenAIRealtimeSessionError.disconnected }
        do {
            let message = URLSessionWebSocketTask.Message.string(try encodable.serialize())
            try await self.sendOperation(message)
        } catch {
            let code = (error as NSError).code
            logIf(.error)?.error("Realtime send failed (code: \(code, privacy: .public)): \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Closes the session and finishes its receiver normally. Repeated calls are safe.
    public func disconnect() {
        self.terminate(.finished)
    }

    private var sendOperation: @AIProxyActor @Sendable (URLSessionWebSocketTask.Message) async throws -> Void {
        if let testTransport { return testTransport.send }
        let connection = self.connection
        return { message in
            guard let connection else {
                throw AIProxyError.assertion("The Realtime session has no WebSocket transport")
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default:
                throw AIProxyError.assertion("Unsupported outbound WebSocket message format")
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "websocket", metadata: [metadata])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: data,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                )
            }
            if data.count < 1500 {
                logIf(.debug)?.debug("AIProxy realtime control send complete (\(data.count) bytes)")
            }
        }
    }

    private func sendInitialSessionUpdate() {
        guard terminalState == nil, !initialUpdateStarted else { return }
        self.initialUpdateStarted = true
        do {
            let message = URLSessionWebSocketTask.Message.string(try self.initialSessionUpdate.serialize())
            // Keep a pending configuration send from retaining the session indefinitely.
            let send = self.sendOperation
            Task { @AIProxyActor [weak self] in
                guard self != nil, self?.terminalState == nil else { return }
                do {
                    try await send(message)
                } catch {
                    self?.fail(error, category: "initial send")
                }
            }
        } catch {
            self.fail(error, category: "initial send")
        }
    }

    // MARK: - Connection Lifecycle

    private func setupConnectionHandlers() {
        self.connection?.stateUpdateHandler = Self.makeStateUpdateHandler(for: self)
    }

    #if DEBUG
    /// Inject a platform state into the native handler without changing host networking.
    func handleConnectionStateForTesting(_ state: NWConnection.State) {
        self.handleConnectionStateChange(state)
    }

    func expireSetupDeadlineForTesting() {
        self.setupDeadlineReached()
    }
    #endif

    private func startSetupDeadline() {
        guard let delay = setupTimeoutNanoseconds else { return }
        self.setupTimeoutTask = Task { @AIProxyActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.setupDeadlineReached()
        }
    }

    private func setupDeadlineReached() {
        guard setupTimeoutTask != nil, terminalState == nil else { return }
        self.fail(URLError(.timedOut), category: "connection")
    }

    private func cancelSetupDeadline() {
        self.setupTimeoutTask?.cancel()
        self.setupTimeoutTask = nil
    }

    private func handleConnectionStateChange(_ state: NWConnection.State) {
        guard terminalState == nil else { return }
        logIf(.debug)?.debug("AIProxy realtime NWConnection state -> \(String(describing: state))")
        switch state {
        case .ready:
            self.cancelSetupDeadline()
            logIf(.debug)?.debug("AIProxy: NWConnection WebSocket ready")
            self.scheduleReceiveIfNeeded()
            self.sendInitialSessionUpdate()
        case .failed(let error):
            self.fail(error, category: "connection")
        case .waiting(let error):
            switch error {
            case .posix(.ECONNABORTED), .posix(.ECONNREFUSED), .tls:
                // Preserve the existing fail-fast policy for refused/aborted
                // attempts and TLS errors, forwarding the original setup cause.
                self.fail(error, category: "connection")
            default:
                // Network can resume a waiting connection after a path change.
                // Preserve that behavior, bounded by the existing setup deadline.
                logIf(.debug)?.debug("AIProxy realtime waiting for network path: \(error.localizedDescription)")
            }
        case .cancelled:
            self.terminate(.finished)
        default:
            break
        }
    }

    /// Schedules a single message receive on the NWConnection.
    private func scheduleReceiveIfNeeded() {
        guard terminalState == nil, !receiveInFlight else { return }
        self.receiveInFlight = true
        if let testTransport {
            testTransport.receive { [weak self] result in
                Task { @AIProxyActor [weak self] in self?.handleTestReceiveResult(result) }
            }
            return
        }
        self.connection?.receiveMessage(completion: Self.makeReceiveHandler(for: self))
    }

    private func handleReceiveResult(
        content: Data?,
        contentContext: NWConnection.ContentContext?,
        isComplete: Bool,
        error: NWError?
    ) {
        guard terminalState == nil else { return }
        self.receiveInFlight = false
        switch openAIRealtimeWebSocketFrameDisposition(content: content, contentContext: contentContext) {
        case .closeConnection:
            guard let metadata = contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                let cause: Error = error ?? AIProxyError.assertion("A WebSocket close frame has no metadata")
                self.fail(cause, category: "receive")
                return
            }
            guard let code = Self.closeCodeValue(metadata.closeCode) else {
                let cause: Error = error ?? AIProxyError.assertion("Unsupported WebSocket close metadata")
                self.fail(cause, category: "receive")
                return
            }
            if code == 1000 {
                self.terminate(.finished)
            } else {
                // Network supplies the close reason as content, without the status bytes.
                self.fail(OpenAIRealtimeSessionError.closed(
                    code: code,
                    reason: content,
                    underlyingError: error
                ), category: "receive", code: code)
            }
            return
        case .ignoreControlFrame:
            if let error { self.fail(error, category: "receive"); return }
            logIf(.debug)?.debug(
                "AIProxy realtime ignoring non-JSON websocket frame (\(content?.count ?? 0, privacy: .public) bytes)"
            )
            self.scheduleReceiveIfNeeded()
            return
        case .decodeTextPayload:
            break
        }
        if let error { self.fail(error, category: "receive"); return }
        guard let content, !content.isEmpty else {
            _ = isComplete
            self.scheduleReceiveIfNeeded()
            return
        }
        self.didReceiveWebSocketData(content, contentContext: contentContext)
    }

    private func handleTestReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard terminalState == nil else { return }
        self.receiveInFlight = false
        switch result {
        case .failure(let error):
            switch self.testTransport?.closeCode() ?? .invalid {
            case .normalClosure: self.terminate(.finished)
            case .invalid: self.fail(error, category: "receive")
            case let code:
                self.fail(OpenAIRealtimeSessionError.closed(
                    code: code.rawValue,
                    reason: self.testTransport?.closeReason(),
                    underlyingError: error
                ), category: "receive", code: code.rawValue)
            }
        case .success(let message):
            switch message {
            case .string(let text): self.didReceiveWebSocketData(Data(text.utf8), contentContext: nil)
            case .data(let bytes): self.didReceiveWebSocketData(bytes, contentContext: nil)
            @unknown default:
                self.fail(AIProxyError.assertion("Received an unsupported WebSocket message format"), category: "receive")
            }
        }
    }

    private func didReceiveWebSocketData(_ data: Data, contentContext: NWConnection.ContentContext?) {
        guard terminalState == nil else { return }
        do {
            let message = try JSONDecoder().decode(OpenAIRealtimeMessage.self, from: data)
            if case .error(let providerError) = message {
                let details = providerError.error?.message ?? providerError.error?.code ?? providerError.error?.type ?? "No error details"
                logIf(.error)?.error("Realtime provider error: \(details, privacy: .private)")
            }
            if case .terminated = continuation.yield(message) {
                self.terminate(.finished)
                return
            }
            self.scheduleReceiveIfNeeded()
        } catch {
            let opcodeLabel = Self.websocketOpcodeLabel(from: contentContext) ?? "unknown_opcode"
            let errorType = String(reflecting: type(of: error))
            logIf(.error)?.error("Realtime decode failed (bytes: \(data.count, privacy: .public), type: \(errorType, privacy: .public), opcode: \(opcodeLabel, privacy: .public))")
            self.terminate(.failed(error))
        }
    }

    private static func closeCodeValue(_ code: NWProtocolWebSocket.CloseCode) -> Int? {
        switch code {
        case .protocolCode(let defined): return Int(defined.rawValue)
        case .applicationCode(let value), .privateCode(let value): return Int(value)
        @unknown default: return nil
        }
    }

    private static func websocketOpcodeLabel(from contentContext: NWConnection.ContentContext?) -> String? {
        guard let metadata = contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return nil }
        return String(describing: metadata.opcode)
    }

    private func fail(_ error: Error, category: String, code: Int? = nil) {
        guard terminalState == nil else { return }
        let errorCode = code ?? (error as NSError).code
        logIf(.error)?.error("Realtime \(category, privacy: .public) failed (code: \(errorCode, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        self.terminate(.failed(error))
    }

    private func terminate(_ state: TerminalState) {
        guard terminalState == nil else { return }
        self.terminalState = state
        self.cancelSetupDeadline()
        self.finish(continuation, with: state)
        self.receiveInFlight = false
        if let testTransport {
            testTransport.cancel()
            return
        }
        self.connection?.stateUpdateHandler = nil
        self.connection?.cancel()
    }

    private func finish(_ continuation: AsyncThrowingStream<OpenAIRealtimeMessage, Error>.Continuation, with state: TerminalState) {
        switch state {
        case .finished: continuation.finish()
        case .failed(let error): continuation.finish(throwing: error)
        }
    }

    private nonisolated static func makeStateUpdateHandler(for session: OpenAIRealtimeSession) -> @Sendable (NWConnection.State) -> Void {
        return { [weak session] state in session?.didReceiveStateUpdateFromNetwork(state) }
    }

    private nonisolated static func makeReceiveHandler(for session: OpenAIRealtimeSession) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        return { [weak session] content, contentContext, isComplete, error in
            session?.didReceiveMessageFromNetwork(content: content, contentContext: contentContext, isComplete: isComplete, error: error)
        }
    }

    private nonisolated func didReceiveStateUpdateFromNetwork(_ state: NWConnection.State) {
        Task { @AIProxyActor [weak self] in self?.handleConnectionStateChange(state) }
    }

    private nonisolated func didReceiveMessageFromNetwork(content: Data?, contentContext: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) {
        Task { @AIProxyActor [weak self] in
            self?.handleReceiveResult(content: content, contentContext: contentContext, isComplete: isComplete, error: error)
        }
    }
}
