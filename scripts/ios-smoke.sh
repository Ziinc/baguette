#!/usr/bin/env bash
# Installs an iOS simulator build of a Baguette app (`BAGUETTE_IOS=sim mix
# release`), launches it, checks that the embedded BEAM boots and Elixir's
# first frame is drawn, and saves the app's output and a screenshot.
#
#   scripts/ios-smoke.sh <path/to/app> <bundle id> [output-dir]
set -euo pipefail

app=${1:?usage: ios-smoke.sh <path/to/app> <bundle id> [output-dir]}
bundle=${2:?usage: ios-smoke.sh <path/to/app> <bundle id> [output-dir]}
out=$(mkdir -p "${3:-ios-smoke}" && cd "${3:-ios-smoke}" && pwd)
log=$out/app.log
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")

device=$(xcrun simctl list devices available -j |
  jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .value[]
          | select(.name | startswith("iPhone"))][0].udid // empty')
[ -n "$device" ] || { echo "FAIL: no iPhone simulator is available"; exit 1; }
echo "ios-smoke: using simulator $device"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"

# The app's stdout and stderr: the host's lines and the BEAM's output.
: >"$log"
xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log" "$device" "$bundle"

fail() {
  echo "FAIL: $*"
  xcrun simctl io "$device" screenshot "$out/failure.png" >/dev/null 2>&1 || true
  xcrun simctl spawn "$device" log show --last 5m --style compact \
    --predicate "process == \"$exe\"" >"$out/system.log" 2>&1 || true
  cp ~/Library/Logs/DiagnosticReports/*.ips "$out/" 2>/dev/null || true
  echo "--- app log ---"
  cat "$log"
  exit 1
}

# wait_for <regex> <seconds>: waits for a line of the app's output.
wait_for() {
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    grep -Eq "$1" "$log" && return 0
    sleep 1
  done
  fail "no line matching /$1/ within $2 s"
}

wait_for 'baguette: release at' 120
wait_for 'baguette: first frame from Elixir' 120
sleep 3
xcrun simctl io "$device" screenshot "$out/first-frame.png" >/dev/null
xcrun simctl spawn "$device" launchctl list | grep -q "$bundle" || fail "the app exited"
grep -E 'baguette|fork' "$log" | tail -20
echo "PASS: the app boots its release and draws Elixir's first frame on iOS"
