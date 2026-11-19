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
for architecture in "$@"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) echo "error: Unsupported Audible helper architecture: $architecture" >&2; exit 2 ;;
    esac
done

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
    echo "error: Install uv to build DownAudible's Audible helper. See https://docs.astral.sh/uv/getting-started/installation/." >&2
    exit 1
fi

source_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$source_root/Scripts/Audible"
cache_root="${PROJECT_TEMP_DIR:-$source_root/.build}/downaudible-audible"
source_hash="$(cat "$0" "$helper/"*.py "$helper/pyproject.toml" "$helper/uv.lock" | shasum -a 256 | cut -d ' ' -f 1)"
bundle_hash="$source_hash $*"

mkdir -p "$cache_root"
exec 9>"$cache_root/build.lock"
/usr/bin/lockf 9

if [[ -f "$destination/built-hash" && $(cat "$destination/built-hash") == "$bundle_hash" ]]; then
    complete=yes
    for architecture in "$@"; do
        if [[ ! -x "$destination/$architecture/audible-helper" || ! -d "$destination/$architecture/_internal" ]]; then
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
          ! -x "$cache/out/audible-helper/audible-helper" || ! -d "$cache/out/audible-helper/_internal" ]]; then
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
                --name audible-helper \
                --onedir --target-architecture "$architecture" --noupx --noconfirm \
                --distpath "$build/out" --workpath "$build/work" --specpath "$build" \
                "$helper/audible_helper.py"
            rm -rf "$cache/out"
            mv "$build/out" "$cache/out"
            printf '%s\n' "$source_hash" > "$cache/built-hash"
        )
    fi
    ditto "$cache/out/audible-helper" "$staging/new/$architecture"
done
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
