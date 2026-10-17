#!/usr/bin/env bash
# Builds Erlang/OTP from source and packs the emulator into one static archive,
# liberlang.a, that the Baguette host links. The OTP install it also produces
# is the one to build releases with, so the host and the release share an ERTS.
#
#   scripts/build-liberlang.sh OTP-29.1.2 /path/to/out
#
# Out: <out>/liberlang.a and <out>/otp (an OTP install prefix).
set -euo pipefail

tag=${1:?usage: build-liberlang.sh OTP_TAG OUT_DIR}
out=$(mkdir -p "${2:?usage: build-liberlang.sh OTP_TAG OUT_DIR}" && cd "$2" && pwd)
src="$out/src"

if [ ! -d "$src" ]; then
  git clone --depth 1 --branch "$tag" https://github.com/erlang/otp "$src"
fi

cd "$src"
export ERL_TOP="$src" RELEASE_LIBBEAM=yes
# macOS has no system OpenSSL headers; crypto builds against Homebrew's.
ssl=()
if [ "$(uname)" = Darwin ]; then ssl=(--with-ssl="$(brew --prefix openssl@3)"); fi
if [ ! -f "$out/otp/bin/erl" ]; then
  ./configure --prefix="$out/otp" \
    --without-javac --without-odbc --without-wx --without-debugger --without-observer --without-et \
    --enable-builtin-zlib ${ssl[@]+"${ssl[@]}"} CFLAGS="-O2 -fPIC"
  make -j"$(getconf _NPROCESSORS_ONLN)"
  make install
fi

target=$(erts/autoconf/config.guess)
archives=(
  "bin/$target/libbeam.a"
  "erts/lib/internal/$target/libethread.a"
  "erts/lib/internal/$target/liberts_internal_r.a"
  "erts/emulator/pcre/obj/$target/opt/libepcre.a"
  "erts/emulator/ryu/obj/$target/opt/libryu.a"
  "erts/emulator/zstd/obj/$target/opt/libzstd.a"
  "erts/emulator/zlib/obj/$target/opt/libz.a"
)
rm -f "$out/liberlang.a"
if [ "$(uname)" = Darwin ]; then
  libtool -static -o "$out/liberlang.a" "${archives[@]}"
else
  {
    echo "CREATE $out/liberlang.a"
    for archive in "${archives[@]}"; do echo "ADDLIB $src/$archive"; done
    echo "SAVE"
    echo "END"
  } | ar -M
  ranlib "$out/liberlang.a"
fi
echo "built $out/liberlang.a"
