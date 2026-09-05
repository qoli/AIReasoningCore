# Architecture

## Product seam

The caller-facing seam is the AnyLanguageModel contract family. The package
defines no parallel inference protocol, session type, transcript or tool system.

```text
App
└── LanguageModelSession
    ├── PiAILanguageModel
    │   └── ProviderRuntime (pi-ai-swift)
    ├── AnyLanguageModel.Tool
    │   ├── HTTPTool
    │   ├── WebReadTool
    │   ├── ImageGenerationTool
    │   ├── DocumentTool
    │   ├── BrowserTool
    │   └── AssetManagementTool
    ├── ConversationStore
    └── AssetStore
```

`ProviderRuntime` is injected because a live runtime and a deterministic test
runtime are both real adapters. AIReasoningCore does not define another provider
interface around it.

## Ownership

- `PiAILanguageModel` maps `Transcript`, tools, schemas and generation options to
  pi-ai-swift DTOs, including output modality, reasoning effort, session and
  cache affinity, service tier, provider options, and native tool choice.
  Reasoning effort uses pi-ai-swift's `ProviderReasoningEffort`; model-specific
  choices and rejection of unsupported values are owned by that runtime.
- Non-streaming provider tool calls are executed through the tools already owned
  by `LanguageModelSession`, then returned to the same provider conversation.
  Mixed text/tool turns retain content order, including text between tool calls.
  They are persisted as adjacent response/toolCalls entries; replay combines
  adjacent assistant entries into one provider message, ending at a prompt,
  instructions entry, or tool output. Tool calls execute in their start order.
- Structured streaming snapshots may contain partial JSON. Final structured
  responses must pass complete JSON validation before conversion to the requested
  type; truncated JSON is rejected even if the partial parser could repair it.
- `ConversationStore` atomically persists `Transcript` plus opaque provider state.
  Both loading and listing validate the persisted schema version.
- `AssetStore` atomically persists generated images, files and browser snapshots.
- `BrowserOperator` is an app-supplied closure over the app-owned browser.
- Host restrictions are an app-owned transport concern. Core does not expose a
  host allowlist or enforce host-based redirect rules. Apps needing those rules
  can supply their own `HTTPClient`. `HTTPAccessPolicy` only configures allowed
  URL schemes.

## Read limits

`HTTPTool` and `WebReadTool` pass their response byte limit through
`HTTPRequest.maximumResponseBytes`. The URLSession transport consumes response
bytes incrementally and cancels the task on overflow. Injected transports must
honor this limit while reading; `HTTPClient.send` additionally rejects an
oversized returned body, but cannot control memory allocated inside a custom
transport. The limit counts body bytes delivered by URLSession, rather than
trusting the Content-Length header. URLSession may maintain its own transport
buffers.

`DocumentTool` reads in chunks of at most 64 KiB and probes at most one byte past
its limit. A zero byte limit permits empty content; negative byte limits fail
explicitly. These limits do not change URL policy or redirect handling.

## Explicit failures

The runtime fails instead of substituting another behavior when:

- the transcript cannot be represented by pi-ai-swift;
- a provider response has the wrong provider/model identity;
- a tool name is unknown;
- a provider emits an asset without an `AssetStore`;
- streamed tool calls cannot be represented by AnyLanguageModel 0.9.0;
- a URL uses a scheme outside the configured allowed schemes;
- a document path escapes its configured root;
- a persisted schema version is unsupported.

## Excluded system

Coding sandbox behavior is outside this repository. The rewritten package does
not contain shell, git, build automation, CLI-agent drivers, iSH, root filesystems
or compatibility servers.
