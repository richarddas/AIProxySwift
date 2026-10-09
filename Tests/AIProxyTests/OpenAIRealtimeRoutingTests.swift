import Foundation
import Network
import Testing
@testable import AIProxy

@AIProxyActor
@Suite(.serialized)
struct OpenAIRealtimeRoutingTests {
    @Test
    func directRealtimeRequestRetainsSecureRouteAndAuthorization() async throws {
        let builder = AIProxyDirectRequestBuilder(
            baseURL: "https://api.openai.com",
            unprotectedAuthHeader: ("Authorization", "Bearer fixture-key")
        )
        let request = try await builder.plainGET(
            path: "/v1/realtime?model=fixture-model",
            secondsToWait: 60,
            additionalHeaders: [:]
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/realtime?model=fixture-model")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 60)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    }

    @Test
    func restDelegatesRemainConfiguredAlongsideNativeRealtime() {
        let direct = DirectServiceNetworker().urlSession
        let proxied = ProxiedServiceNetworker().urlSession
        #expect(direct === AIProxyUtils.directURLSession)
        #expect(direct.delegate is DirectURLSessionDataDelegate)
        #expect(proxied === AIProxyURLSession.urlSession)
        #expect(proxied.delegate === AIProxyURLSession.delegate)
        #expect(proxied.delegate is AIProxyCertificatePinningDelegate)
        #expect(direct !== proxied)
    }

    @Test(arguments: ["direct", "proxy"])
    func factoryUsesSelectedSecureNativeRouteWithoutReadingHTTPURLSession(_ route: String) async throws {
        // The native factory constructs TLS directly, including proxy pinning. The
        // unchanged production route/header/trust implementation is compared to the
        // validated integration baseline separately; no test bypass is installed.
        let server = try RealtimeLoopbackServer()
        defer { server.stop() }
        var components = try #require(URLComponents(url: try await server.listening.value(), resolvingAgainstBaseURL: false))
        server.stop()
        try await server.stoppedListening.value()
        components.scheme = "https"
        components.path = "/\(route)/v1/realtime"
        components.queryItems = [.init(name: "model", value: "fixture-model")]
        var request = URLRequest(url: try #require(components.url))
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("fixture-key", forHTTPHeaderField: route == "direct" ? "Authorization" : "X-AIProxy-Partial-Key")
        request.setValue("fixture-client", forHTTPHeaderField: "X-Fixture-Client")
        let builder = RealtimeCapturingRequestBuilder(request: request)
        let selectedSession = URLSession(configuration: .ephemeral)
        defer { selectedSession.invalidateAndCancel() }
        let networker: RealtimeSelectedNetworker = route == "direct" ?
            RealtimeDirectNativeNetworker(selectedSession: selectedSession) :
            RealtimeProxiedNativeNetworker(selectedSession: selectedSession)
        let service = OpenAIService(
            requestFormat: .standard,
            requestBuilder: builder,
            serviceNetworker: networker
        )
        let originalLogLevel = AIProxyLogLevel.callerDesiredLogLevel
        defer { AIProxyLogLevel.callerDesiredLogLevel = originalLogLevel }
        let session = try await service.realtimeSession(model: "fixture-model", configuration: .init(), logLevel: .warning)
        defer { session.disconnect() }
        #expect(builder.calls.count == 1)
        #expect(builder.calls.first?.path == "/v1/realtime?model=fixture-model")
        #expect(builder.calls.first?.secondsToWait == 60)
        #expect(builder.calls.first?.additionalHeaders == [:])
        #expect(builder.calls.first?.baseURLOverride == nil)
        let recorder = RealtimeMessageRecorder(expectedCount: 0)
        let reader = recorder.consume(session.receiver)
        defer { reader.cancel() }
        do {
            try await recorder.finished.value()
            Issue.record("The native factory must expose this unavailable secure endpoint")
        } catch NWError.posix(let code) {
            #expect(code == .ECONNREFUSED)
        }
        #expect(networker.selectionCount == 0)
    }
}

@AIProxyActor
private final class RealtimeCapturingRequestBuilder: AIProxyRequestBuilder {
    struct Call {
        let path: String
        let secondsToWait: UInt
        let additionalHeaders: [String: String]
        let baseURLOverride: String?
    }
    let request: URLRequest
    private(set) var calls: [Call] = []

    init(request: URLRequest) { self.request = request }

    func plainGET(path: String, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest {
        calls.append(.init(path: path, secondsToWait: secondsToWait, additionalHeaders: additionalHeaders, baseURLOverride: baseURLOverride))
        return request
    }

    func jsonPOST(path: String, body: Encodable, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest {
        throw RealtimeTestFailure.invalidHandshake
    }
    func multipartPOST(path: String, body: MultipartFormEncodable, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest {
        throw RealtimeTestFailure.invalidHandshake
    }
    func plainDELETE(path: String, secondsToWait: UInt, additionalHeaders: [String: String], baseURLOverride: String?) async throws -> URLRequest {
        throw RealtimeTestFailure.invalidHandshake
    }
}

@AIProxyActor
private class RealtimeSelectedNetworker: ServiceMixin {
    let selectedSession: URLSession
    private(set) var selectionCount = 0

    init(selectedSession: URLSession) { self.selectedSession = selectedSession }

    var urlSession: URLSession {
        selectionCount += 1
        return selectedSession
    }
}

@AIProxyActor
private final class RealtimeDirectNativeNetworker: RealtimeSelectedNetworker, DirectService {}

@AIProxyActor
private final class RealtimeProxiedNativeNetworker: RealtimeSelectedNetworker, ProxiedService {}
