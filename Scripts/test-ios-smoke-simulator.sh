#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
project_path="$repository_root/Smoke/AIReasoningSmoke/AIReasoningSmoke.xcodeproj"
scheme="AIReasoningSmoke"
bundle_id="org.aireasoningcore.smoke"
artifact_directory="$repository_root/Artifacts/Smoke"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/AIReasoningSmoke.XXXXXX")"
screenshot_temporary_path=""

cleanup() {
  if [[ -n "$screenshot_temporary_path" && -f "$screenshot_temporary_path" ]]; then
    rm -f -- "$screenshot_temporary_path"
  fi
  if [[ -n "$derived_data" && -d "$derived_data" ]]; then
    rm -rf -- "$derived_data"
  fi
}
trap cleanup EXIT

mkdir -p "$artifact_directory"

simulator_id="${SMOKE_SIMULATOR_UDID:-}"
if [[ -z "$simulator_id" ]]; then
  simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')"
fi
if [[ -z "$simulator_id" ]]; then
  print -u2 "No available iPhone Simulator was found."
  exit 1
fi
screenshot_temporary_path="${TMPDIR:-/tmp}/AIReasoningSmoke-$simulator_id.png"

print "Building $scheme for Simulator $simulator_id"
xcodebuild \
  -quiet \
  -project "$project_path" \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

app_path="$derived_data/Build/Products/Debug-iphonesimulator/AIReasoningSmoke.app"
if [[ ! -d "$app_path" ]]; then
  print -u2 "Built app was not found at $app_path"
  exit 1
fi

xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl install "$simulator_id" "$app_path"
xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id"

data_container="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
report_path="$data_container/Documents/SmokeReport.json"

for _ in {1..60}; do
  if [[ -f "$report_path" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "$report_path" ]]; then
  print -u2 "SmokeReport.json was not produced within 60 seconds."
  xcrun simctl spawn "$simulator_id" log show --last 2m \
    --predicate 'process == "AIReasoningSmoke"' --style compact || true
  exit 1
fi

cp "$report_path" "$artifact_directory/SmokeReport.json"
sleep 1
xcrun simctl io "$simulator_id" screenshot "$screenshot_temporary_path"
cp "$screenshot_temporary_path" "$artifact_directory/Smoke.png"

passed="$(plutil -extract passed raw "$report_path")"
plutil -convert json -o - "$report_path"
if [[ "$passed" != "true" ]]; then
  print -u2 "One or more smoke checks failed."
  exit 1
fi

print "Smoke report: $artifact_directory/SmokeReport.json"
print "Smoke screenshot: $artifact_directory/Smoke.png"
