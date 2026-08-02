# AIReasoningCore

AIReasoningCore exposes Codex CLI and Claude Code as native
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

`ClaudeLanguageModel` has the same configuration shape. Images use
AnyLanguageModel `Transcript.ImageSegment`; structured generation uses
`@Generable` and `respond(to:generating:)`. The model reconstructs every
generation deterministically from `LanguageModelSession.transcript`; its
subprocess conversation is always ephemeral.

Codex requires CLI 0.146.0 or newer. Claude requires Claude Code 2.1.85 or
newer. Missing executables, old versions, tool-bearing Swift sessions,
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
  --backend codex \
  --input request.json \
  --executable /opt/homebrew/bin/codex \
  --cwd /absolute/readable/root \
  --timeout-seconds 120
```

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

## iOS smoke app

[`AIReasoningSmoke`](Smoke/AIReasoningSmoke) is an iOS 17 SwiftUI project that
uses this repository as a local Swift package. It exercises explicit
Codex/Claude/AnyLanguageModel selection, configuration validation, one-shot
text, true text stream, `@Generable` structured output, Photos input and
cancellation.

```bash
./Scripts/typecheck-ios-smoke.sh
./Scripts/test-ios-smoke.sh
./Scripts/test-ios-smoke-simulator.sh
```

The baseline target links the `AIReasoningiSH` dynamic bridge but not the GPL
iSH runtime. Codex and Claude therefore display typed `runtimeNotLinked` until
an integrating app explicitly links the prepared runtime. The app never
switches to another backend when the selected backend is unavailable.

For an iSH-linked app, Codex login must be completed inside that app's own iSH
root filesystem; a login in the standalone iSH app is stored in a different
container and is not shared. The smoke controller supports `codex login
status`, device-code login, API-key login over stdin, verified logout, and a
mandatory authentication preflight before Codex generation. See the
[Smoke authentication workflow](Smoke/AIReasoningSmoke/README.md#codex-authentication-in-an-ish-linked-app).

## Upstream isolation

`AnyLanguageModel` is a normal official SwiftPM dependency with no patches or
submodule. `Upstreams/iSH` is an `update=none` gitlink and is never initialized
by a normal package build.

```bash
./Scripts/verify-upstreams.sh
./Scripts/prepare-ish-integration.sh   # explicit opt-in; applies the patch
./Scripts/verify-no-ish-linkage.sh
```

The prepare command intentionally leaves only
`app/ISHShellExecutor.h` and `.m` modified inside the iSH worktree. It is
idempotent for that exact patch and rejects any other dirty state. See
[Upstream maintenance](Docs/UPSTREAMS.md) and
[iSH compliance](Docs/ISH-COMPLIANCE.md) before updating or distributing an
iSH-linked app.

## Verification

```bash
swift test
./Scripts/test-cli-sigint.sh
./Scripts/typecheck-ios-smoke.sh
./Scripts/test-ios-smoke.sh
./Scripts/verify-upstreams.sh
./Scripts/verify-no-ish-linkage.sh
```

Live provider tests are deliberately opt-in and are not run by ordinary CI.
