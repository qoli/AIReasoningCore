# Upstream maintenance

`Upstreams.env` is the root version table. Updates are intentionally
asymmetric.

| Component | Integration | Current pin |
| --- | --- | --- |
| AnyLanguageModel | official SwiftPM URL, exact version, no patch | 0.9.0 / `f22b78e6b10f67e7d46c67dc59a8a35bc259fbce` |
| MacPaw/OpenAI | CLI compatibility target only, exact version | 0.5.1 / `a532be89be9a30ec003e4ba0974a52a88d26fc6d` |
| OpenMinis ish-arm64 | opt-in `update=none` submodule | `de124dd66124a15239cea1465164f74980ada245` |

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
2. Evaluate the candidate in a temporary checkout. If upstream now provides
   equivalent interactive stdin and process-group APIs, delete the root patch
   and bridge to that API.
3. Otherwise regenerate one patch limited to
   `app/ISHShellExecutor.h` and `app/ISHShellExecutor.m`.
4. Never use `git apply --3way`; patch drift rejects the candidate.
5. Update the gitlink, `ISH_COMMIT`, `ISH_VERSION`, and
   `Patches/manifest.sha256`.
6. Run `verify-upstreams.sh`. It checks the official remote, gitlink, manifest,
   clean replay and identical diff hashes across two independent replays.
7. Run `prepare-ish-integration.sh`, the bridge tests, patched ObjC compile,
   Xcode link/launch smoke and the release compliance gate.

Do not commit inside `Upstreams/iSH`. If a candidate fails, retain the previous
pin.

## Local build prerequisites

The OpenMinis Xcode build follows the upstream prerequisites, including Meson,
Ninja, libarchive, Clang and LLD. Missing prerequisites are build failures; the
verification scripts do not install or substitute tools.
