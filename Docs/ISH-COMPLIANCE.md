# iSH distribution compliance gate

`AIReasoningiSH` is opt-in. The normal `AIReasoningCore` and `ai-reasoning`
artifacts neither compile nor link iSH; `verify-no-ish-linkage.sh` checks this
boundary.

The pinned OpenMinis `libiSHApp` target does not compile
`app/ISHShellExecutor.m`. The consuming opt-in Xcode target must compile the
approved patched file explicitly, link the pinned iSH static libraries, and
boot the iSH root filesystem before using `AIReasoningiSH`. Do not add the file
to the upstream `.pbxproj`: keeping that target-membership injection in the
root-owned consumer project preserves upstream updateability and the approved
two-file patch boundary.

iSH identifies its code as GPLv3, with additional terms in `LICENSE.IOS`, and
describes additional GPLv2 licensing for qualifying contributions. This
repository does not reinterpret those terms. Before distributing any app that
links iSH:

1. Have the release owner review GPL obligations and `LICENSE.IOS`.
2. Include the required copyright and license notices in the shipped app.
3. Publish the complete corresponding source for the precise iSH gitlink,
   approved patch, relevant nested dependency sources and build instructions.
4. Keep that source available for the legally required period and ensure the
   distributed binary can be matched to its source bundle hash.
5. Run `package-ish-source.sh` and `verify-ish-release-compliance.sh` against
   the actual release artifacts.
6. Record the source bundle URL/hash and legal approval in the release record.

The scripts are mechanical gates, not legal advice. A successful script does
not replace the release owner's compliance review.
