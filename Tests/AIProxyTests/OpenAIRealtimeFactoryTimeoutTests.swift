import Foundation
import Network
import Testing
@testable import AIProxy

@AIProxyActor
struct OpenAIRealtimeFactoryTimeoutTests {
    @Test func stalledTLSHonorsFactoryRequestTimeout() async throws {
        let peer = try NWStalledTLSPeer()
        defer { peer.stop() }
        let url = try await peer.listening.value()
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        let service = OpenAIService(requestFormat: .standard, requestBuilder: NWEvaluationBuilder(request: request), serviceNetworker: DirectServiceNetworker())
        let priorLevel = AIProxyLogLevel.callerDesiredLogLevel
        defer { AIProxyLogLevel.callerDesiredLogLevel = priorLevel }
        let session = try await service.realtimeSession(model: "fixture", configuration: .init(), logLevel: .warning)
        defer { session.disconnect() }
        let recorder = RealtimeMessageRecorder(expectedCount: 0)
        let reader = recorder.consume(session.receiver)
        defer { reader.cancel() }
        try await peer.accepted.value()
        do {
            try await recorder.finished.value()
            Issue.record("The native factory must honor request setup timeout")
        } catch let error as URLError { #expect(error.code == .timedOut) }
        session.disconnect()
    }
}

@AIProxyActor
private final class NWEvaluationBuilder: AIProxyRequestBuilder {
    let request: URLRequest
    init(request: URLRequest) { self.request = request }
    func plainGET(path: String, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest { request }
    func jsonPOST(path: String, body: Encodable, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest { throw RealtimeTestFailure.invalidHandshake }
    func multipartPOST(path: String, body: MultipartFormEncodable, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest { throw RealtimeTestFailure.invalidHandshake }
    func plainDELETE(path: String, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest { throw RealtimeTestFailure.invalidHandshake }
}

nonisolated private final class NWStalledTLSPeer: @unchecked Sendable {
    let listening = RealtimeTestSignal<URL>()
    let accepted = RealtimeTestSignal<Void>()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NWContributionEvaluation.peer")
    private var connections: [NWConnection] = []
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = self.listener.port {
                self.listening.succeed(URL(string: "https://127.0.0.1:\(port.rawValue)/v1/realtime")!)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.accepted.succeed(())
            // Accept TCP, but never answer the client's TLS ClientHello.
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.sync {
            for connection in connections { connection.cancel() }
            connections.removeAll()
            listener.cancel()
        }
    }
}
