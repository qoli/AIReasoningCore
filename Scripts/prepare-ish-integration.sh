#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"
PATCH="$ROOT/Patches/iSH/$(sed -n '1p' "$ROOT/Patches/iSH/series")"

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
        "$PATCH" 2>/dev/null; then
        printf '%s\n' "AIReasoningCore iSH patch is already applied."
        exit 0
    fi
    fail "iSH checkout contains changes not produced by the approved patch"
fi

git -C "$ROOT/Upstreams/iSH" apply --check --whitespace=error-all \
    "$PATCH"
git -C "$ROOT/Upstreams/iSH" apply --whitespace=error-all \
    "$PATCH"

git -C "$ROOT/Upstreams/iSH" apply --reverse --check \
    "$PATCH" ||
    fail "applied iSH patch cannot be reversed cleanly"

printf '%s\n' "AIReasoningCore iSH integration patch applied."
