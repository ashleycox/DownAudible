#!/bin/bash
set -euo pipefail

[[ ${ENABLE_HARDENED_RUNTIME:-NO} == YES && ${CODE_SIGNING_ALLOWED:-NO} == YES ]] || exit 0

resources=${1:?Usage: sign-release-tools.sh resources-directory}
identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
audible="$resources/AudibleSupport"
media="$resources/MediaSupport"
signing=(--force --sign "$identity")

find "$audible/_internal" -type f \( -name '*.dylib' -o -name '*.so' \) \
    -exec /usr/bin/codesign "${signing[@]}" {} +

# The hardened Python executable needs an Apple signing team shared by its libraries.
if [[ "$identity" != - ]]; then
    signing+=(--options runtime)
fi
/usr/bin/codesign "${signing[@]}" \
    "$audible/audible-helper" "$media/ffmpeg" "$media/ffprobe"
