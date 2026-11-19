#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/downaudible-checks.XXXXXX")"

cleanup() {
    if [[ -f "$scratch/checks" ]]; then unlink "$scratch/checks"; fi
    rmdir "$scratch"
}
trap cleanup EXIT

xcrun swiftc -warnings-as-errors -swift-version 6 -strict-concurrency=complete \
    -target arm64-apple-macosx15.0 \
    DownAudible/Audible/AudibleClient.swift \
    DownAudible/Media/MediaModels.swift \
    DownAudible/Library/{ArchiveLayout,Preferences,Transfers,LibraryExport,TransferLog}.swift \
    Tests/ArchiveChecks.swift -o "$scratch/checks"
"$scratch/checks"
