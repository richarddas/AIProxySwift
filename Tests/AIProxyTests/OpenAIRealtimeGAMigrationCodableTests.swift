//
//  OpenAIRealtimeGAMigrationCodableTests.swift
//  AIProxyTests
//

import Foundation
import Testing
@testable import AIProxy

struct OpenAIRealtimeGAMigrationCodableTests {

    @Test
    func testLegacySessionConfigurationEncodesBetaShapeByDefault() throws {
        let config = OpenAIRealtimeSessionConfiguration(instructions: "Hi")
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)
        #expect(decoded.type == nil)
        #expect(decoded.instructions == "Hi")
        #expect(decoded.audio == nil)
    }

    @Test
    func testLegacySessionConfigurationUsesTopLevelBetaAudioKeys() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .transcription,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe")
        )
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)

        #expect(decoded.type == nil)
        #expect(decoded.legacyInputAudioTranscription?.model == "gpt-4o-mini-transcribe")
        #expect(decoded.audio == nil)
    }

    @Test
    func testRealtimeAPIInterfaceAppliesBetaHeaderOnlyForBetaV1() {
        let gaHeaders = OpenAIRealtimeAPIVersion.ga.requestHeaders
        #expect(gaHeaders["openai-beta"] == nil)

        let betaHeaders = OpenAIRealtimeAPIVersion.betaV1.requestHeaders
        #expect(betaHeaders["openai-beta"] == "realtime=v1")
    }

    @Test
    func testLegacySessionConfigurationEncodesBetaMaxResponseOutputTokensKey() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            maxOutputTokens: .int(321)
        )
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)

        #expect(decoded.maxOutputTokens == nil)
        #expect(decoded.legacyMaxResponseOutputTokens == 321)
    }

    @Test
    func testLegacySessionConfigurationInitializerLabelsRemainSupported() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            maxResponseOutputTokens: .int(654),
            modalities: [.text]
        )
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)
        #expect(decoded.maxOutputTokens == nil)
        #expect(decoded.outputModalities == nil)
        #expect(decoded.legacyMaxResponseOutputTokens == 654)
        #expect(decoded.modalities == ["text"])
    }

    @Test
    func testGAOptInSessionUpdateUsesNestedAudioAndNoLegacyKeys() throws {
        let update = OpenAIRealtimeAPIVersion.ga.makeSessionUpdate(
            from: OpenAIRealtimeSessionConfigurationGA(
                type: .realtime,
                inputAudioFormat: .pcm16,
                inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe"),
                outputAudioFormat: .pcm16,
                speed: 1.0,
                voice: "alloy"
            )
        )

        let encoded: Data = try update.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: encoded)

        #expect(decoded.type == "session.update")
        #expect(decoded.session.type == "realtime")
        #expect(decoded.session.audio?.input?.format?.type == "audio/pcm")
        #expect(decoded.session.audio?.input?.format?.rate == 24000)
        #expect(decoded.session.audio?.input?.transcription?.model == "gpt-4o-mini-transcribe")
        #expect(decoded.session.audio?.output?.format?.type == "audio/pcm")
        #expect(decoded.session.audio?.output?.format?.rate == 24000)
        #expect(decoded.session.audio?.output?.voice == "alloy")
        #expect(decoded.session.legacyInputAudioFormat == nil)
        #expect(decoded.session.legacyInputAudioTranscription == nil)
        #expect(decoded.session.legacyOutputAudioFormat == nil)
        #expect(decoded.session.temperature == nil)
    }

    @Test
    func testLegacySessionUpdateInitializerRemainsBetaCompatible() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            maxResponseOutputTokens: .int(42),
            modalities: [.text]
        )
        let update = OpenAIRealtimeSessionUpdate(session: config)
        let encoded: Data = try update.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: encoded)
        #expect(decoded.type == "session.update")
        #expect(decoded.session.maxOutputTokens == nil)
        #expect(decoded.session.outputModalities == nil)
        #expect(decoded.session.legacyMaxResponseOutputTokens == 42)
        #expect(decoded.session.modalities == ["text"])
    }

    @Test
    func testSessionUpdateModalitiesMapToOutputModalitiesForGAAndStayModalitiesForBeta() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .realtime,
            outputModalities: [.text]
        )

        let gaUpdate = OpenAIRealtimeAPIVersion.ga.makeSessionUpdate(from: config)
        let gaEncoded: Data = try gaUpdate.serialize(pretty: false)
        let gaDecoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: gaEncoded)
        #expect(gaDecoded.session.outputModalities == ["text"])
        #expect(gaDecoded.session.modalities == nil)

        let betaUpdate = OpenAIRealtimeAPIVersion.betaV1.makeSessionUpdate(from: config)
        let betaEncoded: Data = try betaUpdate.serialize(pretty: false)
        let betaDecoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: betaEncoded)
        #expect(betaDecoded.session.outputModalities == nil)
        #expect(betaDecoded.session.modalities == ["text"])
    }

    @Test
    func testBetaSessionUpdateUsesLegacyKeysAndOmitsGAOnlyShape() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .realtime,
            inputAudioFormat: .pcm16,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe"),
            maxOutputTokens: .int(456),
            outputModalities: [.audio, .text],
            outputAudioFormat: .pcm16,
            speed: 1.0,
            voice: "alloy"
        )
        let betaUpdate = OpenAIRealtimeAPIVersion.betaV1.makeSessionUpdate(from: config)
        let encoded: Data = try betaUpdate.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: encoded)

        #expect(decoded.session.type == nil)
        #expect(decoded.session.audio == nil)
        #expect(decoded.session.modalities == ["audio", "text"])
        #expect(decoded.session.outputModalities == nil)
        #expect(decoded.session.maxOutputTokens == nil)
        #expect(decoded.session.legacyMaxResponseOutputTokens == 456)
        #expect(decoded.session.legacyInputAudioFormat == "pcm16")
        #expect(decoded.session.legacyInputAudioTranscription?.model == "gpt-4o-mini-transcribe")
        #expect(decoded.session.legacyOutputAudioFormat == "pcm16")
    }

    @Test
    func testLegacyConfigurationEncodedAsGAOmitsTemperature() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            outputModalities: [.audio],
            temperature: 0.7
        )
        let update = OpenAIRealtimeAPIVersion.ga.makeSessionUpdate(from: config)
        let encoded: Data = try update.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: encoded)

        #expect(decoded.session.outputModalities == ["audio"])
        #expect(decoded.session.temperature == nil)
    }

    @Test
    func testGAConfigurationUsesNestedAudioForGA() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            inputAudioFormat: .pcm16,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe"),
            outputAudioFormat: .pcm16,
            speed: 1.0,
            voice: "alloy"
        )
        let encoded: Data = try OpenAIRealtimeAPIVersion.ga.makeSessionUpdate(from: config.asGAConfiguration).serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: encoded)

        #expect(decoded.session.audio?.input?.format?.type == "audio/pcm")
        #expect(decoded.session.audio?.input?.format?.rate == 24000)
        #expect(decoded.session.audio?.input?.transcription?.model == "gpt-4o-mini-transcribe")
        #expect(decoded.session.audio?.output?.format?.type == "audio/pcm")
        #expect(decoded.session.audio?.output?.format?.rate == 24000)
        #expect(decoded.session.audio?.output?.speed == 1.0)
        #expect(decoded.session.audio?.output?.voice == "alloy")
        #expect(decoded.session.legacyInputAudioFormat == nil)
        #expect(decoded.session.legacyInputAudioTranscription == nil)
        #expect(decoded.session.legacyOutputAudioFormat == nil)
    }

    @Test
    func testGAAudioFormatsEncodeAsTypedObjectsForG711() throws {
        let update = OpenAIRealtimeAPIVersion.ga.makeSessionUpdate(
            from: OpenAIRealtimeSessionConfigurationGA(
                type: .realtime,
                inputAudioFormat: .g711Ulaw,
                outputAudioFormat: .g711Alaw
            )
        )

        let encoded: Data = try update.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: encoded)

        #expect(decoded.session.audio?.input?.format?.type == "audio/pcmu")
        #expect(decoded.session.audio?.input?.format?.rate == nil)
        #expect(decoded.session.audio?.output?.format?.type == "audio/pcma")
        #expect(decoded.session.audio?.output?.format?.rate == nil)
    }

    @Test
    func testRealtimeErrorWithObjectBodyDecodesMessage() throws {
        let payload = """
        {
          "type":"error",
          "event_id":"event_test",
          "error":{
            "type":"invalid_request_error",
            "code":"unknown_parameter",
            "message":"Unknown parameter: 'session.input_audio_format'.",
            "param":"session.input_audio_format",
            "event_id":null
          }
        }
        """
        let message = try JSONDecoder().decode(OpenAIRealtimeMessage.self, from: Data(payload.utf8))
        guard case .error(let event) = message else {
            Issue.record("Expected decoded realtime error message")
            return
        }
        #expect(event.errorBody == "Unknown parameter: 'session.input_audio_format'.")
    }

    @Test
    func testConversationItemCreateUsesOutputTextForAssistantRole() throws {
        let item = OpenAIRealtimeConversationItemCreate.Item(role: "assistant", text: "Hello")
        let encoded: String = try item.serialize(pretty: false)
        #expect(encoded.contains("\"type\":\"output_text\""))
        #expect(!encoded.contains("\"type\":\"text\""))
    }

    @Test
    func testConversationItemCreateUsesInputTextForUserRole() throws {
        let item = OpenAIRealtimeConversationItemCreate.Item(role: "user", text: "Hello")
        let encoded: String = try item.serialize(pretty: false)
        #expect(encoded.contains("\"type\":\"input_text\""))
    }

    private struct SessionUpdateMirror: Decodable {
        let type: String
        let session: SessionConfigurationMirror
    }

    private struct SessionConfigurationMirror: Decodable {
        let type: String?
        let instructions: String?
        let audio: Audio?
        // beta session.update shape
        let modalities: [String]?
        // GA session.update shape
        let outputModalities: [String]?
        let maxOutputTokens: Int?
        let legacyInputAudioFormat: String?
        let legacyInputAudioTranscription: InputAudioTranscription?
        let legacyOutputAudioFormat: String?
        let legacyMaxResponseOutputTokens: Int?
        let temperature: Double?

        private enum CodingKeys: String, CodingKey {
            case type
            case instructions
            case audio
            case modalities
            case outputModalities = "output_modalities"
            case maxOutputTokens = "max_output_tokens"
            case legacyInputAudioFormat = "input_audio_format"
            case legacyInputAudioTranscription = "input_audio_transcription"
            case legacyOutputAudioFormat = "output_audio_format"
            case legacyMaxResponseOutputTokens = "max_response_output_tokens"
            case temperature
        }
    }

    private struct Audio: Decodable {
        let input: InputAudio?
        let output: OutputAudio?
    }

    private struct InputAudio: Decodable {
        let format: AudioFormatObject?
        let transcription: InputAudioTranscription?
    }

    private struct InputAudioTranscription: Decodable {
        let model: String?
    }

    private struct OutputAudio: Decodable {
        let format: AudioFormatObject?
        let speed: Double?
        let voice: String?
    }

    private struct AudioFormatObject: Decodable {
        let type: String?
        let rate: Int?
    }
}
