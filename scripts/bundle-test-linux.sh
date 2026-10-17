#!/usr/bin/env bash
# Builds an example's Linux bundles with the Tauri bundler, then checks each
# one as a user would get it: installs the .deb and runs the installed
# binary, and runs the AppImage. Each must open its window and receive a
# frame from Elixir, which proves the bundled release booted.
#
# Usage: scripts/bundle-test-linux.sh EXAMPLE_DIR WINDOW_TITLE [OUT_DIR]
# Needs: BAGUETTE_LIBERLANG, Elixir, Node, sudo (for dpkg), Xvfb, xdotool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
example=$(cd "$1" && pwd) title=$2
out=$(mkdir -p "${3:-$ROOT/native/target/bundle-test}" && cd "${3:-$ROOT/native/target/bundle-test}" && pwd)

(cd "$example" && mix deps.get && BAGUETTE_BUNDLES=deb,appimage MIX_ENV=prod mix release --overwrite)
bundles="$example/_build/prod/bundle"
deb=$(ls "$bundles"/deb/*.deb)
appimage=$(ls "$bundles"/appimage/*.AppImage)
ls -la "$deb" "$appimage"

display=${DISPLAY_NUM:-95}
Xvfb ":$display" -screen 0 1600x1000x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
export DISPLAY=":$display"
for _ in $(seq 50); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done

# Runs a bundle, waits for its window and its first frame, screenshots it.
check() {
  local label=$1
  shift
  local log="$out/$label.log"
  (cd /tmp && exec "$@") >"$log" 2>&1 &
  app=$!
  for _ in $(seq 120); do
    grep -q "first frame from Elixir" "$log" && break
    kill -0 "$app" 2>/dev/null || { echo "FAIL: $label exited"; cat "$log"; exit 1; }
    sleep 0.5
  done
  grep -q "first frame from Elixir" "$log" || { echo "FAIL: $label never rendered"; cat "$log"; exit 1; }
  window=$(xdotool search --sync --name "^$title\$" | tail -1)
  sleep 2
  import -window "$window" "$out/$label.png"
  kill "$app"
  wait "$app" 2>/dev/null || true
  echo "PASS: $label rendered ($out/$label.png)"
}

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
as_root dpkg -i "$deb"
binary=/$(dpkg-deb -c "$deb" | awk '{print $6}' | sed 's|^\./||' | grep -E '^usr/bin/.+' | head -1)
check deb "$binary"
check appimage env APPIMAGE_EXTRACT_AND_RUN=1 "$appimage"
as_root dpkg -r "$(dpkg-deb -f "$deb" Package)"
