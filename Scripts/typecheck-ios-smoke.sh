#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SCRATCH_PATH=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ios-typecheck.XXXXXX")

cleanup() {
    case "$SCRATCH_PATH" in
        "${TMPDIR:-/tmp}"/ai-reasoning-ios-typecheck.*) rm -rf -- "$SCRATCH_PATH" ;;
        *) printf '%s\n' "Refusing to remove unexpected path: $SCRATCH_PATH" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

swift build \
    --package-path "$ROOT_DIR" \
    --target AIReasoningiSH \
    --triple arm64-apple-ios17.0 \
    --sdk "$IOS_SDK" \
    --scratch-path "$SCRATCH_PATH"

IOS_BUILD="$SCRATCH_PATH/arm64-apple-ios/debug"
MODULES="$IOS_BUILD/Modules"
MACRO="$SCRATCH_PATH/arm64-apple-macosx/debug/AnyLanguageModelMacros-tool"
RUNTIME_MODULE_MAP="$IOS_BUILD/AIReasoningiSHRuntime.build/module.modulemap"

[ -x "$MACRO" ] || {
    printf '%s\n' "Missing AnyLanguageModel macro executable: $MACRO" >&2
    exit 1
}
[ -f "$RUNTIME_MODULE_MAP" ] || {
    printf '%s\n' "Missing AIReasoningiSHRuntime module map: $RUNTIME_MODULE_MAP" >&2
    exit 1
}

xcrun swiftc \
    -typecheck \
    -parse-as-library \
    -swift-version 6 \
    -strict-concurrency=complete \
    -target arm64-apple-ios17.0 \
    -sdk "$IOS_SDK" \
    -I "$MODULES" \
    -Xcc -fmodule-map-file="$RUNTIME_MODULE_MAP" \
    -Xfrontend -load-plugin-executable \
    -Xfrontend "$MACRO#AnyLanguageModelMacros" \
    "$ROOT_DIR"/Smoke/AIReasoningSmoke/AIReasoningSmoke/*.swift

printf '%s\n' "AIReasoningCore iOS smoke source typecheck passed."
