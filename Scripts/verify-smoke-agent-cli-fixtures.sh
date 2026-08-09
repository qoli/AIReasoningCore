#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CONTRACTS="$ROOT/AgentCLIContracts.env"
FIXTURES="$ROOT/Smoke/Fixtures/AgentCLI.env"

fail() {
    printf '%s\n' "AIReasoningCore Smoke Agent CLI fixture verification failed: $*" >&2
    exit 1
}

[ -f "$CONTRACTS" ] || fail "missing AgentCLIContracts.env"
[ -f "$FIXTURES" ] || fail "missing Smoke/Fixtures/AgentCLI.env"
. "$CONTRACTS"
. "$FIXTURES"

[ "$SMOKE_AGENT_CLI_SCOPE" = "test-only-consumer-supplied" ] ||
    fail "fixture scope must be test-only-consumer-supplied"
[ "$SMOKE_OPENCODE_VERSION" = "$OPENCODE_MINIMUM_VERSION" ] ||
    fail "Smoke OpenCode pin must match the verified ACP contract version"
case "$SMOKE_OPENCODE_LINUX_ARM64_MUSL_URL" in
    "https://github.com/anomalyco/opencode/releases/download/v$SMOKE_OPENCODE_VERSION/"*) ;;
    *) fail "OpenCode Smoke URL is not the pinned official release asset" ;;
esac

verify_sha256() {
    name=$1
    value=$2
    case "$value" in
        ''|*[!0-9a-f]*) fail "$name SHA-256 is not lowercase hexadecimal" ;;
    esac
    [ "${#value}" -eq 64 ] || fail "$name SHA-256 is not 64 characters"
}

verify_sha256 OpenCode "$SMOKE_OPENCODE_LINUX_ARM64_MUSL_SHA256"
verify_sha256 libgcc "$SMOKE_OPENCODE_LIBGCC_APK_SHA256"
verify_sha256 libstdc++ "$SMOKE_OPENCODE_LIBSTDCXX_APK_SHA256"
[ -n "$SMOKE_OPENCODE_LIBGCC_APK_VERSION" ] || fail "libgcc Smoke version is missing"
[ -n "$SMOKE_OPENCODE_LIBSTDCXX_APK_VERSION" ] || fail "libstdc++ Smoke version is missing"

printf '%s\n' "AIReasoningCore Smoke Agent CLI fixture manifest passed."
