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

## Typed reasoning effort integration candidate

The local candidate adopts `ProviderReasoningEffort` and model-specific
`supportedReasoningEfforts` from the coordinated pi-ai-swift candidate. The
Smoke picker uses catalog choices and resets to provider default when the user
changes provider or model. It does not hard-code the selectable effort levels.

The declared dependency remains `pi-ai-swift/main`. Until the pi-ai-swift
candidate is pushed with user authorization, this Core candidate requires a
temporary sibling dependency for local verification.
Remove that override, refresh both resolved snapshots, and run Core tests and
iOS builds against the current remote main revision before claiming integration
complete. A local sibling build is candidate evidence only.

Candidate verification (2026-09-03): Core's 24 macOS tests, its generic iOS
Simulator build, and the Smoke app build passed in a temporary copy using the
sibling pi-ai-swift source. The source checkout has no local dependency override.
The coordinated provider candidate passed 104 macOS tests and the pinned
11-protocol upstream check. Its full Simulator run hit two Keychain tests with
status -34018; excluding `KeychainProviderCredentialStoreTests` passed 102 tests.
Live OAuth was skipped and no paid provider calls were made.

Verification used candidates on separate baselines:

- AIReasoningCore baseline: `6229f1743dd7a927fdeed0c6a6a15c98db7fcd1c`.
- pi-ai-swift baseline and verified remote main: `0d603d151362fce4413b1be5a2c5c4e5ac405822`.
- The provider candidate is now committed locally as
  `8bb240969a906b832b0c3a5be432bcb88d18ce98`; it has not been pushed.
- Both Core resolved snapshots still record `0d603d151362fce4413b1be5a2c5c4e5ac405822`,
  which does not yet contain the typed effort API. A normal remote-dependency
  build of this Core candidate remains pending publication of pi-ai-swift.
