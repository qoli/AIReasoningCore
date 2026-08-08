# AIReasoningSmoke

`AIReasoningSmoke` is an iOS 17 SwiftUI app that exercises the public
AnyLanguageModel-facing API:

- select Codex CLI, Claude CLI, OpenCode, or AnyLanguageModel's native OpenAI model;
- configure the selected execution path explicitly;
- select provider-default, high, or max reasoning effort for OpenAI-compatible
  models; high/max explicitly enable thinking through vendor `extraBody`;
- set an explicit maximum response-token budget (2048 by default), including
  reasoning tokens used by compatible thinking models;
- run one-shot text, real text stream, `@Generable` structured output, and an
  optional Photos image;
- cancel an in-flight generation and inspect its exact error.
- inspect Codex CLI authentication, complete device-code or API-key login, and
  explicitly sign out inside the app-owned iSH root filesystem.

The baseline app links `AIReasoningiSH`, but deliberately does not link the GPL
iSH host XCFramework. Therefore Codex, Claude, and OpenCode display `runtimeNotLinked`
until an integrating iOS app explicitly links and registers the prepared
OpenMinis host. A registered host without a booted writable fakefs reports
`runtimeNotBooted`.
There is no automatic switch to the native OpenAI model.

## OpenCode in an iSH-linked app

Select `OpenCode (iSH)`, use `/usr/local/bin/opencode`, and provide an explicit
OpenCode model ID. The Core driver starts `opencode acp --pure`, selects the
model with process-scoped `OPENCODE_CONFIG_CONTENT`, disables autoupdate,
formatter and LSP, and denies every tool permission. It emits only real ACP
`agent_message_chunk` text deltas. OpenCode is an independent backend and is
never used as a fallback.

The Smoke UI also accepts a provider base URL and an in-memory API key. For
example, use `deepseek/deepseek-v4-flash` with
`https://api.deepseek.com/v1`. Core creates an explicit OpenAI-compatible
provider configuration and exposes the credential only to that OpenCode child
process. A missing key, malformed URL, or model without the matching
`provider/` prefix fails before generation; the app does not switch to an
OpenCode-hosted free model.

The official ARM64 musl distribution requires the guest paths
`/lib/ld-musl-aarch64.so.1`, `/usr/lib/libstdc++.so.6`, and
`/usr/lib/libgcc_s.so.1`. The executable and these runtime libraries belong in
the consumer-owned fakefs; they are not linked into the iOS app binary or
committed to this repository. Provider credentials likewise belong to that
app-owned guest environment (OpenCode's auth store or explicit provider
environment variables). A standalone iSH app's auth store is not shared.

OpenCode ACP v1 supports text and image input but has no lossless structured
schema field. The Smoke app therefore reports a typed unsupported error for
OpenCode structured mode; it does not convert the request to prompt-only JSON.

The separate `AIReasoningiSHHostSmoke` scheme is the opt-in integration target.
It links `Artifacts/AIReasoningiSHHost.xcframework`, embeds `Artifacts/ishsv`,
and registers the host ABI. When an `iSHRootFS` directory and its verified
manifest are present in the app bundle, it copies that immutable distribution
to Application Support, boots iSH, and streams data through `/bin/cat` using the same
`ISHEmbeddedProcessExecutor` used by Codex and Claude. The baseline scheme does
not inherit any of those link settings.

API keys are held in memory only. The smoke app does not read or write a
configuration file, Keychain item, or `UserDefaults`.

## Codex authentication in an iSH-linked app

Codex authentication belongs to the root filesystem in which the CLI runs.
Signing in inside the standalone iSH app does not authenticate a separately
embedded iSH runtime because the two app containers do not share `/root`.

After an integrating app has linked the prepared iSH runtime:

1. Select `Codex CLI (iSH)` and enter the guest Codex executable and working
   directory paths.
2. Press **Refresh status**. The app executes `codex login status` in that exact
   guest filesystem.
3. Use **Sign in with device code** and follow the streamed URL/code, or enter
   an API key and press **Sign in with API key**. The key is written only to the
   Codex process stdin and the field is cleared immediately.
4. The app runs `codex login status` again and only reports success after Codex
   confirms authentication.
5. Press **Run**. A Codex request is rejected before generation when the same
   preflight status is unauthenticated or unrecognized.

**Sign out** runs `codex logout` and verifies that status changed to signed
out. Cancellation first interrupts the authentication process group and then
terminates it after the configured grace period. Authentication failures never
switch backend or execution mode.

Codex owns its authentication cache (normally under `/root/.codex` in this
iSH integration). Treat an exported app root filesystem as credential-bearing
data; do not publish it as a test fixture or source archive.

Typecheck every smoke source against the iOS 17 SDK without requiring an
installed simulator runtime:

```bash
./Scripts/typecheck-ios-smoke.sh
```

Build the complete Xcode app without signing:

```bash
./Scripts/test-ios-smoke.sh
```

Build, install, and launch on the first available iPhone simulator:

```bash
./Scripts/test-ios-smoke-simulator.sh
```

Set `SIMULATOR_UDID` to target a specific available simulator. This launch gate
is intentionally local and is not part of general CI, whose runner is not
required to have an iOS simulator runtime installed.

The Xcode build is a separate strict gate. It fails when the selected Xcode
does not have its matching iOS platform component installed; it does not
silently replace the app build with the source typecheck.

To run the actual embedded-kernel smoke, first prepare and build the pinned host,
then supply an explicit fakefs archive. The archive is never committed or
silently downloaded:

```bash
./Scripts/prepare-ish-integration.sh
./Scripts/build-ish-host.sh Artifacts
./Scripts/test-ish-host-smoke-simulator.sh \
  --rootfs-archive /absolute/path/to/fs.tar.gz
```

The last command validates archive paths, computes the same deterministic
directory digest used by `ISHRootFileSystemPreparer`, inspects the linked Mach-O
for the host/kernel symbols, launches the arm64 simulator app, and requires a
successful guest `/bin/cat` round trip from the app container.

The non-interactive script passes Xcode's `-skipMacroValidation` flag for the
AnyLanguageModel `@Generable` macro. This is bounded by the repository's exact
0.9.0/full-SHA pin and `verify-upstreams.sh`. When opening the project
interactively, review and approve Xcode's package-macro trust prompt instead.

To exercise the native baseline on a device or simulator:

1. Open `AIReasoningSmoke.xcodeproj`.
2. Select the `AIReasoningSmoke` scheme.
3. Select `AnyLanguageModel / OpenAI`.
4. Enter an explicit model, HTTP(S) base URL, API key, response-token budget,
   and prompt.
5. Select one-shot, stream, or structured mode and press Run.

For a downstream app, follow `Docs/ISH-COMPLIANCE.md`: add the generated
XCFramework and `ishsv` only to an opt-in target, register
`ARISHOpenMinisHostRuntimeV1()`, prepare a verified writable fakefs with
`ISHRootFileSystemPreparer`, and boot `ISHEmbeddedRuntime.shared`. Merely
linking the XCFramework does not boot iSH.
