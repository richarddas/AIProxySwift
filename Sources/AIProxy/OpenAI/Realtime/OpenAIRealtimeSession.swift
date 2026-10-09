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

#if DEBUG
/// A test-only transport seam for deterministic session lifecycle failures.
@AIProxyActor struct OpenAIRealtimeTestTransport: Sendable {
    let send: @AIProxyActor @Sendable (URLSessionWebSocketTask.Message) async throws -> Void
    let receive: @AIProxyActor @Sendable (@escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) -> Void
    let resume: @AIProxyActor @Sendable () -> Void
    let cancel: @AIProxyActor @Sendable () -> Void
    let closeCode: @AIProxyActor @Sendable () -> URLSessionWebSocketTask.CloseCode
    let closeReason: @AIProxyActor @Sendable () -> Data?
}
#endif

@AIProxyActor open class OpenAIRealtimeSession {
    private enum TerminalState: Sendable {
        case finished
        case failed(Error)
    }

    private let connection: NWConnection?
    #if DEBUG
    private let testTransport: OpenAIRealtimeTestTransport?
    #endif
    private var terminalState: TerminalState?
    private var hasStarted = false
    private var initialUpdateStarted = false
    private var receiveInFlight = false
    private var receiverStream: AsyncThrowingStream<OpenAIRealtimeMessage, Error>?
    private var continuation: AsyncThrowingStream<OpenAIRealtimeMessage, Error>.Continuation?
    let sessionConfiguration: OpenAIRealtimeSessionConfiguration
    private let initialSessionUpdate: OpenAIRealtimeSessionUpdate

    init(
        connection: NWConnection,
        sessionConfiguration: OpenAIRealtimeSessionConfiguration
    ) {
        self.connection = connection
        #if DEBUG
        self.testTransport = nil
        #endif
        self.sessionConfiguration = sessionConfiguration
        self.initialSessionUpdate = OpenAIRealtimeSessionUpdate(session: sessionConfiguration)
    }

    #if DEBUG
    init(
        testTransport: OpenAIRealtimeTestTransport,
        sessionConfiguration: OpenAIRealtimeSessionConfiguration
    ) {
        self.connection = nil
        self.testTransport = testTransport
        self.sessionConfiguration = sessionConfiguration
        self.initialSessionUpdate = OpenAIRealtimeSessionUpdate(session: sessionConfiguration)
        self.start()
    }
    #endif

    /// Must be called after init to begin the WebSocket connection.
    /// Separated from init because Swift 6 makes global-actor inits nonisolated,
    /// so calling actor-isolated methods from init triggers a runtime executor check.
    func start() {
        guard terminalState == nil, !hasStarted else { return }
        self.hasStarted = true
        #if DEBUG
        if let testTransport {
            testTransport.resume()
            self.scheduleReceiveIfNeeded()
            self.sendInitialSessionUpdate()
            return
        }
        #endif
        logIf(.info)?.info("AIProxy realtime session starting NWConnection")
        self.setupConnectionHandlers()
        self.connection?.start(queue: .global(qos: .userInitiated))
    }

    deinit {
        continuation?.finish()
        if terminalState == nil {
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            #if DEBUG
            if let testTransport {
                Task { @AIProxyActor in testTransport.cancel() }
            }
            #endif
        }
        logIf(.debug)?.debug("OpenAIRealtimeSession is being freed")
    }

    /// Server events for one receiving task. Provider error events remain message data.
    /// Transport and decoding failures terminate the stream with their cause.
    /// Cancelling while awaiting the next event closes the session.
    /// Use `defer { session.disconnect() }` in the receiving task so cancellation
    /// during event handling and early exits also close the session.
    public var receiver: AsyncThrowingStream<OpenAIRealtimeMessage, Error> {
        if let receiverStream { return receiverStream }
        let stream = AsyncThrowingStream<OpenAIRealtimeMessage, Error> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    Task { @AIProxyActor [weak self] in self?.disconnect() }
                }
            }
            // Retain setup failures without buffering events before receiver attachment.
            if let terminalState = self.terminalState {
                self.finish(continuation, with: terminalState)
                self.continuation = nil
            }
        }
        self.receiverStream = stream
        return stream
    }

    /// Completes when serialization and the transport send succeed, without implying
    /// provider acknowledgement. Serialization and send failures are thrown unchanged.
    public func sendMessage(_ encodable: Encodable) async throws {
        guard terminalState == nil else { throw OpenAIRealtimeSessionError.disconnected }
        let message = URLSessionWebSocketTask.Message.string(try encodable.serialize())
        try await self.sendOperation(message)
    }

    /// Closes the session and finishes its receiver normally. Repeated calls are safe.
    public func disconnect() {
        self.terminate(.finished)
    }

    private var sendOperation: @AIProxyActor @Sendable (URLSessionWebSocketTask.Message) async throws -> Void {
        #if DEBUG
        if let testTransport { return testTransport.send }
        #endif
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
                    self?.scheduleReceiveIfNeeded()
                } catch {
                    self?.terminate(.failed(error))
                }
            }
        } catch {
            self.terminate(.failed(error))
        }
    }

    // MARK: - Connection Lifecycle

    private func setupConnectionHandlers() {
        self.connection?.stateUpdateHandler = Self.makeStateUpdateHandler(for: self)
    }

    private func handleConnectionStateChange(_ state: NWConnection.State) {
        guard terminalState == nil else { return }
        logIf(.debug)?.debug("AIProxy realtime NWConnection state -> \(String(describing: state))")
        switch state {
        case .ready:
            logIf(.debug)?.debug("AIProxy: NWConnection WebSocket ready")
            self.sendInitialSessionUpdate()
        case .failed(let error), .waiting(let error):
            // A rejected upgrade and an unavailable endpoint both report .waiting.
            // Expose that original setup cause and leave a new attempt to the caller.
            self.terminate(.failed(error))
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
        #if DEBUG
        if let testTransport {
            testTransport.receive { [weak self] result in
                Task { @AIProxyActor [weak self] in self?.handleTestReceiveResult(result) }
            }
            return
        }
        #endif
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
                self.terminate(.failed(cause))
                return
            }
            guard let code = Self.closeCodeValue(metadata.closeCode) else {
                let cause: Error = error ?? AIProxyError.assertion("Unsupported WebSocket close metadata")
                self.terminate(.failed(cause))
                return
            }
            if code == 1000 {
                self.terminate(.finished)
            } else {
                // Network supplies the close reason as content, without the status bytes.
                self.terminate(.failed(OpenAIRealtimeSessionError.closed(
                    code: code,
                    reason: content,
                    underlyingError: error
                )))
            }
            return
        case .ignoreControlFrame:
            if let error { self.terminate(.failed(error)); return }
            logIf(.debug)?.debug(
                "AIProxy realtime ignoring non-JSON websocket frame (\(content?.count ?? 0, privacy: .public) bytes)"
            )
            self.scheduleReceiveIfNeeded()
            return
        case .decodeTextPayload:
            break
        }
        if let error { self.terminate(.failed(error)); return }
        guard let content, !content.isEmpty else {
            _ = isComplete
            self.scheduleReceiveIfNeeded()
            return
        }
        self.didReceiveWebSocketData(content, contentContext: contentContext)
    }

    #if DEBUG
    private func handleTestReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard terminalState == nil else { return }
        self.receiveInFlight = false
        switch result {
        case .failure(let error):
            switch self.testTransport?.closeCode() ?? .invalid {
            case .normalClosure: self.terminate(.finished)
            case .invalid: self.terminate(.failed(error))
            case let code:
                self.terminate(.failed(OpenAIRealtimeSessionError.closed(
                    code: code.rawValue,
                    reason: self.testTransport?.closeReason(),
                    underlyingError: error
                )))
            }
        case .success(let message):
            switch message {
            case .string(let text): self.didReceiveWebSocketData(Data(text.utf8), contentContext: nil)
            case .data(let bytes): self.didReceiveWebSocketData(bytes, contentContext: nil)
            @unknown default:
                self.terminate(.failed(AIProxyError.assertion("Received an unsupported WebSocket message format")))
            }
        }
    }
    #endif

    private func didReceiveWebSocketData(_ data: Data, contentContext: NWConnection.ContentContext?) {
        guard terminalState == nil else { return }
        do {
            let message = try JSONDecoder().decode(OpenAIRealtimeMessage.self, from: data)
            if let continuation, case .terminated = continuation.yield(message) {
                self.terminate(.finished)
                return
            }
            self.scheduleReceiveIfNeeded()
        } catch {
            let opcodeLabel = Self.websocketOpcodeLabel(from: contentContext) ?? "unknown_opcode"
            let payloadPreview = String(data: data.prefix(256), encoding: .utf8) ?? "non_utf8"
            logIf(.error)?.error(
                "AIProxy realtime decode failed opcode=\(opcodeLabel, privacy: .public) bytes=\(data.count, privacy: .public) preview=\(payloadPreview, privacy: .public)"
            )
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

    private func terminate(_ state: TerminalState) {
        guard terminalState == nil else { return }
        self.terminalState = state
        if let continuation {
            self.finish(continuation, with: state)
            self.continuation = nil
        }
        self.receiveInFlight = false
        #if DEBUG
        if let testTransport {
            testTransport.cancel()
            return
        }
        #endif
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
