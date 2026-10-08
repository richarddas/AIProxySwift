import Foundation
import Testing
@testable import AIProxy

/// Independent literals from primary-websocket.md (2026-10-08), the same source/hash as
/// OpenAILiveStarterTests. Provider choices remain caller-owned; no model/tool execution is simulated.
@Suite(.timeLimit(.minutes(1)))
@AIProxyActor
struct OpenAILiveCommandAndEventTests {
    nonisolated enum Command: CaseIterable, Sendable {
        case audio, mute, unmute, instructions, thinking, commentary, update, item, create
        var expected: String {
            switch self {
            case .audio: return #"{"type":"session.input_audio.append","event_id":"cmd","audio":"AAEC"}"#
            case .mute: return #"{"type":"session.input_audio.mute","event_id":"cmd"}"#
            case .unmute: return #"{"type":"session.input_audio.unmute","event_id":"cmd"}"#
            case .instructions: return #"{"type":"session.instructions.append","event_id":"cmd","delegation_id":null,"content":"  Context.\n"}"#
            case .thinking: return #"{"type":"session.thinking.append","event_id":"cmd","delegation_id":null,"content":"  Context.\n"}"#
            case .commentary: return #"{"type":"session.commentary.append","event_id":"cmd","delegation_id":null,"content":"  Context.\n"}"#
            case .update: return #"{"type":"session.update","event_id":"cmd","session":{"delegation":{"type":"responses","responses":{"instructions":null,"parallel_tool_calls":false}}}}"#
            case .item: return #"{"type":"response.item.create","event_id":"cmd","item":{"type":"function_call_output","call_id":"call_a","output":"synthetic result"}}"#
            case .create: return #"{"type":"response.create","event_id":"cmd"}"#
            }
        }
    }

    private func perform(_ command: Command, on session: OpenAILiveSession) async throws {
        let id: String
        switch command {
        case .audio: try await session.appendAudio(Data([0, 1, 2]), eventID: "cmd"); return
        case .mute: id = try await session.muteInput(eventID: "cmd")
        case .unmute: id = try await session.unmuteInput(eventID: "cmd")
        case .instructions: id = try await session.appendInstructions("  Context.\n", eventID: "cmd")
        case .thinking: id = try await session.appendThinking("  Context.\n", eventID: "cmd")
        case .commentary: id = try await session.appendCommentary("  Context.\n", eventID: "cmd")
        case .update: id = try await session.updateSession(.init(responses: ["instructions": nil, "parallel_tool_calls": false]), eventID: "cmd")
        case .item: id = try await session.createResponseItem(["type": "function_call_output", "call_id": "call_a", "output": "synthetic result"], eventID: "cmd")
        case .create: id = try await session.createResponse(eventID: "cmd")
        }
        #expect(id == "cmd")
    }

    @Test(arguments: Command.allCases)
    func S06_S07_ordinaryCommandsMatchIndependentJSON(_ command: Command) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        try await perform(command, on: session)
        try #require(peer.sent.count == 2)
        try liveExpectJSON(Data(peer.sent[1].utf8), command.expected)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: Command.allCases)
    func S02_2_allOrdinaryCommandsFailBeforeReadinessWithoutReplay(_ command: Command) async throws {
        let peer = LiveProbePeer(); peer.startMessages = []
        let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        let start = Task { try await session.start() }
        await peer.waitForSentCount(1)
        do { try await perform(command, on: session); Issue.record("Command must reject before readiness") }
        catch OpenAILiveError.notReady {}
        peer.emit(.text(LiveProbeFixtures.started))
        _ = try await start.value
        #expect(peer.sent.count == 1)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: ["instructions", "thinking", "commentary"])
    func S06_2_S06_5_contextPreservesExplicitOlderDelegation(_ kind: String) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        switch kind {
        case "instructions": _ = try await session.appendInstructions("Older result.", delegationID: "del_older", eventID: "context")
        case "thinking": _ = try await session.appendThinking("Older result.", delegationID: "del_older", eventID: "context")
        default: _ = try await session.appendCommentary("Older result.", delegationID: "del_older", eventID: "context")
        }
        try liveExpectJSON(Data(peer.sent[1].utf8), "{\"type\":\"session.\(kind).append\",\"event_id\":\"context\",\"delegation_id\":\"del_older\",\"content\":\"Older result.\"}")
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S06_6_fullResponsesSettingsAndDocumentedNullsAreCallerSelected() throws {
        let literal = #"{"model":"backend_fixture","instructions":null,"tools":[{"type":"function","name":"lookup_value","description":null,"parameters":{"type":"object","properties":{}},"strict":false},{"type":"web_search"}],"tool_choice":{"type":"function","name":"lookup_value"},"parallel_tool_calls":false,"max_output_tokens":1024,"service_tier":"default","reasoning":{"effort":"low","summary":null},"text":{"verbosity":"low"},"future_setting":{"values":[null,false,2.5]}}"#
        let fields = try JSONDecoder().decode([String: AIProxyJSONValue].self, from: Data(literal.utf8))
        let config = OpenAILiveSessionConfiguration(model: "gpt-live-1", delegation: .responses(fields))
        try liveExpectJSON(JSONEncoder().encode(config), "{\"model\":\"gpt-live-1\",\"delegation\":{\"type\":\"responses\",\"responses\":\(literal)}}")
        let nullable: [String: AIProxyJSONValue] = ["model": "backend_fixture", "max_output_tokens": nil, "parallel_tool_calls": nil, "reasoning": nil, "service_tier": nil, "text": nil]
        try liveExpectJSON(JSONEncoder().encode(OpenAILiveSessionConfiguration(model: "gpt-live-1", delegation: .responses(nullable))), #"{"model":"gpt-live-1","delegation":{"type":"responses","responses":{"model":"backend_fixture","max_output_tokens":null,"parallel_tool_calls":null,"reasoning":null,"service_tier":null,"text":null}}}"#)
    }

    @Test
    func S03_3_S06_7_rawUpdateAndLocalEncodingErrorDoNotChangeSessionPolicy() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        _ = try await session.start()
        do {
            _ = try await session.createResponseItem(["future": .double(.nan)], eventID: "bad_encoding")
            Issue.record("Nonfinite item must fail encoding")
        } catch is EncodingError {}
        #expect(peer.sent.count == 1); #expect(session.finalization == nil)
        _ = try await session.updateSession(.init(json: ["model": "provider-invalid-update", "delegation": nil, "future": ["enabled": false]]), eventID: "raw_update")
        try liveExpectJSON(Data(peer.sent[1].utf8), #"{"type":"session.update","event_id":"raw_update","session":{"model":"provider-invalid-update","delegation":null,"future":{"enabled":false}}}"#)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S06_3_S07_1_acknowledgmentsRemainSeparateFromWritesAndAudioContinues() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator()
        _ = try await session.start(); _ = try await events.next()
        let id = try await session.appendThinking("Context.")
        #expect(!id.isEmpty)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(peer.sent[1].utf8)) as? [String: Any])
        #expect(sent["event_id"] as? String == id)
        peer.emit(.text(LiveProbeFixtures.output))
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        // No synthetic acknowledgment preceded that output, despite completed command writes.
        _ = try await session.muteInput(eventID: "mute")
        let muted = #"{"type":"session.input_audio.muted","event_id":"muted","client_event_id":"mute"}"#
        peer.emit(.text(muted)); peer.emit(.text(LiveProbeFixtures.output))
        #expect(try await events.next()?.rawMessage == .text(muted))
        #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        let ack = "{\"type\":\"session.thinking.appended\",\"event_id\":\"ack\",\"client_event_id\":\"\(id)\",\"start_ms\":10.25,\"end_ms\":10.25}"
        peer.emit(.text(ack)); #expect(try await events.next()?.rawMessage == .text(ack))
        #expect(peer.sent.count == 3)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: ["session.input_transcript.delta", "session.output_transcript.delta"])
    func S05_1_transcriptFieldsRetainWhitespaceAndFractionalOffsets(_ type: String) {
        let raw = "{\"type\":\"\(type)\",\"event_id\":\"transcript\",\"client_event_id\":\"correlation\",\"delta\":\"  fragment\\n\",\"start_ms\":10.25,\"end_ms\":11.75,\"future\":{\"value\":false}}"
        let event = OpenAILiveEvent.decode(.text(raw))
        #expect(event.rawMessage == .text(raw)); #expect(event.diagnostic == nil)
        let transcript: OpenAILiveEvent.TranscriptDelta
        switch event.payload {
        case .inputTranscript(let data) where type == "session.input_transcript.delta": transcript = data
        case .outputTranscript(let data) where type == "session.output_transcript.delta": transcript = data
        default: Issue.record("Incorrect transcript payload"); return
        }
        #expect(transcript.eventID == "transcript"); #expect(transcript.clientEventID == "correlation")
        #expect(transcript.delta == "  fragment\n"); #expect(transcript.startMs == 10.25); #expect(transcript.endMs == 11.75)
    }

    @Test(arguments: ["instructions", "thinking", "commentary"])
    func S06_3_contextAcknowledgmentFieldFidelity(_ kind: String) {
        let raw = "{\"type\":\"session.\(kind).appended\",\"event_id\":\"ack\",\"client_event_id\":\"context\",\"start_ms\":10.25,\"end_ms\":10.25}"
        let event = OpenAILiveEvent.decode(.text(raw)); #expect(event.diagnostic == nil)
        let ack: OpenAILiveEvent.ContextAppended
        switch event.payload {
        case .instructionsAppended(let value) where kind == "instructions": ack = value
        case .thinkingAppended(let value) where kind == "thinking": ack = value
        case .commentaryAppended(let value) where kind == "commentary": ack = value
        default: Issue.record("Incorrect acknowledgment payload"); return
        }
        #expect(ack.eventID == "ack"); #expect(ack.clientEventID == "context"); #expect(ack.startMs == 10.25); #expect(ack.endMs == 10.25)
    }

    @Test(arguments: ["client", "responses"])
    func S06_1_S06_9_delegationMetadataRetainsOriginalFields(_ target: String) {
        let responseID = target == "responses" ? ",\"response_id\":\"resp_a\"" : ""
        let raw = "{\"type\":\"session.delegation.created\",\"event_id\":\"delegation\",\"offset_ms\":12.25,\"delegation\":{\"id\":\"del_a\",\"type\":\"delegation\",\"target\":\"\(target)\"\(responseID)}}"
        let event = OpenAILiveEvent.decode(.text(raw)); #expect(event.diagnostic == nil)
        guard case .delegationCreated(let data) = event.payload else { Issue.record("Expected delegation"); return }
        #expect(data.eventID == "delegation"); #expect(data.clientEventID == nil); #expect(data.offsetMs == 12.25)
        #expect(data.delegation.id == "del_a"); #expect(data.delegation.type == "delegation"); #expect(data.delegation.target == target)
        #expect(data.delegation.responseID == (target == "responses" ? "resp_a" : nil))
    }

    @Test(arguments: [
        #"{"type":"response.created","response":{"id":"resp_a","instructions":null,"tools":[],"output":[]}}"#,
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"lookup_value","arguments":""}}"#,
        #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"lookup_value","arguments":"{}"}}"#,
        #"{"type":"response.completed","response":{"id":"resp_a","usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15}}}"#,
        #"{"type":"response.future_notice","future":{"flag":false,"values":[null,1.25,"x"]}}"#
    ], ["", ",\"delegation_id\":null", ",\"delegation_id\":\"del_a\""])
    func S06_9_nestedResponsesRemainJSONWithoutStandaloneResponseRequirements(_ nested: String, _ correlation: String) throws {
        let raw = "{\"type\":\"response.event\",\"event_id\":\"backend\"\(correlation),\"event\":\(nested)}"
        let event = OpenAILiveEvent.decode(.text(raw)); #expect(event.rawMessage == .text(raw)); #expect(event.diagnostic == nil)
        guard case .responseEvent(let data) = event.payload else { Issue.record("Expected Responses envelope"); return }
        #expect(data.eventID == "backend"); #expect(data.delegationID == (correlation.contains("del_a") ? "del_a" : nil))
        try liveExpectJSON(JSONEncoder().encode(data.event), nested)
    }

    @Test
    func S06_8_resolvedSessionUpdateAndControlInfoFieldsDecode() throws {
        let raw = #"{"type":"session.updated","event_id":"updated","client_event_id":"update_a","session":{"id":"live_probe","expires_at":1788555600.25,"model":"gpt-live-1","status":"active","delegation":{"type":"responses","responses":{"model":"resolved_backend","parallel_tool_calls":true}}}}"#
        let event = OpenAILiveEvent.decode(.text(raw))
        guard case .updated(let data) = event.payload else { Issue.record("Expected resolved update"); return }
        #expect(data.clientEventID == "update_a"); #expect(data.session.expiresAt == 1788555600.25)
        try liveExpectJSON(JSONEncoder().encode(data.session.json), #"{"id":"live_probe","expires_at":1788555600.25,"model":"gpt-live-1","status":"active","delegation":{"type":"responses","responses":{"model":"resolved_backend","parallel_tool_calls":true}}}"#)
        let muted = OpenAILiveEvent.decode(.text(#"{"type":"session.input_audio.muted","event_id":"muted"}"#))
        let unmuted = OpenAILiveEvent.decode(.text(#"{"type":"session.input_audio.unmuted","event_id":"unmuted","client_event_id":"unmute"}"#))
        guard case .inputMuted(let m) = muted.payload, case .inputUnmuted(let u) = unmuted.payload else { Issue.record("Expected control acknowledgments"); return }
        #expect(m.eventID == "muted"); #expect(m.clientEventID == nil); #expect(u.clientEventID == "unmute")
        let info = OpenAILiveEvent.decode(.text(#"{"type":"info","event_id":"notice","code":"data_channel_permissions","message":"Synthetic notice."}"#))
        guard case .info(let notice) = info.payload else { Issue.record("Expected info"); return }
        #expect(notice.eventID == "notice"); #expect(notice.code == "data_channel_permissions"); #expect(notice.message == "Synthetic notice.")
    }

    @Test(arguments: ["null", "\"unknown_parameter\""])
    func S08_3_errorCodeAndInnerOuterCorrelationRemainIndependent(_ code: String) {
        let raw = "{\"type\":\"error\",\"event_id\":\"err\",\"client_event_id\":\"outer\",\"error\":{\"type\":\"invalid_request_error\",\"code\":\(code),\"message\":\"Synthetic rejection.\",\"param\":\"session.future\",\"client_event_id\":\"inner\"}}"
        let event = OpenAILiveEvent.decode(.text(raw)); #expect(event.diagnostic == nil)
        guard case .error(let value) = event.payload else { Issue.record("Expected provider error"); return }
        #expect(value.eventID == "err"); #expect(value.clientEventID == "outer"); #expect(value.error.clientEventID == "inner")
        #expect(value.error.type == "invalid_request_error"); #expect(value.error.message == "Synthetic rejection."); #expect(value.error.param == "session.future")
        #expect(value.error.code == (code == "null" ? nil : "unknown_parameter"))
    }

    @Test
    func S09_1_usageReplacesRatherThanSumsAndRatioMayDecrease() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        let snapshots = [
            #"{"type":"session.usage.updated","event_id":"usage1","usage":{"seconds":12.5},"context_window":{"usage_ratio":0.92}}"#,
            #"{"type":"session.usage.updated","event_id":"usage2","usage":{"seconds":15.25},"context_window":{"usage_ratio":0.35}}"#,
            #"{"type":"session.usage.updated","event_id":"usage3","usage":{"seconds":15.25}}"#
        ]
        for (index, raw) in snapshots.enumerated() {
            peer.emit(.text(raw)); let event = try #require(try await events.next())
            guard case .usage(let value) = event.payload else { Issue.record("Expected usage"); session.abort(); return }
            #expect(value.usage.seconds == (index == 0 ? 12.5 : 15.25))
            #expect(value.contextWindow?.usageRatio == (index == 0 ? 0.92 : index == 1 ? 0.35 : nil))
            #expect(session.latestUsage?.seconds == (index == 0 ? 12.5 : 15.25))
        }
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: ["close_requested", "expired", "content", "remote_hangup", "connection_lost", "future_reason"])
    func S09_2_S09_3_everyCloseReasonPreservesConfirmedActiveSnapshot(_ reason: String) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        let raw = LiveProbeFixtures.closed.replacingOccurrences(of: "close_requested", with: reason)
        peer.emit(.text(raw)); _ = try await events.next()
        let final = try #require(session.finalization)
        #expect(final.isConfirmed); #expect(final.reason == reason); #expect(final.session?.status == "active"); #expect(final.usage?.seconds == 15.25)
        // Cancellation of the underlying receiver after close cannot downgrade the result.
        await peer.waitUntilIdle(); session.abort()
        #expect(session.finalization?.isConfirmed == true); #expect(session.finalization?.usage?.seconds == 15.25)
        await clock.waitUntilIdle()
    }

    @Test
    func S06_5_multipleUpdatesKeepTheOlderOfTwoDelegationIDs() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        for id in ["del_older", "del_newer"] {
            let raw = "{\"type\":\"session.delegation.created\",\"event_id\":\"evt_\(id)\",\"offset_ms\":12.25,\"delegation\":{\"id\":\"\(id)\",\"type\":\"delegation\",\"target\":\"client\"}}"
            peer.emit(.text(raw)); #expect(try await events.next()?.rawMessage == .text(raw))
        }
        for (index, content) in ["First result.", "Further result."].enumerated() {
            _ = try await session.appendCommentary(content, delegationID: "del_older", eventID: "update_\(index)")
            try liveExpectJSON(Data(peer.sent[index + 1].utf8), "{\"type\":\"session.commentary.append\",\"event_id\":\"update_\(index)\",\"delegation_id\":\"del_older\",\"content\":\"\(content)\"}")
        }
        #expect(peer.sent.count == 3); #expect(session.finalization == nil)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test
    func S06_7_S06_8_sparseUpdateAndResolvedEventCauseNoAdditionalCommands() async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, configuration: .init(model: "gpt-live-1", delegation: .responses(["model": "backend_fixture"])))
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        _ = try await session.updateSession(.init(responses: ["parallel_tool_calls": false]), eventID: "settings")
        try liveExpectJSON(Data(peer.sent[1].utf8), #"{"type":"session.update","event_id":"settings","session":{"delegation":{"type":"responses","responses":{"parallel_tool_calls":false}}}}"#)
        let raw = #"{"type":"session.updated","event_id":"resolved","client_event_id":"settings","session":{"id":"live_probe","expires_at":1788555600,"model":"gpt-live-1","status":"active","delegation":{"type":"responses","responses":{"model":"backend_fixture","parallel_tool_calls":false}}}}"#
        peer.emit(.text(raw)); let event = try #require(try await events.next())
        guard case .updated(let update) = event.payload else { Issue.record("Expected correlated resolved configuration"); session.abort(); return }
        #expect(update.clientEventID == "settings"); #expect(event.rawMessage == .text(raw))
        #expect(peer.sent.count == 2); #expect(session.finalization == nil)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: [
        #"{"type":"message","role":"user","content":[{"type":"input_text","text":"Synthetic input."}]}"#,
        #"{"type":"function_call_output","call_id":"call_a","output":"Synthetic result."}"#
    ])
    func S06_10_callerItemsAreExactAndDoNotStartAnAutomaticResponse(_ literal: String) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock()
        let session = liveProbeSession(peer: peer, clock: clock, configuration: .init(model: "gpt-live-1", delegation: .responses(["model": "backend_fixture"])))
        _ = try await session.start()
        let item = try JSONDecoder().decode([String: AIProxyJSONValue].self, from: Data(literal.utf8))
        _ = try await session.createResponseItem(item, eventID: "item")
        try liveExpectJSON(Data(peer.sent[1].utf8), "{\"type\":\"response.item.create\",\"event_id\":\"item\",\"item\":\(literal)}")
        #expect(peer.sent.count == 2)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: [false, true])
    func S07_1_S07_2_muteAndUnmuteAcknowledgmentsKeepOutputIndependent(_ unmute: Bool) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        if unmute { _ = try await session.unmuteInput(eventID: "control") } else { _ = try await session.muteInput(eventID: "control") }
        peer.emit(.text(LiveProbeFixtures.output)); #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        let type = unmute ? "session.input_audio.unmuted" : "session.input_audio.muted"
        let raw = "{\"type\":\"\(type)\",\"event_id\":\"accepted\",\"client_event_id\":\"control\"}"
        peer.emit(.text(raw)); #expect(try await events.next()?.rawMessage == .text(raw))
        peer.emit(.text(LiveProbeFixtures.output)); #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        #expect(session.finalization == nil); #expect(peer.sent.count == 2)
        session.abort(); await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

    @Test(arguments: [
        #"{"type":"error","event_id":"error_probe","error":{"type":"invalid_request_error","code":null,"message":"Synthetic command rejection."}}"#,
        #"{"type":"error","event_id":"error_probe","error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Synthetic token-limit rejection.","client_event_id":"context"}}"#,
        #"{"type":"error","event_id":"error_probe","error":{"type":"moderation_error","code":"content_policy_violation","message":"Synthetic moderation rejection."}}"#
    ])
    func S08_3_providerErrorsDoNotInferTerminalityOrFinalUsage(_ raw: String) async throws {
        let peer = LiveProbePeer(); let clock = LiveProbeClock(); let session = liveProbeSession(peer: peer, clock: clock)
        var events = try session.events().makeAsyncIterator(); _ = try await session.start(); _ = try await events.next()
        peer.emit(.text(raw)); let error = try #require(try await events.next())
        guard case .error = error.payload else { Issue.record("Expected provider error event"); session.abort(); return }
        #expect(error.rawMessage == .text(raw)); #expect(session.finalization == nil); #expect(session.latestUsage == nil)
        peer.emit(.text(LiveProbeFixtures.output)); #expect(try await events.next()?.rawMessage == .text(LiveProbeFixtures.output))
        peer.emit(.text(#"{"type":"session.usage.updated","event_id":"usage_probe","usage":{"seconds":12.5}}"#)); _ = try await events.next()
        #expect(session.latestUsage?.seconds == 12.5); #expect(session.finalization == nil)
        peer.emit(.text(LiveProbeFixtures.closed.replacingOccurrences(of: "close_requested", with: "content")))
        _ = try await events.next(); #expect(session.finalization?.isConfirmed == true); #expect(session.finalization?.usage?.seconds == 15.25)
        await clock.waitUntilIdle(); await peer.waitUntilIdle()
    }

}
