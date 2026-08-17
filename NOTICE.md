# Third-party components

| Component | Licence | Source |
| --- | --- | --- |
| FFmpeg | LGPL-2.1-or-later | https://github.com/FFmpeg/FFmpeg |
| LAME | LGPL-2.0-or-later | https://github.com/tanersener/lame (mirror of https://lame.sourceforge.io) |
| Shine | LGPL-2.0-or-later | https://github.com/toots/shine |

Built without `--enable-gpl` and without `--enable-nonfree`. `ffmpeg -L` reports the licence of any
given binary.

LAME and Shine are statically linked into the `ffmpeg` binary. This repository, with its pinned
submodules and `patches/`, is the corresponding source.
