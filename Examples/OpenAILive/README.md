# OpenAI Live example

This example imports `AIProxy` through its public API. It provides a finite, opt-in validation function and call sites from both `MainActor` and another actor. Add the two Swift files to a separate target that depends on AIProxy; they are not SDK library sources or automatic tests.

Calling `validateLiveSession` opens a real service session. Supply an explicitly configured `OpenAIService`, raw audio chunks and an event callback when you intend to run it. There is no executable entry point, credential discovery or automatic network call. Direct and proxy service acceptance, supported codec/delegation combinations and physical-device behavior still require separate verification. Compilation alone does not establish them.

## Configure and run

Use your existing service configuration: `AIProxy.openAIService(...)` for a configured AIProxy route, or `AIProxy.openAIDirectService(...)` with credentials supplied by a trusted developer/server environment. The harness accepts that service without changing its route, authentication or TLS policy. Keep credentials outside example source and output.

The following values are supplied by your calling code: `configuredService`, `rawChunks` and the async `handleEvent` callback. The callback receives `(OpenAILiveSession, OpenAILiveEvent)` so the caller can issue supported commands when needed.

```swift
let configuration = LiveExampleConfigurations.client(format: .pcm24kHz)

let report = try await validateLiveSession(
    service: configuredService,
    configuration: configuration,
    inputChunks: rawChunks,
    chunkIntervalNanoseconds: 20_000_000,
    observationNanosecondsAfterInput: 2_000_000_000,
    consume: handleEvent
)
```

Here the caller chooses 20 ms spacing and two seconds of observation after input. Match spacing to the supplied chunks; the harness does not infer duration, resample data or simulate a microphone. It requests graceful close after the finite input and observation interval. A returned report does not by itself mean success: inspect `input.failure`, `events.failure`, `finalization.isConfirmed` and the observed counters. Nonzero output is a useful observation, not a promise about what the model will say.

`LiveExampleConfigurations.providerDefaults` sends only `model: "gpt-live-1"`. Optional audio, voice, storage and delegation fields remain absent. To choose Responses delegation, supply the backend settings yourself:

```swift
let configuration = LiveExampleConfigurations.responses(
    format: .pcm16kHz,
    backendSettings: ["model": .string(backendModel)]
)
```

The SDK also exposes `.client`, explicit `.null` delegation and a JSON configuration initializer for additional documented fields. Omission and explicit values remain distinct: `store: false` is sent when supplied. The provider currently resolves omitted or null delegation to client mode. Changing delegation mode requires a new session. Responses settings may be updated within the existing mode; backend model, tools and continuation decisions belong to the caller. See [delegation](https://developers.openai.com/api/docs/guides/live-delegation) and [session configuration](https://developers.openai.com/api/docs/guides/live-conversations).

The documented provider limits are 16,384 startup instruction tokens, at most 128 initial text messages totaling 8,192 tokens, and 500 tokens per instructions/thinking/commentary append. The SDK leaves these limits to the provider: it does not estimate tokens from character counts, truncate text or split commands automatically. Typed history supplies one `input_text` part for developer/user messages and one `output_text` part for assistant messages. [Primary WebSocket configuration and commands](https://developers.openai.com/api/reference/resources/live/primary-websocket).

## Audio ownership

One startup format applies to both input and output. Supply raw codec bytes without a WAV/container header. PCM is mono signed 16-bit little-endian and requires complete two-byte samples. The SDK transfers bytes without padding odd input, rejecting it as a media policy, or converting codecs. G.711 uses one byte per sample. The documented default is PCM at 24 kHz. [WebSocket audio formats](https://developers.openai.com/api/docs/guides/voice-websockets?api=live).

| SDK format | Rate | Raw bytes in a 20 ms chunk |
| --- | --- | --- |
| `.pcm24kHz` | 24 kHz | 960 |
| `.pcm16kHz` | 16 kHz | 640 |
| `.g711Ulaw` | 8 kHz | 160 |
| `.g711Alaw` | 8 kHz | 160 |

Capture, playback, codec conversion, permissions and audio-session activation belong to your code. The callback receives decoded output audio alongside its original event. A bounded player can consume those bytes using the configured format; this example does not instantiate a player or the optional `AudioController`.

On watchOS 10.5 and later, WebSockets are subject to Apple's low-level networking restrictions. Establish the permitted active audio-streaming context in the adopting application before opening the connection. A simulator does not enforce the same restriction. Test real hardware, phone-assisted and available direct network routes, network loss and foreground/wrist-down/background transitions. Unrestricted background networking is not promised. [Apple TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos).

## Events, completion and errors

The harness reserves one event sequence before startup, consumes it concurrently with input and waits for `start()` readiness before sending audio. It has exactly two structured workers; it does not create a task for each audio chunk or event. The callback is sequential and must return promptly and cooperate with cancellation. Dispatch UI work to the appropriate actor explicitly. `ActorCallSites.swift` demonstrates main-actor and separate-actor callers.

Every delivered event reaches the callback unchanged, including raw content, unknown types, decode diagnostics and provider errors. The example counts these observations without assembling, reordering, grouping, storing or reconciling transcripts. It does not run tools, retry commands, reconnect or continue backend work automatically. The callback may use the supplied session for caller-directed commands; do not request a second event sequence.

An established-session provider error or typed-decode diagnostic is not automatically fatal. Transport and SDK resource failures remain explicit. Configuration/setup errors throw from the harness. Once its workers start, receive, send and callback errors are retained in `events.failure` or `input.failure`; they are not printed. A worker failure aborts this example's remaining transport work. Error objects and raw events can contain caller/provider data, so select any diagnostics you intend to retain.

Normal completion calls `close()` and keeps receiving accepted events and the final event. `finalization.isConfirmed` is true only after a valid `session.closed`; a send completion is not a provider acknowledgment. Usage seconds are cumulative snapshots, and final usage remains unconfirmed if the terminal event was not received. Task cancellation or a callback failure explicitly aborts the session and may discard unread events. The structured workers are joined before the report returns; a callback that ignores cancellation can delay that return even after transport has stopped. When using the SDK directly, explicitly close or abort if you stop iterating while retaining the session. [Usage and graceful close](https://developers.openai.com/api/docs/guides/live-conversations#usage-and-graceful-close).

## Limits

Pass `OpenAILiveSessionOptions` to choose finite positive transport budgets and deadlines. Current defaults are SDK policies rather than provider limits:

| Setting | Default |
| --- | --- |
| Startup deadline, including request/auth construction | 30 seconds |
| Individual write / graceful-close deadlines | 15 seconds each |
| One incoming WebSocket message | 256 KiB |
| Pending event queue | 128 events / 512 KiB of serialized payload |
| Pending write queue | 8 messages / 128 KiB of serialized payload |

The pending write budget excludes one active write; each individual outgoing message must still fit the write byte cap. The pending event budget excludes the bounded incoming message and one reserved bounded terminal record. Base64 and JSON overhead count toward outgoing bytes. These are Live-owned queue bounds, not a total process-memory ceiling. This harness also retains the caller's finite input array; callback/player allocations are separately owned. Slow consumption or excess queued work can end a session with an explicit limit error.

## Verification scope

The intended Live minimums are iOS 15, macOS 13, watchOS 10.5 and visionOS 1. This example uses Swift 6 and the package's Swift 6.2 language/tooling baseline. A successful build with a newer toolchain does not prove compilation with Swift 6.2 itself. Platform compilation, service acceptance and physical audio/network behavior are distinct evidence.

To check external-module access, build the `AIProxy` library for the chosen platform, then typecheck both example files against that build's module directory. No `@testable` import is used:

```sh
xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -sdk "$sdkPath" -target "$targetTriple" -I "$moduleDirectory" \
  Examples/OpenAILive/LiveValidationHarness.swift \
  Examples/OpenAILive/ActorCallSites.swift
```

| SDK | Minimum-target triple |
| --- | --- |
| `watchos` | `arm64_32-apple-watchos10.5` |
| `iphoneos` | `arm64-apple-ios15.0` |
| `macosx` | `arm64-apple-macosx13.0` |
| `xros` | `arm64-apple-xros1.0` |

Protocol references were checked against the official OpenAI documentation on 2026-10-08, including the [primary WebSocket reference](https://developers.openai.com/api/reference/resources/live/primary-websocket). Actual service/device verification remains pending; this example adds no such claim.
