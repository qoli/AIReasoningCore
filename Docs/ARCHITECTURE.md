# Architecture

## Product seam

On OS 27, the caller-facing seam is Apple's Foundation Models contract family.
`PiAILanguageModel` conforms to the native `LanguageModel`; its executor receives
the canonical transcript, enabled Tool definitions, schema and options, and emits
generation-channel events. The system Session owns Tool execution and continuation.
The package defines no parallel inference protocol, session type, transcript or
tool system. AnyLanguageModel remains the explicit compatibility seam where the
native executor contract is unavailable.

```text
App
└── FoundationModels.LanguageModelSession (OS 27)
    ├── PiAILanguageModel (native conformance)
    │   └── PiAILanguageModel.Executor (one generation request)
    │       └── PiAIProviderAdapter (session-independent)
    │           ├── ProviderRuntime (pi-ai-swift)
    │           └── optional provider asset callback
    └── FoundationModels.Tool (Host supplied)
```

`ProviderRuntime` is injected because a live runtime and a deterministic test
runtime are both real adapters. AIReasoningCore does not define another provider
interface around it. Model and Tools are peer dependencies of
`LanguageModelSession`; `PiAILanguageModel` does not own Host capabilities.

## Ownership

### Permanent Core responsibility

- `PiAILanguageModel` is the thin public model conformance. On OS 27 its executor
  maps one canonical generation request and streams channel events; the native
  Session owns orchestration. Its legacy session-shaped requirements delegate to
  the compatibility driver, without a second generation state machine.
- `PiAIProviderAdapter` and `PiAIProviderMapper` map `Transcript`, tools, schemas and
  generation options to
  pi-ai-swift DTOs, including output modality, reasoning effort, session and
  cache affinity, service tier, provider options, and native tool choice.
  Reasoning effort uses pi-ai-swift's `ProviderReasoningEffort`; model-specific
  choices and rejection of unsupported values are owned by that runtime.
- The provider adapter consumes one already-resolved request at a time. It reduces
  and validates provider events, preserves opaque assistant replay state, maps
  reasoning and usage, and delivers asset events. It never receives or reads a
  `LanguageModelSession`.

### Native executor mapping

The native path reuses the same provider event validation and usage reducer. It
maps canonical image attachments to upright PNG pixels at the ProviderRequest
boundary. Native Transcript Codable remains the caller's persistence authority;
Core does not create a reduced conversation record. Response/reasoning/Tool-call
metadata retains signed text, opaque Tool fields and terminal assistant replay.
Replayed content must still match the canonical entries, so a stale metadata copy
cannot silently override edited history.

Each executor invocation creates fresh transcript entry IDs. A logical request ID
can span multiple Tool rounds and cannot be used as their entry identity. Per-call
metadata precedes argument emission, following Apple's channel contract. Text and
reasoning stream before the first pending Tool call; calls and subsequent mixed
content are emitted in order only after the terminal provider snapshot validates.
The executor returns without executing a Tool or starting another provider round.

Capabilities come from the catalog passed by the caller. Native options map
temperature, maximum response tokens, schema, Tool calling mode and reasoning
level. `reasoningLevel(.custom(...))` uses the provider's public reasoning effort
names; unsupported sampling or reasoning values fail explicitly.

Native Tool-only instructions entries may have no text. They remain in the
canonical Transcript; enabled Tools are mapped separately, and no empty provider
system text block is emitted for such an entry.

Provider normalized terminal content must preserve upstream logical block
order. A real OpenAI Completions runtime regression covers reasoning-first
native text, second-turn replay, Tool continuation and Codable restoration.
Partial deltas do not yet expose every upstream block identity; metadata-only
and interleaved-block limitations remain explicit in UPSTREAM_GATES.md.

On the installed Xcode 27.0 SDK, public ResponseStream snapshots are buffered until
the executor returns even though the canonical Session transcript changes live.
Hosts can observe that native transcript for presentation; the executor and
Session remain the generation and continuation owners. See UPSTREAM_GATES.md
for the direct-framework gated reproduction and its verification limits.

### Current compatibility responsibility

`SessionCompatibilityDriver` is the single transitional implementation of behavior
forced into a model adapter by AnyLanguageModel's Foundation Models 26-style
`LanguageModel.respond(within:)` contract. It owns request-context resolution, Tool
snapshot selection and execution, continuation rounds, Tool delegate decisions,
session-facing cancellation, transcript checkpoints, and the Tool-round policy.

Non-streaming and streaming responses use the same driver state machine. The
non-streaming interface collects its terminal result; the streaming interface
exposes the same run's snapshots. Do not add a second session loop or move this
compatibility behavior into the provider adapter.

This driver is a deletion boundary, not a new runtime interface. When
AnyLanguageModel exposes a Foundation Models 27-style executor seam, remove the
driver and connect that seam to `PiAIProviderAdapter`; do not redesign the provider
adapter or `ProviderRuntime` mapping during that migration.

### Detailed invariants

- Tool schema mapping materializes AnyLanguageModel's local root `$ref` into
  an object before passing it to the provider runtime, preserving `$defs` for
  nested references. Unresolved, cyclic, or non-object roots fail explicitly.
  This prevents providers that read root properties from receiving an empty
  tool signature. It does not claim all providers preserve nested references.
- `SessionCompatibilityDriver` executes provider tool calls in both response modes
  through the tools already owned
  by `LanguageModelSession`, then returned to the same provider conversation.
  Immediately before every provider request, including a continuation after a
  tool round, Core resolves AnyLanguageModel's immutable request context. The
  context supplies that request's transient instructions, transcript view and
  Tool instances. Calls emitted by the request execute against those exact Tool
  instances; only the following provider request resolves the dynamic body
  again. In-flight assistant replay and tool outputs are appended to the newly
  resolved transcript view without persisting dynamic instructions as history.
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
- The upstream 0.16 synchronization supplies the same reasoning,
  cancellation and immutable per-request context seams. Dynamic composition
  preserves component whitespace and excludes old instructions from dynamic
  history. Adoption does not change the driver/provider ownership above or
  introduce an executor contract; published integration status is tracked in
  `UPSTREAM_GATES.md`.
- Reasoning uses the FM27-shaped `Transcript.Entry.reasoning`
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
- Provider usage is projected onto the Foundation Models 27-shaped
  `LanguageModelSession.Usage`. Apple's input total includes every transcript
  input token, whereas pi-ai-swift exposes provider-normalized input, cache-read
  and cache-write details. Core therefore derives Apple's inclusive input count
  from reported total minus output, falling back to the sum of the three input
  buckets when a total is absent; cache-read tokens also populate
  `cachedTokenCount`. Output and reasoning counts map directly to their
  corresponding fields.
  Provider updates within one request are cumulative snapshots, while separate
  provider requests made for Tool rounds are added into one logical response.
  Streaming snapshots therefore carry cumulative response usage.
  AnyLanguageModel owns session-lifetime accumulation; Core does not maintain a
  second session counter. Provider-only cost, reported-total and raw metadata
  fields remain at the provider seam until a consumer demonstrates a stable
  metadata contract.
- AnyLanguageModel currently creates response transcript entries with empty
  asset IDs. Core therefore does not invent an asset reference or persistence
  layer; asset-only responses remain unrepresentable until the upstream contract
  grows an asset seam.

## Host ownership

Conversation persistence and external capabilities are outside this package.
The Host composes any browser, filesystem, HTTP, shell, MCP, or other capability
as an `AnyLanguageModel.Tool` alongside `PiAILanguageModel`. Tests use a minimal
deterministic Tool only to verify the provider continuation loop.

Model context capacity is also Host configuration, not a
`LanguageModelSession` property. A Host may resolve an optional capacity from a
provider catalog or a concrete Apple model and pass it to its context-management
layer. Session-lifetime usage is accounting history, not the current transcript's
context occupancy, and must not be used directly as a compaction-pressure ratio.

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

Compatibility Tool output conversion is owned by AnyLanguageModel's ordinary
`Tool.makeOutputSegments` helper. Core consumes its documented Compatibility SPI,
which preserves typed Prompt image attachments and structured/String precedence;
it no longer repeats those output-type decisions in the driver.
