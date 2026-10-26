#!/usr/bin/env bash
#
# Shared configuration for every target. Sourced, never run directly.
#
# The feature set lives here and only here, so an Android build and a desktop build cannot drift
# apart: the same muxers, demuxers, codecs, filters and protocols on all of them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# --- the curated feature set -------------------------------------------------------------------
#
# Everything is disabled and then re-enabled by name. The point is a small binary: a stock ffmpeg
# is ~70 MB, this is 6-8 MB. Adding a format here affects EVERY platform.
#
# Video SW (dav1d / libvpx) is NOT here: native `av1` is a hwaccel wrapper, native `vp9`
# SIGILL/SIGSEGV. Each build-*.sh adds --enable-libdav1d / --enable-libvpx. Hardware is
# MediaCodec (Android, in MSE C) or VideoToolbox (Apple, hwaccel plugins).
#
# Deliberately NOT enabled: --enable-gpl and --enable-nonfree. Both would change the licence of the
# result (see NOTICE.md); the build stays LGPL-2.1+ so it can be shipped beside anything.
# Linkage: desktop + Android substitute FF_LINK_SHARED so the ffmpeg CLI and MSE load the same
# libav DSOs. iOS keeps static (no CLI, no dylibs in the app).
FF_LINK_STATIC="--disable-shared --enable-static"
FF_LINK_SHARED="--disable-static --enable-shared --enable-pic"
FF_OPTS="
$FF_LINK_STATIC
--enable-ffmpeg --disable-ffplay --disable-ffprobe
--disable-encoders --disable-decoders --disable-muxers --disable-demuxers
--disable-protocols --disable-bsfs --disable-devices --disable-filters
--enable-network --disable-symver --disable-amd3dnow --disable-amd3dnowext --disable-doc
--enable-swscale
--enable-protocol=file,pipe,ymix
--enable-demuxer=aac,mpegts,mov,webvtt,srt,mp3,image2,image_png_pipe,matroska,ogg,wav,flac
--enable-muxer=ipod,mp3,mp4,webm,matroska,opus,image2,wav,null,flac
--enable-encoder=aac,libmp3lame,libshine,mpeg4,opus,movtext,webvtt,srt,subrip,mjpeg,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le
--enable-decoder=aac,aac_latm,ac3,eac3,srt,subrip,webvtt,mp3,mjpeg,apng,png,opus,vorbis,h264,hevc,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_u8,pcm_f32le,pcm_s16be,pcm_alaw,pcm_mulaw
--enable-filter=aresample,scale,format,thumbnail
--enable-bsf=aac_adtstoasc,vp9_superframe
--enable-libmp3lame --enable-libshine
"

# Autodetection is off: ffmpeg otherwise links whatever happens to be installed on the BUILD host,
# which produced binaries that died with a dyld error anywhere else (a Mac with Homebrew's libx11
# silently added a dependency on it). Only what is named above gets in.
FF_OPTS="$FF_OPTS --disable-xlib --disable-libxcb"

# --- optimisation ------------------------------------------------------------------------------
#
# -Os MUST go through --optflags. Passed via --extra-cflags it is silently discarded, because
# ffmpeg appends its own -O3 afterwards and the last flag wins (config.mak then reads "-Os -O3").
# Getting this right is worth ~30% of the binary.
FF_OPTFLAGS="-Os"
FF_SIZE_CFLAGS="-ffunction-sections -fdata-sections"

# The vendored lame/shine predate C23, where an empty parameter list means "no parameters".
# Apple clang 21 and GCC 15 default to it and reject shine's shine_mdct_initialise(config).
DEP_STD="-std=gnu17"

# --- guards ------------------------------------------------------------------------------------

# A distributed binary may only depend on what the target OS already ships. Called after every
# build; the allowed patterns differ per platform, so each caller passes its own.
assert_no_stray_deps() {
  local binary="$1" allowed="$2" listing="" od
  # Prefer ELF readers first: Android packs are built on macOS, where otool cannot
  # parse NEEDED. The `|| true` keeps `pipefail` from aborting under `set -e` when
  # readelf hits a PE binary (Windows): readelf -d returns non-zero on wrong magic,
  # we want to fall through to objdump below instead of killing the whole script.
  for od in llvm-readelf readelf; do
    command -v "$od" >/dev/null || continue
    listing="$({ "$od" -d "$binary" 2>/dev/null || true; } | awk '/NEEDED/ {print $NF}' | tr -d '[]')"
    if [ -n "$listing" ]; then break; fi
  done
  if [ -z "$listing" ]; then
    case "$(uname -s)" in
      Darwin) listing="$(otool -L "$binary" | tail -n +2 | awk '{print $1}')" ;;
      # ELF prints "NEEDED  libfoo.so"; PE prints "DLL Name: FOO.dll" — different field.
      # llvm-objdump is the fallback for CLANGARM64, which ships no GNU binutils, and whose
      # aarch64 PE output the MSYS2 binutils objdump cannot read either.
      *) for od in objdump llvm-objdump; do
           command -v "$od" >/dev/null || continue
           listing="$("$od" -p "$binary" 2>/dev/null | awk '/NEEDED/ {print $2} /DLL Name:/ {print $3}')"
           if [ -n "$listing" ]; then break; fi
         done ;;
    esac
  fi
  # An unreadable import table would otherwise pass the check below with an empty list.
  [ -n "$listing" ] || { echo "FATAL: cannot read the imports of $binary" >&2; return 1; }
  local stray
  # Case-insensitive: PE import names are upper-case for some DLLs and lower-case for others.
  stray="$(echo "$listing" | grep -viE "$allowed" || true)"
  if [ -n "$stray" ]; then
    echo "FATAL: $binary depends on libraries outside the OS:" >&2
    echo "$stray" | sed 's/^/  /' >&2
    return 1
  fi
  # Printed on success too: a surprise import is then visible in the log rather than only fatal.
  echo "  deps OK (OS only): $(echo "$listing" | tr '\n' ' ')"
}

# ffmpeg compiles its configure line into the binary and prints it with `ffmpeg -version`, so an
# absolute path from the build machine is published to every user.
assert_anonymous() {
  local binary="$1" hits
  hits="$(strings -a "$binary" | grep -cE "/(Users|home)/[^/ ]+" || true)"
  if [ "$hits" != "0" ]; then
    echo "FATAL: $binary embeds build-machine paths:" >&2
    strings -a "$binary" | grep -oE "/(Users|home)/[^\"' ]*" | sort -u | sed 's/^/  /' >&2
    return 1
  fi
  echo "  no build-machine paths"
}

# shine.pc lists "Libs: ... -lm -lshine". GNU ld resolves static libraries in order and needs the
# math lib AFTER libshine, or ffmpeg's configure link test fails on undefined sqrt/log/pow and
# reports the misleading "shine not found using pkg-config". macOS's linker does not care, so this
# only ever breaks on Linux.
fix_shine_pc() {
  local pc="$1/lib/pkgconfig/shine.pc"
  [ -f "$pc" ] || return 0
  sed 's/-lm -lshine/-lshine -lm/' "$pc" > "$pc.tmp" && mv "$pc.tmp" "$pc"
}

# Copy the ffmpeg CLI and its libav/libsw DSOs into a flat [pack] dir and rewrite install names
# so the set is relocatable ($ORIGIN / @loader_path). LAME/shine/dav1d/libvpx stay inside libav.
# $4 optional: ALLOWED_DEPS regex, applied to the CLI and every packed DSO.
pack_ffmpeg_shared() {
  local pack="$1" prefix="$2" binname="$3" allowed="${4:-}"
  rm -rf "$pack"
  mkdir -p "$pack"
  local srcbin=""
  if [ -f "$prefix/bin/ffmpeg.exe" ]; then
    srcbin="$prefix/bin/ffmpeg.exe"
  elif [ -f "$prefix/bin/ffmpeg" ]; then
    srcbin="$prefix/bin/ffmpeg"
  else
    echo "FATAL: no ffmpeg in $prefix/bin" >&2
    return 1
  fi
  cp "$srcbin" "$pack/$binname"
  chmod +x "$pack/$binname"
  # Versioned SONAMEs + unversioned symlinks; Windows DLLs live in bin/ after make install.
  # zlib1.dll + libwinpthread-1.dll are MinGW's shared libs that ffmpeg's --enable-zlib and
  # per-DSO pthread link pick up on Windows; ship them next to ffmpeg.exe. Non-Windows prefixes
  # don't have these in bin/ so the extra globs are a no-op there.
  local f
  for f in "$prefix/lib"/libav* "$prefix/lib"/libsw* "$prefix/bin"/av*.dll "$prefix/bin"/sw*.dll \
           "$prefix/lib"/av*.dll "$prefix/lib"/sw*.dll \
           "$prefix/bin"/zlib*.dll "$prefix/bin"/libwinpthread*.dll; do
    [ -e "$f" ] || continue
    case "$f" in *.a|*.pc|*.la) continue ;; esac
    cp -a "$f" "$pack/"
  done
  relocatable_pack "$pack" "$binname"
  if [ "$binname" = "libffmpeg.so" ]; then
    flatten_elf_sonames_unversioned "$pack"
  fi
  if [ -n "$allowed" ]; then
    assert_no_stray_deps "$pack/$binname" "$allowed"
    for f in "$pack"/libav* "$pack"/libsw* "$pack"/av*.dll "$pack"/sw*.dll; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      case "$f" in *.a|*.pc|*.la) continue ;; esac
      assert_no_stray_deps "$f" "$allowed"
    done
  fi
}

# Make [pack]/[binname] and sibling libav/libsw DSOs look next to each other at runtime.
relocatable_pack() {
  local pack="$1" binname="$2"
  local bin="$pack/$binname"
  case "$(uname -s)" in
    Darwin)
      local lib dep depbase
      for lib in "$pack"/libav*.dylib "$pack"/libsw*.dylib; do
        [ -f "$lib" ] || continue
        [ -L "$lib" ] && continue
        install_name_tool -id "@rpath/$(basename "$lib")" "$lib"
        otool -L "$lib" | awk '/libav|libsw/{print $1}' | while read -r dep; do
          depbase="$(basename "$dep")"
          [ -e "$pack/$depbase" ] || continue
          install_name_tool -change "$dep" "@rpath/$depbase" "$lib"
        done
        install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
      done
      otool -L "$bin" | awk '/libav|libsw/{print $1}' | while read -r dep; do
        depbase="$(basename "$dep")"
        [ -e "$pack/$depbase" ] || continue
        install_name_tool -change "$dep" "@rpath/$depbase" "$bin"
      done
      install_name_tool -add_rpath "@loader_path" "$bin" 2>/dev/null || true
      ;;
    Linux|MINGW*|MSYS*|CLANG*|UCRT*)
      # Linked with -rpath $ORIGIN (see build-*.sh). Windows loads DLLs from the exe directory.
      if command -v patchelf >/dev/null; then
        local so
        for so in "$pack"/libav*.so* "$pack"/libsw*.so* "$bin"; do
          [ -f "$so" ] && [ ! -L "$so" ] || continue
          patchelf --set-rpath '$ORIGIN' "$so"
        done
      fi
      ;;
  esac
}

# Android's installer only extracts filenames that end in ".so" (not libavcodec.so.61).
# Rewrite SONAME + DT_NEEDED to the unversioned name and keep only that file. Needs patchelf.
flatten_elf_sonames_unversioned() {
  local pack="$1"
  command -v patchelf >/dev/null || {
    echo "FATAL: patchelf is required to flatten Android SONAMEs (libfoo.so.N → libfoo.so)" >&2
    return 1
  }
  local f base unversioned needed
  for f in "$pack"/libav*.so.* "$pack"/libsw*.so.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base="$(basename "$f")"
    unversioned="${base%%.so.*}.so"
    cp -f "$f" "$pack/$unversioned"
    patchelf --set-soname "$unversioned" "$pack/$unversioned"
  done
  for f in "$pack"/libav*.so.* "$pack"/libsw*.so.*; do
    [ -e "$f" ] || continue
    rm -f "$f"
  done
  for f in "$pack"/*.so; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    # Capture NEEDED first: replacing while reading the pipe is fine (patchelf rewrites in place).
    patchelf --print-needed "$f" | while read -r needed; do
      case "$needed" in
        libav*.so.*|libsw*.so.*)
          unversioned="${needed%%.so.*}.so"
          patchelf --replace-needed "$needed" "$unversioned" "$f"
          ;;
      esac
    done
    patchelf --set-rpath '$ORIGIN' "$f"
  done
}

# shine ships no configure; bootstrap needs autoreconf and libtoolize. Failing loudly here beats
# exit 127 from a missing tool three steps later.
bootstrap_shine() {
  [ -x "$SRC/shine/configure" ] && return 0
  command -v autoreconf >/dev/null || { echo "autoreconf missing (install autoconf/automake/libtool)" >&2; return 1; }
  ( cd "$SRC/shine" && ./bootstrap )
}

# Applied to a freshly checked-out submodule. Idempotent: a second run is a no-op rather than an
# error, so re-running a build locally does not require resetting src/ffmpeg by hand.
apply_ymix_patch() {
  local patch="$ROOT/patches/0001-ymix-protocol.patch"
  if [ -f "$SRC/ffmpeg/libavformat/ymix.c" ]; then
    echo "[patch] ymix already applied"
    return 0
  fi
  echo "[patch] applying ymix to src/ffmpeg"
  git -C "$SRC/ffmpeg" apply --verbose "$patch"
}

# H.264 VT must not Require hardware: simulator has none.
apply_vt_allow_sw_patch() {
  local patch="$ROOT/patches/0002-videotoolbox-allow-sw-h264.patch"
  local vt="$SRC/ffmpeg/libavcodec/videotoolbox.c"
  if grep -q "RequireHardwareAcceleratedVideoDecoder," "$vt" 2>/dev/null; then
    echo "[patch] applying videotoolbox allow-sw H.264"
    git -C "$SRC/ffmpeg" apply --verbose "$patch"
  else
    echo "[patch] videotoolbox allow-sw already applied"
  fi
}
