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

## iOS smoke verification

The deterministic iOS smoke app exercises every Native Tool and Interactive
Tool on an iOS Simulator, including a visible app-owned `WKWebView`, valid image
assets, sandboxed document I/O, and a real `URLSession` transport adapter. It
writes a machine-readable report that the runner reads back from the app
container:

```bash
./Scripts/test-ios-smoke-simulator.sh
```

See `Smoke/AIReasoningSmoke/README.md` for the exact acceptance and claim
boundaries. The baseline requires no API key or public network service.

## Development setup

Dependencies are pinned through Swift Package Manager. Run:

```bash
swift test
```

`pi-ai-swift` is pinned to its public `0.2.0` release. Updating that dependency
requires its own compatibility review, release, and verification.

## Provider runtime status

`PiAILanguageModel` accepts an injected `PiAIProviderRuntime.ProviderRuntime`.
The adapter, mapping, structured output, non-stream tool loop, persistence and
tooling are verified with a deterministic runtime. The iOS Smoke app also has a
manual Live Provider Console for pi-ai-swift catalog, authorization, streaming,
function-call, image-input, and image-output acceptance. Live results remain
environmental evidence and do not replace deterministic fixtures.

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
