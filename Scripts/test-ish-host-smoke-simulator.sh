#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/Smoke/AIReasoningSmoke/AIReasoningSmoke.xcodeproj"
HOST_XCFRAMEWORK="$ROOT_DIR/Artifacts/AIReasoningiSHHost.xcframework"
SUPERVISOR="$ROOT_DIR/Artifacts/ishsv"
BUNDLE_IDENTIFIER=org.aireasoningcore.ish-host-smoke

if [ "${1:-}" != "--rootfs-archive" ] || [ -z "${2:-}" ] || [ "$#" -ne 2 ]; then
    printf '%s\n' "usage: $0 --rootfs-archive /absolute/path/to/fs.tar.gz" >&2
    exit 64
fi
ROOTFS_ARCHIVE=$2
[ -f "$ROOTFS_ARCHIVE" ] || {
    printf '%s\n' "Missing rootfs archive: $ROOTFS_ARCHIVE" >&2
    exit 66
}
[ -d "$HOST_XCFRAMEWORK" ] || {
    printf '%s\n' "Missing host XCFramework. Run Scripts/build-ish-host.sh Artifacts first." >&2
    exit 66
}
[ -x "$SUPERVISOR" ] || {
    printf '%s\n' "Missing guest supervisor: $SUPERVISOR" >&2
    exit 66
}

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ish-host-smoke.XXXXXX")
cleanup() {
    case "$TEMP_ROOT" in
        "${TMPDIR:-/tmp}"/ai-reasoning-ish-host-smoke.*) rm -rf -- "$TEMP_ROOT" ;;
        *) printf '%s\n' "Refusing to remove unexpected path: $TEMP_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

tar -tzf "$ROOTFS_ARCHIVE" | while IFS= read -r entry; do
    case "$entry" in
        /*|../*|*/../*|*/..) printf '%s\n' "Unsafe archive entry: $entry" >&2; exit 65 ;;
    esac
done
mkdir "$TEMP_ROOT/extracted"
tar -xzf "$ROOTFS_ARCHIVE" -C "$TEMP_ROOT/extracted"
ROOTFS="$TEMP_ROOT/extracted/fs"
[ -d "$ROOTFS/data" ] && [ -f "$ROOTFS/meta.db" ] || {
    printf '%s\n' "Archive must contain fs/data and fs/meta.db." >&2
    exit 65
}
DIGEST=$(xcrun swift "$ROOT_DIR/Scripts/digest-ish-rootfs.swift" "$ROOTFS")

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
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme AIReasoningiSHHostSmoke \
    -skipMacroValidation \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath "$TEMP_ROOT/DerivedData" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH="$TEMP_ROOT/DerivedData/Build/Products/Debug-iphonesimulator/AIReasoningiSHHostSmoke.app"
DEBUG_DYLIB="$APP_PATH/AIReasoningiSHHostSmoke.debug.dylib"
[ -f "$DEBUG_DYLIB" ] || {
    printf '%s\n' "Missing linked smoke binary: $DEBUG_DYLIB" >&2
    exit 1
}
for symbol in ARISHOpenMinisHostRuntimeV1 ish_embed_boot system_halt_hook; do
    xcrun nm -gU "$DEBUG_DYLIB" | grep -F "_$symbol" >/dev/null || {
        printf '%s\n' "Linked smoke binary is missing _$symbol" >&2
        exit 1
    }
done

cp -R "$ROOTFS" "$APP_PATH/iSHRootFS"
MANIFEST="$APP_PATH/iSHRootFSManifest.plist"
plutil -create xml1 "$MANIFEST"
plutil -insert identifier -string "local-smoke" "$MANIFEST"
plutil -insert version -string "$DIGEST" "$MANIFEST"
plutil -insert sha256 -string "$DIGEST" "$MANIFEST"

xcrun simctl uninstall "$SIMULATOR_UDID" "$BUNDLE_IDENTIFIER" 2>/dev/null || true
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl launch --terminate-running-process "$SIMULATOR_UDID" "$BUNDLE_IDENTIFIER" \
    --run-ish-bootstrap-smoke
DATA_CONTAINER=$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_IDENTIFIER" data)
STATUS="$DATA_CONTAINER/Library/Application Support/iSHHostSmoke.status.json"

attempt=0
while [ "$attempt" -lt 30 ]; do
    if [ -f "$STATUS" ] && grep -F '"state":"succeeded"' "$STATUS" >/dev/null; then
        printf '%s\n' "AIReasoningiSH host boot and /bin/cat stream smoke passed on $SIMULATOR_UDID."
        exit 0
    fi
    if [ -f "$STATUS" ] && grep -F '"state":"failed"' "$STATUS" >/dev/null; then
        printf '%s\n' "Embedded guest smoke failed:" >&2
        sed -n '1,20p' "$STATUS" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done

printf '%s\n' "Timed out waiting for embedded guest smoke status: $STATUS" >&2
[ ! -f "$STATUS" ] || sed -n '1,20p' "$STATUS" >&2
exit 1
