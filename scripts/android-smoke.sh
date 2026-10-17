#!/usr/bin/env bash
# Installs the Firehose APK on a running emulator, checks the embedded BEAM
# boots and its Broadway pipeline runs, taps the dashboard's controls, and
# saves screenshots and logcat to the output directory.
#
#   scripts/android-smoke.sh firehose.apk [OUT_DIR]
set -euo pipefail

APK=$1
OUT=${2:-android-smoke}
PKG=${PKG:-dev.baguette.firehose}
mkdir -p "$OUT"
ADB_BIN=$(command -v adb)
# Bound every adb call so a wedged device fails the run instead of hanging it.
adb() { timeout 90 "$ADB_BIN" "$@"; }

timeout 300 "$ADB_BIN" wait-for-device
adb shell settings put global hide_error_dialogs 1 || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null || true
adb install -r -g "$APK"
# The launcher relaunches a just-installed app's activity; let that settle.
adb shell am wait-for-broadcast-idle || sleep 5
adb logcat -c
"$ADB_BIN" logcat >"$OUT/logcat.txt" 2>&1 &
logcat=$!
# Whatever happens, keep a picture of the screen as the run ends.
trap 'adb exec-out screencap -p >"$OUT/final.png" || true; kill "$logcat" 2>/dev/null || true' EXIT
adb shell am start -n "$PKG/.MainActivity"

failures=0
# wait_for <regex> <seconds>: waits for a logcat line.
wait_for() {
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    if grep -Eq "$1" "$OUT/logcat.txt"; then return 0; fi
    sleep 1
  done
  echo "FAIL: no logcat line matching /$1/ within $2 s"
  failures=$((failures + 1))
  return 1
}
shot() { adb exec-out screencap -p >"$OUT/$1.png"; }
acked() { grep -Eo 'firehose: acked=[0-9]+' "$OUT/logcat.txt" | tail -1 | grep -Eo '[0-9]+$' || echo 0; }

wait_for 'baguette: release at' 120
wait_for 'baguette: first frame from Elixir' 120
wait_for 'firehose: acked=[1-9]' 60
sleep 3
shot firehose-start
first=$(acked)
sleep 6
second=$(acked)
echo "acked: $first then $second"
if ((second <= first)); then
  echo "FAIL: the pipeline is not acknowledging events ($first then $second)"
  failures=$((failures + 1))
fi

# Taps go through GPUI's touch handling to the Elixir view: `+` raises the
# rate, Chaos turns on failures. The host logs where each labelled control
# is, in device pixels.
# tap <label>: taps the control's centre.
tap() {
  local at
  at=$(grep -Eo "baguette: bounds $1 [0-9]+ [0-9]+" "$OUT/logcat.txt" | tail -1 | cut -d' ' -f4-)
  if [[ -z $at ]]; then
    echo "FAIL: no bounds logged for $1"
    failures=$((failures + 1))
    return 1
  fi
  echo "tap $1 at $at"
  # shellcheck disable=SC2086
  adb shell input tap $at
}
tap Faster
wait_for 'firehose: rate=800' 20
tap Chaos
wait_for 'firehose: chaos=10' 20
wait_for 'firehose: acked=[0-9]+ failed=[1-9]' 30
sleep 2
shot firehose-chaos

if adb shell pidof "$PKG" >/dev/null; then echo "app still running"; else
  echo "FAIL: the app exited"
  failures=$((failures + 1))
fi
grep -E 'baguette|beam|firehose|FATAL|AndroidRuntime' "$OUT/logcat.txt" | tail -40 || true
if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "PASS: Firehose runs on Android"
