# AIReasoningCore

AIReasoningCore is a native Swift AI runtime for iOS and macOS. Its public model
is `PiAILanguageModel`, which conforms directly to
`AnyLanguageModel.LanguageModel` and is used through `LanguageModelSession`.

The package deliberately contains no coding sandbox, shell, CLI-agent bridge,
iSH runtime, provider compatibility server, or second language-model protocol.

## Modules

The package ships one library target:

```text
AIReasoningCore
├── PiAILanguageModel
├── Provider mapping
├── Conversation persistence
├── Native tools
│   ├── HTTP
│   ├── Web read
│   ├── Image generation
│   └── Document read/write
└── Interactive tools
    ├── Browser operation
    └── Asset management
```

Browser behavior is injected by the app through `BrowserOperator`.

## Development setup

Until `pi-ai-swift` has a remote and version tag, both repositories must be
siblings:

```text
Github/
├── AIReasoningCore/
└── pi-ai-swift/
```

Then run:

```bash
swift test
```

The sibling dependency is a development-only publication gate. Do not publish
AIReasoningCore while `Package.swift` uses `.package(path: "../pi-ai-swift")`.

## Provider runtime status

`PiAILanguageModel` accepts an injected `PiAIProviderRuntime.ProviderRuntime`.
The adapter, mapping, structured output, non-stream tool loop, persistence and
tooling are implemented and tested with a deterministic runtime.

The current `pi-ai-swift` checkout does not yet ship a concrete live generation
runtime. Consequently, AIReasoningCore does not claim live provider generation.
Codex OAuth availability in `pi-ai-swift` is not evidence of generation support.

## Known AnyLanguageModel 0.9.0 limits

- Streaming snapshots cannot carry tool-call or tool-output transcript entries.
  AIReasoningCore therefore fails explicitly when a provider emits tool calls
  during `streamResponse`; it does not switch silently to non-streaming.
- The session stream wrapper does not propagate caller termination to the model
  stream, so provider-request cancellation is not claimed.
- Session-generated response transcript entries always use empty asset IDs.
  Provider assets are persisted to `AssetStore`, outside `Transcript`.
- Provider response IDs, reasoning signatures, usage and opaque provider state
  have no representation in `Transcript`; persistent provider continuation
  remains a provider-runtime responsibility.

## License

GPL-3.0-or-later. See `LICENSE` and `NOTICE`.
