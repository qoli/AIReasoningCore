#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"

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
git -C "$ROOT/Upstreams/iSH" apply --reverse --check \
    "$ROOT/Patches/iSH/0001-interactive-stdin.patch" ||
    fail "the approved iSH patch is not applied"

unexpected=$(
    git -C "$ROOT/Upstreams/iSH" status --porcelain --untracked-files=all |
        awk '$2 != "app/ISHShellExecutor.h" && $2 != "app/ISHShellExecutor.m" { print }'
)
[ -z "$unexpected" ] || fail "iSH contains changes outside the approved patch"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ish-source.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
BUNDLE="$TEMP_ROOT/AIReasoningCore-iSH-source-$ISH_COMMIT"
mkdir -p "$BUNDLE/iSH" "$BUNDLE/AIReasoningCore/Patches/iSH"

tar -C "$ROOT/Upstreams/iSH" --exclude=.git -cf - . |
    tar -C "$BUNDLE/iSH" -xf -
cp "$ROOT/Upstreams.env" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/.gitmodules" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/Patches/iSH/0001-interactive-stdin.patch" \
    "$BUNDLE/AIReasoningCore/Patches/iSH/"
cp "$ROOT/Patches/iSH/series" "$BUNDLE/AIReasoningCore/Patches/iSH/"
cp "$ROOT/Docs/UPSTREAMS.md" "$BUNDLE/AIReasoningCore/"
cp "$ROOT/Docs/ISH-COMPLIANCE.md" "$BUNDLE/AIReasoningCore/"

mkdir -p "$(dirname "$OUTPUT")"
tar -C "$TEMP_ROOT" -czf "$OUTPUT" "$(basename "$BUNDLE")"
shasum -a 256 "$OUTPUT" >"$OUTPUT.sha256"
printf '%s\n' "Created $OUTPUT and $OUTPUT.sha256"
