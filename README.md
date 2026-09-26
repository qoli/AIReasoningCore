# AIReasoningCore

AIReasoningCore is a native Swift AI runtime for iOS and macOS. Its public model
is `PiAILanguageModel`, which conforms directly to
`AnyLanguageModel.LanguageModel` and is used through `LanguageModelSession`.

The package deliberately contains no coding sandbox, shell, CLI-agent bridge,
iSH runtime, provider compatibility server, Host capability framework, or second
language-model protocol.

## Modules

The package ships one library target:

```text
AIReasoningCore
├── PiAILanguageModel
├── AnyLanguageModel ↔ pi-ai-swift mapping
├── Provider streaming and replay state
├── Reasoning and tool-call continuation
└── Provider asset delivery callback
```

External capabilities are ordinary `AnyLanguageModel.Tool` values owned and
injected by the Host. Conversation persistence, browser/filesystem/network
access, asset storage, and asset presentation are not shipped by this package.

## Reasoning effort

Select a typed effort through the standard custom generation options seam:

```swift
var options = GenerationOptions()
options[custom: PiAILanguageModel.self] = .init(reasoningEffort: .high)
let response = try await session.respond(to: "Explain the tradeoff", options: options)
```

Use the selected `ProviderModel.supportedReasoningEfforts` from the runtime
catalog to populate a picker. `nil` leaves the provider default unchanged;
`.off` requests disabled reasoning and is offered only where representable.
Unsupported selections fail explicitly in pi-ai-swift. Provider/model mappings
remain owned by pi-ai-swift, not by the app or Core.

The typed seam is integrated with `pi-ai-swift/main`; the verified revision and
acceptance boundaries are recorded in `Docs/UPSTREAM_GATES.md`.

## iOS smoke verification

The deterministic iOS smoke app exercises the Core-owned provider adapter path:
text and structured responses, reasoning, external Tool continuation, transcript
checkpoints, replay metadata, and provider asset delivery. The Tool fixture is a
small deterministic echo implementation; it is not a shipped Host capability.
The app writes a machine-readable report that the runner reads back from the app
container:

```bash
./Scripts/test-ios-smoke-simulator.sh
```

See `Smoke/AIReasoningSmoke/README.md` for the exact acceptance and claim
boundaries. The baseline requires no API key or public network service.

## Development setup

Dependencies are resolved through Swift Package Manager. Run:

```bash
swift test
```

`pi-ai-swift` tracks the latest commit on its public `main` branch. SwiftPM
records the revision used by a particular checkout in `Package.resolved`; run
package resolution/update before compatibility verification so that snapshot
advances to the current remote `main` commit.

## Provider runtime status

`PiAILanguageModel` accepts an injected `PiAIProviderRuntime.ProviderRuntime`.
The adapter, mapping, structured output, reasoning, cancellation and Tool
continuation are verified with a deterministic runtime. The iOS Smoke app also has a
manual Live Provider Console for pi-ai-swift catalog, authorization, streaming,
function-call, image-input, and image-output acceptance. Live results remain
environmental evidence and do not replace deterministic fixtures.

## AnyLanguageModel integration limits

- The maintained fork uses FM27-shaped reasoning transcript entries and explicit
  streaming error policies. With `.preserveTranscript`, callers can retain the
  latest reasoning/tool checkpoint and await `waitForResponseCompletion()` before
  saving. No partial answer is committed as a successful response. Non-streaming
  failures have no partial checkpoint channel; tool side effects are not rolled back.
- Reasoning text, opaque signature, redaction and provider metadata survive
  transcript persistence. Answer text stays separate. Signed answer text, tool
  thought signatures, response identity and other opaque assistant state still
  lack full transcript representation.
- Session-generated response transcript entries always use empty asset IDs.
  Provider assets are delivered to the optional `PiAILanguageModel` `onAsset`
  callback. The Host owns storage, presentation, and retention; a provider asset
  fails explicitly when no callback is installed.
- Formal dependency pins consume the published maintained fork. See
  [upstream gates](Docs/UPSTREAM_GATES.md) for exact revisions and verification.

## License

GPL-3.0-or-later. See `LICENSE` and `NOTICE`.
