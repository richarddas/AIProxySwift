# GA Realtime `session.update` Schema Matrix

This matrix maps OpenAI GA `session.update.session` fields to AIProxySwift GA types and wire encoding behavior.

Reference: https://developers.openai.com/api/reference/resources/realtime

| GA field | AIProxySwift GA API | Wire shape emitted |
| --- | --- | --- |
| `type` | `OpenAIRealtimeSessionConfigurationGA.type` | string |
| `include` | `OpenAIRealtimeSessionConfigurationGA.include` | string array |
| `model` | `OpenAIRealtimeSessionConfigurationGA.model` | string |
| `instructions` | `OpenAIRealtimeSessionConfigurationGA.instructions` | string |
| `max_output_tokens` | `OpenAIRealtimeSessionConfigurationGA.maxOutputTokens` | int or `"inf"` |
| `output_modalities` | `OpenAIRealtimeSessionConfigurationGA.outputModalities` | enum string array |
| `prompt` | `OpenAIRealtimeSessionConfigurationGA.prompt` | object (`id`, optional `variables`, optional `version`) |
| `tracing` | `OpenAIRealtimeSessionConfigurationGA.tracing` | string `"auto"` or object (`group_id`, `metadata`, `workflow_name`) |
| `truncation` | `OpenAIRealtimeSessionConfigurationGA.truncation` | string (`"auto"`/`"disabled"`) or retention-ratio object |
| `tools` | `OpenAIRealtimeSessionConfigurationGA.tools` | union array (`function`, `mcp`, `web_search`) |
| `tool_choice` | `OpenAIRealtimeSessionConfigurationGA.toolChoice` | string (`auto`/`none`/`required`) or typed selector object |
| `audio.input.format` | `OpenAIRealtimeSessionConfigurationGA.inputAudioFormat` | object (`type`, optional `rate`) |
| `audio.input.noise_reduction` | `OpenAIRealtimeSessionConfigurationGA.inputAudioNoiseReduction` | object (`type`) |
| `audio.input.transcription` | `OpenAIRealtimeSessionConfigurationGA.inputAudioTranscription` | object (`language`, `model`, `prompt`) |
| `audio.input.turn_detection` | `OpenAIRealtimeSessionConfigurationGA.turnDetection` | typed object union (`server_vad` / `semantic_vad`) |
| `audio.output.format` | `OpenAIRealtimeSessionConfigurationGA.outputAudioFormat` | object (`type`, optional `rate`) |
| `audio.output.speed` | `OpenAIRealtimeSessionConfigurationGA.speed` | number (GA range 0.25...1.5) |
| `audio.output.voice` | `OpenAIRealtimeSessionConfigurationGA.voice` | string or object (`id`) |

## Compatibility Notes

- GA and beta-v1 wire paths are separate. GA-only fields are emitted only on the GA encoder path.
- `OpenAIService.realtimeSessionGA(...)` now sends initial GA `session.update` from the GA configuration directly, so GA-only fields are preserved.
- Legacy conversion still exists for migration compatibility and local session state; unsupported GA-only unions are dropped on legacy conversion.

## GA `response.create` Matrix

Reference: https://platform.openai.com/docs/api-reference/realtime-client-events/response

| GA field | AIProxySwift API | Wire shape emitted |
| --- | --- | --- |
| `type` | `OpenAIRealtimeResponseCreate.type` | `"response.create"` |
| `event_id` | `OpenAIRealtimeResponseCreate.eventID` | optional string |
| `response.instructions` | `OpenAIRealtimeResponseCreate.Response.instructions` | optional string |
| `response.output_modalities` | `OpenAIRealtimeResponseCreate.Response.outputModalities` | optional enum string array |
| `response.tools` | `OpenAIRealtimeResponseCreate.Response.tools` | optional tool union array (`function`, `mcp`, `web_search`) |
| `response.tool_choice` | `OpenAIRealtimeResponseCreate.Response.toolChoice` | optional string/object union |

## GA `conversation.item.create` Matrix

Reference: https://platform.openai.com/docs/api-reference/realtime-client-events/conversation/item/create

| GA field | AIProxySwift API | Wire shape emitted |
| --- | --- | --- |
| `type` | `OpenAIRealtimeConversationItemCreate.type` | `"conversation.item.create"` |
| `item.type` | `OpenAIRealtimeConversationItemCreate.Item` | `"message"`, `"function_call"`, `"function_call_output"` |
| `item.role` | `OpenAIRealtimeConversationItemCreate.Item.role` | optional string for message items |
| `item.content[].type` | `OpenAIRealtimeConversationItemCreate.Item.Content.type` | `input_text`, `output_text`, `input_audio`, `item_reference`, `input_image` |
| `item.content[].text` | `...Content.text` | optional string |
| `item.content[].audio` | `...Content.audio` | optional string |
| `item.content[].item_id` | `...Content.itemID` | optional string |
| `item.call_id` | `OpenAIRealtimeConversationItemCreate.Item.callID` | optional string |
| `item.name` | `OpenAIRealtimeConversationItemCreate.Item.name` | optional string |
| `item.arguments` | `OpenAIRealtimeConversationItemCreate.Item.arguments` | optional string |
| `item.output` | `OpenAIRealtimeConversationItemCreate.Item.output` | optional string |
