#!/usr/bin/env bash
# Builds an example's macOS disk image with the Tauri bundler, then checks it
# as a user would get it: mounts the .dmg and runs the app inside. The app
# must receive a frame from Elixir, which proves the bundled release booted.
#
# Usage: scripts/bundle-test-macos.sh EXAMPLE_DIR [OUT_DIR]
# Needs: Elixir, Node. Signs and notarizes when Tauri's APPLE_* variables are set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
example=$(cd "$1" && pwd)
out=$(mkdir -p "${2:-$ROOT/native/target/bundle-test}" && cd "${2:-$ROOT/native/target/bundle-test}" && pwd)

(cd "$example" && mix deps.get && BAGUETTE_BUNDLES=app,dmg MIX_ENV=prod mix release --overwrite)
dmg=$(ls "$example"/_build/prod/bundle/dmg/*.dmg)
ls -la "$dmg"

mnt=$(mktemp -d)
app=
trap 'kill $app 2>/dev/null || true; hdiutil detach -quiet "$mnt" || true' EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg"
binary=$(ls "$mnt"/*.app/Contents/MacOS/* | head -1)
codesign -dv "$mnt"/*.app 2>&1 | grep -E 'Identifier|Authority|Signature' || true

log="$out/dmg.log"
(cd /tmp && exec "$binary") >"$log" 2>&1 &
app=$!
for _ in $(seq 120); do
  grep -q "first frame from Elixir" "$log" && break
  kill -0 "$app" 2>/dev/null || { echo "FAIL: app exited"; cat "$log"; exit 1; }
  sleep 0.5
done
grep -q "first frame from Elixir" "$log" || { echo "FAIL: app never rendered"; cat "$log"; exit 1; }
sleep 2
screencapture -x "$out/dmg.png" || true
echo "PASS: dmg rendered ($out/dmg.png)"
