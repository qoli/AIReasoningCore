#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"
PATCH_DIR="$ROOT/Patches/iSH"
SERIES="$PATCH_DIR/series"

fail() {
    printf '%s\n' "AIReasoningCore upstream verification failed: $*" >&2
    exit 1
}

validate_commit() {
    case "$2" in
        *[!0-9a-f]*|"") fail "$1 commit is not lowercase hexadecimal" ;;
    esac
    [ "${#2}" -eq 40 ] || fail "$1 commit is not a full 40-character SHA"
}

validate_commit AnyLanguageModel "$ANYLANGUAGEMODEL_COMMIT"
validate_commit iSH "$ISH_COMMIT"
validate_commit MacPaw/OpenAI "$MACPAW_OPENAI_COMMIT"

grep -Fq "exact: \"$ANYLANGUAGEMODEL_VERSION\"" "$ROOT/Package.swift" ||
    fail "Package.swift does not exact-pin AnyLanguageModel $ANYLANGUAGEMODEL_VERSION"

SMOKE_PROJECT="$ROOT/Smoke/AIReasoningSmoke/AIReasoningSmoke.xcodeproj/project.pbxproj"
SMOKE_RESOLVED="$ROOT/Smoke/AIReasoningSmoke/AIReasoningSmoke.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
grep -Fq "version = $ANYLANGUAGEMODEL_VERSION;" "$SMOKE_PROJECT" ||
    fail "iOS smoke project does not exact-pin AnyLanguageModel $ANYLANGUAGEMODEL_VERSION"
grep -Fq "\"revision\" : \"$ANYLANGUAGEMODEL_COMMIT\"" "$SMOKE_RESOLVED" ||
    fail "iOS smoke Package.resolved does not pin AnyLanguageModel $ANYLANGUAGEMODEL_COMMIT"

resolve_tag() {
    git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}" |
        awk '
            NR == 1 { first = $1 }
            /\^\{\}$/ { resolved = $1 }
            END {
                if (resolved != "") {
                    print resolved
                } else {
                    print first
                }
            }
        '
}

resolved_anylanguage_commit=$(resolve_tag \
    "$ANYLANGUAGEMODEL_REMOTE" "$ANYLANGUAGEMODEL_VERSION")
[ "$resolved_anylanguage_commit" = "$ANYLANGUAGEMODEL_COMMIT" ] ||
    fail "AnyLanguageModel tag resolves to '$resolved_anylanguage_commit', expected '$ANYLANGUAGEMODEL_COMMIT'"

grep -Fq "exact: \"$MACPAW_OPENAI_VERSION\"" "$ROOT/Package.swift" ||
    fail "Package.swift does not exact-pin MacPaw/OpenAI $MACPAW_OPENAI_VERSION"
resolved_macpaw_commit=$(resolve_tag \
    "$MACPAW_OPENAI_REMOTE" "$MACPAW_OPENAI_VERSION")
[ "$resolved_macpaw_commit" = "$MACPAW_OPENAI_COMMIT" ] ||
    fail "MacPaw/OpenAI tag resolves to '$resolved_macpaw_commit', expected '$MACPAW_OPENAI_COMMIT'"

registered_url=$(git -C "$ROOT" config -f .gitmodules --get submodule.iSH.url)
[ "$registered_url" = "$ISH_REMOTE" ] ||
    fail "iSH .gitmodules URL is '$registered_url', expected '$ISH_REMOTE'"
registered_update=$(git -C "$ROOT" config -f .gitmodules --get submodule.iSH.update)
[ "$registered_update" = "none" ] ||
    fail "iSH submodule must use update=none"

mode=$(git -C "$ROOT" ls-files --stage -- Upstreams/iSH | awk 'NR == 1 { print $1 }')
[ "$mode" = "160000" ] || fail "Upstreams/iSH is not a gitlink"
gitlink=$(git -C "$ROOT" ls-files --stage -- Upstreams/iSH | awk 'NR == 1 { print $2 }')
[ "$gitlink" = "$ISH_COMMIT" ] ||
    fail "iSH gitlink is '$gitlink', expected '$ISH_COMMIT'"

(cd "$ROOT" && shasum -a 256 -c Patches/manifest.sha256)

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ish-verify.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

if git -C "$ROOT/Upstreams/iSH" rev-parse --git-dir >/dev/null 2>&1 &&
   [ "$(git -C "$ROOT/Upstreams/iSH" remote get-url origin)" = "$ISH_REMOTE" ] &&
   git -C "$ROOT/Upstreams/iSH" cat-file -e "$ISH_COMMIT^{commit}" 2>/dev/null
then
    git clone --quiet --shared --no-checkout "$ROOT/Upstreams/iSH" "$TEMP_ROOT/iSH"
    git -C "$TEMP_ROOT/iSH" remote set-url origin "$ISH_REMOTE"
else
    git clone --quiet --filter=blob:none --no-checkout "$ISH_REMOTE" "$TEMP_ROOT/iSH"
fi
git -C "$TEMP_ROOT/iSH" checkout --quiet --detach "$ISH_COMMIT"
[ "$(git -C "$TEMP_ROOT/iSH" remote get-url origin)" = "$ISH_REMOTE" ] ||
    fail "temporary iSH verification checkout does not use the official remote"

apply_and_hash() {
    while IFS= read -r patch; do
        case "$patch" in ""|'#'*) continue ;; esac
        git -C "$TEMP_ROOT/iSH" apply --check --whitespace=error-all "$PATCH_DIR/$patch"
        git -C "$TEMP_ROOT/iSH" apply --whitespace=error-all "$PATCH_DIR/$patch"
    done < "$SERIES"
    git -C "$TEMP_ROOT/iSH" diff --binary |
        shasum -a 256 |
        awk '{ print $1 }'
}

first_hash=$(apply_and_hash)
git -C "$TEMP_ROOT/iSH" reset --hard --quiet "$ISH_COMMIT"
git -C "$TEMP_ROOT/iSH" clean -ffdq
second_hash=$(apply_and_hash)
[ "$first_hash" = "$second_hash" ] ||
    fail "iSH patch replay is not deterministic"

printf '%s\n' "AIReasoningCore upstream verification passed (iSH patch-series diff $first_hash)."
