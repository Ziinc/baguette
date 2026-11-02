#!/usr/bin/env bash
# Spike: links scripts/ios-spike/main.c against an iOS-simulator liberlang.a,
# wraps it in an app bundle with the host's OTP (its .beam files are portable),
# and runs it in a booted simulator.
#
#   scripts/ios-spike/run.sh <liberlang dir> <otp root (lib/erlang)>
set -euo pipefail

liberlang=${1:?liberlang dir}
otp=${2:?otp root}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
app=$work/Spike.app
mkdir -p "$app/otp"

xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=15.0 \
  -o "$app/Spike" "$here/main.c" "$liberlang/liberlang.a" -lc++ \
  -framework CoreFoundation
# The release's code: what start_clean, crypto and asn1 need.
mkdir -p "$app/otp/bin" "$app/otp/lib"
cp "$otp"/bin/start_clean.boot "$app/otp/bin/"
for lib in kernel stdlib compiler crypto asn1 public_key; do
  cp -R "$otp"/lib/$lib-* "$app/otp/lib/"
done
cp -R "$otp/releases" "$app/otp/"

cat >"$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.baguette.spike</string>
  <key>CFBundleExecutable</key><string>Spike</string>
  <key>CFBundleName</key><string>Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>15.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"

device=$(xcrun simctl list devices available -j |
  python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for r,ds in d.items() if "iOS" in r for x in ds if "iPhone" in x["name"]))')
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
log=$work/console.log
# --console-pty streams the app's stdout/stderr until it exits.
xcrun simctl launch --console-pty --terminate-running-process "$device" dev.baguette.spike | tee "$log" || true
grep -q "baguette: spike ok" "$log"
