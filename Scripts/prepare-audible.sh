#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/AudibleSupport" >&2
    exit 2
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
    echo "error: Install uv to build DownAudible's Audible helper. See https://docs.astral.sh/uv/getting-started/installation/." >&2
    exit 1
fi

source_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$source_root/Scripts/Audible"
cache_root="${PROJECT_TEMP_DIR:-$source_root/.build}/downaudible-audible"
destination="$1"
source_hash="$(cat "$0" "$helper/"*.py "$helper/pyproject.toml" "$helper/uv.lock" | shasum -a 256 | cut -d ' ' -f 1)"

if [[ ! -f "$cache_root/built-hash" || $(cat "$cache_root/built-hash") != "$source_hash" || ! -x "$cache_root/out/audible-helper/audible-helper" ]]; then
    mkdir -p "$cache_root"
    export UV_PROJECT_ENVIRONMENT="$cache_root/venv"
    export MACOSX_DEPLOYMENT_TARGET=15.0
    uv run --project "$helper" --locked --python 3.13 pyinstaller \
        --name audible-helper \
        --onedir --target-architecture arm64 --noupx --noconfirm \
        --distpath "$cache_root/out" --workpath "$cache_root/build" --specpath "$cache_root" \
        "$helper/audible_helper.py"
    printf '%s\n' "$source_hash" > "$cache_root/built-hash"
fi

if [[ ! -f "$destination/built-hash" || $(cat "$destination/built-hash") != "$source_hash" || ! -x "$destination/audible-helper" ]]; then
    parent="$(dirname -- "$destination")"
    mkdir -p "$parent"
    staging="$(mktemp -d "$parent/.audible-support.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    ditto "$cache_root/out/audible-helper" "$staging/new"
    printf '%s\n' "$source_hash" > "$staging/new/built-hash"
    # Replacing the directory removes libraries that a newer helper no longer ships.
    if [[ -e "$destination" || -L "$destination" ]]; then
        mv "$destination" "$staging/previous"
    fi
    if ! mv "$staging/new" "$destination"; then
        if [[ -e "$staging/previous" || -L "$staging/previous" ]]; then
            if ! mv "$staging/previous" "$destination"; then
                trap - EXIT
                echo "error: Previous Audible helper is at $staging/previous" >&2
            fi
        fi
        exit 1
    fi
fi
