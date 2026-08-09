#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURE="$ROOT/Tests/CLIIntegration/Fixtures/codex-hang.sh"
REQUEST="$ROOT/Tests/CLIIntegration/Fixtures/stream-request.json"

swift build --package-path "$ROOT" --product ai-reasoning >/dev/null
BIN=$(swift build --package-path "$ROOT" --show-bin-path)/ai-reasoning
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-sigint.XXXXXX")
PID=

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

"$BIN" chat \
    --backend codex \
    --input "$REQUEST" \
    --executable "$FIXTURE" \
    --cwd "$TEMP_ROOT" \
    --timeout-seconds 10 \
    >"$TEMP_ROOT/stdout" \
    2>"$TEMP_ROOT/stderr" &
PID=$!

attempt=0
while [ ! -s "$TEMP_ROOT/stdout" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
done

kill -INT "$PID"
set +e
wait "$PID"
EXIT_CODE=$?
set -e
PID=

[ "$EXIT_CODE" -eq 130 ] || {
    printf '%s\n' "Expected SIGINT exit 130, got $EXIT_CODE" >&2
    exit 1
}
grep -Fq 'data: {' "$TEMP_ROOT/stdout"
grep -Fq '"code":"cancelled"' "$TEMP_ROOT/stdout"
if grep -Fq 'data: [DONE]' "$TEMP_ROOT/stdout"; then
    printf '%s\n' "Cancelled stream must not emit [DONE]" >&2
    exit 1
fi

printf '%s\n' "AIReasoningCore CLI SIGINT verification passed."
