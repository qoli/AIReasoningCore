# Upstream Gates

These gates distinguish capabilities supplied by the current dependencies from
remaining contract limitations.

## Transcript reasoning (maintained fork)

The working implementation replaces the prototype `Response.reasoning` and
`Snapshot.reasoning` properties with Apple Foundation Models 27-shaped
`Transcript.Entry.reasoning` / `Transcript.Reasoning`. Snapshots and responses
carry reasoning via `transcriptEntries`; existing initializer selectors are
restored. This follows the direction requested in
[upstream PR #264](https://github.com/huggingface/AnyLanguageModel/pull/264#issuecomment-5819322352).

The maintained `qoli/AnyLanguageModel/main` now publishes this contract at
`78498ee06dc07f24d57cd660987edb354c35f33c`, replacing the prototype
`9265b9d8b8d3ffbf1d28cbf5ad147105a8198f11`. Core and Smoke resolution snapshots
adopt the published commit without local package overrides. pi-ai-swift remains
remote `main` revision `44c079d92d6ffbcdfbef73019664d04f1ce93269`.

Core creates stable reasoning entry IDs, preserves opaque signatures and provider
metadata through Codable transcript replay, and keeps redacted data out of display
segments. SwiftChat renders reasoning entries independently from answer deltas;
legacy presentation sidecars remain readable but new reasoning is persisted in
the transcript. The optional session error policy supports explicit preserve and
revert behavior. Its nil setting preserves the fork's legacy behavior; it is not
a claim of Apple's default error-policy behavior. The fork-specific
`waitForResponseCompletion()` lets callers await cancellation cleanup before save.

The provider event seam has unindexed reasoning text/signature deltas. Terminal
blocks are authoritative for signature and metadata replay. Core does not infer
provider-specific signature-fragment concatenation rules. Reasoning blocks are
identified in streaming order, with text/tool boundaries separating blocks;
terminal provider content supplies the completed representation.

Candidate verification on 2026-09-25:

- AnyLanguageModel: 587 offline tests in 59 suites passed, including built-in
  Anthropic reasoning/replay, opaque Codable data and cancellation policies.
- Core: 47 deterministic tests passed, recursive Swift format lint and whitespace
  checks passed, and the generic iOS Simulator build passed.
- SwiftChat: 29 coordinator tests, macOS build, generic iOS Simulator
  build, and both Arc CDP renderer fixtures passed.
- Core and app candidate harnesses consume the modified AnyLanguageModel source;
  Core resolves pi-ai-swift from the current published remote revision above.
  No live model calls, commits, pushes, or release publication were performed.

Evidence: `/tmp/aml-transcript-full-tests.log`, `/tmp/core-transcript-full-tests.log`,
`/tmp/core-transcript-candidate-ios.log`, `/tmp/core-transcript-format.log`,
`/tmp/swiftchat-transcript-native-test.log`, `/tmp/swiftchat-transcript-macos.log`,
`/tmp/swiftchat-transcript-ios.log`,
`/tmp/swiftchat-transcript-renderer.log`, and
`/tmp/swiftchat-transcript-generation-start.log`.

Published dependency acceptance on 2026-09-25: the ordinary checkout resolves
AnyLanguageModel `78498ee06dc07f24d57cd660987edb354c35f33c` and pi-ai-swift
`44c079d92d6ffbcdfbef73019664d04f1ce93269`. All 47 Core tests, recursive format
lint, whitespace checks, and the Core generic iOS Simulator build passed against
that remote graph. Smoke consumes the same two revisions. Logs are
`/tmp/core-transcript-publish-tests.log`, `/tmp/core-transcript-publish-ios.log`
and `/tmp/core-transcript-publish-smoke.log`. No live provider call was made.

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

The maintained fork supports explicit `.preserveTranscript` on errors/cancellation,
retaining cumulative reasoning and completed tool checkpoints without treating a
partial answer as a successful final response. Checkpoints require a representable
partial output type; scalar structured generation may defer reasoning and tool
checkpoints until answer content is representable. `.revertTranscript` removes the
request's entries. The default nil policy keeps legacy behavior. Apps must await
session response cleanup before persistence. These policies do not reverse tool
side effects or retry tools automatically. Non-streaming calls have no partial
checkpoint channel: preserve retains the prompt on failure, while revert restores
the pre-request transcript. Completed non-streaming tool effects cannot be
reconstructed from a thrown response.

Immediate tool continuation uses pi-ai-swift's terminal
`ProviderResponseSnapshot` and its opaque `ProviderAssistantMessage`. Persisted
reasoning now retains text, signature, redaction, and provider metadata. Signed
answer text, tool thought signatures, source identity, and response-level metadata
still lack complete transcript representation; full opaque assistant-state replay
across a reconstructed session is therefore not claimed.

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
