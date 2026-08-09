# Upstream maintenance

`Upstreams.env` contains only source and build dependencies owned by this
repository. Updates are intentionally asymmetric.

| Component | Integration | Current pin |
| --- | --- | --- |
| AnyLanguageModel | official SwiftPM URL, exact version, no patch | 0.9.0 / `f22b78e6b10f67e7d46c67dc59a8a35bc259fbce` |
| MacPaw/OpenAI | CLI compatibility target only, exact version | 0.5.1 / `a532be89be9a30ec003e4ba0974a52a88d26fc6d` |
| OpenMinis ish-arm64 | opt-in `update=none` submodule | `de124dd66124a15239cea1465164f74980ada245` |

Agent CLI executables are not upstream package dependencies. Their protocol
compatibility floor is recorded separately in `AgentCLIContracts.env`.
`Smoke/Fixtures/AgentCLI.env` contains test-only binary/runtime pins used to
reproduce opt-in Smoke rootfs validation; it is never included in the iSH
source bundle or a Swift package product.

## AnyLanguageModel update

1. Change the exact version in `Package.swift`, the iOS smoke Xcode project,
   and its version/full tag SHA in `Upstreams.env`.
2. Resolve both root and smoke-project package graphs from the official
   `https://github.com/huggingface/AnyLanguageModel.git` remote.
3. Commit both `Package.resolved` files with the verified full tag SHA.
4. Run all text-stream, image, transcript and `@Generable` tests, including
   `typecheck-ios-smoke.sh`.
5. Run the CLI golden tests and linkage verifier.
6. Keep no local patch, fork URL or submodule for this dependency.

An API migration is not complete if any required model behavior is silently
discarded.

## iSH update

The gitlink is the complete OpenMinis commit, not a locally patched commit.
The OpenMinis fork remains responsible for its own relationship to
`ish-app/ish`.

1. Start from a clean root worktree and leave the current pin intact.
2. Evaluate the candidate in a temporary checkout. The host/protocol/
   supervisor implementation belongs to `Integrations/iSHHost`, not the fork.
3. If upstream now provides an embedding-safe system halt callback, delete the
   patch and bind to that API. Otherwise regenerate the single patch limited to
   `kernel/exit.c` and `kernel/task.h`; ordinary iSH must retain `_exit(0)`.
4. Never use `git apply --3way`; patch drift rejects the candidate.
5. Update the gitlink, `ISH_COMMIT`, `ISH_VERSION`, and
   `Patches/manifest.sha256`.
6. Run `verify-upstreams.sh`. It checks the official remote, gitlink, manifest,
   clean replay and identical diff hashes across two independent replays.
7. Run `prepare-ish-integration.sh`, `build-ish-host.sh`, the runtime/bridge
   tests, an Xcode link/launch smoke and the release compliance gate.

Do not commit inside `Upstreams/iSH`. If a candidate fails, retain the previous
pin.

## OpenCode update

OpenCode is not a SwiftPM dependency, submodule, or linked app component. Core
speaks ACP stdio to an executable supplied by the consumer. The compatible ACP
version belongs to `AgentCLIContracts.env`; it does not authorize Core to
download, install, bundle, authenticate or update OpenCode.

The opt-in iSH Smoke may use the official `opencode-linux-arm64-musl.tar.gz`
asset and pinned guest libraries from `Smoke/Fixtures/AgentCLI.env`. That
manifest is test infrastructure only. The binary, libraries, rootfs and auth
state are never committed or distributed by AIReasoningCore.

1. Verify protocol compatibility and update `OPENCODE_MINIMUM_VERSION` in
   `AgentCLIContracts.env` only after the Core ACP tests pass.
2. Re-run the ACP delta, image, cancellation, malformed-wire and explicit
   structured-output rejection tests.
3. Independently update the test-only version, official asset URL and hashes in
   `Smoke/Fixtures/AgentCLI.env`; never substitute host libraries.
4. The Smoke integrator supplies the verified rootfs. Run
   `/usr/local/bin/opencode --version` and a real ACP generation inside it.
   Keep the previous pins if either fails.
5. Run `verify-agent-cli-contracts.sh` and
   `verify-smoke-agent-cli-fixtures.sh` separately; neither script downloads
   or installs a missing artifact.
6. Never add an OpenCode-to-Codex/Claude fallback or silently replace ACP with
   the completed-part `run --format json` output.

## Local build prerequisites

The opt-in host builder uses the upstream `libiSHApp` Xcode target for iOS and
iOS Simulator, plus Zig for the statically linked arm64 Linux supervisor.
Missing prerequisites are explicit build failures; scripts never install or
substitute tools.
