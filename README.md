# AIReasoningCore

AIReasoningCore exposes Codex CLI, Claude Code, and OpenCode as native
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) models. It
does not define a second AI request/result protocol. A separate
`ai-reasoning` executable provides an OpenAI-compatible
`/v1/chat/completions` JSON-file interface for testing and interoperability.

The package supports iOS 17 and macOS 14. AnyLanguageModel is exact-pinned to
0.9.0. The opt-in iSH integration is isolated from both the Core library and
the CLI.

## Swift API

Consumers import both modules and use `LanguageModelSession` directly:

```swift
import AIReasoningCore
import AnyLanguageModel

let model = CodexLanguageModel(
    configuration: .init(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        model: "your-model",
        workingDirectoryURL: URL(fileURLWithPath: "/absolute/readable/root")
    )
)
let session = LanguageModelSession(model: model)

let response = try await session.respond(to: "Summarize this note")
print(response.content)

for try await snapshot in session.streamResponse(to: "Write one sentence") {
    print(snapshot.content)
}
```

`ClaudeLanguageModel` and `OpenCodeLanguageModel` have the same configuration
shape. Images use
AnyLanguageModel `Transcript.ImageSegment`; structured generation uses
`@Generable` and `respond(to:generating:)`. The model reconstructs every
generation deterministically from `LanguageModelSession.transcript`; its
subprocess conversation is always ephemeral.

Codex requires CLI 0.146.0 or newer. Claude requires Claude Code 2.1.85 or
newer. OpenCode requires 1.18.15 or newer and uses ACP stdio for real text
deltas and base64 image blocks. ACP v1 has no lossless structured-output field,
so OpenCode `@Generable` requests fail explicitly instead of injecting a JSON
prompt contract. Missing executables, old versions, tool-bearing Swift sessions,
unsupported generation options, corrupt images, protocol drift, timeout and
cancellation are typed failures.

## CLI

Build the compatibility executable:

```bash
swift build --product ai-reasoning
```

Run a request stored as an unmodified Chat Completions request body:

```bash
.build/debug/ai-reasoning chat \
  --backend opencode \
  --input request.json \
  --executable /absolute/path/to/opencode \
  --base-url https://api.deepseek.com/v1 \
  --provider-id deepseek \
  --api-key-env DEEPSEEK_API_KEY \
  --cwd /absolute/readable/root \
  --timeout-seconds 120
```

For an explicit OpenCode-compatible provider, the three provider flags are
required together. The named API-key environment variable must already be set;
the credential is never accepted as a CLI flag or placed in `request.json`.
The request model uses `provider/model`, for example
`deepseek/deepseek-v4-flash`. Omitting any required provider value fails before
the OpenCode subprocess starts.

For `--backend openai`, set `OPENAI_API_KEY`; `--base-url` may select another
OpenAI-compatible HTTP endpoint. `--output response.out` redirects protocol
bytes to a file. Logs remain on stderr.

- `stream: false` emits one Chat Completion JSON object.
- `stream: true` emits Chat Completion SSE chunks followed by
  `data: [DONE]`.
- A failure after streaming begins emits an error SSE event, omits `[DONE]`
  and exits nonzero.
- Non-stream function tools are passive: the response contains `tool_calls`;
  the caller executes them and submits a later request containing the tool
  result.

The OpenAI backend passes supported fields through MacPaw/OpenAI 0.5.1.
Codex/Claude support text, images, `json_object`, `json_schema`, true text
streaming and non-stream passive function calls. Their CLIs do not expose
lossless temperature, top-p or token-limit controls, so those fields fail
explicitly for these two backends. `stream + tools`,
`stream_options.include_usage`, audio/file content and unknown fields also
fail explicitly. No backend, model, modality or execution-mode fallback is
performed.

OpenCode supports text, images, and true text streaming through ACP. Because
ACP v1 does not carry an output schema, CLI `response_format` and passive
function tools are explicit unsupported-parameter errors for this backend.
`--pure`, disabled formatter/LSP/autoupdate, and deny-all tool permissions keep
the subprocess consumer-neutral and non-agentic.

## iOS smoke app

[`AIReasoningSmoke`](Smoke/AIReasoningSmoke) is an iOS 17 SwiftUI project that
uses this repository as a local Swift package. It exercises explicit
Codex/Claude/OpenCode/AnyLanguageModel selection, configuration validation, one-shot
text, true text stream, `@Generable` structured output, Photos input and
cancellation.

```bash
./Scripts/typecheck-ios-smoke.sh
./Scripts/test-ios-smoke.sh
./Scripts/test-ios-smoke-simulator.sh
```

All AIReasoningCore products are licensed under GPL-3.0-or-later. The baseline
target links `AIReasoningiSH` but does not embed the separate OpenMinis iSH
emulator/host runtime. Codex and Claude therefore display typed
`runtimeNotLinked` until an integrating app explicitly links, registers and
boots the generated host.
`runtimeNotBooted` distinguishes a linked host from a prepared writable rootfs.
The app never switches backend when the selected backend is unavailable.

For an iSH-linked app, Codex login must be completed inside that app's own iSH
root filesystem; a login in the standalone iSH app is stored in a different
container and is not shared. The smoke controller supports `codex login
status`, device-code login, API-key login over stdin, verified logout, and a
mandatory authentication preflight before Codex generation. See the
[Smoke authentication workflow](Smoke/AIReasoningSmoke/README.md#codex-authentication-in-an-ish-linked-app).

## Upstream isolation

`AnyLanguageModel` is a normal official SwiftPM dependency with no patches or
submodule. `Upstreams/iSH` is an `update=none` gitlink and is never initialized
by a normal package build. Agent CLI executables are consumer-owned runtime
inputs, not repository dependencies.

```bash
./Scripts/verify-upstreams.sh
./Scripts/verify-agent-cli-contracts.sh
./Scripts/verify-smoke-agent-cli-fixtures.sh
./Scripts/prepare-ish-integration.sh   # explicit opt-in; applies the patch
./Scripts/build-ish-host.sh /absolute/output
./Scripts/verify-no-ish-linkage.sh
```

The prepare command intentionally leaves only `kernel/exit.c` and
`kernel/task.h` modified inside the iSH worktree. The separate build command
produces `AIReasoningiSHHost.xcframework` plus the arm64 Linux `ishsv` guest
supervisor; it does not modify the upstream Xcode project. Both commands reject
unknown dirty state. See
[Upstream maintenance](Docs/UPSTREAMS.md) and
[iSH compliance](Docs/ISH-COMPLIANCE.md) before updating or distributing an
iSH-linked app.

The repository also includes an opt-in `AIReasoningiSHHostSmoke` iOS scheme.
After supplying an explicit local fakefs archive, it proves the linked host can
boot and complete a streamed guest-process round trip on an arm64 simulator:

```bash
./Scripts/test-ish-host-smoke-simulator.sh \
  --rootfs-archive /absolute/path/to/fs.tar.gz
```

The rootfs is scoped to the generated smoke app and its simulator container; it
is not added to source control or shared with the standalone iSH app.
`Smoke/Fixtures/AgentCLI.env` records only test-only reproducibility pins; it
does not make OpenCode, its guest libraries, or any rootfs a Core deliverable.

## Verification

```bash
swift test
./Scripts/test-cli-sigint.sh
./Scripts/typecheck-ios-smoke.sh
./Scripts/test-ios-smoke.sh
./Scripts/verify-license-metadata.sh
./Scripts/verify-upstreams.sh
./Scripts/verify-agent-cli-contracts.sh
./Scripts/verify-smoke-agent-cli-fixtures.sh
./Scripts/verify-no-ish-linkage.sh
```

Live provider tests are deliberately opt-in and are not run by ordinary CI.

## License

AIReasoningCore is licensed under
[GPL-3.0-or-later](LICENSE). Third-party dependencies and opt-in components
retain their own licenses; see [NOTICE](NOTICE) and
[iSH distribution compliance](Docs/ISH-COMPLIANCE.md).
