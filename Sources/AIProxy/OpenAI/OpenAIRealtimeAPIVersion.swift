//
//  OpenAIRealtimeAPIVersion.swift
//

import Foundation

/// Realtime API wire version.
public enum OpenAIRealtimeAPIVersion: Sendable {
    case ga
    @available(*, deprecated, message: "beta-v1 is being sunset. Prefer GA realtime.")
    case betaV1

    var requestHeaders: [String: String] {
        switch self {
        case .ga:
            return [:]
        case .betaV1:
            return ["openai-beta": "realtime=v1"]
        }
    }

    func makeSessionUpdate(
        from configuration: OpenAIRealtimeSessionConfiguration,
        eventID: String? = nil
    ) -> OpenAIRealtimeSessionUpdate {
        switch self {
        case .ga:
            return OpenAIRealtimeSessionUpdate(
                eventId: eventID,
                session: .ga(.init(configuration: configuration))
            )
        case .betaV1:
            return OpenAIRealtimeSessionUpdate(
                eventId: eventID,
                session: .betaV1(.init(configuration: configuration))
            )
        }
    }
}

enum OpenAIRealtimeSessionUpdateBody: Encodable, Sendable {
    case ga(OpenAIRealtimeSessionConfigurationGA)
    case betaV1(OpenAIRealtimeSessionConfigurationBetaV1)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .ga(let payload):
            try payload.encode(to: encoder)
        case .betaV1(let payload):
            try payload.encode(to: encoder)
        }
    }
}

// MARK: - GA Session Configuration
struct OpenAIRealtimeSessionConfigurationGA: Encodable, Sendable {
    let type: OpenAIRealtimeSessionConfiguration.SessionType
    let inputAudioFormat: OpenAIRealtimeSessionConfiguration.AudioFormat?
    let inputAudioTranscription: OpenAIRealtimeSessionConfiguration.InputAudioTranscription?
    let instructions: String?
    let maxOutputTokens: OpenAIRealtimeSessionConfiguration.MaxOutputTokens?
    let outputModalities: [OpenAIRealtimeSessionConfiguration.Modality]?
    let outputAudioFormat: OpenAIRealtimeSessionConfiguration.AudioFormat?
    let speed: Float?
    let temperature: Double?
    let tools: [OpenAIRealtimeSessionConfiguration.Tool]?
    let toolChoice: OpenAIRealtimeSessionConfiguration.ToolChoice?
    let turnDetection: OpenAIRealtimeSessionConfiguration.TurnDetection?
    let voice: String?

    init(configuration: OpenAIRealtimeSessionConfiguration) {
        self.type = configuration.type
        self.inputAudioFormat = configuration.inputAudioFormat
        self.inputAudioTranscription = configuration.inputAudioTranscription
        self.instructions = configuration.instructions
        self.maxOutputTokens = configuration.maxOutputTokens
        self.outputModalities = configuration.outputModalities
        self.outputAudioFormat = configuration.outputAudioFormat
        self.speed = configuration.speed
        self.temperature = configuration.temperature
        self.tools = configuration.tools
        self.toolChoice = configuration.toolChoice
        self.turnDetection = configuration.turnDetection
        self.voice = configuration.voice
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case audio
        case instructions
        case maxOutputTokens = "max_output_tokens"
        case outputModalities = "output_modalities"
        case temperature
        case tools
        case toolChoice = "tool_choice"
    }

    private enum AudioCodingKeys: String, CodingKey {
        case input
        case output
    }

    private enum InputAudioCodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
    }

    private enum OutputAudioCodingKeys: String, CodingKey {
        case format
        case speed
        case voice
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(outputModalities, forKey: .outputModalities)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)

        let hasInputAudioConfig =
            inputAudioFormat != nil || inputAudioTranscription != nil || turnDetection != nil
        let hasOutputAudioConfig =
            outputAudioFormat != nil || speed != nil || voice != nil

        if hasInputAudioConfig || hasOutputAudioConfig {
            var audioContainer = container.nestedContainer(
                keyedBy: AudioCodingKeys.self,
                forKey: .audio
            )
            if hasInputAudioConfig {
                var inputContainer = audioContainer.nestedContainer(
                    keyedBy: InputAudioCodingKeys.self,
                    forKey: .input
                )
                try inputContainer.encodeIfPresent(inputAudioFormat, forKey: .format)
                try inputContainer.encodeIfPresent(inputAudioTranscription, forKey: .transcription)
                try inputContainer.encodeIfPresent(turnDetection, forKey: .turnDetection)
            }
            if hasOutputAudioConfig {
                var outputContainer = audioContainer.nestedContainer(
                    keyedBy: OutputAudioCodingKeys.self,
                    forKey: .output
                )
                try outputContainer.encodeIfPresent(outputAudioFormat, forKey: .format)
                try outputContainer.encodeIfPresent(speed, forKey: .speed)
                try outputContainer.encodeIfPresent(voice, forKey: .voice)
            }
        }
    }
}

// MARK: - beta-v1 Session Configuration
struct OpenAIRealtimeSessionConfigurationBetaV1: Encodable, Sendable {
    let inputAudioFormat: OpenAIRealtimeSessionConfiguration.AudioFormat?
    let inputAudioTranscription: OpenAIRealtimeSessionConfiguration.InputAudioTranscription?
    let instructions: String?
    let maxResponseOutputTokens: OpenAIRealtimeSessionConfiguration.MaxOutputTokens?
    let modalities: [OpenAIRealtimeSessionConfiguration.Modality]?
    let outputAudioFormat: OpenAIRealtimeSessionConfiguration.AudioFormat?
    let speed: Float?
    let temperature: Double?
    let tools: [OpenAIRealtimeSessionConfiguration.Tool]?
    let toolChoice: OpenAIRealtimeSessionConfiguration.ToolChoice?
    let turnDetection: OpenAIRealtimeSessionConfiguration.TurnDetection?
    let voice: String?

    init(configuration: OpenAIRealtimeSessionConfiguration) {
        self.inputAudioFormat = configuration.inputAudioFormat
        self.inputAudioTranscription = configuration.inputAudioTranscription
        self.instructions = configuration.instructions
        self.maxResponseOutputTokens = configuration.maxOutputTokens
        self.modalities = configuration.outputModalities
        self.outputAudioFormat = configuration.outputAudioFormat
        self.speed = configuration.speed
        self.temperature = configuration.temperature
        self.tools = configuration.tools
        self.toolChoice = configuration.toolChoice
        self.turnDetection = configuration.turnDetection
        self.voice = configuration.voice
    }

    private enum CodingKeys: String, CodingKey {
        case inputAudioFormat = "input_audio_format"
        case inputAudioTranscription = "input_audio_transcription"
        case instructions
        case maxResponseOutputTokens = "max_response_output_tokens"
        case modalities
        case outputAudioFormat = "output_audio_format"
        case speed
        case temperature
        case tools
        case toolChoice = "tool_choice"
        case turnDetection = "turn_detection"
        case voice
    }
}
