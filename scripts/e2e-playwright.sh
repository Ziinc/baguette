#!/usr/bin/env bash
# Drives the Tally example with Playwright: builds `examples/playwright` as a
# `mix release` with the `playwright` host feature, then runs its
# playwright_ex tests (`mix test --only playwright`), which start the release
# and connect to the Playwright server inside it. Runs on a virtual X display.
#
# Requires: Elixir, BAGUETTE_LIBERLANG, Xvfb and a Vulkan driver.
#
# Usage: scripts/e2e-playwright.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/examples/playwright"
mix deps.get
MIX_ENV=prod mix release --overwrite

if [ -z "${DISPLAY:-}" ]; then
  DISPLAY_NUM="${DISPLAY_NUM:-96}"
  Xvfb ":$DISPLAY_NUM" -screen 0 1600x1000x24 -nolisten tcp 2>/dev/null &
  XVFB_PID=$!
  trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
  export DISPLAY=":$DISPLAY_NUM"
  sleep 1
fi

mix test --only playwright
