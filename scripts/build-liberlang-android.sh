#!/usr/bin/env bash
# Cross-builds Erlang/OTP for Android and packs the emulator into one static
# archive, liberlang.a, that the Baguette host links into its Android library.
#
#   scripts/build-liberlang-android.sh OTP-29.1.2 x86_64 /path/to/out
#   scripts/build-liberlang-android.sh OTP-29.1.2 arm64  /path/to/out
#
# Out: <out>/liberlang.so (and the .a it is made from), <out>/erl_child_setup (the BEAM forks it at boot;
# the app ships it as a native library so Android lets it run).
#
# Android loads app code with RTLD_LOCAL, so a NIF loaded later cannot see the
# BEAM's `enif_*` symbols. OTP's own NIFs (crypto, asn1) are therefore linked
# in statically (`--enable-static-nifs`), with OpenSSL's libcrypto. The JIT is
# off: the interpreter needs no executable memory.
#
# Needs: ANDROID_NDK_HOME (r27), and `erl`/`erlc` of the same OTP release on
# PATH, which a cross build uses to compile Erlang code.
set -euo pipefail

tag=${1:?usage: build-liberlang-android.sh OTP_TAG ARCH OUT_DIR}
arch=${2:?usage: build-liberlang-android.sh OTP_TAG ARCH OUT_DIR}
out=$(mkdir -p "${3:?usage: build-liberlang-android.sh OTP_TAG ARCH OUT_DIR}" && cd "$3" && pwd)
ndk=${ANDROID_NDK_HOME:-${NDK_HOME:?set ANDROID_NDK_HOME}}
api=${ANDROID_API:-24}
openssl_version=${OPENSSL_VERSION:-3.5.4}

case $arch in
  x86_64) triple=x86_64-linux-android openssl_target=android-x86_64 ;;
  arm64) triple=aarch64-linux-android openssl_target=android-arm64 ;;
  *) echo "unknown arch $arch (x86_64 or arm64)" >&2; exit 1 ;;
esac

toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
export PATH="$toolchain/bin:$PATH" ANDROID_NDK_ROOT=$ndk ANDROID_NDK_HOME=$ndk
cc="$triple$api-clang"
jobs=$(nproc)

# OpenSSL's libcrypto, static, for the crypto NIF.
openssl=$out/openssl
if [ ! -f "$openssl/lib/libcrypto.a" ]; then
  mkdir -p "$out/build"
  curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" |
    tar -xz -C "$out/build"
  (
    cd "$out/build/openssl-$openssl_version"
    ./Configure "$openssl_target" no-shared no-tests no-apps no-docs -D__ANDROID_API__="$api" \
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

cat >"$out/xcomp.conf" <<CONF
erl_xcomp_build=guess
erl_xcomp_host=$triple
erl_xcomp_configure_flags="--without-termcap --without-wx --without-javac --without-odbc \
  --without-debugger --without-observer --without-et --without-megaco \
  --enable-builtin-zlib --disable-jit --enable-static-nifs \
  --with-ssl=$openssl --disable-dynamic-ssl-lib"
CC="$cc"
CXX="$triple$api-clang++"
LD="$cc"
DED_LD="$cc"
AR=llvm-ar
RANLIB=llvm-ranlib
CFLAGS="-O2 -fPIC"
LIBS="$openssl/lib/libcrypto.a"
erl_xcomp_sysroot=$toolchain/sysroot
CONF

export ERL_TOP=$src RELEASE_LIBBEAM=yes
if [ ! -f "$out/.configured" ]; then
  ./otp_build configure --xcomp-conf="$out/xcomp.conf"
  touch "$out/.configured"
fi
# Builds the static NIF archives (crypto, asn1), libbeam.a and
# erl_child_setup. It then fails on erts/etc's command-line tools (erl_call
# needs erl_interface), which an embedded BEAM does not use; the archive
# step below fails if anything it needs is missing.
make -j"$jobs" emulator || echo "(erts/etc tools failed to build; not needed)"

target=$(ls -d bin/*android* | head -1 | xargs basename)
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
{
  echo "CREATE $out/liberlang.a"
  for archive in "${archives[@]}"; do
    case $archive in /*) echo "ADDLIB $archive" ;; *) echo "ADDLIB $src/$archive" ;; esac
  done
  echo "SAVE"
  echo "END"
} | llvm-ar -M
llvm-ranlib "$out/liberlang.a"
cp "bin/$target/erl_child_setup" "$out/erl_child_setup"

# Android resolves a library's symbols only from what it links, so NIFs
# loaded later (Rustler's, the app's own) find `enif_*` in this shared
# library rather than in the app's: it carries the whole BEAM and exports it.
# ERTS builds with hidden visibility, so `erl_start` gets an exported entry
# point of its own.
cat >"$out/liberlang_start.c" <<'C'
extern void erl_start(int argc, char **argv);
__attribute__((visibility("default"))) void liberlang_start(int argc, char **argv) {
    erl_start(argc, argv);
}
C
"$cc" -shared -fPIC -o "$out/liberlang.so" -Wl,-soname,liberlang.so "$out/liberlang_start.c" \
  -Wl,--whole-archive "$out/liberlang.a" -Wl,--no-whole-archive -lm -ldl -llog
llvm-strip --strip-unneeded "$out/liberlang.so"
echo "built $out/liberlang.a for $target"
