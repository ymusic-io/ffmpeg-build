# ffmpeg-build

FFmpeg builds for YMusic: Android, macOS, Linux and Windows. Binaries are published as GitHub
Releases, one asset per platform plus `SHA256SUMS`.

## What gets built

A trimmed ffmpeg, 6–8 MB against a stock build's ~70 MB. The feature set is defined once in
`scripts/common.sh` and shared by every target.

| target | how |
| --- | --- |
| `macos-x86_64`, `macos-arm64` | native, one runner each (no cross-compile) |
| `linux-x86_64`, `linux-arm64` | native |
| `windows-x86_64` | native, MSYS2 MINGW64 |
| `windows-arm64` | native, MSYS2 CLANGARM64 |
| `android-{arm64-v8a,armeabi-v7a,x86,x86_64}` | NDK r27+, API 21, 16 KB page aligned |

## Building locally

```bash
git clone --recursive --shallow-submodules <this repo> && cd ffmpeg-build
scripts/build-desktop.sh out/ffmpeg              # host platform
scripts/build-android.sh arm64-v8a out/libffmpeg.so
```

`--shallow-submodules` fetches 21 MB instead of 654 MB. Each script applies
`patches/0001-ymix-protocol.patch` to the ffmpeg submodule first; re-running is safe.

## The `ymix` protocol

`ymix:<socket_path>` — reads and writes a file through a helper process over a Unix socket, for
Android's `content://` documents that FFmpeg cannot open directly.

Kept as a patch against the upstream commit in `patches/UPSTREAM_BASE`, so moving to a newer FFmpeg
is re-applying one file. Excluded from the Windows build: `ymix.c` needs `<sys/un.h>`.

## Licence

Output is **LGPL-2.1-or-later** (FFmpeg), with LGPL-2.0-or-later LAME and Shine statically linked
in. Components and sources: [NOTICE.md](NOTICE.md).
