#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CONTRACTS="$ROOT/AgentCLIContracts.env"

fail() {
    printf '%s\n' "AIReasoningCore Agent CLI contract verification failed: $*" >&2
    exit 1
}

[ -f "$CONTRACTS" ] || fail "missing AgentCLIContracts.env"
. "$CONTRACTS"

verify_driver_version() {
    name=$1
    version=$2
    source=$3
    case "$version" in
        ''|*[!0-9.]*) fail "$name minimum version is invalid: $version" ;;
    esac
    grep -Fq "minimumVersion: \"$version\"" "$source" ||
        fail "$name driver does not require $version"
}

verify_driver_version Codex "$CODEX_MINIMUM_VERSION" \
    "$ROOT/Sources/AIReasoningCore/CodexDriver.swift"
verify_driver_version Claude "$CLAUDE_MINIMUM_VERSION" \
    "$ROOT/Sources/AIReasoningCore/ClaudeDriver.swift"
verify_driver_version OpenCode "$OPENCODE_MINIMUM_VERSION" \
    "$ROOT/Sources/AIReasoningCore/OpenCodeDriver.swift"

printf '%s\n' "AIReasoningCore Agent CLI protocol contracts passed."
