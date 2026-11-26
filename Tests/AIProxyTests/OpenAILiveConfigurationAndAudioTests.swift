import Foundation
import Testing
@testable import AIProxy

/// Fixture oracle: primary-websocket.md, sections session.start/input_audio.append/output_audio.delta.
/// Captured 2026-10-08; SHA-256 8b84c091389c659ea77c18e17939fa6c8f04d2cca6fd1afffa5a3f680f2103e0.
/// Fixed base64 vectors were checked independently with Python's standard library.
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveConfigurationAndAudioTests {
    nonisolated struct FormatFixture: Sendable {
        let format: OpenAILiveSessionConfiguration.AudioFormat
        let json: String
        let bytes: [UInt8]
        let base64: String
    }

    nonisolated static let formats: [FormatFixture] = [
        .init(format: .pcm24kHz, json: #"{"type":"audio/pcm","rate":24000}"#, bytes: [0, 0, 255, 127, 0, 128], base64: "AAD/fwCA"),
        .init(format: .pcm16kHz, json: #"{"type":"audio/pcm","rate":16000}"#, bytes: [1, 0, 255, 255], base64: "AQD//w=="),
        .init(format: .g711Ulaw, json: #"{"type":"audio/pcmu","rate":8000}"#, bytes: [255, 127, 0], base64: "/38A"),
        .init(format: .g711Alaw, json: #"{"type":"audio/pcma","rate":8000}"#, bytes: [213, 85, 128], base64: "1VWA")
    ]

    @Test(arguments: formats)
    func S03_1_S04_1_fourConfiguredFormatsPreserveWireBytes(_ fixture: FormatFixture) async throws {
        let configuration = OpenAILiveSessionConfiguration(model: "gpt-live-1", audio: .init(format: fixture.format, voice: "marin"))
        let expected = "{\"model\":\"gpt-live-1\",\"audio\":{\"format\":\(fixture.json),\"output\":{\"voice\":\"marin\"}}}"
        try liveExpectJSON(JSONEncoder().encode(configuration), expected)
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, configuration: configuration)
        _ = try await session.start(eventID: "start_b")
        try await session.appendAudio(Data(fixture.bytes), eventID: "audio_b")
        try liveExpectJSON(Data(peer.sent[0].utf8), "{\"type\":\"session.start\",\"event_id\":\"start_b\",\"session\":\(expected)}")
        try liveExpectJSON(Data(peer.sent[1].utf8), "{\"type\":\"session.input_audio.append\",\"event_id\":\"audio_b\",\"audio\":\"\(fixture.base64)\"}")
        session.abort()
        await clock.waitUntilIdle()
    }

    @Test
    func S03_4_typedOmissionAndFalseAreDistinct() throws {
        try liveExpectJSON(JSONEncoder().encode(OpenAILiveSessionConfiguration(model: "gpt-live-1")), #"{"model":"gpt-live-1"}"#)
        try liveExpectJSON(JSONEncoder().encode(OpenAILiveSessionConfiguration(model: "gpt-live-1", instructions: "", store: false)), #"{"model":"gpt-live-1","instructions":"","store":false}"#)
    }

    @Test(arguments: [
        #"{"model":"gpt-live-1","instructions":null,"delegation":null,"store":false}"#,
        #"{"model":"gpt-live-1","audio":{"output":{"voice":{"id":"voice_synthetic"}}}}"#,
        #"{"model":"gpt-live-1","input":[{"role":"developer","content":[{"type":"input_text","text":"  Generic instruction.\n"}],"id":null,"status":null},{"role":"user","content":[{"type":"input_text","text":"Synthetic question."}]},{"role":"assistant","content":[{"type":"output_text","text":"Synthetic reply."}]}]}"#,
        #"{"model":"gpt-live-1","input":[]}"#,
        #"{"model":"gpt-live-1","delegation":{"type":"client"},"future_setting":{"enabled":false,"level":2.5,"values":[null,"x"]}}"#,
        #"{"model":"gpt-live-1","audio":{"format":{"type":"provider-invalid-format","rate":-1}},"store":null}"#
    ])
    func S03_2_S03_3_S03_4_rawConfigurationPreservesCallerValues(_ literal: String) async throws {
        let fields = try JSONDecoder().decode([String: AIProxyJSONValue].self, from: Data(literal.utf8))
        let configuration = OpenAILiveSessionConfiguration(json: fields)
        try liveExpectJSON(JSONEncoder().encode(configuration), literal)
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, configuration: configuration)
        _ = try await session.start(eventID: "start_b")
        try liveExpectJSON(Data(peer.sent[0].utf8), "{\"type\":\"session.start\",\"event_id\":\"start_b\",\"session\":\(literal)}")
        session.abort()
        await clock.waitUntilIdle()
    }

    @Test
    func S03_3_nonFiniteJSONFailsLocallyBeforeOpeningTransport() async throws {
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let config = OpenAILiveSessionConfiguration(json: ["model": "gpt-live-1", "future_number": .double(.nan)])
        let session = liveProbeSession(peer: peer, clock: clock, configuration: config)
        do {
            _ = try await session.start()
            Issue.record("Non-finite JSON must fail encoding")
        } catch is EncodingError {
            #expect(peer.sent.isEmpty)
            #expect(peer.cancelCount == 0)
            #expect(session.finalization == nil)
        }
        session.abort()
        await clock.waitUntilIdle()
    }

    @Test(arguments: [Data(), Data([0, 1, 2])])
    func S04_2_emptyAndOddRawInputIsUnmodified(_ bytes: Data) async throws {
        let peer = LiveProbePeer()
        let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        try await session.appendAudio(bytes)
        let expectedBase64 = bytes.isEmpty ? "" : "AAEC"
        try liveExpectJSON(Data(peer.sent[1].utf8), "{\"type\":\"session.input_audio.append\",\"audio\":\"\(expectedBase64)\"}")
        session.abort()
        await clock.waitUntilIdle()
    }

    @Test(arguments: formats)
    func S04_3_minimalOutputInEveryFormatPreservesBase64AndBytes(_ fixture: FormatFixture) throws {
        let raw = OpenAILiveRawMessage.text("{\"type\":\"session.output_audio.delta\",\"delta\":\"\(fixture.base64)\"}")
        let event = OpenAILiveEvent.decode(raw)
        #expect(event.rawMessage == raw)
        #expect(event.diagnostic == nil)
        guard case .outputAudio(let audio) = event.payload else { Issue.record("Expected typed output audio"); return }
        #expect(audio.delta == fixture.base64)
        #expect(audio.audio == Data(fixture.bytes))
        #expect(audio.startMs == nil)
        #expect(audio.endMs == nil)
    }

    @Test(arguments: ["", "AA==", "AA", "AAE=", "AAE", "AAEC"])
    func S04_3_S08_4_base64AcceptsDocumentedSDKPaddingPolicy(_ encoded: String) {
        let expected: [String: [UInt8]] = ["": [], "AA==": [0], "AA": [0], "AAE=": [0, 1], "AAE": [0, 1], "AAEC": [0, 1, 2]]
        let event = OpenAILiveEvent.decode(.text("{\"type\":\"session.output_audio.delta\",\"delta\":\"\(encoded)\"}"))
        #expect(event.diagnostic == nil)
        guard case .outputAudio(let audio) = event.payload else { Issue.record("Expected audio"); return }
        #expect(audio.delta == encoded)
        #expect(audio.audio == Data(expected[encoded]!))
    }

    @Test(arguments: ["A", "A=AA", "AA===", "AA*A", "AA A"])
    func S08_4_invalidBase64RetainsOriginalStringAndDiagnostic(_ encoded: String) {
        let raw = OpenAILiveRawMessage.text("{\"type\":\"session.output_audio.delta\",\"delta\":\"\(encoded)\"}")
        let event = OpenAILiveEvent.decode(raw)
        #expect(event.rawMessage == raw)
        guard case .invalidBase64 = event.diagnostic else { Issue.record("Invalid base64 must diagnose"); return }
        guard case .outputAudio(let audio) = event.payload else { Issue.record("Invalid bytes must retain typed original base64"); return }
        #expect(audio.delta == encoded)
        #expect(audio.audio == nil)
    }
}
