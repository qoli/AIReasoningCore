#!/bin/sh
set -eu

fail() {
    printf '%s\n' "AIReasoningCore iSH release compliance failed: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] ||
    fail "usage: verify-ish-release-compliance.sh /absolute/source.tar.gz /absolute/notices.txt"
SOURCE=$1
NOTICES=$2
case "$SOURCE:$NOTICES" in
    /*:/*) ;;
    *) fail "source bundle and notices paths must be absolute" ;;
esac
[ -f "$SOURCE" ] || fail "source bundle is missing"
[ -f "$SOURCE.sha256" ] || fail "source bundle hash file is missing"
[ -f "$NOTICES" ] || fail "release notices file is missing"

(cd "$(dirname "$SOURCE")" && shasum -a 256 -c "$(basename "$SOURCE").sha256")
tar -tzf "$SOURCE" | grep -Eq '/iSH/LICENSE\.md$' ||
    fail "source bundle lacks iSH LICENSE.md"
tar -tzf "$SOURCE" | grep -Eq '/iSH/LICENSE\.IOS$' ||
    fail "source bundle lacks iSH LICENSE.IOS"
tar -tzf "$SOURCE" | grep -Eq '/AIReasoningCore/Patches/iSH/0001-interactive-stdin\.patch$' ||
    fail "source bundle lacks the approved patch"
grep -Eiq 'iSH' "$NOTICES" || fail "release notices do not name iSH"
grep -Eiq 'GPL' "$NOTICES" || fail "release notices do not identify the GPL"

printf '%s\n' "AIReasoningCore iSH release compliance verification passed."
