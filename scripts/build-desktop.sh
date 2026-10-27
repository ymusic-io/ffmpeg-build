#!/usr/bin/env bash
#
# Native desktop build: macOS (x86_64 or arm64, whichever the host is) and Linux.
#
#   scripts/build-desktop.sh [output_path]
#
# Windows builds natively under MSYS2's MINGW64 shell, not cross-compiled: the toolchain is the same
# mingw-w64, but a native host can also RUN the result, which is the only way it gets smoke-tested.
# Each macOS architecture is likewise built on a host of that architecture.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/deps-video.sh"

# Shared libav: the CLI and MSE both load these DSOs. iOS stays static (common.sh default).
FF_OPTS="${FF_OPTS//$FF_LINK_STATIC/$FF_LINK_SHARED}"

OUT="${1:-}"
# Resolved before anything cd's: the copy at the end runs from src/ffmpeg, so a relative path would
# deposit the binary inside the source tree instead of where the caller asked for it.
[ -n "$OUT" ] && { mkdir -p "$(dirname "$OUT")"; OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"; }
DEPS="$ROOT/.deps"
# Relative to src/ffmpeg, where every compile runs. Absolute paths here end up in the binary's
# recorded configure line and would name the build machine's user.
DEPS_REL="../../.deps"

case "$(uname -s)" in
  Darwin)
    # Pinned, not inherited: without this the binary takes the build host's SDK version and refuses
    # to launch on anything older (a Sonoma host produced binaries demanding macOS 14).
    MIN_OS="-mmacosx-version-min=11.0"
    LD_STRIP="-Wl,-dead_strip"          # ld64's spelling of --gc-sections
    ALLOWED_DEPS='^(/usr/lib/|/System/|@rpath/)'
    RPATH_LDFLAGS="-Wl,-rpath,@loader_path -Wl,-headerpad_max_install_names"
    ;;
  Linux)
    MIN_OS=""
    LD_STRIP="-Wl,--gc-sections"
    ALLOWED_DEPS='^(libc|libm|libdl|libpthread|librt|libz|libbz2|ld-linux|libav|libsw)'
    RPATH_LDFLAGS='-Wl,-rpath,\$ORIGIN'
    ;;
  # Any MSYS2 environment: uname -s reads MINGW64_NT even under CLANGARM64.
  MINGW*|MSYS*|CLANG*|UCRT*)
    WINDOWS=1
    MIN_OS=""
    LD_STRIP="-Wl,--gc-sections"
    # Shared libav DLLs sit next to ffmpeg.exe (Windows loads from the exe directory). Do not
    # -static: that would bake libav into the exe and MSE could not share it. Still bake the
    # mingw runtime so we do not ship libgcc/libwinpthread beside the exe.
    # ffmpeg derives the OS from `uname -s`, which here names the MSYS2 environment. Only the
    # mingw* spellings are recognised, so CLANGARM64 would be configured as an unknown Unix.
    # (The arch needs no help: configure reads $MSYSTEM_CARCH.)
    EXTRA_LDFLAGS="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic"
    EXTRA_CONF="--target-os=mingw64 --host-os=mingw64"
    # Case-insensitively matched; OS DLLs plus our libav/libsw.
    # zlib1 is MinGW's shared zlib (ffmpeg --enable-zlib picks it up); ship it beside ffmpeg.exe.
    # libwinpthread-1 similarly — ffmpeg's own `--extra-ldflags "-Bstatic -lwinpthread -Bdynamic"`
    # sandwich doesn't survive ffmpeg's internal reordering for the per-lib .so links, so each DSO
    # ends up linking the shared one; ship it too.
    ALLOWED_DEPS='^(kernel32|user32|advapi32|ws2_32|shell32|ole32|oleaut32|secur32|bcrypt|ncrypt|crypt32|gdi32|imm32|version|psapi|iphlpapi|winmm|shlwapi|msvcrt|ucrtbase|api-ms-|avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample|zlib1|libwinpthread-1)'
    # ymix talks over a Unix socket to reach Android's content:// documents. Windows has no such
    # restriction and no <sys/un.h>, so the protocol comes out for this target only.
    FF_OPTS="${FF_OPTS//--enable-protocol=file,pipe,ymix/--enable-protocol=file,pipe}"
    BIN=ffmpeg.exe
    ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac
BIN="${BIN:-ffmpeg}"

DEP_CFLAGS="$DEP_STD $FF_OPTFLAGS $FF_SIZE_CFLAGS $MIN_OS"

# Build a vendored autotools dependency in a disposable copy, so src/ stays pristine while still
# building in-tree (shine's CLI includes a sibling header by relative path and breaks under VPATH).
build_dep() {
  local src="$1" name="$2"; shift 2
  local bdir="$DEPS/.build/$name"
  [ -f "$src/configure" ] || { echo "no configure in $src — wrong path, or the tree needs bootstrapping" >&2; return 1; }
  # -L dereferences: shine carries symlinks under js/test, and MSYS2 cannot create symlinks
  # without developer mode. They are test fixtures, so copying their contents is equivalent.
  rm -rf "$bdir"; mkdir -p "$bdir"; cp -RL "$src/." "$bdir/"
  ( cd "$bdir"
    make distclean >/dev/null 2>&1 || true
    ./configure --prefix="$DEPS" --disable-shared --enable-static CFLAGS="$DEP_CFLAGS" "$@" >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null )
}

apply_ymix_patch

[ -f "$DEPS/lib/libmp3lame.a" ] || { echo "[deps] lame";  build_dep "$SRC/lame/lame" lame --disable-frontend --disable-gtktest; }
[ -f "$DEPS/lib/libshine.a" ]   || { echo "[deps] shine"; bootstrap_shine; build_dep "$SRC/shine" shine; fix_shine_pc "$DEPS"; }

fetch_video_srcs
HOST_CC_BIN="${CC:-$(command -v clang || command -v cc)}"
HOST_AR_BIN="${AR:-$(command -v ar)}"
case "$(uname -s)-$(uname -m)" in
  Darwin-x86_64) LIBVPX_TARGET=x86_64-darwin20-gcc ;;
  Darwin-arm64) LIBVPX_TARGET=arm64-darwin20-gcc ;;
  Linux-x86_64) LIBVPX_TARGET=x86_64-linux-gcc ;;
  Linux-aarch64|Linux-arm64) LIBVPX_TARGET=arm64-linux-gcc ;;
  # Neither uname names the target on Windows ARM: MSYS2's runtime is x86_64 there, and uname -s
  # reads MINGW64_NT under CLANGARM64 too. MSYSTEM_CARCH is the environment's own target.
  MINGW*|MSYS*|CLANG*|UCRT*)
    case "$MSYSTEM_CARCH" in
      aarch64) LIBVPX_TARGET=arm64-win64-gcc ;;
      *) LIBVPX_TARGET=x86_64-win64-gcc ;;
    esac
    ;;
  *) LIBVPX_TARGET=generic-gnu ;;
esac
export LIBVPX_TARGET
build_dav1d "$DEPS" "$HOST_CC_BIN" "$DEP_CFLAGS" "$HOST_AR_BIN"
build_libvpx "$DEPS" "$HOST_CC_BIN" "$DEP_CFLAGS" "$HOST_AR_BIN"
if [[ $LIBVPX_TARGET == x86_64-* ]]; then
  # grep -q + pipefail dies on nm's SIGPIPE; size is the portable SIMD check
  # (generic-gnu decode-only is ~400 KB).
  vpx_n=$(wc -c < "$DEPS/lib/libvpx.a")
  [ "$vpx_n" -gt 600000 ] \
    || { echo "FATAL: libvpx is ${vpx_n} bytes (generic-gnu, no SIMD)" >&2; exit 1; }
  echo "[deps] libvpx SIMD present ($vpx_n bytes)"
fi
FF_OPTS="$FF_OPTS --disable-autodetect --enable-zlib $(video_sw_ff_opts)"
case "$(uname -s)" in
  Darwin)
    FF_OPTS="$FF_OPTS --enable-videotoolbox --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox"
    ;;
  Linux)
    install_hw_headers "$DEPS"
    FF_OPTS="$FF_OPTS $(video_hw_linux_ff_opts)"
    ;;
  MINGW*|MSYS*|CLANG*|UCRT*)
    # D3D11VA on Windows: the one cross-vendor (Intel/AMD/NVIDIA) hwaccel. Covers H.264 everywhere,
    # VP9 on Gen9+/Vega+/Pascal+, AV1 on 11th-gen+/RDNA2+/Ampere+. Windows SDK headers are in MinGW
    # already, so no extra deps. DXVA2 kept as a last-resort fallback for very old GPUs where D3D11
    # device create fails.
    FF_OPTS="$FF_OPTS --enable-d3d11va --enable-dxva2 --enable-hwaccel=h264_d3d11va,hevc_d3d11va,vp9_d3d11va,av1_d3d11va,h264_dxva2,hevc_dxva2,vp9_dxva2"
    ;;
esac

# Install prefix: include/ + lib/ (shared libav) + bin/ffmpeg. pack/ is the relocatable flat
# set YMusic ships (CLI + the same DSOs MSE loads).
# MSYSTEM_CARCH: the MSYS2 environment's target (aarch64 on CLANGARM64), where uname -m says x86_64.
ARCH_SLUG="${MSYSTEM_CARCH:-$(uname -m)}"
case "$ARCH_SLUG" in arm64|aarch64) ARCH_SLUG=arm64 ;; x86_64|amd64) ARCH_SLUG=x86_64 ;; esac
case "$(uname -s)" in
  Darwin) SLUG="macos-$ARCH_SLUG" ;;
  Linux) SLUG="linux-$ARCH_SLUG" ;;
  *) SLUG="windows-$ARCH_SLUG" ;;
esac
PREFIX="$ROOT/out/$SLUG"
PREFIX_REL="../../out/$SLUG"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

echo "[build] ffmpeg for $(uname -s)/$(uname -m) (shared libav)"
cd "$SRC/ffmpeg"
make distclean >/dev/null 2>&1 || true
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ./configure \
  --prefix="$PREFIX_REL" \
  --optflags="$FF_OPTFLAGS" \
  ${HOST_CC:+--cc="$HOST_CC"} \
  --extra-cflags="-I$DEPS_REL/include $FF_SIZE_CFLAGS $MIN_OS" \
  --extra-ldflags="-L$DEPS_REL/lib $LD_STRIP $MIN_OS ${RPATH_LDFLAGS:-} ${EXTRA_LDFLAGS:-}" \
  ${EXTRA_CONF:-} \
  $FF_OPTS
make -j"$JOBS"
make install

if [ -n "${WINDOWS:-}" ]; then
  # ffmpeg --enable-zlib picks MinGW's shared zlib1.dll, and the per-DSO link stages pick MinGW's
  # libwinpthread-1.dll (the -Bstatic sandwich in EXTRA_LDFLAGS gets reordered). Seed both into
  # $PREFIX/bin so pack_ffmpeg_shared ships them (otherwise the pack has unsatisfied imports).
  mingw_bin="$(dirname "$(command -v gcc)")"
  for dll in zlib1.dll libwinpthread-1.dll; do
    [ -f "$mingw_bin/$dll" ] && cp -a "$mingw_bin/$dll" "$PREFIX/bin/"
  done
fi

PACK="$PREFIX/pack"
pack_ffmpeg_shared "$PACK" "$PREFIX" "$BIN" "$ALLOWED_DEPS"
# MSE CMake links $PREFIX/lib. Overwrite with the relocatable copies so JNI records
# @rpath / $ORIGIN install names, not the build-machine prefix.
cp -a "$PACK"/libav* "$PACK"/libsw* "$PREFIX/lib/" 2>/dev/null || true
if [ -n "${WINDOWS:-}" ]; then
  cp -a "$PACK"/av*.dll "$PACK"/sw*.dll "$PREFIX/bin/" 2>/dev/null || true
fi

echo "[verify]"
file "$PACK/$BIN"
assert_anonymous "$PACK/$BIN"
# Native on every platform now, so the binary is always executed before it is published.
"$PACK/$BIN" -hide_banner -muxers | grep -qw wav && echo "  runs; wav muxer present"
# Hyphen here is the -decoders name. CONFIG_LIBVPX=yes is not enough: a mistyped
# --enable-decoder=libvpx-vp9 used to ship native `vp9` only (YouTube 0 fps).
"$PACK/$BIN" -hide_banner -decoders 2>/dev/null | grep -q 'libvpx-vp9' \
  || { echo "FATAL: libvpx-vp9 decoder missing from $PACK/$BIN" >&2; exit 1; }
"$PACK/$BIN" -hide_banner -decoders 2>/dev/null | grep -q 'libdav1d' \
  || { echo "FATAL: libdav1d decoder missing from $PACK/$BIN" >&2; exit 1; }
echo "  libvpx-vp9 and libdav1d decoders present"
if [ "$(uname -s)" = Linux ]; then
  for hw in cuda vulkan; do
    "$PACK/$BIN" -hide_banner -hwaccels 2>/dev/null | grep -qx "$hw" \
      || { echo "FATAL: $hw hwaccel missing from $PACK/$BIN" >&2; exit 1; }
  done
  echo "  cuda (nvdec) and vulkan hwaccels present"
fi
if [ -z "${WINDOWS:-}" ]; then  # ymix is not built for Windows
  "$PACK/$BIN" -hide_banner -protocols | tr -d ' ' | grep -qw ymix && echo "  ymix protocol present"
  # rpath must be enough: KmpProcess starts the child with an empty env (no LD_LIBRARY_PATH).
  env -i "$PACK/$BIN" -hide_banner -version >/dev/null && echo "  runs with empty env (rpath, not LD_LIBRARY_PATH)"
fi

if [ -n "$OUT" ]; then
  mkdir -p "$OUT"
  cp -a "$PACK"/. "$OUT/"
  echo "[out] $OUT ($(du -sh "$OUT" | cut -f1))"
fi
echo "[desktop] BUILD_OK"
