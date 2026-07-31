#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"

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

if ! git -C "$ROOT/Upstreams/iSH" diff --quiet ||
   [ -n "$(git -C "$ROOT/Upstreams/iSH" status --porcelain --untracked-files=all)" ]; then
    if git -C "$ROOT/Upstreams/iSH" apply --reverse --check \
        "$ROOT/Patches/iSH/0001-interactive-stdin.patch" 2>/dev/null; then
        printf '%s\n' "AIReasoningCore iSH patch is already applied."
        exit 0
    fi
    fail "iSH checkout contains changes not produced by the approved patch"
fi

git -C "$ROOT/Upstreams/iSH" apply --check --whitespace=error-all \
    "$ROOT/Patches/iSH/0001-interactive-stdin.patch"
git -C "$ROOT/Upstreams/iSH" apply --whitespace=error-all \
    "$ROOT/Patches/iSH/0001-interactive-stdin.patch"

git -C "$ROOT/Upstreams/iSH" apply --reverse --check \
    "$ROOT/Patches/iSH/0001-interactive-stdin.patch" ||
    fail "applied iSH patch cannot be reversed cleanly"

printf '%s\n' "AIReasoningCore iSH integration patch applied."
