# Upstream Gates

These gates distinguish capabilities supplied by the current dependencies from
remaining contract limitations.

## Display reasoning (published through the maintained fork)

The maintained dependency is `qoli/AnyLanguageModel/main`. The display-reasoning
contract is published there at `9265b9d8b8d3ffbf1d28cbf5ad147105a8198f11`, based on
huggingface main `6136ad3a3c9bc418ded7d29ac37ec4862671f68a`:

- `LanguageModelSession.Response.reasoning: String?`;
- `LanguageModelSession.ResponseStream.Snapshot.reasoning: String?`;
- trailing `reasoning: String? = nil` initializer arguments, including the
  single-value response stream, preserving existing source calls;
- forwarding through stream collection and schema conversion without changing
  tool execution or Transcript types;
- a demonstrated cancellation repair: `wrapStream` checks cancellation after
  the upstream loop before committing the final response. A cancelled
  `AsyncThrowingStream` can otherwise appear to end normally and commit its
  last partial snapshot (including a reasoning-only empty answer).

The value is cumulative provider-public display text for one generation,
including its tool rounds. `nil` means no display text was supplied. It is not
opaque replay data, a token count, or model-facing conversation context.

The user authorized adopting and publishing through the fork on 2026-09-25.
[Upstream PR #264](https://github.com/huggingface/AnyLanguageModel/pull/264)
remains available for contribution upstream; its merge is not a distribution
gate for Core or SwiftChat. Package manifests and lockfiles use the published
fork, never a sibling path override. Optional future candidate verification can
still use the disposable `Scripts/check-display-reasoning.py` harness.

Local verification on 2026-09-25:

- AnyLanguageModel: 562 deterministic tests passed, including six reasoning
  tests. Live provider tests were skipped and Ollama integration tests excluded.
  An initial unfiltered run attempted localhost Ollama and failed with connection
  refused; it supplied no model response and is not acceptance evidence.
- Core: 45 tests passed; formatting, generic iOS Simulator build and whitespace
  checks passed. This includes cumulative reasoning, unchanged-answer updates,
  final collection, tool rounds/replay/execution count, stopped tools, structured
  object and scalar output, cancellation, terminal mismatch, and usage-only input.
- SwiftChat: 24 coordinator tests, macOS build, iOS Simulator build, and both
  renderer fixtures passed. Tests cover separate bridge deltas, presentation
  persistence/reopening, exclusion from follow-up model requests, and completion.
- Both integration harnesses resolved published pi-ai-swift/main
  `93fcae3a6a4c11c29dcc6f02f0f4e0ca02bf33f1`; pi-ai-swift was not modified.

Core evidence is in `/tmp/AIReasoningCore-reasoning-{test,ios,format}.log`.
App evidence is in `/tmp/SwiftChat-reasoning-{macOS-test,iOS}-final.log`.
These are local build/test results, not live provider or native-window acceptance.

Published-fork acceptance on 2026-09-25: ordinary `swift test` passed all
45 tests; recursive Swift format lint, Core iOS Simulator build, Smoke iOS
Simulator build, and whitespace checks passed. Both resolution snapshots bind
`qoli/AnyLanguageModel` to `9265b9d8b8d3ffbf1d28cbf5ad147105a8198f11` and
pi-ai-swift to `93fcae3a6a4c11c29dcc6f02f0f4e0ca02bf33f1`. Xcode builds used
`-skipMacroValidation` after verifying the fork did not alter macro sources;
no local dependency override was used.

## AnyLanguageModel contract-only product

The maintained AnyLanguageModel fork at `9265b9d8b8d3ffbf1d28cbf5ad147105a8198f11`
exposes one library product. Its contract types and provider implementations
share the same target, so importing the protocol family also compiles EventSource
and JSONSchema. SwiftNIO is now behind optional HTTP transport traits.

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

The adopted `main` revision adds cumulative `transcriptEntries` to stream snapshots.
The session commits them before stream completion and forwards consumer stream
cancellation to the model stream. AIReasoningCore now uses these entries for tool
rounds and continues through its normal `Tool.call` path.

The wrapper commits entries only after successful stream completion. If a tool
already ran and a later provider turn is cancelled or fails, its call/result
entries are absent from the session transcript. Neither Core nor the session
automatically retries that call. Apps must treat this as an interrupted operation
whose side effects may already have happened; a durable partial transcript would
require a further upstream session contract.

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

## pi-ai-swift pin update (2026-09-25)

Core and Smoke now resolve published pi-ai-swift/main
`44c079d92d6ffbcdfbef73019664d04f1ce93269`, replacing `93fcae3`.
The branch dependency remains `main`; AnyLanguageModel remains the maintained
fork at `9265b9d8b8d3ffbf1d28cbf5ad147105a8198f11`.

Pre-adoption verification passed: exact accepted upstream signals, 171 provider
runtime tests, 15 maintenance/catalog tests, 18 iOS Simulator runtime tests,
47 isolated Core consumer tests (including real-adapter response identity), and
both provider/Core Simulator builds. Only the pi-ai-swift pin changed in the
isolated consumer graph. No live provider calls were made. Completion models
without `supportsStrictMode` now omit strict projection, matching upstream.
SwiftChat has its own resolution snapshot and requires a separate update.

After adopting the pin in the real checkout, all 45 Core tests passed; Core
and Smoke generic iOS Simulator builds, recursive Swift formatting, and
whitespace checks passed. Both lockfiles changed only the pi-ai-swift revision.

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
as `60d47d489435fca8f2737d1ebc7d6d78505a881d`. Both Core resolution
snapshots contained that commit at acceptance; the current integration resolves
pi-ai-swift `44c079d92d6ffbcdfbef73019664d04f1ce93269`. SwiftChat's own resolution and product
acceptance remain separate evidence.

## Typed reasoning effort integration (resolved)

Core adopts `ProviderReasoningEffort` and model-specific
`supportedReasoningEfforts` from pi-ai-swift. The Smoke picker uses catalog
choices and resets to provider default when the user changes provider or model.
It does not hard-code the selectable effort levels.

The 2026-09-20 remote-main integration was verified against published
pi-ai-swift commit `d0fb08df6cad382c336b229fe4ebb56956537664`. Both
`Package.resolved` snapshots resolved that exact revision at the time. The current integration
resolves `44c079d92d6ffbcdfbef73019664d04f1ce93269`. The package
declarations continue to track `main`, with no sibling package override.

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
