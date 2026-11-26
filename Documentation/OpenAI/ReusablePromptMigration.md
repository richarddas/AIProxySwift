# Migrating from reusable Responses prompts

OpenAI has deprecated reusable prompt objects and scheduled `/v1/prompts` and reusable prompt objects for shutdown on November 30, 2026. Check [OpenAI's deprecation schedule](https://developers.openai.com/api/docs/deprecations) for updates. Existing `OpenAICreateResponseRequestBody.Prompt` values continue to encode as before while the API remains available.

Move the prompt content and variable substitution into your application. Pass reusable guidance as a developer message and the user's input as a user message. Use `instructions` for turn-specific guidance:

```swift
let request = OpenAICreateResponseRequestBody(
    input: .items([
        .message(role: .developer, content: .text("Answer clearly and concisely.")),
        .message(role: .user, content: .text("Explain photosynthesis."))
    ]),
    instructions: "Use a short example.",
    model: "example-model"
)
```

When migrating, reproduce any model, tool, and other settings your saved prompt supplied, and render its variables in your application. Compare representative requests and responses before rollout; moving a prompt can change behavior if instructions or configuration differ. For multi-turn requests, note that `instructions` do not carry over via `previousResponseId`; see [OpenAI's text guide](https://developers.openai.com/api/docs/guides/text#version-prompts-in-code) and [prompt migration guide](https://developers.openai.com/api/docs/guides/prompting/migrate-from-prompt-object).
