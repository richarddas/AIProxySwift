import Foundation
import Security
import Testing
@testable import AIProxy

/// Synthetic EC certificate, generated locally with OpenSSL for pin comparison only.
/// These challenge tests exercise the existing delegate policy, not an Apple trust evaluation
/// or a successful TLS connection to the service. No production private key is involved.
@Suite(.timeLimit(.minutes(1)))
struct OpenAILiveTrustTests {
    @Test(arguments: ["matching", "mismatching", "production"])
    func S01_4_pinDelegateKeepsItsConfiguredTrustPolicy(_ mode: String) async throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, Data(base64Encoded: Self.certificateDER)! as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let serverTrust = try #require(trust)
        let key = try #require(SecCertificateCopyKey(certificate))
        let publicKey = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        let delegate: AIProxyCertificatePinningDelegate
        switch mode {
        case "matching": delegate = AIProxyCertificatePinningDelegate(pinnedPublicKeys: [publicKey])
        case "mismatching": delegate = AIProxyCertificatePinningDelegate(pinnedPublicKeys: [Data([0, 1, 2])])
        default: delegate = AIProxyCertificatePinningDelegate()
        }
        let space = LiveFixtureProtectionSpace(trust: serverTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: LiveFixtureChallengeSender())
        let urlSession = URLSession(configuration: .ephemeral)
        defer { urlSession.invalidateAndCancel() }
        let answer = await delegate.urlSession(urlSession, didReceive: challenge)
        if mode == "matching" {
            #expect(answer.0 == .useCredential); #expect(answer.1 != nil)
        } else {
            #expect(answer.0 == .cancelAuthenticationChallenge); #expect(answer.1 == nil)
        }
        let task = urlSession.dataTask(with: URL(string: "https://live-fixture.invalid")!)
        let taskAnswer = await delegate.urlSession(urlSession, task: task, didReceive: challenge)
        #expect(taskAnswer.0 == answer.0)
    }

    private static let certificateDER = "MIIBlDCCATmgAwIBAgIUfoDjqmCtC05gabWWywtkzjlEFR4wCgYIKoZIzj0EAwIwHzEdMBsGA1UEAwwUbGl2ZS1maXh0dXJlLmludmFsaWQwHhcNMjYxMDA4MTIxNDQxWhcNMzYxMDA1MTIxNDQxWjAfMR0wGwYDVQQDDBRsaXZlLWZpeHR1cmUuaW52YWxpZDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABFKVnSC3+aVtwITJ6OIPY2/vCmyeNwiTldcf4ZGuOh+2tC9kYSLthvgjsffcSHXv5lbzvHLan5hTU/KPsrwesjSjUzBRMB0GA1UdDgQWBBSvauxEEX5pm9UPcde1Fq6QjdK7aDAfBgNVHSMEGDAWgBSvauxEEX5pm9UPcde1Fq6QjdK7aDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDreyCU0b6yi/RXa84sFzt3fwyeiHHF7A1LHjIeCWGGrgIhANqznYZS4H+EV9u+xLXSJduwluTqLSKV7AEdOpDZKcKK"
}

nonisolated private final class LiveFixtureProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let fixtureTrust: SecTrust
    init(trust: SecTrust) {
        self.fixtureTrust = trust
        super.init(host: "live-fixture.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("Test fixture does not support decoding") }
    override var serverTrust: SecTrust? { fixtureTrust }
}

nonisolated private final class LiveFixtureChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
