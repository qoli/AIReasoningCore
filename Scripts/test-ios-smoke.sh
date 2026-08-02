#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/Smoke/AIReasoningSmoke/AIReasoningSmoke.xcodeproj"
DERIVED_DATA=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ios-smoke.XXXXXX")

cleanup() {
    case "$DERIVED_DATA" in
        "${TMPDIR:-/tmp}"/ai-reasoning-ios-smoke.*) rm -rf -- "$DERIVED_DATA" ;;
        *) printf '%s\n' "Refusing to remove unexpected path: $DERIVED_DATA" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme AIReasoningSmoke \
    -skipMacroValidation \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/AIReasoningSmoke.app"
[ -d "$APP_PATH" ] || {
    printf '%s\n' "Missing smoke app artifact: $APP_PATH" >&2
    exit 1
}
APP_BINARY="$APP_PATH/AIReasoningSmoke"
[ -x "$APP_BINARY" ] || {
    printf '%s\n' "Missing smoke app executable: $APP_BINARY" >&2
    exit 1
}

if nm "$APP_BINARY" | grep -E '_OBJC_(CLASS|METACLASS)_\\$_ISHShellExecutor' >/dev/null
then
    printf '%s\n' "AIReasoningSmoke unexpectedly contains iSH implementation symbols." >&2
    exit 1
fi
if otool -L "$APP_BINARY" | grep -Ei 'libish' >/dev/null; then
    printf '%s\n' "AIReasoningSmoke unexpectedly links an iSH library." >&2
    exit 1
fi

printf '%s\n' "AIReasoningCore iOS smoke build passed."
