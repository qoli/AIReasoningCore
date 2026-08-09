#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"
PATCH_DIR="$ROOT/Patches/iSH"
SERIES="$PATCH_DIR/series"

fail() {
    printf '%s\n' "AIReasoningCore iSH source packaging failed: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: package-ish-source.sh /absolute/output.tar.gz"
OUTPUT=$1
case "$OUTPUT" in
    /*) ;;
    *) fail "output path must be absolute" ;;
esac

[ "$(git -C "$ROOT/Upstreams/iSH" rev-parse HEAD)" = "$ISH_COMMIT" ] ||
    fail "iSH is not at the pinned commit"
index=$(mktemp "${TMPDIR:-/tmp}/ai-reasoning-ish-index.XXXXXX")
rm -f "$index"
GIT_INDEX_FILE="$index" git -C "$ROOT/Upstreams/iSH" read-tree "$ISH_COMMIT"
while IFS= read -r patch; do
    case "$patch" in ""|'#'*) continue ;; esac
    GIT_INDEX_FILE="$index" git -C "$ROOT/Upstreams/iSH" apply \
        --cached --whitespace=error-all "$PATCH_DIR/$patch"
done < "$SERIES"
expected_hash=$(GIT_INDEX_FILE="$index" git -C "$ROOT/Upstreams/iSH" diff --cached --binary |
    shasum -a 256 | awk '{ print $1 }')
rm -f "$index"
actual_hash=$(git -C "$ROOT/Upstreams/iSH" diff --binary | shasum -a 256 | awk '{ print $1 }')
[ -z "$(git -C "$ROOT/Upstreams/iSH" ls-files --others --exclude-standard)" ] ||
    fail "iSH contains untracked changes outside the approved patch series"
[ "$actual_hash" = "$expected_hash" ] || fail "the approved iSH patch series is not applied exactly"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ish-source.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
BUNDLE="$TEMP_ROOT/AIReasoningCore-iSH-source-$ISH_COMMIT"
mkdir -p \
    "$BUNDLE/iSH" \
    "$BUNDLE/AIReasoningCore/Patches/iSH" \
    "$BUNDLE/AIReasoningCore/Integrations/iSHHost" \
    "$BUNDLE/AIReasoningCore/Scripts/toolchain" \
    "$BUNDLE/AIReasoningCore/Sources/AIReasoningiSH" \
    "$BUNDLE/AIReasoningCore/Sources/AIReasoningiSHRuntime"

tar -C "$ROOT/Upstreams/iSH" --exclude=.git -cf - . |
    tar -C "$BUNDLE/iSH" -xf -
cp "$ROOT/Upstreams.env" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/.gitmodules" "$BUNDLE/AIReasoningCore/"
while IFS= read -r patch; do
    case "$patch" in ""|'#'*) continue ;; esac
    cp "$PATCH_DIR/$patch" "$BUNDLE/AIReasoningCore/Patches/iSH/"
done < "$SERIES"
cp "$ROOT/Patches/iSH/series" "$BUNDLE/AIReasoningCore/Patches/iSH/"
tar -C "$ROOT/Integrations/iSHHost" -cf - . |
    tar -C "$BUNDLE/AIReasoningCore/Integrations/iSHHost" -xf -
tar -C "$ROOT/Sources/AIReasoningiSHRuntime" -cf - . |
    tar -C "$BUNDLE/AIReasoningCore/Sources/AIReasoningiSHRuntime" -xf -
tar -C "$ROOT/Sources/AIReasoningiSH" -cf - . |
    tar -C "$BUNDLE/AIReasoningCore/Sources/AIReasoningiSH" -xf -
tar -C "$ROOT/Scripts/toolchain" -cf - . |
    tar -C "$BUNDLE/AIReasoningCore/Scripts/toolchain" -xf -
cp "$ROOT/Scripts/build-ish-host.sh" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/LICENSE" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/NOTICE" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/Package.swift" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/Package.resolved" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/Docs/UPSTREAMS.md" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/Docs/ISH-COMPLIANCE.md" "$BUNDLE/AIReasoningCore/"

mkdir -p "$(dirname "$OUTPUT")"
tar -C "$TEMP_ROOT" -czf "$OUTPUT" "$(basename "$BUNDLE")"
shasum -a 256 "$OUTPUT" >"$OUTPUT.sha256"
printf '%s\n' "Created $OUTPUT and $OUTPUT.sha256"
