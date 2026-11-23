#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s destination x64|arm64 llvm-mingw-directory\n' "$0" >&2
    exit 2
fi

destination=$1
architecture=$2
toolchain=$3
case "$architecture" in
    x64) target=x86_64 ;;
    arm64) target=aarch64 ;;
    *) printf 'Unsupported Windows architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac

repository="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
source_cache="${DOWNAUDIBLE_WINDOWS_CACHE:-${TMPDIR:-/tmp}/downaudible-windows}/downloads"
mkdir -p "$source_cache" "$destination"
source_cache="$(cd "$source_cache" && pwd)"
destination="$(cd "$destination" && pwd)"
cross="$target-w64-mingw32"
compiler="$cross-gcc"
if [[ ! -x "$toolchain/bin/$compiler" ]]; then
    printf 'Missing Windows cross compiler: %s\n' "$toolchain/bin/$compiler" >&2
    exit 1
fi
export PATH="$toolchain/bin:$PATH"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-946684800}"
if [[ "$(uname -s)" == Darwin ]]; then
    sha256=(shasum -a 256)
else
    sha256=(sha256sum)
fi

fetch() {
    local name=$1 url=$2 hash=$3 scratch path
    path="$source_cache/$name"
    if [[ -f "$path" ]] && printf '%s  %s\n' "$hash" "$path" | "${sha256[@]}" --check --status; then
        return
    fi
    scratch="$(mktemp "$source_cache/download.XXXXXX")"
    if curl --fail --silent --show-error --location --retry 2 "$url" --output "$scratch" &&
        printf '%s  %s\n' "$hash" "$scratch" | "${sha256[@]}" --check --status; then
        mv -f "$scratch" "$path"
    else
        rm -f "$scratch"
        printf 'Could not verify %s\n' "$name" >&2
        exit 1
    fi
}

fetch ffmpeg-8.1.2.tar.xz https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz \
    464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
fetch lame-4.0.tar.gz https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz \
    3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
fetch zlib-1.4.tar.gz https://zlib.net/fossils/zlib-1.4.tar.gz \
    02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584

build="$(mktemp -d "${TMPDIR:-/tmp}/downaudible-$architecture-media.XXXXXX")"
trap 'rm -rf "$build"' EXIT
jobs="${DOWNAUDIBLE_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
make_command="${DOWNAUDIBLE_MAKE:-make}"
prefix="$build/prefix"
mkdir -p "$prefix/include" "$prefix/lib"
tar -xzf "$source_cache/lame-4.0.tar.gz" -C "$build"
tar -xzf "$source_cache/zlib-1.4.tar.gz" -C "$build"
tar -xJf "$source_cache/ffmpeg-8.1.2.tar.xz" -C "$build"

printf 'Building zlib and LAME for Windows %s\n' "$architecture"
(
    cd "$build/zlib-1.4" &&
    "$make_command" -j "$jobs" -f win32/Makefile.gcc PREFIX="$cross-" libz.a &&
    cp zlib.h zconf.h "$prefix/include/" &&
    cp libz.a "$prefix/lib/"
) >"$build/zlib.log" 2>&1 || { tail -n 80 "$build/zlib.log" >&2; exit 1; }
(
    cd "$build/lame-4.0" &&
    patch -p1 < "$repository/Scripts/Media/LAME/optional-pkg-config.patch" &&
    CC="$compiler" AR="$cross-ar" RANLIB="$cross-ranlib" ac_cv_prog_cc_c23=no \
        CFLAGS='-O2 -std=gnu17 -Wno-implicit-function-declaration' \
        ./configure --host="$target-w64-mingw32" --prefix="$prefix" \
          --disable-frontend --disable-decoder --disable-shared --enable-static \
          --disable-dependency-tracking --disable-debug &&
    "$make_command" -j "$jobs" &&
    "$make_command" install
) >"$build/lame.log" 2>&1 || { tail -n 80 "$build/lame.log" >&2; exit 1; }

printf 'Building FFmpeg and FFprobe for Windows %s\n' "$architecture"
cd "$build/ffmpeg-8.1.2"
for patch_file in "$repository/Scripts/Media/"*.patch; do patch -p1 < "$patch_file"; done
./configure --enable-cross-compile --arch="$target" --target-os=mingw32 \
    --cross-prefix="$cross-" --cc="$compiler" --host-cc=/usr/bin/clang --pkg-config=false \
    --extra-cflags="-I../prefix/include" --extra-ldflags="-L../prefix/lib -Wl,--no-insert-timestamp" \
    --disable-x86asm --disable-autodetect --enable-zlib --enable-libmp3lame \
    --disable-debug --disable-doc --disable-ffplay --disable-network --disable-everything --disable-devices \
    --enable-protocol=file,pipe \
    --enable-demuxer=aa,mov,mp3,concat,image2,image_jpeg_pipe,image_png_pipe,ffmetadata,flac,wav,aac,aiff \
    --enable-muxer=ipod,mp4,mp3,ffmetadata,image2,null,flac,wav \
    --enable-decoder=aac,mp3,mp3float,sipr,ac3,eac3,mjpeg,png,flac,pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32le,pcm_f64le,pcm_f32be,pcm_f64be \
    --enable-encoder=aac,mjpeg,png,pcm_s16le,flac,libmp3lame \
    --enable-parser=aac,mpegaudio,ac3,mjpeg,png,flac \
    --enable-filter=aresample,aformat,asetpts,trim,atrim,format,null,anull,concat \
    --enable-bsf=aac_adtstoasc,setts \
    >"$build/configure.log" 2>&1 || { tail -n 70 "$build/configure.log" >&2; tail -n 55 ffbuild/config.log >&2; exit 1; }
"$make_command" -j "$jobs" ffmpeg.exe ffprobe.exe >"$build/build.log" 2>&1 || {
    tail -n 80 "$build/build.log" >&2
    exit 1
}
cp ffmpeg.exe ffprobe.exe COPYING.LGPLv2.1 "$destination/"
cp "$build/lame-4.0/COPYING" "$destination/LAME-COPYING"
cp "$build/zlib-1.4/LICENSE" "$destination/ZLIB-LICENSE"
