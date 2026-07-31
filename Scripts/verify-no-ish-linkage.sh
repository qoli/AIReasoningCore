#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

swift build --package-path "$ROOT" --product ai-reasoning
BIN=$(swift build --package-path "$ROOT" --show-bin-path)/ai-reasoning

if nm -u "$BIN" | grep -Eq 'ISH(ShellExecutor|Agent)|ARISH'; then
    printf '%s\n' "AIReasoningCore linkage verification failed: ai-reasoning references iSH" >&2
    exit 1
fi

if otool -L "$BIN" | grep -Ei 'libish|AIReasoningiSH'; then
    printf '%s\n' "AIReasoningCore linkage verification failed: ai-reasoning links iSH" >&2
    exit 1
fi

printf '%s\n' "AIReasoningCore linkage verification passed."
