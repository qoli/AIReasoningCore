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
- Tool schema mapping materializes AnyLanguageModel's local root `$ref` into
  an object before passing it to the provider runtime, preserving `$defs` for
  nested references. Unresolved, cyclic, or non-object roots fail explicitly.
  This prevents providers that read root properties from receiving an empty
  tool signature. It does not claim all providers preserve nested references.
- Non-streaming provider tool calls are executed through the tools already owned
  by `LanguageModelSession`, then returned to the same provider conversation.
  Mixed text/tool turns retain content order, including text between tool calls.
  They are persisted as adjacent response/toolCalls entries; replay combines
  adjacent assistant entries into one provider message, ending at a prompt,
  instructions entry, or tool output. Tool calls execute in their start order.
  Each provider turn must include a terminal `ProviderResponseSnapshot` before
  completion. Core validates that snapshot against the streamed text, tool calls,
  identity and finish reason, then uses its `ProviderAssistantMessage` for the
  immediate tool continuation so signed text, reasoning signatures, tool thought
  signatures, namespaces and provider replay metadata remain intact.
- Streaming tool calls use the same validated terminal response and tool resolver.
  Snapshots carry completed tool-round transcript entries cumulatively; their
  content represents only the current provider round. The session appends those
  entries before the final response when the stream completes. The immediate
  continuation retains the provider's opaque assistant message.
- Structured streaming snapshots may contain partial JSON. Final structured
  responses must pass complete JSON validation before conversion to the requested
  type; truncated JSON is rejected even if the partial parser could repair it.
- Display reasoning uses the proposed AnyLanguageModel `Response.reasoning`
  and `ResponseStream.Snapshot.reasoning` optional string contract (publication
  gate below). It accumulates the nonempty `reasoningDelta` strings in event
  order across every provider round of one generation, without inserted separators.
  A new generation starts at `nil`. Reasoning-only updates yield snapshots even
  when answer text is unchanged. Answer content remains scoped to its provider
  round as before. Before structured fields arrive, an empty structure is used
  only if the requested partial type can represent it; otherwise reasoning is
  retained until a representable answer snapshot exists. Reasoning never enters
  JSON parsing, transcript entries, or provider-message reconstruction.
- Display reasoning does not expose `reasoningSignatureDelta`, terminal opaque
  metadata, redacted payloads, or usage counts. The validated terminal snapshot
  remains the sole source for immediate tool-continuation replay. App-owned
  presentation persistence is separate from model-facing transcript persistence.
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
- a provider omits, duplicates, reorders or contradicts its terminal response snapshot;
- a tool name is unknown;
- a provider emits an asset without an `AssetStore`;
- a URL uses a scheme outside the configured allowed schemes;
- a document path escapes its configured root;
- a persisted schema version is unsupported.

## Excluded system

Coding sandbox behavior is outside this repository. The rewritten package does
not contain shell, git, build automation, CLI-agent drivers, iSH, root filesystems
or compatibility servers.
