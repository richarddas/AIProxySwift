//
//  OpenAIRealtimeGAMigrationCodableTests.swift
//  AIProxyTests
//

import Foundation
import Testing
@testable import AIProxy

struct OpenAIRealtimeGAMigrationCodableTests {

    @Test
    func testSessionConfigurationDefaultsToRealtimeType() throws {
        let config = OpenAIRealtimeSessionConfiguration(instructions: "Hi")
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)
        #expect(decoded.type == "realtime")
    }

    @Test
    func testSessionConfigurationCanEncodeTranscriptionType() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .transcription,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe")
        )
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)

        #expect(decoded.type == "transcription")
        #expect(decoded.audio?.input?.transcription?.model == "gpt-4o-mini-transcribe")
    }

    @Test
    func testRealtimeAPIInterfaceAppliesBetaHeaderOnlyForBetaV1() {
        let gaHeaders = OpenAIRealtimeAPIInterface.ga.realtimeHeaders
        #expect(gaHeaders["openai-beta"] == nil)

        let betaHeaders = OpenAIRealtimeAPIInterface.betaV1.realtimeHeaders
        #expect(betaHeaders["openai-beta"] == "realtime=v1")
    }

    @Test
    func testSessionConfigurationEncodesGAMaxOutputTokensKey() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            maxResponseOutputTokens: .int(321)
        )
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)

        #expect(decoded.maxOutputTokens == 321)
        #expect(decoded.legacyMaxResponseOutputTokens == nil)
    }

    @Test
    func testSessionUpdateEnvelopeUsesNestedAudioAndNoLegacyKeys() throws {
        let update = OpenAIRealtimeSessionUpdate(
            session: OpenAIRealtimeSessionConfiguration(
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
        #expect(decoded.session.audio?.input?.format == "pcm16")
        #expect(decoded.session.audio?.input?.transcription?.model == "gpt-4o-mini-transcribe")
        #expect(decoded.session.audio?.output?.format == "pcm16")
        #expect(decoded.session.audio?.output?.voice == "alloy")
        #expect(decoded.session.legacyInputAudioFormat == nil)
        #expect(decoded.session.legacyInputAudioTranscription == nil)
        #expect(decoded.session.legacyOutputAudioFormat == nil)
    }

    @Test
    func testSessionUpdateModalitiesAreStrippedForGAAndPreservedForBeta() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .realtime,
            modalities: [.text]
        )

        let gaUpdate = OpenAIRealtimeSessionUpdate(
            session: config.sessionUpdateConfiguration(for: .ga)
        )
        let gaEncoded: Data = try gaUpdate.serialize(pretty: false)
        let gaDecoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: gaEncoded)
        #expect(gaDecoded.session.modalities == nil)

        let betaUpdate = OpenAIRealtimeSessionUpdate(
            session: config.sessionUpdateConfiguration(for: .betaV1)
        )
        let betaEncoded: Data = try betaUpdate.serialize(pretty: false)
        let betaDecoded = try JSONDecoder().decode(SessionUpdateMirror.self, from: betaEncoded)
        #expect(betaDecoded.session.modalities == ["text"])
    }

    @Test
    func testSessionConfigurationUsesNestedAudioForGA() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            inputAudioFormat: .pcm16,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe"),
            outputAudioFormat: .pcm16,
            speed: 1.0,
            voice: "alloy"
        )
        let encoded: Data = try config.serialize(pretty: false)
        let decoded = try JSONDecoder().decode(SessionConfigurationMirror.self, from: encoded)

        #expect(decoded.audio?.input?.format == "pcm16")
        #expect(decoded.audio?.input?.transcription?.model == "gpt-4o-mini-transcribe")
        #expect(decoded.audio?.output?.format == "pcm16")
        #expect(decoded.audio?.output?.speed == 1.0)
        #expect(decoded.audio?.output?.voice == "alloy")
        #expect(decoded.legacyInputAudioFormat == nil)
        #expect(decoded.legacyInputAudioTranscription == nil)
        #expect(decoded.legacyOutputAudioFormat == nil)
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
        let audio: Audio?
        let modalities: [String]?
        let maxOutputTokens: Int?
        let legacyInputAudioFormat: String?
        let legacyInputAudioTranscription: InputAudioTranscription?
        let legacyOutputAudioFormat: String?
        let legacyMaxResponseOutputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case type
            case audio
            case modalities
            case maxOutputTokens = "max_output_tokens"
            case legacyInputAudioFormat = "input_audio_format"
            case legacyInputAudioTranscription = "input_audio_transcription"
            case legacyOutputAudioFormat = "output_audio_format"
            case legacyMaxResponseOutputTokens = "max_response_output_tokens"
        }
    }

    private struct Audio: Decodable {
        let input: InputAudio?
        let output: OutputAudio?
    }

    private struct InputAudio: Decodable {
        let format: String?
        let transcription: InputAudioTranscription?
    }

    private struct InputAudioTranscription: Decodable {
        let model: String?
    }

    private struct OutputAudio: Decodable {
        let format: String?
        let speed: Double?
        let voice: String?
    }
}
