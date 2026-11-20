#!/bin/bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 /path/to/AudibleSupport [architecture ...]" >&2
    exit 2
fi

destination="$1"
shift
if [[ $# -eq 0 ]]; then
    set -- "$(uname -m)"
fi
case "$#:$*" in
    1:arm64|1:x86_64|"2:arm64 x86_64"|"2:x86_64 arm64") ;;
    *) echo "error: Expected arm64, x86_64, or both for the Audible helper." >&2; exit 2 ;;
esac

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
    echo "error: Install uv to build DownAudible's Audible helper. See https://docs.astral.sh/uv/getting-started/installation/." >&2
    exit 1
fi

source_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$source_root/Scripts/Audible"
cache_root="${PROJECT_TEMP_DIR:-$source_root/.build}/downaudible-audible"
source_hash="$(cat "$0" "$helper/"*.py "$helper/audible-helper.spec" "$helper/pyproject.toml" "$helper/uv.lock" | shasum -a 256 | cut -d ' ' -f 1)"
bundle_hash="$source_hash $*"

mkdir -p "$cache_root"
exec 9>"$cache_root/build.lock"
/usr/bin/lockf 9

if [[ -f "$destination/built-hash" && $(cat "$destination/built-hash") == "$bundle_hash" ]]; then
    complete=yes
    for architecture in "$@"; do
        if [[ ! -x "$destination/$architecture/audible-helper" ||
              ! -f "$destination/$architecture/audible-helper.pkg" ||
              ! -d "$destination/$architecture/_internal" ]]; then
            complete=no
            break
        fi
    done
    if [[ "$complete" == yes ]]; then
        exit 0
    fi
fi

parent="$(dirname -- "$destination")"
mkdir -p "$parent"
staging="$(mktemp -d "$parent/.audible-support.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

for architecture in "$@"; do
    cache="$cache_root/$architecture"
    if [[ ! -f "$cache/built-hash" || $(cat "$cache/built-hash") != "$source_hash" ||
          ! -x "$cache/out/audible-helper/audible-helper" ||
          ! -f "$cache/out/audible-helper/audible-helper.pkg" ||
          ! -d "$cache/out/audible-helper/_internal" ]]; then
        (
            python_arch="$architecture"
            if [[ "$architecture" == arm64 ]]; then
                python_arch=aarch64
            fi
            mkdir -p "$cache"
            build="$(mktemp -d "$cache/.build.XXXXXX")"
            trap 'rm -rf "$build"' EXIT
            UV_PROJECT_ENVIRONMENT="$cache/venv" MACOSX_DEPLOYMENT_TARGET=15.0 \
                uv run --project "$helper" --locked --python "cpython-3.13-macos-$python_arch-none" pyinstaller \
                --noconfirm --distpath "$build/out" --workpath "$build/work" \
                "$helper/audible-helper.spec"
            rm -rf "$cache/out"
            mv "$build/out" "$cache/out"
            printf '%s\n' "$source_hash" > "$cache/built-hash"
        )
    fi
done

if [[ $# -eq 1 ]]; then
    ditto "$cache_root/$1/out/audible-helper" "$staging/new/$1"
else
    arm="$cache_root/arm64/out/audible-helper"
    intel="$cache_root/x86_64/out/audible-helper"
    shared="$staging/new/_internal"
    lipo="$(xcrun --find lipo)"
    ditto "$arm/_internal" "$shared"

    merge_binary() {
        local arm_file="$1" intel_file="$2" output="$3"
        if ! "$lipo" -verify_arch arm64 "$arm_file" || ! "$lipo" -verify_arch x86_64 "$intel_file"; then
            echo "error: Missing a native Audible helper slice for ${output##*/}." >&2
            exit 1
        fi
        "$lipo" -create "$arm_file" "$intel_file" -output "$output"
        /usr/bin/codesign --force --sign - "$output"
    }

    while IFS= read -r -d '' arm_file; do
        if "$lipo" -archs "$arm_file" >/dev/null 2>&1; then
            relative="${arm_file#"$arm/_internal/"}"
            merge_binary "$arm_file" "$intel/_internal/$relative" "$shared/$relative"
        fi
    done < <(find "$arm/_internal" -type f -print0)

    while IFS= read -r -d '' intel_file; do
        relative="${intel_file#"$intel/_internal/"}"
        if "$lipo" -archs "$intel_file" >/dev/null 2>&1 &&
           { ! "$lipo" -verify_arch arm64 "$shared/$relative" ||
             ! "$lipo" -verify_arch x86_64 "$shared/$relative"; }; then
            echo "error: No universal counterpart for Audible library $relative." >&2
            exit 1
        fi
    done < <(find "$intel/_internal" -type f -print0)

    # Keep each interpreter's frozen Python archive separate. The launcher and all loaded libraries are universal.
    mkdir -p "$staging/new/arm64" "$staging/new/x86_64"
    merge_binary "$arm/audible-helper" "$intel/audible-helper" "$staging/new/arm64/audible-helper"
    install -m 755 "$staging/new/arm64/audible-helper" "$staging/new/x86_64/audible-helper"
    for architecture in "$@"; do
        support="$staging/new/$architecture"
        install -m 644 "$cache_root/$architecture/out/audible-helper/audible-helper.pkg" "$support/"
        ln -s ../_internal "$support/_internal"
    done
fi

printf '%s\n' "$bundle_hash" > "$staging/new/built-hash"

# Replace the directory to remove any helpers or libraries no longer shipped.
if [[ -e "$destination" || -L "$destination" ]]; then
    mv "$destination" "$staging/previous"
fi
if ! mv "$staging/new" "$destination"; then
    if [[ -e "$staging/previous" || -L "$staging/previous" ]]; then
        if ! mv "$staging/previous" "$destination"; then
            trap - EXIT
            echo "error: Previous Audible helpers are at $staging/previous" >&2
        fi
    fi
    exit 1
fi
