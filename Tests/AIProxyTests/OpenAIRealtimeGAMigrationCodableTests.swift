//
//  OpenAIRealtimeGAMigrationCodableTests.swift
//  AIProxyTests
//

import XCTest
@testable import AIProxy

final class OpenAIRealtimeGAMigrationCodableTests: XCTestCase {

    func testSessionConfigurationDefaultsToRealtimeType() throws {
        let config = OpenAIRealtimeSessionConfiguration(instructions: "Hi")
        let encoded: String = try config.serialize(pretty: false)
        XCTAssertTrue(encoded.contains("\"type\":\"realtime\""))
    }

    func testSessionConfigurationCanEncodeTranscriptionType() throws {
        let config = OpenAIRealtimeSessionConfiguration(
            type: .transcription,
            inputAudioTranscription: .init(model: "gpt-4o-mini-transcribe")
        )
        let encoded: String = try config.serialize(pretty: false)
        XCTAssertTrue(encoded.contains("\"type\":\"transcription\""))
    }

    func testConversationItemCreateUsesOutputTextForAssistantRole() throws {
        let item = OpenAIRealtimeConversationItemCreate.Item(role: "assistant", text: "Hello")
        let encoded: String = try item.serialize(pretty: false)
        XCTAssertTrue(encoded.contains("\"type\":\"output_text\""))
        XCTAssertFalse(encoded.contains("\"type\":\"text\""))
    }

    func testConversationItemCreateUsesInputTextForUserRole() throws {
        let item = OpenAIRealtimeConversationItemCreate.Item(role: "user", text: "Hello")
        let encoded: String = try item.serialize(pretty: false)
        XCTAssertTrue(encoded.contains("\"type\":\"input_text\""))
    }
}
