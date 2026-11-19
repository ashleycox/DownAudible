#!/bin/bash
set -euo pipefail

destination=${1:?Usage: prepare-media.sh destination}
script_dir="$(cd "$(dirname "$0")" && pwd)"
version=8.1.2
archive="ffmpeg-$version.tar.xz"
archive_sha256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
lame_version=4.0
lame_archive="lame-$lame_version.tar.gz"
lame_sha256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
sdk="$(xcrun --sdk macosx --show-sdk-path)"
compiler="$(xcrun --sdk macosx --find clang)"
minimum_macos=15.0
build_id="$(shasum -a 256 "$script_dir/prepare-media.sh" "$script_dir/Media/"*.patch "$script_dir/Media/LAME/"*.patch | awk '{print $1}' | shasum -a 256 | cut -c 1-16)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
cache_root="${DOWNAUDIBLE_MEDIA_CACHE:-$HOME/Library/Caches/DownAudible/FFmpeg}"
cache="$cache_root/$version-$sdk_version-$build_id"
mkdir -p "$cache" "$destination"

if [ ! -x "$cache/ffmpeg" ] || [ ! -x "$cache/ffprobe" ] ||
    [ ! -f "$cache/COPYING.LGPLv2.1" ] || [ ! -f "$cache/LAME-COPYING" ]; then
    echo "Building FFmpeg $version and LAME $lame_version for DownAudible (first build only)"
    build_dir="$(mktemp -d "$cache_root/.build.XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT
    jobs="$(sysctl -n hw.logicalcpu)"
    lame_prefix="$build_dir/lame"
    curl --fail --silent --show-error --location --retry 2 \
        "https://downloads.sourceforge.net/project/lame/lame/$lame_version/$lame_archive" --output "$build_dir/$lame_archive"
    printf '%s  %s\n' "$lame_sha256" "$build_dir/$lame_archive" | shasum -a 256 --check --status
    tar -xzf "$build_dir/$lame_archive" -C "$build_dir"
    (
        cd "$build_dir/lame-$lame_version" &&
        patch -p1 < "$script_dir/Media/LAME/optional-pkg-config.patch" &&
        CC="$compiler" ac_cv_prog_cc_c23=no \
            CFLAGS="-O2 -std=gnu17 -Wno-implicit-function-declaration -isysroot $sdk -arch arm64 -mmacosx-version-min=$minimum_macos" \
            LDFLAGS="-isysroot $sdk -arch arm64 -mmacosx-version-min=$minimum_macos" \
            ./configure --prefix="$lame_prefix" --disable-frontend --disable-decoder \
                --disable-shared --enable-static --disable-dependency-tracking --disable-debug &&
        make -j "$jobs" &&
        make install
    ) > "$build_dir/lame.log" 2>&1 || { tail -n 80 "$build_dir/lame.log"; exit 1; }
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
        --extra-cflags="-arch arm64 -mmacosx-version-min=$minimum_macos -I$lame_prefix/include" \
        --extra-ldflags="-arch arm64 -mmacosx-version-min=$minimum_macos -L$lame_prefix/lib" \
        --disable-autodetect --enable-zlib --enable-libmp3lame --disable-debug --disable-doc --disable-ffplay \
        --disable-network --disable-everything --disable-devices \
        --enable-protocol=file,pipe \
        --enable-demuxer=aa,mov,mp3,concat,image2,image_jpeg_pipe,image_png_pipe,ffmetadata,flac \
        --enable-muxer=ipod,mp4,mp3,ffmetadata,image2,null,flac \
        --enable-decoder=aac,mp3,mp3float,sipr,ac3,eac3,mjpeg,png,pcm_s16le,flac \
        --enable-encoder=aac,mjpeg,png,pcm_s16le,flac,libmp3lame \
        --enable-parser=aac,mpegaudio,ac3,mjpeg,png,flac \
        --enable-filter=aresample,aformat,asetpts,trim,atrim,format,null,anull,concat \
        --enable-bsf=aac_adtstoasc \
        > "$build_dir/configure.log" 2>&1 || { cat "$build_dir/configure.log"; tail -n 60 ffbuild/config.log; exit 1; }
    make -j "$jobs" ffmpeg ffprobe > "$build_dir/build.log" 2>&1 || {
        tail -n 80 "$build_dir/build.log"
        exit 1
    }
    cp "$build_dir/lame-$lame_version/COPYING" "$cache/LAME-COPYING"
    mv ffmpeg ffprobe COPYING.LGPLv2.1 "$cache/"
fi

install -m 755 "$cache/ffmpeg" "$cache/ffprobe" "$destination/"
install -m 644 "$cache/COPYING.LGPLv2.1" "$destination/"
install -m 644 "$cache/LAME-COPYING" "$destination/"
