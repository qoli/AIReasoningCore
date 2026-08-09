#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'codex-cli 0.146.0'
    exit 0
fi
if [ "${1:-}" = "mcp" ]; then
    printf '%s\n' '[]'
    exit 0
fi

while IFS= read -r line; do
    case "$line" in
        *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{"userAgent":"fixture"}}'
            ;;
        *'thread/start'*|*'thread\/start'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-fixture"}}}'
            ;;
        *'turn/start'*|*'turn\/start'*)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-fixture"}}}'
            sleep 30
            ;;
    esac
done
