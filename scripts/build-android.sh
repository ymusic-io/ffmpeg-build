#!/usr/bin/env bash
#
# Android, one ABI at a time so CI can fan the four out across parallel runners.
#
#   scripts/build-android.sh <abi> [output_path]      abi: arm64-v8a | armeabi-v7a | x86 | x86_64
#
# Needs ANDROID_NDK_ROOT. The binary is named libffmpeg.so on purpose: Android only extracts and
# grants exec permission to files under lib/<abi>/ that look like native libraries, so an executable
# has to be disguised as one to be runnable from an installed app.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ABI="${1:?usage: build-android.sh <abi> [out]}"
OUT="${2:-}"
# Resolved before anything cd's: the copy at the end runs from src/ffmpeg, so a relative path would
# deposit the binary inside the source tree instead of where the caller asked for it.
[ -n "$OUT" ] && { mkdir -p "$(dirname "$OUT")"; OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"; }
: "${ANDROID_NDK_ROOT:?set ANDROID_NDK_ROOT to an NDK r27+}"

# API 21 is the floor r27+ still ships, and covers the Android 7 target. armeabi-v7a is built WITH
# NEON — every v7a device since ~2012 has it, so the plain-ARM variant is wasted time.
API=21
# ffmpeg's --arch names are not the ABI names. 32-bit x86 additionally cannot use the hand-written
# assembly: it needs text relocations, which ld.lld rejects for a PIE, and Android requires PIE.
case "$ABI" in
  arm64-v8a)   TRIPLE=aarch64-linux-android;    ARCH=aarch64; CPU=armv8-a ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; ARCH=armv7;   CPU=armv7-a
               EXTRA_CFLAGS="-mfpu=neon -mfloat-abi=softfp" ;;
  x86)         TRIPLE=i686-linux-android;       ARCH=i686;    CPU=i686
               ASM_OPT="--disable-asm" ;;
  x86_64)      TRIPLE=x86_64-linux-android;     ARCH=x86_64;  CPU=x86-64 ;;
  *) echo "unknown ABI: $ABI" >&2; exit 1 ;;
esac

TC="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"
[ -d "$TC" ] || { echo "no NDK toolchain at $TC" >&2; exit 1; }
# The toolchain goes on PATH and the tools are named bare, because ffmpeg records --cc/--ar/... in
# the configure line it compiles into the binary. Absolute paths there would publish the NDK
# location — which on a developer machine is under $HOME, and on a runner is under /home/runner.
export PATH="$TC/bin:$PATH"
export CC="${TRIPLE}${API}-clang"
export AR=llvm-ar NM=llvm-nm RANLIB=llvm-ranlib STRIP=llvm-strip
command -v "$CC" >/dev/null || { echo "no $CC in $TC/bin" >&2; exit 1; }

DEPS="$ROOT/.deps-android-$ABI"
DEPS_REL="../../.deps-android-$ABI"
# 16 KB page alignment: required by Android 15+ devices that use 16 KB pages, and harmless on the
# 4 KB ones, so a single binary covers both.
LDFLAGS_ALIGN="-Wl,-z,max-page-size=16384"
DEP_CFLAGS="$DEP_STD $FF_OPTFLAGS $FF_SIZE_CFLAGS ${EXTRA_CFLAGS:-}"

build_dep() {
  local src="$1" name="$2"; shift 2
  local bdir="$DEPS/.build/$name"
  [ -f "$src/configure" ] || { echo "no configure in $src — wrong path, or the tree needs bootstrapping" >&2; return 1; }
  # -L dereferences: shine carries symlinks under js/test, and MSYS2 cannot create symlinks
  # without developer mode. They are test fixtures, so copying their contents is equivalent.
  rm -rf "$bdir"; mkdir -p "$bdir"; cp -RL "$src/." "$bdir/"
  ( cd "$bdir"
    make distclean >/dev/null 2>&1 || true
    ./configure --host="$TRIPLE" --prefix="$DEPS" --disable-shared --enable-static \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS="$DEP_CFLAGS" "$@" >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null )
}

apply_ymix_patch

[ -f "$DEPS/lib/libmp3lame.a" ] || { echo "[deps] lame";  build_dep "$SRC/lame/lame" lame --disable-frontend --disable-gtktest; }
[ -f "$DEPS/lib/libshine.a" ]   || { echo "[deps] shine"; bootstrap_shine; build_dep "$SRC/shine" shine; fix_shine_pc "$DEPS"; }

echo "[build] ffmpeg for android/$ABI (API $API)"
cd "$SRC/ffmpeg"
make distclean >/dev/null 2>&1 || true
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig" ./configure \
  --target-os=android --arch="$ARCH" --cpu="$CPU" --enable-cross-compile ${ASM_OPT:-} \
  --cc="$CC" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
  --enable-jni --enable-mediacodec \
  --enable-pic \
  --optflags="$FF_OPTFLAGS" \
  --extra-cflags="-I$DEPS_REL/include $FF_SIZE_CFLAGS ${EXTRA_CFLAGS:-}" \
  --extra-ldflags="-L$DEPS_REL/lib -Wl,--gc-sections $LDFLAGS_ALIGN" \
  $FF_OPTS
make -j"$JOBS" ffmpeg

echo "[verify]"
file ffmpeg
assert_anonymous ffmpeg
"$TC/bin/llvm-readelf" -l ffmpeg | grep -q "0x4000" && echo "  16 KB page aligned"

if [ -n "$OUT" ]; then
  cp ffmpeg "$OUT"
  echo "[out] $OUT ($(du -h "$OUT" | cut -f1))"
fi
echo "[android/$ABI] BUILD_OK"
