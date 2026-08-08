# Upstream maintenance

`Upstreams.env` is the root version table. Updates are intentionally
asymmetric.

| Component | Integration | Current pin |
| --- | --- | --- |
| AnyLanguageModel | official SwiftPM URL, exact version, no patch | 0.9.0 / `f22b78e6b10f67e7d46c67dc59a8a35bc259fbce` |
| MacPaw/OpenAI | CLI compatibility target only, exact version | 0.5.1 / `a532be89be9a30ec003e4ba0974a52a88d26fc6d` |
| OpenMinis ish-arm64 | opt-in `update=none` submodule | `de124dd66124a15239cea1465164f74980ada245` |
| OpenCode | external CLI; official ARM64 musl release in consumer fakefs | 1.18.15 / release asset SHA-256 in `Upstreams.env` |

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
speaks ACP stdio to an executable supplied by the consumer. The iSH smoke uses
the official `opencode-linux-arm64-musl.tar.gz` asset and records its SHA-256 in
`Upstreams.env`; the binary is never committed.

1. Verify the official release asset and update the minimum version plus full
   SHA-256 together.
2. Re-run the ACP delta, image, cancellation, malformed-wire and explicit
   structured-output rejection tests.
3. For iSH, package the pinned Alpine ARM64 `libgcc` and `libstdc++` runtime
   files recorded in `Upstreams.env`; do not substitute host libraries.
4. Run `/usr/local/bin/opencode --version` and a real ACP generation inside the
   app-owned iSH rootfs. Keep the previous pins if either fails.
5. Never add an OpenCode-to-Codex/Claude fallback or silently replace ACP with
   the completed-part `run --format json` output.

## Local build prerequisites

The opt-in host builder uses the upstream `libiSHApp` Xcode target for iOS and
iOS Simulator, plus Zig for the statically linked arm64 Linux supervisor.
Missing prerequisites are explicit build failures; scripts never install or
substitute tools.
