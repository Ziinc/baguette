#!/usr/bin/env bash
# Smoke test of the counter release on Windows (Git Bash): builds
# `examples/counter` with `mix release`, starts `bin/counter_app.exe` and
# waits for the host to log Elixir's first frame. The log goes to OUT_DIR.
#
# GPUI renders through wgpu's Vulkan or OpenGL backend. A machine without a
# GPU driver for either (CI runners) can set MESA_DLLS to a directory of
# Mesa's Windows DLLs (mesa-dist-win's x64), which are put next to the
# executable so it renders with llvmpipe.
#
# Usage: scripts/e2e-windows.sh [OUT_DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$(mkdir -p "${1:-$ROOT/native/target/e2e}" && cd "${1:-$ROOT/native/target/e2e}" && pwd)"
REL="$ROOT/examples/counter/_build/prod/rel/counter"

(cd "$ROOT/examples/counter" && mix deps.get && MIX_ENV=prod mix release --overwrite)
echo "release ERTS:"
ls -la "$REL"/erts-*/bin

if [ -n "${MESA_DLLS:-}" ]; then
  cp "$MESA_DLLS"/*.dll "$REL/bin/"
  export GALLIUM_DRIVER=llvmpipe
fi

LOG="$OUT_DIR/counter.log"
export RUST_LOG="${RUST_LOG:-warn}"
"$REL/bin/counter_app.exe" >"$LOG" 2>&1 &
APP_PID=$!
trap 'taskkill //F //IM counter_app.exe >/dev/null 2>&1 || true' EXIT

for _ in $(seq 120); do
  if grep -q "baguette: first frame from Elixir" "$LOG"; then
    echo "first frame drawn"
    cat "$LOG"
    exit 0
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "counter_app exited before its first frame"
    break
  fi
  sleep 1
done

echo "no first frame from Elixir; log:"
cat "$LOG"
exit 1
