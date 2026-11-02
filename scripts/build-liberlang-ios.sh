#!/usr/bin/env bash
# Cross-builds Erlang/OTP for iOS and packs the emulator into one static
# archive, liberlang.a, that the Baguette host links into the app.
#
#   scripts/build-liberlang-ios.sh OTP-29.1.2 sim    /path/to/out
#   scripts/build-liberlang-ios.sh OTP-29.1.2 device /path/to/out
#
# Out: <out>/liberlang.a.
#
# iOS loads no code but the app's own, so everything is static: the emulator,
# OTP's NIFs (crypto, asn1, `--enable-static-nifs`) and OpenSSL's libcrypto.
# The JIT is off: iOS forbids writable executable memory.
#
# Unpatched OTP: built with `-D__IOS__` (OTP's own iOS xcomp configs), ERTS
# refuses to spawn OS processes (`open_port({spawn, _})`, `os:cmd/1`), so
# nothing ever talks to `erl_child_setup`. The host makes `fork()` fail, as
# the device sandbox does, and the BEAM boots without it.
#
# Needs: Xcode, and `erl`/`erlc` of the same OTP release on PATH, which a
# cross build uses to compile Erlang code.
set -euo pipefail

usage="usage: build-liberlang-ios.sh OTP_TAG sim|device OUT_DIR"
tag=${1:?$usage}
kind=${2:?$usage}
out=$(mkdir -p "${3:?$usage}" && cd "$3" && pwd)
openssl_version=${OPENSSL_VERSION:-3.5.4}
ios_min=${IOS_DEPLOYMENT_TARGET:-15.0}

case $kind in
  sim)
    sdk=iphonesimulator host=arm64-apple-iossimulator openssl_target=iossimulator-xcrun
    min_flag=-mios-simulator-version-min=$ios_min
    ;;
  device)
    sdk=iphoneos host=arm64-apple-ios openssl_target=ios64-xcrun
    min_flag=-mios-version-min=$ios_min
    ;;
  *) echo "$usage" >&2; exit 1 ;;
esac

sdkroot=$(xcrun -sdk "$sdk" --show-sdk-path)
cc="xcrun -sdk $sdk clang -arch arm64 $min_flag"
jobs=$(sysctl -n hw.ncpu)

# OpenSSL's libcrypto, static, for the crypto NIF.
openssl=$out/openssl
if [ ! -f "$openssl/lib/libcrypto.a" ]; then
  mkdir -p "$out/build"
  curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" |
    tar -xz -C "$out/build"
  (
    cd "$out/build/openssl-$openssl_version"
    CC="$cc" ./Configure "$openssl_target" no-shared no-tests no-apps no-docs no-engine \
      --prefix="$openssl" --libdir=lib
    make -j"$jobs" build_libs
    make install_dev
  )
fi

src=$out/otp
if [ ! -d "$src" ]; then
  git clone --depth 1 --branch "$tag" https://github.com/erlang/otp "$src"
fi
cd "$src"

# OTP's xcomp/erl-xcomp-arm64-ios{,simulator}.conf, with OpenSSL linked in
# statically, and DED_LD through the compiler driver: OTP 29's hardening
# flags in DED_LDFLAGS are compiler flags that `ld` rejects.
cat >"$out/xcomp.conf" <<CONF
erl_xcomp_build=guess
erl_xcomp_host=$host
erl_xcomp_configure_flags="--without-termcap --without-wx --without-javac --without-odbc \
  --without-debugger --without-observer --without-cdv --without-et --without-megaco \
  --enable-builtin-zlib --enable-static-nifs --enable-static-drivers --disable-jit \
  --with-ssl=$openssl --disable-dynamic-ssl-lib"
CC="$cc"
CXX="xcrun -sdk $sdk clang++ -arch arm64 $min_flag"
CFLAGS="-fno-common -O2 -D__IOS__=yes"
CXXFLAGS="-fno-common -O2 -D__IOS__=yes"
LD="xcrun -sdk $sdk ld -arch arm64"
LDFLAGS="-L$sdkroot/usr/lib/ -lc++"
DED_LD="$cc"
DED_LDFLAGS="-r"
AR="xcrun -sdk $sdk ar"
RANLIB="xcrun -sdk $sdk ranlib"
LIBS="$openssl/lib/libcrypto.a"
erl_xcomp_sysroot=$sdkroot
CONF

export ERL_TOP=$src RELEASE_LIBBEAM=yes
if [ ! -f "$out/.configured" ]; then
  ./otp_build configure --xcomp-conf="$out/xcomp.conf"
  touch "$out/.configured"
fi
# Builds the static NIF archives (crypto, asn1) and libbeam.a. It may then
# fail on erts/etc's command-line tools, which an embedded BEAM does not use;
# the archive step below fails if anything it needs is missing.
make -j"$jobs" emulator || echo "(erts/etc tools failed to build; not needed)"

target=$(ls -d bin/*apple-ios* | head -1 | xargs basename)
archives=(
  "bin/$target/libbeam.a"
  "erts/lib/internal/$target/libethread.a"
  "erts/lib/internal/$target/liberts_internal_r.a"
  "erts/emulator/pcre/obj/$target/opt/libepcre.a"
  "erts/emulator/ryu/obj/$target/opt/libryu.a"
  "erts/emulator/zstd/obj/$target/opt/libzstd.a"
  "erts/emulator/zlib/obj/$target/opt/libz.a"
  "lib/crypto/priv/lib/$target/crypto.a"
  "lib/asn1/priv/lib/$target/asn1rt_nif.a"
  "$openssl/lib/libcrypto.a"
)
paths=()
for archive in "${archives[@]}"; do
  case $archive in /*) paths+=("$archive") ;; *) paths+=("$src/$archive") ;; esac
done
rm -f "$out/liberlang.a"
xcrun libtool -static -o "$out/liberlang.a" "${paths[@]}"
echo "built $out/liberlang.a for $target"
