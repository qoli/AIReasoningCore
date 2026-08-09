# iSH distribution compliance gate

The repository and all AIReasoningCore products are licensed under
GPL-3.0-or-later. `AIReasoningiSH` remains an opt-in integration boundary: the
normal `AIReasoningCore` and `ai-reasoning` artifacts neither compile nor link
the separate OpenMinis iSH emulator/host runtime; `verify-no-ish-linkage.sh`
checks this technical boundary.

`Scripts/build-ish-host.sh` builds the pinned upstream `libiSHApp` target and
combines it with the GPL host/protocol implementation under
`Integrations/iSHHost`. It emits an opt-in XCFramework and guest supervisor
without changing the upstream `.pbxproj`. The only upstream patch is the
two-file embedding-safe system halt hook; stdin, stdout, process groups and
session multiplexing live entirely in this repository.

An app that consumes the XCFramework must also import `AIReasoningiSH`, call
`ISHEmbeddedRuntime.register(hostRuntime:)` with
`ARISHOpenMinisHostRuntimeV1()`, prepare an app-owned writable fakefs using
`ISHRootFileSystemPreparer`, and explicitly boot it with the generated `ishsv`.
No registration, rootfs or executor fallback is provided.

`AIReasoningiSHHostSmoke` demonstrates this consumer-owned target boundary. Its
end-to-end runner accepts a caller-provided fakefs archive, verifies and stages
it only into a temporary app bundle, boots the embedded runtime, and requires a
successful guest command. No rootfs image or authentication state belongs in
the repository or the corresponding-source archive.

iSH identifies its code as GPLv3, with additional terms in `LICENSE.IOS`, and
describes additional GPLv2 licensing for qualifying contributions. The root
AIReasoningCore license does not replace, broaden or reinterpret those upstream
terms. Before distributing any app that links iSH:

1. Have the release owner review GPL obligations and `LICENSE.IOS`.
2. Include the required copyright and license notices in the shipped app.
3. Publish the complete corresponding source for the precise iSH gitlink,
   approved patch, host/protocol/supervisor sources, relevant nested dependency
   sources and build instructions.
4. Keep that source available for the legally required period and ensure the
   distributed binary can be matched to its source bundle hash.
5. Run `package-ish-source.sh` and `verify-ish-release-compliance.sh` against
   the actual release artifacts.
6. Record the source bundle URL/hash and legal approval in the release record.

The scripts are mechanical gates, not legal advice. A successful script does
not replace the release owner's compliance review.
