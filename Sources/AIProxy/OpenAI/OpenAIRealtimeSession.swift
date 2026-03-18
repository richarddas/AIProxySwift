//
//  RealtimeSession.swift
//
//
//  Created by Lou Zell on 11/28/24.
//

import AVFoundation
import Foundation
import Network

nonisolated private let kWebsocketDisconnectedEarlyThreshold: TimeInterval = 3

@AIProxyActor open class OpenAIRealtimeSession {
    private var isTearingDown = false
    private var hasFinishedReceiverStream = false
    private var receiveInFlight = false
    private let connection: NWConnection
    private var continuation: AsyncStream<OpenAIRealtimeMessage>.Continuation?
    private let setupTime = Date()
    private let apiVersion: OpenAIRealtimeAPIVersion
    let sessionConfiguration: OpenAIRealtimeSessionConfiguration
    private let initialSessionUpdate: OpenAIRealtimeSessionUpdate

    init(
        connection: NWConnection,
        sessionConfiguration: OpenAIRealtimeSessionConfiguration,
        apiVersion: OpenAIRealtimeAPIVersion,
        initialSessionUpdate: OpenAIRealtimeSessionUpdate? = nil
    ) {
        self.connection = connection
        self.sessionConfiguration = sessionConfiguration
        self.apiVersion = apiVersion
        self.initialSessionUpdate = initialSessionUpdate ?? apiVersion.makeSessionUpdate(from: sessionConfiguration)
    }

    /// Must be called after init to begin the WebSocket connection.
    /// Separated from init because Swift 6 makes global-actor inits nonisolated,
    /// so calling actor-isolated methods from init triggers a runtime executor check.
    func start() {
        logIf(.info)?.info("AIProxy realtime session starting NWConnection")
        self.setupConnectionHandlers()
        self.connection.start(queue: .global(qos: .userInitiated))
    }

    deinit {
        logIf(.debug)?.debug("OpenAIRealtimeSession is being freed")
    }

    /// Messages sent from OpenAI are published on this receiver as they arrive
    public var receiver: AsyncStream<OpenAIRealtimeMessage> {
        return AsyncStream { continuation in
            self.continuation = continuation
            self.hasFinishedReceiverStream = false
        }
    }

    /// Sends a message through the websocket connection
    public func sendMessage(_ encodable: Encodable) async {
        guard !self.isTearingDown else {
            logIf(.debug)?.debug("Ignoring ws sendMessage. The RT session is tearing down.")
            return
        }
        do {
            let data: Data = try encodable.serialize()
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "websocket",
                metadata: [metadata]
            )
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.connection.send(
                    content: data,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                )
            }
            if data.count < 1500 {
                logIf(.debug)?.debug("AIProxy realtime control send complete (\(data.count) bytes)")
            }
        } catch {
            logIf(.error)?.error("Could not send message to OpenAI: \(error.localizedDescription)")
        }
    }

    /// Close the websocket connection
    public func disconnect() {
        guard !self.isTearingDown else { return }
        self.isTearingDown = true
        logIf(.info)?.info("AIProxy realtime session disconnecting NWConnection")
        self.finishReceiverStreamIfNeeded()
        self.receiveInFlight = false
        self.connection.stateUpdateHandler = nil
        self.connection.cancel()
    }

    // MARK: - Connection Lifecycle

    private func setupConnectionHandlers() {
        self.connection.stateUpdateHandler = Self.makeStateUpdateHandler(for: self)
    }

    private func handleConnectionStateChange(_ state: NWConnection.State) async {
        logIf(.debug)?.debug("AIProxy realtime NWConnection state -> \(String(describing: state))")
        switch state {
        case .ready:
            logIf(.debug)?.debug("AIProxy: NWConnection WebSocket ready")
            await self.sendMessage(self.initialSessionUpdate)
            self.scheduleReceiveIfNeeded()
        case .preparing:
            break
        case .setup:
            break
        case .failed(let error):
            self.didReceiveConnectionError(error)
        case .waiting(let error):
            logIf(.debug)?.debug("AIProxy: NWConnection waiting: \(error.localizedDescription)")
        case .cancelled:
            logIf(.info)?.info("AIProxy realtime NWConnection cancelled")
            self.disconnect()
        default:
            break
        }
    }

    /// Schedules a single message receive on the NWConnection
    private func scheduleReceiveIfNeeded() {
        guard !self.isTearingDown, !self.receiveInFlight else { return }
        self.receiveInFlight = true

        let receiveHandler = Self.makeReceiveHandler(for: self)
        self.connection.receiveMessage(completion: receiveHandler)
    }

    private func handleReceiveResult(
        content: Data?,
        contentContext: NWConnection.ContentContext?,
        isComplete: Bool,
        error: NWError?
    ) async {
        self.receiveInFlight = false

        if let error {
            logIf(.error)?.error("AIProxy realtime receive callback error: \(error.localizedDescription)")
            self.didReceiveConnectionError(error)
            return
        }

        guard let content, !content.isEmpty else {
            _ = isComplete
            _ = contentContext
            self.scheduleReceiveIfNeeded()
            return
        }

        self.didReceiveWebSocketData(content)
    }

    /// Handles connection-level errors
    private func didReceiveConnectionError(_ error: NWError) {
        guard !isTearingDown else { return }

        let disconnectedEarly =
            Date().timeIntervalSince(setupTime) <= kWebsocketDisconnectedEarlyThreshold
        if disconnectedEarly {
            logIf(.warning)?.warning(
                "AIProxy: websocket disconnected immediately. Check that you've followed the DeviceCheck integration guide at https://www.aiproxy.com/docs/integration-guide.html"
            )
        } else {
            logIf(.error)?.error("AIProxy: NWConnection error: \(error.localizedDescription)")
        }

        self.disconnect()
    }

    private func didReceiveWebSocketData(_ data: Data) {
        guard !self.isTearingDown else {
            return
        }

        do {
            let message = try JSONDecoder().decode(OpenAIRealtimeMessage.self, from: data)
            self.continuation?.yield(message)
            if case .error = message {
                return
            }
            self.scheduleReceiveIfNeeded()
        } catch {
            logIf(.error)?.error("Received websocket data that we don't understand")
            self.disconnect()
        }
    }

    private func finishReceiverStreamIfNeeded() {
        guard !self.hasFinishedReceiverStream else { return }
        self.hasFinishedReceiverStream = true
        self.continuation?.finish()
        self.continuation = nil
    }

    private nonisolated static func makeStateUpdateHandler(
        for session: OpenAIRealtimeSession
    ) -> @Sendable (NWConnection.State) -> Void {
        return { [weak session] state in
            session?.didReceiveStateUpdateFromNetwork(state)
        }
    }

    private nonisolated static func makeReceiveHandler(
        for session: OpenAIRealtimeSession
    ) -> @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        return { [weak session] content, contentContext, isComplete, error in
            session?.didReceiveMessageFromNetwork(
                content: content,
                contentContext: contentContext,
                isComplete: isComplete,
                error: error
            )
        }
    }

    private nonisolated func didReceiveStateUpdateFromNetwork(_ state: NWConnection.State) {
        Task { @AIProxyActor [weak self] in
            await self?.handleConnectionStateChange(state)
        }
    }

    private nonisolated func didReceiveMessageFromNetwork(
        content: Data?,
        contentContext: NWConnection.ContentContext?,
        isComplete: Bool,
        error: NWError?
    ) {
        Task { @AIProxyActor [weak self] in
            await self?.handleReceiveResult(
                content: content,
                contentContext: contentContext,
                isComplete: isComplete,
                error: error
            )
        }
    }
}
