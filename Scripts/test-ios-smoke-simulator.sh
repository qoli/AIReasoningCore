#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/Smoke/AIReasoningSmoke/AIReasoningSmoke.xcodeproj"
BUNDLE_IDENTIFIER=org.aireasoningcore.smoke
DERIVED_DATA=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ios-simulator.XXXXXX")

cleanup() {
    case "$DERIVED_DATA" in
        "${TMPDIR:-/tmp}"/ai-reasoning-ios-simulator.*) rm -rf -- "$DERIVED_DATA" ;;
        *) printf '%s\n' "Refusing to remove unexpected path: $DERIVED_DATA" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

SIMULATOR_UDID=${SIMULATOR_UDID:-$(
    xcrun simctl list devices available |
        awk '/iPhone/ && /\([0-9A-F-]+\)/ {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^\([0-9A-F-]+\)$/) {
                    value = $field
                    gsub(/[()]/, "", value)
                    print value
                    exit
                }
            }
        }'
)}

[ -n "$SIMULATOR_UDID" ] || {
    printf '%s\n' "No available iPhone simulator was found." >&2
    exit 1
}
xcrun simctl list devices available | grep -F "$SIMULATOR_UDID" >/dev/null || {
    printf '%s\n' "Simulator is unavailable: $SIMULATOR_UDID" >&2
    exit 1
}

xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme AIReasoningSmoke \
    -skipMacroValidation \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/AIReasoningSmoke.app"
[ -d "$APP_PATH" ] || {
    printf '%s\n' "Missing simulator app artifact: $APP_PATH" >&2
    exit 1
}

xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl launch --terminate-running-process \
    "$SIMULATOR_UDID" "$BUNDLE_IDENTIFIER"
xcrun simctl spawn "$SIMULATOR_UDID" launchctl print system |
    grep -F "UIKitApplication:$BUNDLE_IDENTIFIER" >/dev/null || {
        printf '%s\n' "Smoke app did not remain registered after launch." >&2
        exit 1
    }

printf '%s\n' \
    "AIReasoningCore iOS simulator smoke launched on $SIMULATOR_UDID."
