import Foundation
import Testing
@testable import AIProxy

/// Credential fixtures are synthetic. These tests use the actual proxy builder and SDK-owned
/// callback bridge, while replacing only OS credential acquisition. No service credentials or I/O.
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveAuthenticationTests {
    @Test(arguments: [false, true])
    func S02_3_S02_5_ownedCredentialWorkerExitsBeforeLateCallback(_ expireStartup: Bool) async throws {
        let credential = LiveHeldCredential()
        let builder = AIProxyProxiedRequestBuilder(partialKey: "fixture-partial-key", serviceURL: "https://example.invalid/proxy", clientID: "fixture-client", deviceCheckTokenGenerator: { completion in credential.hold(completion) })
        let clock = LiveProbeClock(); let peer = LiveProbePeer(); let probe = LiveRequestWorkerProbe()
        var transports = 0
        let session = OpenAILiveSession(configuration: .init(model: "gpt-live-1"), options: .init(startupTimeout: 23), dependencies: .init(
            makeRequest: {
                probe.enter()
                defer { probe.exit() }
                return try await builder.plainGET(path: "/v1/live/sessions", secondsToWait: 23, additionalHeaders: [:], baseURLOverride: nil)
            },
            makeTransport: { _, _ in transports += 1; return peer },
            sleep: { try await clock.sleep($0) }
        ))
        let start = Task { try await session.start() }
        await credential.entered.wait()
        #expect(probe.active == 1)
        if expireStartup { await clock.waitForDeadline(23); await clock.expire(23) }
        else { start.cancel() }
        do { _ = try await start.value; Issue.record("Pending startup must fail") }
        catch {
            if expireStartup {
                guard case .timeout(.startup)? = error as? OpenAILiveError else { Issue.record("Expected startup timeout"); return }
            } else { #expect(error is CancellationError) }
        }
        // This awaits actual return from the SDK's builder, without invoking the held OS callback.
        await probe.exited.wait()
        #expect(probe.active == 0); #expect(transports == 0)
        liveExpectEmptyResources(session.resourceSnapshot)
        await clock.waitUntilIdle()
        credential.complete(Data([0, 1, 2]))
        credential.complete(Data([3, 4, 5])) // duplicate/late OS callbacks cannot resume twice
        await Task.yield()
        #expect(probe.active == 0); #expect(transports == 0)
        #expect(session.finalization?.isConfirmed == false)
    }

    @Test
    func S01_2_realProxyBuilderPreservesRoutingAuthenticationAndMetadata() async throws {
        let builder = AIProxyProxiedRequestBuilder(partialKey: "fixture-partial-key", serviceURL: "https://proxy.example.invalid/service", clientID: "fixture-client", deviceCheckTokenGenerator: { complete in complete(Data([0, 1, 2, 255]), nil) })
        let request = try await builder.plainGET(path: "/v1/live/sessions", secondsToWait: 31,
            additionalHeaders: ["X-Fixture": "kept"], baseURLOverride: "https://upstream.example.invalid")
        #expect(request.url?.absoluteString == "https://proxy.example.invalid/service/v1/live/sessions")
        #expect(request.httpMethod == "GET"); #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 31); #expect(request.networkServiceType == .avStreaming)
        #expect(request.value(forHTTPHeaderField: "aiproxy-partial-key") == "fixture-partial-key")
        #expect(request.value(forHTTPHeaderField: "aiproxy-client-id") == "fixture-client")
        #expect(request.value(forHTTPHeaderField: "aiproxy-devicecheck") == "AAEC/w==")
        #expect(request.value(forHTTPHeaderField: "aiproxy-permitted-upstream") == "https://upstream.example.invalid")
        #expect(request.value(forHTTPHeaderField: "X-Fixture") == "kept")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let metadata = try #require(request.value(forHTTPHeaderField: "aiproxy-metadata"))
        let fields = metadata.split(separator: "|", omittingEmptySubsequences: false)
        #expect(fields.count == 9); #expect(fields.first == "v4"); #expect(fields.last == "0")
    }

    @Test
    func S01_1_realDirectBuilderKeepsCallerRouteAndHeaders() async throws {
        let builder = AIProxyDirectRequestBuilder(baseURL: "https://default.example.invalid", unprotectedAuthHeader: ("Authorization", "Bearer synthetic"))
        let request = try await builder.plainGET(path: "/v1/live/sessions", secondsToWait: 30,
            additionalHeaders: ["X-Fixture": "kept"], baseURLOverride: "https://alternate.example.invalid")
        #expect(request.url?.absoluteString == "https://alternate.example.invalid/v1/live/sessions")
        #expect(request.httpMethod == "GET"); #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
        #expect(request.value(forHTTPHeaderField: "X-Fixture") == "kept")
        #expect(request.value(forHTTPHeaderField: "aiproxy-partial-key") == nil)
    }

    @Test
    func S02_5_credentialCallbackSuccessAndDuplicateCompletionSettleOnce() async throws {
        let held = LiveHeldCredential()
        let token = Task { try await AIProxyDeviceCheck.getToken(forClient: "fixture-client", tokenGenerator: { held.hold($0) }) }
        await held.entered.wait()
        held.complete(Data([0, 1, 2, 255]))
        #expect(try await token.value == "AAEC/w==")
        held.complete(Data([9]))
        await Task.yield()
    }
}

@AIProxyActor
private final class LiveHeldCredential {
    let entered = LiveProbeSignal()
    private var callback: (@Sendable (Data?, (any Error)?) -> Void)?
    func hold(_ callback: @escaping @Sendable (Data?, (any Error)?) -> Void) { self.callback = callback; entered.signal() }
    func complete(_ data: Data) { callback?(data, nil) }
}

@AIProxyActor
private final class LiveRequestWorkerProbe {
    private(set) var active = 0
    let exited = LiveProbeSignal()
    func enter() { active += 1 }
    func exit() { active -= 1; exited.signal() }
}
