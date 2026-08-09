#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"
PATCH_DIR="$ROOT/Patches/iSH"
SERIES="$PATCH_DIR/series"

fail() {
    printf '%s\n' "AIReasoningCore iSH preparation failed: $*" >&2
    exit 1
}

(cd "$ROOT" && shasum -a 256 -c Patches/manifest.sha256)

git -C "$ROOT" -c submodule.iSH.update=checkout \
    submodule update --init --recursive -- Upstreams/iSH

[ "$(git -C "$ROOT/Upstreams/iSH" rev-parse HEAD)" = "$ISH_COMMIT" ] ||
    fail "iSH checkout is not at the pinned commit $ISH_COMMIT"
[ "$(git -C "$ROOT/Upstreams/iSH" remote get-url origin)" = "$ISH_REMOTE" ] ||
    fail "iSH origin does not match $ISH_REMOTE"

expected_diff_hash() {
    index=$(mktemp "${TMPDIR:-/tmp}/ai-reasoning-ish-index.XXXXXX")
    trap 'rm -f "$index"' EXIT HUP INT TERM
    rm -f "$index"
    GIT_INDEX_FILE="$index" git -C "$ROOT/Upstreams/iSH" read-tree "$ISH_COMMIT"
    while IFS= read -r patch; do
        case "$patch" in ""|'#'*) continue ;; esac
        GIT_INDEX_FILE="$index" git -C "$ROOT/Upstreams/iSH" apply \
            --cached --whitespace=error-all "$PATCH_DIR/$patch"
    done < "$SERIES"
    GIT_INDEX_FILE="$index" git -C "$ROOT/Upstreams/iSH" diff --cached --binary |
        shasum -a 256 | awk '{ print $1 }'
    rm -f "$index"
    trap - EXIT HUP INT TERM
}

expected_hash=$(expected_diff_hash)
if ! git -C "$ROOT/Upstreams/iSH" diff --quiet ||
   [ -n "$(git -C "$ROOT/Upstreams/iSH" ls-files --others --exclude-standard)" ]; then
    actual_hash=$(git -C "$ROOT/Upstreams/iSH" diff --binary | shasum -a 256 | awk '{ print $1 }')
    if [ -z "$(git -C "$ROOT/Upstreams/iSH" ls-files --others --exclude-standard)" ] &&
       [ "$actual_hash" = "$expected_hash" ]; then
        printf '%s\n' "AIReasoningCore iSH patch series is already applied."
        exit 0
    fi
    fail "iSH checkout contains changes not produced by the approved patch series"
fi

while IFS= read -r patch; do
    case "$patch" in ""|'#'*) continue ;; esac
    git -C "$ROOT/Upstreams/iSH" apply --check --whitespace=error-all "$PATCH_DIR/$patch"
    git -C "$ROOT/Upstreams/iSH" apply --whitespace=error-all "$PATCH_DIR/$patch"
done < "$SERIES"

actual_hash=$(git -C "$ROOT/Upstreams/iSH" diff --binary | shasum -a 256 | awk '{ print $1 }')
[ "$actual_hash" = "$expected_hash" ] || fail "applied iSH patch series has an unexpected diff"

printf '%s\n' "AIReasoningCore iSH integration patch series applied."
