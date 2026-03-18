//
//  OpenAIRealtimeGAMigrationCodableTests.swift
//  AIProxyTests
//

import Testing
@testable import AIProxy

struct OpenAIRealtimeGAMigrationCodableTests {

    @Test
    func testSessionConfigurationDefaultsToRealtimeType() throws {
        let config = OpenAIRealtimeSessionConfiguration(instructions: "Hi")
        let encoded: String = try config.serialize(pretty: false)
        #expect(encoded.contains("\"type\":\"realtime\""))
    }

    @Test
    func testSessionConfigurationCanEncodeTranscriptionType() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .transcription,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe")
        )
        let encoded: String = try config.serialize(pretty: false)
        #expect(encoded.contains("\"type\":\"transcription\""))
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
}
