//
//  OpenAIRealtimeMessageTests.swift
//  AIProxyTests
//

import XCTest
@testable import AIProxy

final class OpenAIRealtimeMessageTests: XCTestCase {

    func testResponseOutputAudioDeltaIsDecodable() throws {
        let event = try decode(
            #"{"type":"response.output_audio.delta","delta":"AQID","response_id":"resp_1","event_id":"event_1"}"#
        )

        guard case .responseAudioDelta(let payload) = event else {
            return XCTFail("Expected responseAudioDelta")
        }
        XCTAssertEqual(payload.base64Audio, "AQID")
        XCTAssertEqual(payload.responseID, "resp_1")
    }

    func testConversationItemAddedAndDoneAreDecodable() throws {
        let added = try decode(
            #"{"type":"conversation.item.added","event_id":"event_2","item":{"id":"msg_1","role":"assistant"},"previous_item_id":"msg_0"}"#
        )
        let done = try decode(
            #"{"type":"conversation.item.done","event_id":"event_3","item":{"id":"msg_1","role":"assistant"},"previous_item_id":"msg_0"}"#
        )

        guard case .conversationItemAdded(let addedPayload) = added else {
            return XCTFail("Expected conversationItemAdded")
        }
        XCTAssertEqual(addedPayload.itemID, "msg_1")
        XCTAssertEqual(addedPayload.role, "assistant")
        XCTAssertEqual(addedPayload.previousItemID, "msg_0")

        guard case .conversationItemDone(let donePayload) = done else {
            return XCTFail("Expected conversationItemDone")
        }
        XCTAssertEqual(donePayload.itemID, "msg_1")
        XCTAssertEqual(donePayload.role, "assistant")
        XCTAssertEqual(donePayload.previousItemID, "msg_0")
    }

    func testInputAudioBufferTimeoutTriggeredIsDecodable() throws {
        let event = try decode(
            #"{"type":"input_audio_buffer.timeout_triggered","event_id":"event_4","item_id":"item_1","audio_start_ms":1200,"audio_end_ms":2400}"#
        )

        guard case .inputAudioBufferTimeoutTriggered(let payload) = event else {
            return XCTFail("Expected inputAudioBufferTimeoutTriggered")
        }
        XCTAssertEqual(payload.itemID, "item_1")
        XCTAssertEqual(payload.audioStartMS, 1200)
        XCTAssertEqual(payload.audioEndMS, 2400)
        XCTAssertEqual(payload.eventID, "event_4")
    }

    func testInputAudioBufferDTMFEventReceivedIsDecodable() throws {
        let event = try decode(
            #"{"type":"input_audio_buffer.dtmf_event_received","event":"5","received_at":1743985938}"#
        )

        guard case .inputAudioBufferDTMFEventReceived(let payload) = event else {
            return XCTFail("Expected inputAudioBufferDTMFEventReceived")
        }
        XCTAssertEqual(payload.event, "5")
        XCTAssertEqual(payload.receivedAt, 1743985938)
    }

    func testTranscriptDeltasRemainDecodableAcrossInterleavedLifecycleEvents() throws {
        let lines: [String] = [
            #"{"type":"conversation.item.added","event_id":"event_10","item":{"id":"assistant_item","role":"assistant"},"previous_item_id":"user_item"}"#,
            #"{"type":"response.output_audio_transcript.delta","event_id":"event_11","response_id":"resp_9","item_id":"assistant_item","content_index":0,"delta":"Hel"}"#,
            #"{"type":"conversation.item.done","event_id":"event_12","item":{"id":"user_item","role":"user"},"previous_item_id":"older_item"}"#,
            #"{"type":"response.output_audio_transcript.delta","event_id":"event_13","response_id":"resp_9","item_id":"assistant_item","content_index":0,"delta":"lo"}"#,
            #"{"type":"response.output_audio_transcript.done","event_id":"event_14","response_id":"resp_9","item_id":"assistant_item","content_index":0,"transcript":"Hello"}"#,
        ]

        var assembled = ""
        var finalTranscript: String?

        for line in lines {
            let event = try decode(line)
            switch event {
            case .responseTranscriptDelta(let payload):
                assembled += payload.delta
            case .responseTranscriptDone(let payload):
                finalTranscript = payload.transcript
            default:
                continue
            }
        }

        XCTAssertEqual(assembled, "Hello")
        XCTAssertEqual(finalTranscript, "Hello")
    }

    func testResponseOutputTextEventsAreDecodable() throws {
        let deltaEvent = try decode(
            #"{"type":"response.output_text.delta","event_id":"event_21","response_id":"resp_11","item_id":"assistant_item","output_index":0,"content_index":0,"delta":"Hi"}"#
        )
        let doneEvent = try decode(
            #"{"type":"response.output_text.done","event_id":"event_22","response_id":"resp_11","item_id":"assistant_item","output_index":0,"content_index":0,"text":"Hi there"}"#
        )

        guard case .responseTextDelta(let deltaPayload) = deltaEvent else {
            return XCTFail("Expected responseTextDelta")
        }
        XCTAssertEqual(deltaPayload.delta, "Hi")
        XCTAssertEqual(deltaPayload.itemID, "assistant_item")

        guard case .responseTextDone(let donePayload) = doneEvent else {
            return XCTFail("Expected responseTextDone")
        }
        XCTAssertEqual(donePayload.text, "Hi there")
        XCTAssertEqual(donePayload.itemID, "assistant_item")
    }

    func testLegacyResponseTextEventsRemainDecodableForCompatibility() throws {
        let deltaEvent = try decode(
            #"{"type":"response.text.delta","event_id":"event_23","response_id":"resp_12","item_id":"assistant_item","output_index":0,"content_index":0,"delta":"A"}"#
        )
        let doneEvent = try decode(
            #"{"type":"response.text.done","event_id":"event_24","response_id":"resp_12","item_id":"assistant_item","output_index":0,"content_index":0,"text":"AB"}"#
        )

        guard case .responseTextDelta(let deltaPayload) = deltaEvent else {
            return XCTFail("Expected legacy responseTextDelta")
        }
        XCTAssertEqual(deltaPayload.delta, "A")

        guard case .responseTextDone(let donePayload) = doneEvent else {
            return XCTFail("Expected legacy responseTextDone")
        }
        XCTAssertEqual(donePayload.text, "AB")
    }

    private func decode(_ json: String) throws -> OpenAIRealtimeMessage {
        try JSONDecoder().decode(OpenAIRealtimeMessage.self, from: Data(json.utf8))
    }
}
