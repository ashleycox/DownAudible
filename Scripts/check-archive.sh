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
    -target "$(uname -m)-apple-macosx15.0" \
    DownAudible/App/DownAudibleIdentity.swift \
    DownAudible/Audible/{AudibleAnnotations,AudibleClient,AudibleInsights}.swift \
    DownAudible/Media/*.swift \
    DownAudible/Library/{AppleBooks,ArchiveLayout,ArchiveVerification,ArchiveWatcher,ArchiveWorker,IncompleteDownloads,LibraryExport}.swift \
    DownAudible/Library/{Audiobookshelf,DownloadPacing,ShelfUploadQueue,SpreadsheetExport}.swift \
    DownAudible/Library/{GoodreadsExport,LibraryBrowsing,LibraryCatalog,LibraryFilterSuggestions,LibraryOrganization}.swift \
    DownAudible/Library/{QueueCompletionSound,TransferFeedback}.swift \
    DownAudible/Library/{Preferences,TransferLog,TransferQueue,Transfers}.swift \
    Tests/ArchiveChecks.swift -o "$scratch/checks"
"$scratch/checks"
