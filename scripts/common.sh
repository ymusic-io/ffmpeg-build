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
# Deliberately NOT enabled: --enable-gpl and --enable-nonfree. Both would change the licence of the
# result (see NOTICE.md); the build stays LGPL-2.1+ so it can be shipped beside anything.
FF_OPTS="
--disable-shared --enable-static
--enable-ffmpeg --disable-ffplay --disable-ffprobe
--disable-encoders --disable-decoders --disable-muxers --disable-demuxers
--disable-protocols --disable-bsfs --disable-devices --disable-filters
--enable-network --disable-symver --disable-amd3dnow --disable-amd3dnowext --disable-doc
--enable-swscale
--enable-protocol=file,pipe,ymix
--enable-demuxer=aac,mpegts,mov,webvtt,srt,mp3,image2,image_png_pipe,matroska,wav,flac
--enable-muxer=ipod,mp3,mp4,webm,opus,image2,wav,null,flac
--enable-encoder=aac,libmp3lame,libshine,mpeg4,opus,movtext,webvtt,srt,subrip,mjpeg,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le
--enable-decoder=aac,aac_latm,srt,subrip,webvtt,mp3,mjpeg,apng,png,opus,h264,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_u8,pcm_f32le,pcm_s16be,pcm_alaw,pcm_mulaw
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
# absolute path from the build machine is published to every user. CI runners are anonymous, but a
# local build is not — this catches it either way.
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
