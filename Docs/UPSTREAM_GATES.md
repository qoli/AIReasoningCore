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

Non-streaming tool continuation within one `respond` call now uses
pi-ai-swift's terminal `ProviderResponseSnapshot` and preserves its opaque replay
metadata in a `ProviderAssistantMessage`. AnyLanguageModel's persisted
`Transcript`, however, can represent only visible assistant text and tool calls;
it cannot retain signed text, reasoning blocks, thought signatures, source
identity or response metadata when a transcript is encoded and later restored.
Core records that loss explicitly and does not claim opaque provider-state replay
across a reconstructed `LanguageModelSession`.

## AnyLanguageModel response assets

`LanguageModelSession` creates the final response transcript entry itself and
sets `assetIDs` to an empty array. Provider assets are safely written to
`AssetStore`, but they cannot be linked into that transcript entry without an
upstream contract change.

## pi-ai-swift branch distribution

The concrete built-in provider runtime now supplies catalog, authorization, wire
protocol, streaming, tool continuation, and asset events to the Smoke app. The
manual live console can exercise those capabilities without adding provider
conditionals to AIReasoningCore.

Both AIReasoningCore package declarations track the public `pi-ai-swift/main`
branch. SwiftPM still writes the exact revision selected by each resolution to
the two `Package.resolved` files; those snapshots must be refreshed and checked
against remote `main` before deterministic acceptance. There is no local package
override or release-tag requirement. Live provider results remain separate
environmental evidence because credentials, quota, and provider service state
cannot be deterministic release inputs.

## Response identity regression verification

pi-ai-swift response-start and terminal identity must retain the requested model;
a server-reported alias is separate metadata. Core's exact identity validation
remains in force. The consumer regression uses the actual custom provider runtime,
its production Chat Completions adapter, and a sanitized upstream-derived alias
fixture through `LanguageModelSession`, covering both respond and streaming. A
test-only mutation of normalized start identity must still be rejected.

Run the optional cross-repository probe from this checkout:

```sh
python3 Scripts/check-provider-identity.py --pi /Volumes/Data/Github/pi-ai-swift
```

The probe copies Core sources and its manifest to a temporary harness, replacing
only that harness's pi-ai-swift dependency with the supplied checkout. It uses
the supplied checkout's `response-rich.json` identity fixture and dummy credentials;
the transport cannot call a provider. SwiftPM may fetch build dependencies.
Neither repository's manifest, resolution snapshots, or dependency checkouts are
edited. Consumer assertions live in
`IntegrationTests/ProviderIdentity/ConsumerResponseIdentityTests.swift`.

This is local integration evidence. The repair was pushed to pi-ai-swift `main`
as `60d47d489435fca8f2737d1ebc7d6d78505a881d`; the existing package resolution
snapshots do not contain that commit. Remote-main refresh and product acceptance
remain separate follow-up work; this probe does not establish that SwiftChat has
received it.

## Typed reasoning effort integration (resolved)

Core adopts `ProviderReasoningEffort` and model-specific
`supportedReasoningEfforts` from pi-ai-swift. The Smoke picker uses catalog
choices and resets to provider default when the user changes provider or model.
It does not hard-code the selectable effort levels.

Remote-main integration was refreshed on 2026-09-20 against published
pi-ai-swift commit `d0fb08df6cad382c336b229fe4ebb56956537664`. Both
`Package.resolved` snapshots and the SwiftPM/Xcode source-control checkouts
resolve that exact revision. The package declarations continue to track `main`,
with no sibling package override.

Verification on the published revision:

- pi-ai-swift: 158 macOS tests and the pinned 11-protocol upstream check passed.
- Core: 33 macOS tests and the generic iOS Simulator build passed.
- Smoke app: generic iOS Simulator build passed with Xcode restricted to the
  resolved package versions.
- Formatting and whitespace checks passed.

The integration consumes mandatory terminal response snapshots, preserves their
signed text/reasoning/tool metadata during an immediate non-streaming tool loop,
and rejects missing or contradictory terminal state. Live OAuth and generation
were not run; deterministic compilation and tests do not establish live Kimi
service behavior.

The implementation commits remain separate: Core
`b7ff9df` integrates pi-ai-swift `d0fb08df6cad382c336b229fe4ebb56956537664`.
