#!/bin/bash
set -euo pipefail

[[ ${ENABLE_HARDENED_RUNTIME:-NO} == YES && ${CODE_SIGNING_ALLOWED:-NO} == YES ]] || exit 0

resources=${1:?Usage: sign-release-tools.sh resources-directory}
identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
audible="$resources/AudibleSupport"
media="$resources/MediaSupport"
signing=(--force --sign "$identity")

helpers=()
for architecture in arm64 x86_64; do
    support="$audible/$architecture"
    if [[ -d "$support" ]]; then
        find "$support/_internal" -type f \( -name '*.dylib' -o -name '*.so' \) \
            -exec /usr/bin/codesign "${signing[@]}" {} +
        helpers+=("$support/audible-helper")
    fi
done
if [[ ${#helpers[@]} -eq 0 ]]; then
    echo "error: No Audible helpers to sign in $audible" >&2
    exit 1
fi

# The hardened Python executable needs an Apple signing team shared by its libraries.
if [[ "$identity" != - ]]; then
    signing+=(--options runtime)
fi
/usr/bin/codesign "${signing[@]}" \
    "${helpers[@]}" "$media/ffmpeg" "$media/ffprobe"
