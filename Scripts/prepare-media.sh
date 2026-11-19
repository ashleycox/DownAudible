#!/bin/bash
set -euo pipefail

destination=${1:?Usage: prepare-media.sh destination}
script_dir="$(cd "$(dirname "$0")" && pwd)"
version=8.1.2
archive="ffmpeg-$version.tar.xz"
archive_sha256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
sdk="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --sdk macosx --find clang)"
minimum_macos=15.0
build_id="$(shasum -a 256 "$script_dir/prepare-media.sh" "$script_dir/Media/"*.patch | awk '{print $1}' | shasum -a 256 | cut -c 1-16)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
cache_root="${DOWNAUDIBLE_MEDIA_CACHE:-$HOME/Library/Caches/DownAudible/FFmpeg}"
cache="$cache_root/$version-$sdk_version-$build_id"
mkdir -p "$cache" "$destination"

if [ ! -x "$cache/ffmpeg" ] || [ ! -x "$cache/ffprobe" ] || [ ! -f "$cache/COPYING.LGPLv2.1" ]; then
    echo "Building FFmpeg $version for DownAudible (first build only)"
    build_dir="$(mktemp -d "$cache_root/.build.XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT
    curl --fail --silent --show-error --location --retry 2 \
        "https://ffmpeg.org/releases/$archive" --output "$build_dir/$archive"
    printf '%s  %s\n' "$archive_sha256" "$build_dir/$archive" | shasum -a 256 --check --status
    tar -xJf "$build_dir/$archive" -C "$build_dir"
    cd "$build_dir/ffmpeg-$version"
    for patch_file in "$script_dir/Media/"*.patch; do
        patch -p1 < "$patch_file"
    done
    ./configure \
        --arch=aarch64 --target-os=darwin --cc="$compiler" --sysroot="$sdk" \
        --host-cflags="-isysroot $sdk" --host-ldflags="-isysroot $sdk" \
        --extra-cflags="-arch arm64 -mmacosx-version-min=$minimum_macos" \
        --extra-ldflags="-arch arm64 -mmacosx-version-min=$minimum_macos" \
        --disable-autodetect --enable-zlib --disable-debug --disable-doc --disable-ffplay \
        --disable-network --disable-everything --disable-devices \
        --enable-protocol=file,pipe \
        --enable-demuxer=aa,mov,mp3,concat,image2,image_jpeg_pipe,image_png_pipe,ffmetadata \
        --enable-muxer=ipod,mp4,mp3,ffmetadata,image2,null \
        --enable-decoder=aac,mp3,mp3float,sipr,ac3,eac3,mjpeg,png,pcm_s16le \
        --enable-encoder=aac,mjpeg,png,pcm_s16le \
        --enable-parser=aac,mpegaudio,ac3,mjpeg,png \
        --enable-filter=aresample,aformat,asetpts,trim,atrim,format,null,anull \
        --enable-bsf=aac_adtstoasc \
        > "$build_dir/configure.log" 2>&1 || { cat "$build_dir/configure.log"; tail -n 60 ffbuild/config.log; exit 1; }
    make -j "$(sysctl -n hw.logicalcpu)" ffmpeg ffprobe > "$build_dir/build.log" 2>&1 || {
        tail -n 80 "$build_dir/build.log"
        exit 1
    }
    mv ffmpeg ffprobe COPYING.LGPLv2.1 "$cache/"
fi

install -m 755 "$cache/ffmpeg" "$cache/ffprobe" "$destination/"
install -m 644 "$cache/COPYING.LGPLv2.1" "$destination/"
