#!/usr/bin/env bash
# Checks an iOS device build of a Baguette app (`BAGUETTE_IOS=device mix
# release`) without a phone: the executable is for iOS on arm64, and it
# carries what the BEAM needs at run time: the static NIF table with
# Baguette's NIF, the `enif_*` functions Rustler looks up, and the fork()
# that refuses as the sandbox does.
#
#   scripts/ios-check-ipa.sh <path/to/app.ipa>
set -euo pipefail

ipa=${1:?usage: ios-check-ipa.sh <path/to/app.ipa>}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$ipa" -d "$work"
app=$(find "$work/Payload" -maxdepth 1 -name '*.app' | head -1)
[ -n "$app" ] || { echo "FAIL: no Payload/*.app in $ipa"; exit 1; }
exe=$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
failures=0

file "$exe"
lipo -archs "$exe" | grep -qx arm64 || { echo "FAIL: not arm64"; failures=$((failures + 1)); }
# LC_BUILD_VERSION platform 2 is iOS (7 would be the simulator).
otool -l "$exe" | grep -A3 LC_BUILD_VERSION | grep -Eq 'platform (2|IOS)$' ||
  { echo "FAIL: not built for iOS devices"; failures=$((failures + 1)); }

exported=$(nm -gU "$exe")
for symbol in _start_app _erl_start _erts_static_nif_tab _baguette_nif_nif_init _enif_alloc _enif_make_atom _fork; do
  if grep -q " $symbol\$" <<<"$exported"; then
    echo "ok: $symbol"
  else
    echo "FAIL: $symbol is not exported"
    failures=$((failures + 1))
  fi
done

ls -la "$ipa"
if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "PASS: $(basename "$ipa") is an iOS arm64 build carrying the BEAM and Baguette's NIF"
