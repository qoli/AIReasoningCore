# AIReasoningCore Agent Maintenance Contract

This repository and [`qoli/pi-ai-swift`](https://github.com/qoli/pi-ai-swift) are
both maintenance targets for agents working on AIReasoningCore capabilities.
They form one runtime stack, but remain separate repositories with independent
source histories, tests, commits, versions, tags, and releases.

Treat `Package.swift` as the authoritative declaration of the released
`pi-ai-swift` version consumed by this repository. A sibling checkout may be
used while developing a coordinated change, but released AIReasoningCore code
must be verified against the remote, exactly pinned package version. Never edit
or commit changes inside `.build/checkouts/pi-ai-swift`, and do not vendor the
provider implementation into this repository.

## Required Reading

Before changing architecture or crossing repository boundaries, read:

- `Docs/ARCHITECTURE.md` for the current AIReasoningCore component boundaries.
- `Docs/UPSTREAM_GATES.md` for unresolved upstream contract limitations.
- `pi-ai-swift/AGENTS.md` and `pi-ai-swift/Docs/AI_MAINTENANCE.md` in the
  pi-ai-swift source repository before changing provider behavior or syncing
  its TypeScript upstream.

Code and tests are authoritative when prose has drifted. Correct the affected
documentation in the same scoped change.

## Responsibility Boundary

### AIReasoningCore owns

- The `AnyLanguageModel.LanguageModel` and `LanguageModelSession` integration
  exposed to callers.
- `PiAILanguageModel` and translation between AnyLanguageModel transcript,
  prompt, tool, schema, and generation options and pi-ai-swift request DTOs.
- Session orchestration, tool-call execution, tool-result transcript entries,
  cancellation propagation, and caller-facing error translation.
- Conversation persistence and its associated metadata or sidecars.
- Native tools: HTTP/API, web read, image generation, and document read/write.
- Interactive tools: app-owned browser operation and asset management.
- Product-facing composition and host integration above the provider runtime.

AIReasoningCore must not implement provider wire protocols, provider
authentication, model catalogs, or provider-specific streaming semantics.

### pi-ai-swift owns

- The `ProviderRuntime` seam and provider-facing request, event, model, usage,
  credential, and authorization types.
- Provider catalogs and model metadata.
- Provider endpoints, headers, request encoding, response decoding, SSE/event
  normalization, usage normalization, and provider error semantics.
- OAuth/device authorization, token refresh, credential representation, and
  provider-specific authentication behavior.
- Provider-specific state such as reasoning signatures, cache affinity, and
  continuation metadata.
- Semantic synchronization with `earendil-works/pi/packages/ai`, including the
  upstream pin, capability mapping, fixtures, and reconstruction procedure.

pi-ai-swift must remain independent of AnyLanguageModel, session/tool
orchestration, conversation persistence, browser/document/image tools, asset
storage, product UI, and coding environments.

### AnyLanguageModel upstream owns

- The public `LanguageModel`, `LanguageModelSession`, transcript, tool, and
  structured-generation contracts that AIReasoningCore adopts.

Do not silently work around an upstream contract limitation in AIReasoningCore
or pi-ai-swift. Record the gate in `Docs/UPSTREAM_GATES.md` and make any local
compatibility decision explicit and tested.

## Choosing the Owning Repository

Classify the change before editing:

- Change pi-ai-swift when behavior differs by provider, touches the network
  protocol or authorization flow, changes provider DTOs/events, or follows a
  change in the pi TypeScript upstream.
- Change AIReasoningCore when behavior concerns AnyLanguageModel mapping,
  session lifecycle, tool execution, persistence, native/interactive tools, or
  app integration.
- Change both only when the public provider seam itself must evolve. Keep the
  seam narrow and make the pi-ai-swift change independently usable and tested.

Do not move code across the boundary merely to avoid a coordinated release.
Do not duplicate provider conditionals in AIReasoningCore or product/session
conditionals in pi-ai-swift.

## Coordinated Change Workflow

When a task crosses the seam:

1. Make and verify the owning pi-ai-swift change in its own checkout, following
   its `AGENTS.md` and `Docs/AI_MAINTENANCE.md`.
2. Commit, tag, and publish pi-ai-swift independently only when the user has
   authorized those actions.
3. Update AIReasoningCore to an exact released pi-ai-swift version in
   `Package.swift` and refresh `Package.resolved`.
4. Remove any local package override and verify AIReasoningCore against the
   remote tag before considering integration complete.
5. Report the two repository commit SHAs and the pi-ai-swift tag separately.

Never combine two repositories into one commit or treat an unpublished sibling
checkout as release evidence. Preserve unrelated worktree changes in both
repositories. Technical maintenance scope does not itself authorize commits,
tags, pushes, releases, paid API calls, or other external mutations.

## Verification

For AIReasoningCore changes, run the checks proportional to the affected seam:

```sh
swift format lint --recursive Sources Tests Package.swift
swift test
xcodebuild -scheme AIReasoningCore -destination 'generic/platform=iOS Simulator' build
git diff --check
```

For pi-ai-swift changes, follow its repository contract. At minimum this
normally includes formatting, `swift test`, `./Scripts/check-upstream.sh`, and
an iOS Simulator build. Live provider tests are opt-in integration evidence;
they do not replace deterministic fixtures and must never expose credentials.

Cross-repository changes are complete only when each repository passes its own
checks and AIReasoningCore resolves and tests the released remote pi-ai-swift
version.

## Failure and Credential Policy

- Prefer explicit typed failure. Do not add hidden provider, model, endpoint,
  protocol, authentication, or tool fallbacks unless the user explicitly asks
  for that behavior in the current task.
- Never place API keys, OAuth tokens, device codes, authorization responses, or
  credential-bearing fixtures in source, documentation, commits, or logs.
- Redact secrets from diagnostics and use environment variables or the
  platform credential store for explicitly authorized live tests.

## Scope Exclusions

AIReasoningCore and pi-ai-swift do not own a coding sandbox, shell, git/build
automation, iSH integration, or an agent CLI runtime. Do not reintroduce these
capabilities through provider adapters, tools, or convenience layers.
