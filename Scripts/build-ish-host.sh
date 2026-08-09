#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/Upstreams.env"

fail() {
    printf '%s\n' "AIReasoningCore iSH host build failed: $*" >&2
    exit 1
}

OUTPUT=${1:-"$ROOT/Artifacts"}
case "$OUTPUT" in
    /*) ;;
    *) fail "output directory must be absolute" ;;
esac

ISH="$ROOT/Upstreams/iSH"
PATCH="$ROOT/Patches/iSH/$(sed -n '1p' "$ROOT/Patches/iSH/series")"
[ "$(git -C "$ISH" rev-parse HEAD)" = "$ISH_COMMIT" ] || fail "iSH is not at the pinned commit"
git -C "$ISH" apply --reverse --check "$PATCH" || fail "the approved iSH patch is not applied"
unexpected=$(git -C "$ISH" status --porcelain --untracked-files=all | awk '$2 != "kernel/exit.c" && $2 != "kernel/task.h" { print }')
[ -z "$unexpected" ] || fail "iSH contains changes outside the approved patch"
command -v zig >/dev/null 2>&1 || fail "zig is required to build the arm64 Linux guest supervisor"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-reasoning-ish-host.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

make -C "$ROOT/Integrations/iSHHost/supervisor" \
    OUT_DIR="$TEMP_ROOT/supervisor" clean all

build_slice() {
    sdk=$1
    destination=$2
    slice=$3
    archive="$TEMP_ROOT/$slice/libAIReasoningiSHHost.a"
    mkdir -p "$TEMP_ROOT/$slice/objects"

    for upstream_target in libiSHApp libish libish_emu libfakefs
    do
        PATH="$ROOT/Scripts/toolchain:$PATH" xcodebuild \
            -project "$ISH/iSH.xcodeproj" \
            -target "$upstream_target" \
            -configuration Release \
            -sdk "$sdk" \
            -destination "$destination" \
            -arch arm64 \
            GUEST_ARCH=arm64 \
            CODE_SIGNING_ALLOWED=NO \
            CONFIGURATION_BUILD_DIR="$TEMP_ROOT/$slice/upstream" \
            build >/dev/null
    done

    SDK_PATH=$(xcrun --sdk "$sdk" --show-sdk-path)
    case "$sdk" in
        iphonesimulator) TARGET=arm64-apple-ios17.0-simulator ;;
        iphoneos) TARGET=arm64-apple-ios17.0 ;;
        *) fail "unsupported SDK $sdk" ;;
    esac

    for source in \
        "$ROOT/Integrations/iSHHost/ffi/ish_ffi.c" \
        "$ROOT/Integrations/iSHHost/host/ishembed.c" \
        "$ROOT/Integrations/iSHHost/host/runtime_provider.c"
    do
        object="$TEMP_ROOT/$slice/objects/$(basename "${source%.c}").o"
        xcrun --sdk "$sdk" clang \
            -target "$TARGET" -isysroot "$SDK_PATH" -O2 -DGUEST_ARM64=1 \
            -I"$ISH" -I"$ISH/vdso/arm64" \
            -I"$ROOT/Sources/AIReasoningiSHRuntime/include" \
            -I"$ROOT/Integrations/iSHHost/include" \
            -I"$ROOT/Integrations/iSHHost/protocol" \
            -I"$ROOT/Integrations/iSHHost/ffi" \
            -c "$source" -o "$object"
    done

    for required_archive in libiSHApp.a libish.a libish_emu.a libfakefs.a
    do
        [ -f "$TEMP_ROOT/$slice/upstream/$required_archive" ] ||
            fail "upstream build did not produce $required_archive for $slice"
    done

    xcrun libtool -static -o "$archive" \
        "$TEMP_ROOT/$slice/objects/ish_ffi.o" \
        "$TEMP_ROOT/$slice/objects/ishembed.o" \
        "$TEMP_ROOT/$slice/objects/runtime_provider.o" \
        "$TEMP_ROOT/$slice/upstream/libiSHApp.a" \
        "$TEMP_ROOT/$slice/upstream/libish.a" \
        "$TEMP_ROOT/$slice/upstream/libish_emu.a" \
        "$TEMP_ROOT/$slice/upstream/libfakefs.a"

    nm "$archive" | grep -Eq '[[:space:]][A-Z][[:space:]]+_system_halt_hook$' ||
        fail "combined host archive does not define system_halt_hook"

    xcrun --sdk "$sdk" clang \
        -target "$TARGET" -isysroot "$SDK_PATH" \
        -I"$ROOT/Integrations/iSHHost/include" \
        "$ROOT/Integrations/iSHHost/smoke/link_smoke.c" "$archive" \
        -framework Foundation -framework UIKit -framework CoreGraphics \
        -framework Security -lsqlite3 -lz \
        -o "$TEMP_ROOT/$slice/AIReasoningiSHHostLinkSmoke"
}

build_slice iphonesimulator 'generic/platform=iOS Simulator' simulator
build_slice iphoneos 'generic/platform=iOS' device

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/AIReasoningiSHHost.xcframework"
xcodebuild -create-xcframework \
    -library "$TEMP_ROOT/simulator/libAIReasoningiSHHost.a" \
    -headers "$ROOT/Integrations/iSHHost/include" \
    -library "$TEMP_ROOT/device/libAIReasoningiSHHost.a" \
    -headers "$ROOT/Integrations/iSHHost/include" \
    -output "$OUTPUT/AIReasoningiSHHost.xcframework" >/dev/null
cp "$TEMP_ROOT/supervisor/ishsv" "$OUTPUT/ishsv"
shasum -a 256 "$OUTPUT/ishsv" >"$OUTPUT/ishsv.sha256"

printf '%s\n' "Created $OUTPUT/AIReasoningiSHHost.xcframework and $OUTPUT/ishsv"
