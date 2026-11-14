#!/usr/bin/env bash
# Installs an iOS simulator build of a Baguette app (`BAGUETTE_IOS=sim mix
# release`), launches it, checks that the embedded BEAM boots and Elixir's
# first frame is drawn, taps the counter's buttons (COUNTER_TAPS=0 skips that
# for another app; EXPECT names a line it logs instead), and saves the app's
# output and screenshots.
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

# Tauri sends the app's stdout and stderr (the host's lines, the BEAM's
# output) to the unified log, tagged [stdout] and [stderr]. It is read from
# just before launch on each check: `log stream` can attach after the app's
# first lines.
since=$(date '+%Y-%m-%d %H:%M:%S')
sleep 1
xcrun simctl launch --terminate-running-process "$device" "$bundle"

# Every line since launch, untagged ones too: lines written together reach
# the log as one entry, whose later lines carry no tag.
sync_log() {
  xcrun simctl spawn "$device" log show --style compact --info --debug --start "$since" \
    --predicate "process == \"$exe\"" >"$out/system.log" 2>&1 || true
  cp "$out/system.log" "$log"
}

fail() {
  sync_log
  echo "FAIL: $*"
  xcrun simctl io "$device" screenshot "$out/failure.png" >/dev/null 2>&1 || true
  cp ~/Library/Logs/DiagnosticReports/"$exe"*.ips "$out/" 2>/dev/null || true
  echo "--- app log (the app's own lines; the rest is in $out/system.log) ---"
  grep -E '\[(stdout|stderr)\]|baguette|counter|ios_nif' "$log" | tail -80 || true
  exit 1
}

# wait_for <regex> <seconds>: waits for a line of the app's output.
wait_for() {
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    sync_log
    grep -Eq "$1" "$log" && return 0
    sleep 1
  done
  fail "no line matching /$1/ within $2 s"
}

wait_for 'levain: app at' 120
# The BEAM boots with fork() refused, as a phone's sandbox refuses it.
wait_for 'baguette: fork\(\) refused' 60
# The system's DNS servers, which Baguette.DNS gives the BEAM's resolver.
wait_for 'baguette: nameservers [0-9a-fA-F:.]+' 60
wait_for 'levain: first frame' 120
sleep 3
xcrun simctl io "$device" screenshot "$out/first-frame.png" >/dev/null

# Another app's own line to wait for (EXPECT, an extended regex).
if [ -n "${EXPECT:-}" ]; then
  wait_for "$EXPECT" 30
fi

# Taps go through UIKit's touch handling and GPUI to the Elixir view. The
# host logs where each labelled control is, in points; idb taps there
# (`brew install facebook/fb/idb-companion` and `pipx install fb-idb`).
tap() {
  local at
  at=$(grep -Eo "levain: bounds $1 [0-9]+ [0-9]+" "$log" | tail -1 | cut -d' ' -f4-)
  [ -n "$at" ] || fail "no bounds logged for $1"
  echo "tap $1 at $at"
  # shellcheck disable=SC2086
  idb ui tap --udid "$device" $at
}
if [ "${COUNTER_TAPS:-1}" = 1 ]; then
  command -v idb >/dev/null || fail "idb is not installed (COUNTER_TAPS=0 skips the taps)"
  wait_for 'levain: bounds Increment [0-9]+ [0-9]+' 30
  tap Increment
  wait_for 'counter: count=1' 20
  tap Increment
  wait_for 'counter: count=2' 20
  tap Decrement
  wait_for 'counter: count=1$' 20
  sleep 1
  xcrun simctl io "$device" screenshot "$out/tapped.png" >/dev/null
fi
# Read in full first: `grep -q` stops early, and under pipefail the SIGPIPE
# it leaves `launchctl` with reads as the app having exited.
services=$(xcrun simctl spawn "$device" launchctl list)
grep -qF "$bundle" <<<"$services" || fail "the app exited"
sync_log
grep -E 'baguette|fork' "$log" | tail -20
echo "PASS: the app boots its release and draws Elixir's first frame on iOS"
