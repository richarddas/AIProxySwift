import Foundation

@available(watchOS 10.5, *)
@AIProxyActor
protocol OpenAILiveTransport: Sendable {
    func resume()
    func send(_ text: String) async throws
    func receive() async throws -> OpenAILiveRawMessage
    func cancel()
    var response: HTTPURLResponse? { get }
    var closeCode: Int? { get }
    var closeReason: Data? { get }
}

@available(watchOS 10.5, *)
extension OpenAILiveTransport {
    var closeCode: Int? { nil }
    var closeReason: Data? { nil }
}

@available(watchOS 10.5, *)
struct OpenAILiveDependencies: Sendable {
    let makeRequest: @AIProxyActor @Sendable () async throws -> URLRequest
    let makeTransport: @AIProxyActor @Sendable (URLRequest, Int) -> any OpenAILiveTransport
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let beforeOrdinaryWrite: (@AIProxyActor @Sendable () async -> Void)?

    init(makeRequest: @escaping @AIProxyActor @Sendable () async throws -> URLRequest,
         makeTransport: @escaping @AIProxyActor @Sendable (URLRequest, Int) -> any OpenAILiveTransport,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
         beforeOrdinaryWrite: (@AIProxyActor @Sendable () async -> Void)? = nil) {
        self.makeRequest = makeRequest
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.beforeOrdinaryWrite = beforeOrdinaryWrite
    }
}

/// Uses the service-selected URLSession so its existing route and TLS policy remain in force.
@available(watchOS 10.5, *)
@AIProxyActor
final class OpenAILiveURLSessionTransport: OpenAILiveTransport {
    private let task: URLSessionWebSocketTask

    init(session: URLSession, request: URLRequest, maximumMessageBytes: Int) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageBytes
    }

    var response: HTTPURLResponse? { task.response as? HTTPURLResponse }
    var closeCode: Int? { task.closeCode == .invalid ? nil : task.closeCode.rawValue }
    var closeReason: Data? { task.closeReason }
    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> OpenAILiveRawMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw URLError(.cannotParseResponse)
            }
        } catch {
            let failure = error as NSError
            // URLSession reports its maximumMessageSize receive limit as POSIX EMSGSIZE.
            if failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.EMSGSIZE.rawValue) {
                throw OpenAILiveError.limitExceeded(.incomingMessage)
            }
            throw error
        }
    }
}
