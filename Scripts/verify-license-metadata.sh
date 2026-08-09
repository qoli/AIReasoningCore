#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
EXPECTED_GPL3_SHA256=3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986

fail() {
    printf '%s\n' "AIReasoningCore license metadata verification failed: $*" >&2
    exit 1
}

[ -f "$ROOT/LICENSE" ] || fail "missing LICENSE"
[ -f "$ROOT/NOTICE" ] || fail "missing NOTICE"

actual_hash=$(shasum -a 256 "$ROOT/LICENSE" | awk '{print $1}')
[ "$actual_hash" = "$EXPECTED_GPL3_SHA256" ] ||
    fail "LICENSE is not the verified GNU GPL version 3 text"

grep -Fq 'GPL-3.0-or-later' "$ROOT/README.md" ||
    fail "README does not declare GPL-3.0-or-later"
grep -Fq 'AnyLanguageModel 0.9.0' "$ROOT/NOTICE" ||
    fail "NOTICE does not identify AnyLanguageModel"
grep -Fq 'MacPaw/OpenAI 0.5.1' "$ROOT/NOTICE" ||
    fail "NOTICE does not identify MacPaw/OpenAI"
grep -Fq 'OpenMinis/ish-arm64' "$ROOT/NOTICE" ||
    fail "NOTICE does not identify OpenMinis/iSH"

find "$ROOT/Sources" "$ROOT/Integrations" \
    "$ROOT/Smoke/AIReasoningSmoke/AIReasoningSmoke" "$ROOT/Tests" "$ROOT/Scripts" \
    -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' -o -name '*.sh' \
    -o -name 'Makefile' -o -name 'module.modulemap' \) -print |
while IFS= read -r source; do
    grep -Fq 'SPDX-License-Identifier:' "$source" ||
        fail "missing SPDX declaration: ${source#"$ROOT/"}"
done

grep -Fq 'SPDX-License-Identifier: GPL-3.0-or-later' "$ROOT/Package.swift" ||
    fail "Package.swift does not declare GPL-3.0-or-later"

printf '%s\n' "AIReasoningCore license metadata passed."
