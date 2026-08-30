# Upstream Gates

These gates distinguish the completed AIReasoningCore rewrite from capabilities
that its current dependencies cannot yet supply.

## AnyLanguageModel contract-only product

AnyLanguageModel 0.9.0 exposes one library product. Its contract types and its
provider implementations share the same target, so importing the protocol family
also compiles EventSource, SwiftNIO, JSONSchema and PartialJSONDecoder.

AIReasoningCore source code uses the contract family but the dependency graph is
not yet contract-only. A publishable minimal runtime requires AnyLanguageModel to
ship a separate core product while preserving type identity for:

- `LanguageModel`;
- `LanguageModelSession`;
- `Transcript`, `Prompt` and `GenerationOptions`;
- `Generable`, `GeneratedContent` and `GenerationSchema`;
- `Tool` and `ToolExecutionDelegate`.

Vendoring those declarations into AIReasoningCore is rejected because it would
create a second protocol family with different Swift type identity.

## AnyLanguageModel streaming transcript

`LanguageModelSession.ResponseStream.Snapshot` cannot return transcript entries.
A conforming external model therefore cannot persist streamed tool calls and tool
outputs in the session transcript. AIReasoningCore reports
`unsupportedStreamingToolCalls`; it does not switch to `respond`.

The upstream contract needs stream snapshots or a completion value that can carry
ordered transcript entries.

The current session wrapper also drains the model stream in its own task without
propagating downstream iterator termination. Cancelling or abandoning a caller's
session stream therefore cannot reliably cancel the underlying provider request.
AIReasoningCore does not claim session-level provider cancellation until that
wrapper forwards termination.

## AnyLanguageModel response assets

`LanguageModelSession` creates the final response transcript entry itself and
sets `assetIDs` to an empty array. Provider assets are safely written to
`AssetStore`, but they cannot be linked into that transcript entry without an
upstream contract change.

## pi-ai-swift release distribution

The concrete built-in provider runtime now supplies catalog, authorization, wire
protocol, streaming, tool continuation, and asset events to the Smoke app. The
manual live console can exercise those capabilities without adding provider
conditionals to AIReasoningCore.

The distribution gate is resolved by the independently verified public
pi-ai-swift `0.2.0` tag. Both AIReasoningCore package manifests pin that exact
version, with no revision pin or local override. Deterministic acceptance has
also been rerun against the remote tag. Live provider results remain separate
environmental evidence because credentials, quota, and provider service state
cannot be deterministic release inputs.
