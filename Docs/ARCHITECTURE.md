# Architecture

## Product seam

The caller-facing seam is the AnyLanguageModel contract family. The package
defines no parallel inference protocol, session type, transcript or tool system.

```text
App
└── LanguageModelSession
    ├── PiAILanguageModel
    │   ├── ProviderRuntime (pi-ai-swift)
    │   └── optional provider asset callback
    └── AnyLanguageModel.Tool (Host supplied)
```

`ProviderRuntime` is injected because a live runtime and a deterministic test
runtime are both real adapters. AIReasoningCore does not define another provider
interface around it. Model and Tools are peer dependencies of
`LanguageModelSession`; `PiAILanguageModel` does not own Host capabilities.

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
- Reasoning uses the maintained fork's FM27-shaped `Transcript.Entry.reasoning`
  and `Transcript.Reasoning`, carried in cumulative `transcriptEntries`. Stable
  entry and text-segment IDs identify updates within a provider round; completed
  rounds retain their entries. `response.content` contains only the answer.
  Empty structured snapshots are emitted only when the requested partial type
  can represent them; scalar reasoning waits for a representable answer.
- Terminal reasoning blocks supply authoritative signatures and provider metadata.
  Signature delta events are not concatenated: their provider-dependent fragment
  semantics belong to pi-ai-swift. Core copies terminal signature strings to
  opaque UTF-8 `Data`, and preserves provider metadata and optional redaction flags
  under `pi-ai-swift.*` metadata keys. Redacted payloads have no display segments.
  Codable transcript restoration reconstructs these reasoning blocks for provider
  replay. Signed answer text and tool-specific opaque fields still have separate
  upstream representation gaps.
- Streaming checkpoints include tool calls before execution and each completed
  tool output. The explicit session `.preserveTranscript` error policy retains
  the latest checkpoint without fabricating a completed answer. Callers cancel
  their consumer and await the fork's `waitForResponseCompletion()` before saving.
  A cancellation cannot roll back external tool side effects; an unfinished tool
  has no fabricated output. The session policy and drain API belong to
  AnyLanguageModel, not the provider runtime.
- Provider `.asset` events are delivered unchanged through the optional
  `PiAILanguageModel.onAsset` callback, serially and in event order. The callback
  is awaited before the next provider event is consumed. Its error is propagated
  without retry, deduplication, or rollback. Storage, presentation and retention
  belong to the Host. Without a callback, the first asset fails explicitly.
- AnyLanguageModel currently creates response transcript entries with empty
  asset IDs. Core therefore does not invent an asset reference or persistence
  layer; asset-only responses remain unrepresentable until the upstream contract
  grows an asset seam.

## Host ownership

Conversation persistence and external capabilities are outside this package.
The Host composes any browser, filesystem, HTTP, shell, MCP, or other capability
as an `AnyLanguageModel.Tool` alongside `PiAILanguageModel`. Tests use a minimal
deterministic Tool only to verify the provider continuation loop.

## Explicit failures

The runtime fails instead of substituting another behavior when:

- the transcript cannot be represented by pi-ai-swift;
- a provider response has the wrong provider/model identity;
- a provider omits, duplicates, reorders or contradicts its terminal response snapshot;
- a tool name is unknown;
- a provider emits an asset without an asset callback.

## Excluded system

Host capability and product persistence behavior are outside this repository.
The package does not contain browser, filesystem, HTTP/Web, image-generation,
asset-management, shell, git, build-automation, CLI-agent, iSH, root-filesystem,
or compatibility-server implementations.
