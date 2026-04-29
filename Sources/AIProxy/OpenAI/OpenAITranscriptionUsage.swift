//
//  OpenAITranscriptionUsage.swift
//  AIProxy
//
//
//  Created by OpenAI on 4/29/26.
//

import Foundation

/// Shared usage and token-confidence models used by OpenAI transcription APIs.
nonisolated public struct OpenAITranscriptionUsage: Decodable, Sendable {
    /// The billing model used for this transcription response.
    public let type: UsageType

    /// Number of input tokens billed for the request when `type == .tokens`.
    public let inputTokens: Int?

    /// Number of output tokens generated when `type == .tokens`.
    public let outputTokens: Int?

    /// Total billed tokens when `type == .tokens`.
    public let totalTokens: Int?

    /// Token usage details. The Swift property uses Responses-style naming while decoding the transcription wire key `input_token_details`.
    public let inputTokensDetails: InputTokensDetails?

    /// Duration billed for the request when `type == .duration`.
    public let seconds: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputTokensDetails = "input_token_details"
        case seconds
    }
}

extension OpenAITranscriptionUsage {
    nonisolated public enum UsageType: Decodable, Sendable {
        case tokens
        case duration
        case futureProof

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "tokens":
                self = .tokens
            case "duration":
                self = .duration
            default:
                self = .futureProof
            }
        }
    }

    nonisolated public struct InputTokensDetails: Decodable, Sendable {
        /// Number of audio tokens billed for the request.
        public let audioTokens: Int?

        /// Number of text tokens billed for the request.
        public let textTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case audioTokens = "audio_tokens"
            case textTokens = "text_tokens"
        }
    }
}

nonisolated public struct OpenAITranscriptionLogprob: Decodable, Sendable {
    /// The emitted token.
    public let token: String?

    /// Raw bytes for the emitted token.
    public let bytes: [Int]?

    /// Log-probability for the emitted token.
    public let logprob: Double?
}
