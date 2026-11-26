import Foundation
import Testing
@testable import AIProxy

/// Startup convenience configuration preserves the documented wire fields.
/// Wire oracle: primary-websocket.md session.start (source hash in OpenAILiveStarterTests).
@Suite
struct OpenAILiveConfigurationConvenienceTests {
    @Test
    func S03_1_customVoiceUsesDocumentedIDObject() throws {
        let configuration = OpenAILiveSessionConfiguration(
            model: "gpt-live-1",
            audio: .init(format: .pcm16kHz, customVoiceID: "voice_synthetic")
        )
        try liveExpectJSON(JSONEncoder().encode(configuration), #"{"model":"gpt-live-1","audio":{"format":{"type":"audio/pcm","rate":16000},"output":{"voice":{"id":"voice_synthetic"}}}}"#)
    }

    @Test
    func S03_2_typedHistoryKeepsRolesTextPartKindsAndOrder() throws {
        let configuration = OpenAILiveSessionConfiguration(
            model: "gpt-live-1",
            input: [
                .init(role: .developer, text: "  Generic instruction.\n"),
                .init(role: .user, text: "Synthetic question."),
                .init(role: .assistant, text: "Synthetic reply.")
            ]
        )
        let root = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        let input = try #require(root["input"] as? [[String: Any]])
        try #require(input.count == 3)
        let roles = ["developer", "user", "assistant"]
        let types = ["input_text", "input_text", "output_text"]
        let texts = ["  Generic instruction.\n", "Synthetic question.", "Synthetic reply."]
        for index in input.indices {
            #expect(input[index]["role"] as? String == roles[index])
            #expect(input[index]["id"] == nil)
            let parts = try #require(input[index]["content"] as? [[String: Any]])
            #expect(parts.count == 1)
            #expect(parts.first?["type"] as? String == types[index])
            #expect(parts.first?["text"] as? String == texts[index])
        }
    }

    @Test
    func S03_4_typedDelegationPreservesClientNullAndCallerResponsesSettings() throws {
        try liveExpectJSON(
            JSONEncoder().encode(OpenAILiveSessionConfiguration(model: "gpt-live-1", delegation: .client)),
            #"{"model":"gpt-live-1","delegation":{"type":"client"}}"#
        )
        try liveExpectJSON(
            JSONEncoder().encode(OpenAILiveSessionConfiguration(model: "gpt-live-1", delegation: .null)),
            #"{"model":"gpt-live-1","delegation":null}"#
        )
        try liveExpectJSON(
            JSONEncoder().encode(OpenAILiveSessionConfiguration(model: "gpt-live-1", delegation: .responses([
                "model": "backend_fixture", "instructions": nil, "parallel_tool_calls": false
            ]))),
            #"{"model":"gpt-live-1","delegation":{"type":"responses","responses":{"model":"backend_fixture","instructions":null,"parallel_tool_calls":false}}}"#
        )
    }
}
