#!/usr/bin/env bash
#
# Native desktop build: macOS (x86_64 or arm64, whichever the host is) and Linux.
#
#   scripts/build-desktop.sh [output_path]
#
# Windows builds natively under MSYS2's MINGW64 shell, not cross-compiled: the toolchain is the same
# mingw-w64, but a native runner can also RUN the result, which is the only way any of this gets
# smoke-tested before publishing. Each macOS architecture is likewise built on its own runner.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
    ALLOWED_DEPS='^(/usr/lib/|/System/)'
    ;;
  Linux)
    MIN_OS=""
    LD_STRIP="-Wl,--gc-sections"
    ALLOWED_DEPS='^(libc|libm|libdl|libpthread|librt|libz|libbz2|ld-linux)'
    ;;
  # uname -s names the MSYS2 environment: MINGW64 on x86_64, CLANGARM64 on arm64.
  MINGW*|MSYS*|CLANG*|UCRT*)
    WINDOWS=1
    MIN_OS=""
    LD_STRIP="-Wl,--gc-sections"
    # Without -static the .exe needs the toolchain runtime DLLs beside it (libwinpthread-1,
    # libgcc_s_seh-1 under MINGW64; libunwind under CLANGARM64).
    EXTRA_LDFLAGS="-static"
    # ffmpeg derives the OS from `uname -s`, which here names the MSYS2 environment. Only the
    # mingw* spellings are recognised, so CLANGARM64 would be configured as an unknown Unix.
    # (The arch needs no help: configure reads $MSYSTEM_CARCH.)
    EXTRA_CONF="--target-os=mingw64 --host-os=mingw64"
    # Case-insensitively matched; these are the DLLs a stock Windows already has.
    ALLOWED_DEPS='^(kernel32|user32|advapi32|ws2_32|shell32|ole32|oleaut32|secur32|bcrypt|ncrypt|crypt32|gdi32|imm32|version|psapi|iphlpapi|winmm|shlwapi|msvcrt|ucrtbase|api-ms-)'
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

echo "[build] ffmpeg for $(uname -s)/$(uname -m)"
cd "$SRC/ffmpeg"
make distclean >/dev/null 2>&1 || true
# shellcheck disable=SC2086
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ./configure \
  --optflags="$FF_OPTFLAGS" \
  ${HOST_CC:+--cc="$HOST_CC"} \
  --extra-cflags="-I$DEPS_REL/include $FF_SIZE_CFLAGS $MIN_OS" \
  --extra-ldflags="-L$DEPS_REL/lib $LD_STRIP $MIN_OS ${EXTRA_LDFLAGS:-}" \
  ${EXTRA_CONF:-} \
  $FF_OPTS
make -j"$JOBS" "$BIN"

echo "[verify]"
file "$BIN"
assert_no_stray_deps "$BIN" "$ALLOWED_DEPS"
assert_anonymous "$BIN"
# Native on every platform now, so the binary is always executed before it is published.
"./$BIN" -hide_banner -muxers | grep -qw wav && echo "  runs; wav muxer present"
if [ -z "${WINDOWS:-}" ]; then  # ymix is not built for Windows
  "./$BIN" -hide_banner -protocols | tr -d ' ' | grep -qw ymix && echo "  ymix protocol present"
fi

if [ -n "$OUT" ]; then
  cp "$BIN" "$OUT"
  echo "[out] $OUT ($(du -h "$OUT" | cut -f1))"
fi
echo "[desktop] BUILD_OK"
