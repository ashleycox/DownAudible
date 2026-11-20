#!/bin/bash
set -euo pipefail

app=${1:?Usage: check-bundle-architectures.sh /path/to/App.app architecture [architecture]}
shift
if [[ $# -eq 0 || ! -d "$app/Contents" ]]; then
    echo "error: Specify a macOS app bundle and at least one required architecture." >&2
    exit 2
fi

lipo="$(xcrun --find lipo)"
failed=no
count=0
while IFS= read -r -d '' file; do
    if ! slices=$("$lipo" -archs "$file" 2>/dev/null); then
        continue
    fi
    count=$((count + 1))
    for architecture in "$@"; do
        if [[ " $slices " != *" $architecture "* ]]; then
            echo "error: ${file#"$app/"} includes $slices. This build requires $*." >&2
            failed=yes
            break
        fi
    done
done < <(find "$app/Contents" -type f -print0)

if [[ "$count" -eq 0 ]]; then
    echo "error: No Mach-O files found in $app." >&2
    exit 1
fi
if [[ "$failed" == yes ]]; then
    exit 1
fi
echo "Verified $count Mach-O files contain $*."
