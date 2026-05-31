//
//  OpenAIRealtimeSessionReceiveTests.swift
//  AIProxyTests
//

import Foundation
import Network
import Testing
@testable import AIProxy

struct OpenAIRealtimeSessionReceiveTests {

    private func contentContext(opcode: NWProtocolWebSocket.Opcode) -> NWConnection.ContentContext {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        return NWConnection.ContentContext(identifier: "websocket", metadata: [metadata])
    }

    @Test
    func pingFramesAreIgnoredWithoutDisconnecting() {
        let pingPayload = Data([0x00, 0x01, 0x02])
        let disposition = openAIRealtimeWebSocketFrameDisposition(
            content: pingPayload,
            contentContext: contentContext(opcode: .ping)
        )
        #expect(disposition == .ignoreControlFrame)
    }

    @Test
    func pongFramesAreIgnoredWithoutDisconnecting() {
        let disposition = openAIRealtimeWebSocketFrameDisposition(
            content: Data(),
            contentContext: contentContext(opcode: .pong)
        )
        #expect(disposition == .ignoreControlFrame)
    }

    @Test
    func closeFramesRequestDisconnect() {
        let disposition = openAIRealtimeWebSocketFrameDisposition(
            content: Data(),
            contentContext: contentContext(opcode: .close)
        )
        #expect(disposition == .closeConnection)
    }

    @Test
    func binaryFramesAreIgnoredWithoutDisconnecting() {
        let disposition = openAIRealtimeWebSocketFrameDisposition(
            content: Data([0xff, 0xfe]),
            contentContext: contentContext(opcode: .binary)
        )
        #expect(disposition == .ignoreControlFrame)
    }

    @Test
    func textFramesAreDecoded() {
        let disposition = openAIRealtimeWebSocketFrameDisposition(
            content: Data(#"{"type":"session.created"}"#.utf8),
            contentContext: contentContext(opcode: .text)
        )
        #expect(disposition == .decodeTextPayload)
    }

    @Test
    func missingMetadataDefaultsToDecode() {
        let disposition = openAIRealtimeWebSocketFrameDisposition(
            content: Data(#"{"type":"session.created"}"#.utf8),
            contentContext: nil
        )
        #expect(disposition == .decodeTextPayload)
    }
}
