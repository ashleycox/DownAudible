import Foundation
import UserNotifications

@main
struct ArchiveChecks {
    static func main() async throws {
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: workspace) }
        let root = workspace.appending(path: "Books")
        let outside = workspace.appending(path: "Other")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let title = ArchiveTitle(title: "My Great Book", author: "Me", asin: "B000000001")
        let layout = ArchiveLayout(root: root, template: ArchiveLayout.defaultTemplate)
        check(try layout.directory(for: title, format: "aax").path.hasSuffix("/aax/Me/My Great Book"))
        check(try layout.directory(for: title, format: "m4b").path.hasSuffix("/m4b/Me/My Great Book"))
        check(!ArchiveLayout(root: root, template: "../{title}").isValid)
        check(!ArchiveLayout(root: root, template: "{typo}").isValid)
        try checkMediaChapterBounds()
        try checkLosslessChapters()
        try await checkActivationRefresh(in: workspace)
        try await checkDownloadAfterActivationFailure(in: workspace)
        try await checkAAXCleanup(in: workspace)
        let literal = ArchiveTitle(title: "{author}/Book", author: "Name/Name", asin: nil)
        check(try layout.directory(for: literal, format: "m4b").path.hasSuffix("/m4b/Name-Name/{author}-Book"))
        try manager.createSymbolicLink(at: root.appending(path: "aax"), withDestinationURL: outside)
        do {
            _ = try layout.directory(for: title, format: "aax")
            fatalError("Archive path escaped through a symlink")
        } catch ArchiveError.outsideDestination {}
        check(FilenameStyle.asinOnly.name(for: title) == "B000000001")
        check(ArchiveLayout.filename(String(repeating: "é", count: 160), maxBytes: 75).utf8.count == 74)
        try checkOutputNaming(root: root)
        try checkIncompleteStaging(in: workspace)
        try await checkAudibleHelperExit(in: workspace)
        try await checkMediaErrors(in: workspace)

        let previous = Data(#"{"convert":false,"keepOriginal":true,"downloadPDF":false,"downloadCover":true}"#.utf8)
        let options = try JSONDecoder().decode(DownloadOptions.self, from: previous)
        check(options.savesOriginal && options.downloadAudio && options.downloadCover && !options.downloadChapters)
        checkBundleIdentifierMigration()
        try checkLibraryBrowsing()
        checkTransferNotifications()
        checkTransferFeedback()

        let file = LocalAudioFile(url: root.appending(path: "Book.aax"), format: "aax", title: "Écho", author: "Me", asin: nil, durationSeconds: 10)
        let echo = try matchingBook("Echo", asin: "B000000001", authors: ["me"])
        check(try LocalAudioIndex(files: [file]).matches(for: [echo]) == [echo.id: [file.url]])
        check(try LocalAudioIndex(files: [file, file]).matches(for: [echo]).isEmpty)
        try await checkFolderMatching(in: workspace)
        let book = try JSONDecoder().decode(AudibleBook.self, from: Data(#"{"asin":"B000000001","title":"One, \"Two\"","authors":["Me"],"narrators":[],"hasPDF":false,"isDownloadable":true}"#.utf8))
        check(book.downloadUnavailableReason == nil)
        checkLibraryAudioCategories()
        let csv = workspace.appending(path: "Library.csv")
        try await LibraryExportFormat.csv.write([book], to: csv)
        check(try String(contentsOf: csv, encoding: .utf8).contains("\"One, \"\"Two\"\"\""))
        try await checkMultilineExport(in: workspace)
        try await checkTransferQueue(in: workspace, book: book, file: file, layout: layout)
        try await checkReplacingMissingAudio(in: workspace, book: book)

        var preferences = TransferPreferences()
        preferences.logLevel = .errors
        let logFile = workspace.appending(path: "Transfers.txt")
        preferences.logFile = logFile
        var transfer = Transfer(title: "Me\nTest")
        transfer.status = .failed("Test")
        let log = TransferLog()
        try await log.record(transfer, preferences: preferences)
        try await log.record(transfer, preferences: preferences)
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        check(contents.split(separator: "\n").count == 2 && contents.contains("Me Test\tFailed: Test"))
        try await checkArchiveWatcher(in: workspace, existsAtStart: true)
        try await checkArchiveWatcher(in: workspace, existsAtStart: false)
        print("Archive naming, incomplete transfers, queue persistence, file watching, matching, library status, preference migration, CSV export, logs, AAX activation recovery, AAX cleanup, and notification settings and payloads passed.")
    }

    private static func checkTransferNotifications() {
        let notRequested = TransferNotificationStatus(
            authorization: .notDetermined, notificationCenter: .disabled, alerts: .disabled, style: .none
        )
        check(notRequested.authorization == .notRequested && !notRequested.canSendTest && !notRequested.showsBanners)
        let blocked = TransferNotificationStatus(
            authorization: .denied, notificationCenter: .enabled, alerts: .enabled, style: .banner
        )
        check(blocked.authorization == .blocked && !blocked.canSendTest && !blocked.showsBanners)
        let centerOnly = TransferNotificationStatus(
            authorization: .authorized, notificationCenter: .enabled, alerts: .enabled, style: .none
        )
        check(centerOnly.authorization == .allowed && centerOnly.canSendTest && !centerOnly.showsBanners)
        let bannersOnly = TransferNotificationStatus(
            authorization: .authorized, notificationCenter: .disabled, alerts: .enabled, style: .banner
        )
        check(bannersOnly.authorization == .allowed && !bannersOnly.canSendTest && bannersOnly.showsBanners)
        let provisional = TransferNotificationStatus(
            authorization: .provisional, notificationCenter: .enabled, alerts: .disabled, style: .none
        )
        check(provisional.authorization == .allowed && provisional.canSendTest)

        let first = TransferNotificationJob(id: UUID(), title: "First book")
        let second = TransferNotificationJob(id: UUID(), title: "Second book")
        let single = TransferNotificationContent.batch(.downloadCompleted, jobs: [first])
        check(single?.body == first.title && single?.sound == nil)
        check(TransferNotificationContent.transferIDs(in: single?.userInfo ?? [:]) == [first.id])
        let batch = TransferNotificationContent.batch(.conversionFailed, jobs: [first, second])
        check(batch?.title == TransferFeedbackEvent.conversionFailed.displayName && batch?.sound == nil)
        check(TransferNotificationContent.transferIDs(in: batch?.userInfo ?? [:]) == [first.id, second.id])
        check(TransferNotificationContent.batch(.conversionFailed, jobs: []) == nil)
        check(TransferNotificationContent.batch(.queueFinished, jobs: [first]) == nil)
        let test = TransferNotificationContent.test()
        check(test.sound == nil && TransferNotificationContent.transferIDs(in: test.userInfo).isEmpty)
        check(TransferNotificationContent.transferIDs(in: [:]).isEmpty)
    }

    private static func checkTransferFeedback() {
        let output = URL(filePath: "/fixture.m4b")
        let success = Transfer.Status.done(output, note: nil)
        let failure = Transfer.Status.failed("Fixture failure")
        var progress = TransferFeedbackProgress(isDownload: true)
        check(progress.outcomes(for: success).isEmpty)
        check(progress.outcomes(for: failure) == [.downloadFailed])
        progress.record(.downloaded)
        progress.record(.preparingConversion)
        check(progress.outcomes(for: failure) == [.downloadCompleted, .conversionFailed])
        progress.record(.downloading)
        check(progress.outcomes(for: failure) == [.downloadFailed])
        progress.record(.downloaded)
        progress.record(.preparingConversion)
        progress.record(.converted)
        check(progress.outcomes(for: success) == [.downloadCompleted, .conversionCompleted])
        check(progress.outcomes(for: .cancelled).isEmpty)

        var conversion = TransferFeedbackProgress(isDownload: false)
        check(conversion.outcomes(for: success).isEmpty)
        check(conversion.outcomes(for: failure) == [.conversionFailed])
        conversion.record(.converted)
        check(conversion.outcomes(for: success) == [.conversionCompleted])

        var settings = TransferFeedbackPreferences.Settings()
        settings.sound.source = .custom
        settings.setDelivery(.soundOnly)
        check(settings.sound.source == .builtIn)
    }

    private static func checkAAXCleanup(in workspace: URL) async throws {
        let defaults = UserDefaults.standard
        let originalIndex = defaults.object(forKey: "ArchiveIndex")
        defer { defaults.set(originalIndex, forKey: "ArchiveIndex") }
        let tools = workspace.appending(path: "AAX Cleanup Tools", directoryHint: .isDirectory)
        let trash = workspace.appending(path: "Test Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let probe = #"""
            #!/bin/sh
            for input do :; done
            case "$input" in
                *.aax)
                    printf '%s\n' '{"streams":[{"index":0,"codec_type":"audio","codec_name":"aac","duration":"2","sample_rate":"44100","channels":1}],"chapters":[{"start_time":"0","end_time":"1","tags":{"title":"One"}},{"start_time":"1","end_time":"2","tags":{"title":"Two"}}],"format":{}}'
                    ;;
                *.mp3)
                    [ "$(cat "$input")" = mp3 ] || exit 1
                    printf '%s\n' '{"streams":[{"index":0,"codec_type":"audio","codec_name":"mp3","duration":"1","sample_rate":"44100","channels":1}],"chapters":[],"format":{}}'
                    ;;
                *) exit 1 ;;
            esac
            """#
        let encoder = #"""
            #!/bin/sh
            set -eu
            start=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -ss) start=$2; shift ;;
                    -i) [ -n "${input:-}" ] || input=$2; shift ;;
                esac
                output=$1
                shift
            done
            case "$input" in
                */Incomplete.aax) [ "$start" = 0 ] || exit 1 ;;
                */Changed.aax) printf '%s' replacement > "$input" ;;
            esac
            printf '%s' mp3 > "$output"
            """#
        for (name, script) in [("ffprobe", probe), ("ffmpeg", encoder)] {
            let url = tools.appending(path: name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let retryMarker = trash.appending(path: "Allow Retry")
        let worker = ArchiveWorker(media: MediaTools(toolDirectory: tools)) { source in
            if ["Retry.aax", "DamagedOutput.aax"].contains(source.lastPathComponent),
               !FileManager.default.fileExists(atPath: retryMarker.path) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: source, to: trash.appending(path: source.lastPathComponent))
        }
        let layout = ArchiveLayout(root: workspace.appending(path: "Cleanup Outputs"), template: ArchiveLayout.defaultTemplate)
        var defaultsOnly = ConversionPreferences()
        defaultsOnly.format = .mp3
        defaultsOnly.chapterMode = .separate
        var cleanup = defaultsOnly
        cleanup.moveAAXToTrash = true
        check(!defaultsOnly.cleansUpAAX && cleanup.cleansUpAAX)
        check(cleanup.outputRecipe == defaultsOnly.outputRecipe)
        let preferences = try JSONEncoder().encode(cleanup)
        check(try JSONDecoder().decode(ConversionPreferences.self, from: preferences).cleansUpAAX)

        func source(_ title: String) throws -> LocalAudioFile {
            let url = workspace.appending(path: title + ".aax")
            try Data("source".utf8).write(to: url)
            return LocalAudioFile(url: url, format: "aax", title: title, author: nil, asin: nil, durationSeconds: 2)
        }

        func convert(_ file: LocalAudioFile, preferences: ConversionPreferences, requestID: UUID = UUID()) async throws -> ExportReceipt {
            try await worker.convert(
                file, audible: AudibleClient(), layout: layout, activationBytes: "12345678", existingFiles: .reuse,
                conversion: preferences, requestID: requestID, progress: { _, _ in }
            )
        }
        let ready = try source("Complete")
        let written = try await convert(ready, preferences: cleanup)
        check(written.converted.count == 2 && written.converted.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        check(written.removedAAX == [ready.url] && written.note == nil)
        check(!FileManager.default.fileExists(atPath: ready.url.path))
        check(try Data(contentsOf: trash.appending(path: "Complete.aax")) == Data("source".utf8))

        let disabled = try source("Keep")
        let saved = try await convert(disabled, preferences: defaultsOnly)
        let reused = try await convert(disabled, preferences: cleanup)
        check(reused.converted == saved.converted && reused.removedAAX.isEmpty)
        check(FileManager.default.fileExists(atPath: disabled.url.path))

        let incomplete = try source("Incomplete")
        do {
            _ = try await convert(incomplete, preferences: cleanup)
            fatalError("A failed chapter should fail the job")
        } catch MediaError.conversionFailed {}
        check(FileManager.default.fileExists(atPath: incomplete.url.path))

        let changed = try source("Changed")
        let changedResult = try await convert(changed, preferences: cleanup)
        check(changedResult.removedAAX.isEmpty && changedResult.note?.contains("changed during conversion") == true)
        check(try Data(contentsOf: changed.url) == Data("replacement".utf8))

        let retry = try source("Retry")
        let requestID = UUID()
        let firstAttempt = try await convert(retry, preferences: cleanup, requestID: requestID)
        check(firstAttempt.removedAAX.isEmpty && firstAttempt.note?.contains("MP3 export was saved") == true)
        check(FileManager.default.fileExists(atPath: retry.url.path))

        let damaged = try source("DamagedOutput")
        let damagedRequestID = UUID()
        let beforeDamage = try await convert(damaged, preferences: cleanup, requestID: damagedRequestID)
        check(beforeDamage.removedAAX.isEmpty && beforeDamage.converted.count == 2)
        let damagedChapter = beforeDamage.converted[1]
        let oldBytes = try Data(contentsOf: damagedChapter)
        let date = try damagedChapter.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let outputHandle = try FileHandle(forWritingTo: damagedChapter)
        try outputHandle.write(contentsOf: Data(repeating: 0, count: oldBytes.count))
        try outputHandle.close()
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: damagedChapter.path)
        }

        try Data().write(to: retryMarker)
        let secondAttempt = try await convert(retry, preferences: cleanup, requestID: requestID)
        check(secondAttempt.converted == firstAttempt.converted && secondAttempt.removedAAX == [retry.url])
        check(!FileManager.default.fileExists(atPath: retry.url.path))
        let afterDamage = try await convert(damaged, preferences: cleanup, requestID: damagedRequestID)
        check(afterDamage.removedAAX.isEmpty && afterDamage.note?.contains("could not be verified") == true)
        check(FileManager.default.fileExists(atPath: damaged.url.path))
        check(try Data(contentsOf: damagedChapter).count == oldBytes.count)

        let cancelled = try source("Cancelled")
        let (published, signal) = AsyncStream<Void>.makeStream()
        let (waiting, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let job = Task { [cleanup] in
            defer { signal.finish() }
            return try await worker.convert(
                cancelled, audible: AudibleClient(), layout: layout, activationBytes: "12345678", existingFiles: .reuse,
                conversion: cleanup, requestID: UUID(), progress: { _, fraction in
                    guard fraction == 1 else { return }
                    signal.yield(())
                    for await _ in waiting { break }
                }
            )
        }
        for await _ in published {
            job.cancel()
            break
        }
        do {
            _ = try await job.value
            fatalError("Cancelling after publishing the MP3 files should stop cleanup.")
        } catch is CancellationError {}
        check(FileManager.default.fileExists(atPath: cancelled.url.path))
    }

    private static func checkLosslessChapters() throws {
        let data = Data(#"""
            {"streams":[{"index":0,"codec_type":"audio","codec_name":"aac","profile":"LC",
            "sample_rate":"44100","channels":1,"time_base":"1/44100","start_pts":0,"duration_ts":132300}],
            "chapters":[],"format":{}}
            """#.utf8)
        let probe = try JSONDecoder().decode(AudioProbe.self, from: data)
        let ranges: [Range<Int64>?] = [0..<1_305, 1_305..<2_719, 2_719..<3_599, 3_599..<5_999, 5_999..<6_000]
        let chapters = LosslessChapter.plan(ranges, sources: [probe.audio, probe.audio], enabled: true)
        check(chapters.map { $0?.sourceIndex } == [0, 0, nil, 1, 1])
        check(chapters[0]?.sampleCount == 57_551)
        check(chapters[1]?.sampleCount == 62_357)
        check(chapters[4]?.sampleCount == 44)
        check(LosslessChapter.plan(ranges, sources: [probe.audio], enabled: false).allSatisfy { $0 == nil })

        var preferences = ConversionPreferences()
        preferences.chapterMode = .separate
        let saved = try JSONEncoder().encode(preferences.outputRecipe)
        check(!String(decoding: saved, as: UTF8.self).contains("losslessChapterAudio"))
        check(try !JSONDecoder().decode(ConversionPreferences.self, from: saved).copyChapterAudio)
        preferences.copyChapterAudio = true
        let updated = try JSONEncoder().encode(preferences.outputRecipe)
        check(try JSONDecoder().decode(ConversionPreferences.self, from: updated).copyChapterAudio)
        preferences.sampleRate = .hz44100
        check(!preferences.outputRecipe.copyChapterAudio)
        preferences.sampleRate = .automatic
        preferences.format = .mp3
        check(!preferences.outputRecipe.copyChapterAudio)
    }

    private static func checkFolderMatching(in workspace: URL) async throws {
        let tools = workspace.appending(path: "ScanTools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
        let probe = tools.appending(path: "ffprobe")
        let script = #"""
            #!/bin/sh
            for file do :; done
            case "$file" in
                */Imported.m4b)
                    tags='{"title":"A Different Name","asin":"Unspecified","com.apple.iTunes:ASIN":"b000000001"}' ;;
                */AnotherName.m4a)
                    tags='{"title":"The Opening","album":"The River: A Story (Unabridged)","artist":"A Narrator","album_artist":"Zoë Bell"}' ;;
                */Chapter.mp3)
                    tags='{"asin":"B000000004","album":"Winter","tracktotal":"12"}' ;;
                */Spring.aax)
                    tags='{"title":"Spring","album_artist":"Audible Studios"}' ;;
                *) exit 1 ;;
            esac
            printf '{"streams":[{"index":0,"codec_type":"audio","duration":"600"}],"chapters":[],"format":{"tags":%s}}\n' "$tags"
            """#
        try script.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)

        let library = workspace.appending(path: "Existing Audio", directoryHint: .isDirectory)
        let layout = ArchiveLayout(root: library, template: ArchiveLayout.defaultTemplate)
        let title = ArchiveTitle(title: "The River", author: "Zoë Bell", asin: "B000000002")
        let archiveFolder = try layout.directory(for: title, format: "aax")
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        let archived = archiveFolder.appending(path: "Custom File.aax")
        let springFolder = try layout.directory(
            for: ArchiveTitle(title: "Spring", author: "Zoe Bell", asin: nil), format: "aax"
        )
        try FileManager.default.createDirectory(at: springFolder, withIntermediateDirectories: true)
        let conflictingArtist = springFolder.appending(path: "Spring.aax")
        let original = library.appending(path: "Other App Export [B000000001].aax")
        let untagged = library.appending(path: "Other App Export.aaxc")
        let converted = library.appending(path: "Imported.m4b")
        let album = library.appending(path: "AnotherName.m4a")
        let chapter = library.appending(path: "Chapter.mp3")
        let compact = library.appending(path: "BehindtheClouds_AAX_64_64.aax")
        let nameAndAuthor = library.appending(path: "Jules Verne - The Lighthouse.aaxc")
        let ignored = library.appending(path: "Unsupported.flac")
        let audio = [archived, conflictingArtist, original, untagged, converted, album, chapter, compact, nameAndAuthor]
        for url in audio + [ignored] {
            try Data().write(to: url)
        }

        let files = try await MediaTools(toolDirectory: tools).scan(library)
        check(Set(files.map(\.url)) == Set(audio))
        let index = LocalAudioIndex(files: files)
        let imported = try matchingBook("Other App Export", asin: "B000000001", duration: 600)
        check(try index.matches(for: [imported]) == [imported.id: [original]])
        check(try LocalAudioIndex(files: files.filter { $0.url != original })
            .matches(for: [imported]) == [imported.id: [converted]])
        let otherEdition = try matchingBook("Other App Export", asin: "B000000101", duration: 600)
        check(try index.matches(for: [imported, otherEdition]) == [imported.id: [original]])

        let river = try matchingBook("The River", asin: "B000000002", authors: ["Zoe Bell"])
        let compactName = try matchingBook("Behind the Clouds", asin: "B000000005")
        let lighthouse = try matchingBook("The Lighthouse", asin: "B000000006", authors: ["Jules Verne"])
        let spring = try matchingBook("Spring", asin: "B000000007", authors: ["Zoe Bell"], duration: 600)
        check(try index.matches(for: [river, compactName, lighthouse, spring]) == [
            river.id: [archived], compactName.id: [compact], lighthouse.id: [nameAndAuthor], spring.id: [conflictingArtist]
        ])

        let wrongIdentifier = try matchingBook("A Different Name", asin: "B000000003", duration: 600)
        let onlyChapter = try matchingBook("Winter", asin: "B000000004")
        let wrongAuthor = try matchingBook("The River", asin: "B000000008", authors: ["Another Author"])
        let anotherClouds = try matchingBook("Behind the Clouds", asin: "B000000105")
        check(try index.matches(for: [wrongIdentifier, onlyChapter, wrongAuthor, compactName, anotherClouds]).isEmpty)

        let outsideArchive = LocalAudioIndex(files: files.filter { $0.url != archived })
        let sameDuration = try matchingBook(
            "The River", asin: "B000000002", subtitle: "A Story", authors: ["Another Author", "Zoe Bell"], duration: 600
        )
        let differentDuration = try matchingBook(
            "The River", asin: "B000000102", subtitle: "A Story", authors: ["Zoe Bell"], duration: 1_200
        )
        check(try outsideArchive.matches(for: [sameDuration, differentDuration]) == [sameDuration.id: [album]])
    }

    private static func checkMediaErrors(in workspace: URL) async throws {
        let probe = workspace.appending(path: "probe-without-audio")
        let script = """
            #!/bin/sh
            printf '%s\\n' '{"streams":[],"chapters":[],"format":{}}'
            """
        try script.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        let source = workspace.appending(path: "Empty.m4a")
        do {
            _ = try await MediaTools.probe(source, options: [], ffprobe: probe, directory: workspace)
            fatalError("A missing source should be reported before probing")
        } catch MediaError.sourceMissing {}
        try Data().write(to: source)
        do {
            _ = try await MediaTools.probe(source, options: [], ffprobe: probe, directory: workspace)
            fatalError("A readable container with no audio should have its own error")
        } catch MediaError.noAudioTrack {}
        check(MediaError.conversionFailure(from: Data("Error closing file: No space left on device".utf8)) == .destinationFull)
        check(MediaError.conversionFailure(from: Data("Error opening output files: Permission denied".utf8)) == .destinationPermissionDenied)
        check(MediaError.conversionFailure(from: Data("Unhandled detail in /private/book.m4a".utf8)) == .conversionFailed)
    }

    private static func matchingBook(
        _ title: String, asin: String, subtitle: String? = nil, authors: [String] = [], duration: Int? = nil
    ) throws -> AudibleBook {
        var attributes: [String: Any] = [
            "asin": asin, "title": title, "authors": authors, "narrators": [String](),
            "hasPDF": false, "isDownloadable": true
        ]
        attributes["subtitle"] = subtitle
        attributes["durationSeconds"] = duration
        return try JSONDecoder().decode(AudibleBook.self, from: JSONSerialization.data(withJSONObject: attributes))
    }

    private static func checkMediaChapterBounds() throws {
        let input = Data("""
            {
              "streams": [{"index": 0, "codec_type": "audio", "duration": "2.000"}],
              "chapters": [
                {"start_time": "0.000", "end_time": "5.000", "tags": {"title": "Audio"}},
                {"start_time": "2.500", "end_time": "5.000", "tags": {"title": "Past the Audio"}}
              ],
              "format": {"duration": "5.000"}
            }
            """.utf8)
        let probe = try JSONDecoder().decode(AudioProbe.self, from: input)
        check(probe.durationMilliseconds == 2_000)
        let chapters = MediaTags.markers(probes: [probe, probe], supplied: [], title: nil)
        check(chapters == [
            MediaChapter(startMilliseconds: 0, durationMilliseconds: 2_000, title: "Audio"),
            MediaChapter(startMilliseconds: 2_000, durationMilliseconds: 2_000, title: "Audio")
        ])

        let supplied = [
            MediaChapter(startMilliseconds: 0, durationMilliseconds: 1_000, title: "Opening"),
            MediaChapter(startMilliseconds: 1_000, durationMilliseconds: 4_000, title: "Closing")
        ]
        let catalogChapters = MediaTags.markers(probes: [probe], supplied: supplied, title: nil)
        check(catalogChapters == [
            supplied[0], MediaChapter(startMilliseconds: 1_000, durationMilliseconds: 1_000, title: "Closing")
        ])
    }

    private static func checkActivationRefresh(in workspace: URL) async throws {
        let manager = FileManager.default
        let tools = workspace.appending(path: "ActivationTools", directoryHint: .isDirectory)
        try manager.createDirectory(at: tools, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: tools.appending(path: "ffmpeg"), withDestinationURL: URL(filePath: "/usr/bin/true"))
        let probe = tools.appending(path: "ffprobe")
        let validCode = "11223344"
        let script = #"""
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -/activation_bytes) bytes=$(cat "$2"); shift ;;
                    -i) source=$2; shift ;;
                esac
                shift
            done
            if [ "${source##*/}" = Damaged.aax ]; then exit 1; fi
            if [ "$bytes" != \#(validCode) ]; then
                echo '[aax] mismatch in checksums' >&2
                exit 1
            fi
            printf '%s\n' '{"streams":[{"index":0,"codec_type":"audio","codec_name":"aac","duration":"2"}],"chapters":[],"format":{}}'
            """#
        try script.write(to: probe, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)

        let media = MediaTools(toolDirectory: tools)
        let wrongCode = "55667788"
        let aax = workspace.appending(path: "Book.aax")
        let stale = MediaInput(url: aax, credentials: MediaCredentials(activationBytes: wrongCode))
        let second = MediaInput(url: workspace.appending(path: "Part Two.aax"), credentials: stale.credentials)
        let missing = MediaInput(url: aax)
        let valid = MediaInput(url: aax, credentials: MediaCredentials(activationBytes: validCode))
        let damaged = MediaInput(url: workspace.appending(path: "Damaged.aax"), credentials: valid.credentials)
        let mp3 = MediaInput(url: workspace.appending(path: "Book.mp3"))
        for source in [stale, second, damaged, mp3] {
            try Data().write(to: source.url)
        }

        func expect(
            _ outcome: ActivationCheckOutcome, from inputs: [MediaInput],
            refresh: Result<String, ActivationCheckOutcome>?, requests: Int, line: UInt = #line
        ) async {
            let fixture = refresh.map(ActivationRefreshFixture.init)
            let callback: (@Sendable () async throws -> String)?
            if let fixture {
                callback = { try await fixture.refresh() }
            } else {
                callback = nil
            }
            do {
                _ = try await media.convert(inputs, preferences: .init(), refreshActivation: callback) { _ in
                    // Stop after all source files are ready, before rendering audio.
                    throw ActivationCheckOutcome.sourcesPrepared
                }
                fatalError("Conversion should stop before rendering audio")
            } catch let error as MediaError {
                check(.mediaError(error) == outcome, line: line)
            } catch {
                check(error as? ActivationCheckOutcome == outcome, line: line)
            }
            check(await fixture?.requests ?? 0 == requests, line: line)
        }

        await expect(.sourcesPrepared, from: [stale, second], refresh: .success(validCode), requests: 1)
        await expect(.sourcesPrepared, from: [missing], refresh: .success(validCode), requests: 1)
        await expect(.sourcesPrepared, from: [valid], refresh: .success(validCode), requests: 0)
        await expect(.mediaError(.activationRequired), from: [stale], refresh: .success(wrongCode), requests: 1)
        await expect(.mediaError(.activationRequired), from: [stale], refresh: nil, requests: 0)
        await expect(.mediaError(.activationRequired), from: [mp3], refresh: .success(validCode), requests: 0)
        await expect(.mediaError(.unreadableAudio), from: [damaged], refresh: .success(validCode), requests: 0)
        await expect(.refreshFailed, from: [stale], refresh: .failure(.refreshFailed), requests: 1)
    }

    private enum ActivationCheckOutcome: Error, Equatable {
        case sourcesPrepared
        case mediaError(MediaError)
        case refreshFailed
    }

    private actor ActivationRefreshFixture {
        let result: Result<String, ActivationCheckOutcome>
        private(set) var requests = 0

        init(_ result: Result<String, ActivationCheckOutcome>) {
            self.result = result
        }

        func refresh() throws -> String {
            requests += 1
            return try result.get()
        }
    }

    private actor TransferFeedbackFixture {
        private var progress = TransferFeedbackProgress(isDownload: true)

        func record(_ milestone: ArchiveWorker.FeedbackMilestone) {
            progress.record(milestone)
        }

        func outcomes(for status: Transfer.Status) -> [TransferFeedbackEvent] {
            progress.outcomes(for: status)
        }
    }

    private static func checkDownloadAfterActivationFailure(in workspace: URL) async throws {
        let manager = FileManager.default
        let tools = workspace.appending(path: "FallbackTools", directoryHint: .isDirectory)
        try manager.createDirectory(at: tools, withIntermediateDirectories: false)
        let helper = tools.appending(path: "audible-helper")
        let helperScript = #"""
            #!/bin/sh
            set -eu
            request=$(cat)
            field() { printf '%s' "$request" | /usr/bin/plutil -extract "$1" raw -o - -; }
            log="$(dirname "$0")/requests"
            case "$(field command)" in
                importAuthFile)
                    printf '%s\n' '{"result":{"session":"fixture","marketplace":"uk"}}' ;;
                activation)
                    [ "$(field session)" = fixture ]
                    printf 'activation %s\n' "$(field refreshActivation)" >> "$log"
                    if [ -f "$(dirname "$0")/use-aax" ]; then
                        printf '%s\n' '{"result":{"activationBytes":"12345678","session":"fixture"}}'
                    else
                        printf '%s\n' '{"error":"activation"}'
                    fi ;;
                download)
                    [ "$(field session)" = fixture ]
                    format=$(field options.format)
                    printf 'download %s\n' "$format" >> "$log"
                    case "$format" in
                        preferAAX) file=Book.aax ;;
                        aaxcOnly)
                            if [ -f "$(dirname "$0")/fail-aaxc" ]; then
                                printf '%s\n' '{"error":"aaxcUnavailable"}'
                                exit 0
                            fi
                            file=Book.mp3 ;;
                        *) exit 1 ;;
                    esac
                    printf '%s' "$file" > "$(field directory)/$file"
                    printf '{"result":{"parts":[{"file":"%s","asin":"B000000001","credentials":{}}]}}\n' "$file" ;;
                *) exit 1 ;;
            esac
            """#
        let mediaScript = #"""
            #!/bin/sh
            set -eu
            if [ "${0##*/}" = ffprobe ]; then
                for file do :; done
                case "$(cat "$file")" in
                    Book.aax) codec=aac ;;
                    Book.mp3) codec=mp3 ;;
                    converted) codec=aac ;;
                    converted-mp3) codec=mp3 ;;
                    *) exit 1 ;;
                esac
                printf '{"streams":[{"index":0,"codec_type":"audio","codec_name":"%s","duration":"2","sample_rate":"44100","channels":1}],"chapters":[],"format":{}}\n' "$codec"
            else
                while [ "$1" != -i ]; do shift; done
                input=$(cat "$2")
                for output do :; done
                case "$input:$output" in
                    Book.mp3:-|converted:-|converted-mp3:-) exit 0 ;;
                    Book.aax:*.mp3) printf '%s' converted-mp3 > "$output" ;;
                    Book.mp3:*) printf '%s' converted > "$output" ;;
                    *) exit 1 ;;
                esac
            fi
            """#
        for (url, script) in [(helper, helperScript), (tools.appending(path: "ffprobe"), mediaScript),
                              (tools.appending(path: "ffmpeg"), mediaScript)] {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let profile = UUID()
        let client = AudibleClient(profileID: profile, helperURL: helper)
        _ = try await client.importAuthFile(tools.appending(path: "fixture.json"), password: nil)
        defer { try? client.signOut() }
        let defaults = UserDefaults.standard
        let originalIndex = defaults.object(forKey: "ArchiveIndex")
        defer { defaults.set(originalIndex, forKey: "ArchiveIndex") }

        let trash = workspace.appending(path: "Archive Test Trash", directoryHint: .isDirectory)
        try manager.createDirectory(at: trash, withIntermediateDirectories: false)
        let archive = ArchiveWorker(media: MediaTools(toolDirectory: tools)) { source in
            try FileManager.default.moveItem(at: source, to: trash.appending(path: source.lastPathComponent))
        }
        let book = try matchingBook("Fallback fixture", asin: "B000000001")
        let root = workspace.appending(path: "Fallback Archive", directoryHint: .isDirectory)
        let layout = ArchiveLayout(root: root, template: ArchiveLayout.defaultTemplate)
        var options = DownloadOptions()
        options.convert = true
        var conversion = ConversionPreferences()
        conversion.embedArtwork = false
        conversion.embedChapters = false
        let fallbackFeedback = TransferFeedbackFixture()
        let receipt = try await archive.download(
            book, account: profile.uuidString, audible: client, matches: [], layout: layout, options: options,
            existingFiles: .reuse, conversion: conversion, feedback: { await fallbackFeedback.record($0) }, progress: { _, _ in }
        )
        let completedEvents = await fallbackFeedback.outcomes(for: .done(receipt.url, note: nil))
        check(completedEvents == [.downloadCompleted, .conversionCompleted])
        let requests = try String(contentsOf: tools.appending(path: "requests"), encoding: .utf8)
        check(requests.split(separator: "\n") == ["download preferAAX", "activation false", "activation true", "download aaxcOnly"])
        check(receipt.original.count == 1 && receipt.original[0].pathExtension == "aax")
        check(try Data(contentsOf: receipt.original[0]) == Data("Book.aax".utf8))
        check(receipt.converted == [receipt.url] && receipt.url.pathExtension == "m4b")
        check(try Data(contentsOf: receipt.url) == Data("converted".utf8))
        check(!IncompleteDownloads.containsAudio(for: book.id, account: profile.uuidString, root: root))

        let fallbackFailure = TransferFeedbackFixture()
        let failureFlag = tools.appending(path: "fail-aaxc")
        let failedBook = try matchingBook("Unavailable fallback fixture", asin: "B000000007")
        try Data().write(to: failureFlag)
        do {
            _ = try await archive.download(
                failedBook, account: profile.uuidString, audible: client, matches: [], layout: layout, options: options,
                existingFiles: .saveNewCopy, conversion: conversion,
                feedback: { await fallbackFailure.record($0) }, progress: { _, _ in }
            )
            fatalError("The fallback download should fail")
        } catch AudibleError.aaxcUnavailable {
            let events = await fallbackFailure.outcomes(for: .failed("Fixture failure"))
            check(events == [.downloadFailed])
        }
        try manager.removeItem(at: failureFlag)

        try Data().write(to: tools.appending(path: "use-aax"))
        options.keepOriginal = false
        conversion.format = .mp3
        conversion.moveAAXToTrash = true
        let cleaned = try await archive.download(
            book, account: profile.uuidString, audible: client, matches: [], layout: layout, options: options,
            existingFiles: .reuse, conversion: conversion, progress: { _, _ in }
        )
        check(cleaned.removedAAX == Set(receipt.original))
        let following = await archive.inventory(for: [book.id], account: profile.uuidString, layout: layout)
        check(following[book.id]?.originals.isEmpty == true)
        check(following[book.id]?.missingFiles.isEmpty == true)
        check(following[book.id]?.files.contains(cleaned.url) == true)

        let other = try matchingBook("Matched fixture", asin: "B000000002")
        let matched = workspace.appending(path: "Matched.aax")
        try Data("Book.aax".utf8).write(to: matched)
        let matchedReceipt = try await archive.download(
            other, account: profile.uuidString, audible: client, matches: [matched], layout: layout, options: options,
            existingFiles: .reuse, conversion: conversion, progress: { _, _ in }
        )
        check(matchedReceipt.removedAAX.isEmpty && manager.fileExists(atPath: matched.path))

        let missing = try matchingBook("Missing audio fixture", asin: "B000000003")
        let incomplete = try matchingBook("Incomplete audio fixture", asin: "B000000004")
        let partial = try IncompleteDownloads.audioFolder(
            for: incomplete.id, account: profile.uuidString, root: root, restart: false
        )
        try Data("partial audio".utf8).write(to: partial.appending(path: "Book.aax.partial"))
        try manager.removeItem(at: receipt.url)
        let damage = Data(repeating: 0, count: try Data(contentsOf: cleaned.url).count)
        try damage.write(to: cleaned.url, options: .atomic)
        let verification = try await archive.verifyArchive(
            books: [book, other, missing, incomplete], account: profile.uuidString, layout: layout,
            matches: [other.id: [matched]], progress: { _, _ in }
        )
        let issues = Dictionary(uniqueKeysWithValues: verification.map { ($0.id, $0) })
        check(issues[book.id]?.kind == .unreadable && issues[book.id]?.files.contains(cleaned.url) == true)
        check(issues[other.id] == nil)
        check(issues[missing.id]?.kind == .missing && issues[incomplete.id]?.kind == .incomplete)
        check(try Data(contentsOf: cleaned.url) == damage)

        let repaired = try await archive.download(
            book, account: profile.uuidString, audible: client, matches: [], layout: layout, options: options,
            existingFiles: .reuse, conversion: conversion, repairAudio: true, progress: { _, _ in }
        )
        check(repaired.url != cleaned.url && repaired.addedConverted == [repaired.url] && repaired.removedAAX.isEmpty)
        check(try Data(contentsOf: cleaned.url) == damage)
        let verifiedRepair = try await archive.verifyArchive(
            books: [book], account: profile.uuidString, layout: layout, matches: [:], progress: { _, _ in }
        )
        check(verifiedRepair.isEmpty)
        let repairedInventory = await archive.inventory(for: [book.id], account: profile.uuidString, layout: layout)
        check(repairedInventory[book.id]?.missingFiles.isEmpty == true)
    }

    private static func checkAudibleHelperExit(in workspace: URL) async throws {
        let helper = workspace.appending(path: "exit-before-reading")
        try "#!/bin/sh\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let client = AudibleClient(helperURL: helper)
        // A request larger than the pipe buffer forces the write to observe the helper's exit.
        let config = workspace.appending(path: String(repeating: "x", count: 1024 * 1024))
        do {
            _ = try await client.cliProfiles(config: config)
            fatalError("An early Audible helper exit should fail the request.")
        } catch AudibleError.service {}
    }

    private static func checkLibraryBrowsing() throws {
        let previous = Data(#"{"id":"1D25B1E2-F9AC-4D68-9043-E5468118B94A","name":"First","marketplace":"uk","usesLegacySession":false}"#.utf8)
        var first = try JSONDecoder().decode(SavedAudibleAccount.self, from: previous)
        check(first.librarySort == nil)
        first.librarySort = LibrarySort(field: .purchaseDate, direction: .descending)
        let second = SavedAudibleAccount(id: UUID(), name: "Second", marketplace: .unitedKingdom)
        let accounts = try JSONEncoder().encode([first, second])
        let saved = try JSONDecoder().decode([SavedAudibleAccount].self, from: accounts)
        check(saved[0].librarySort == LibrarySort(field: .purchaseDate, direction: .descending))
        check(saved[1].librarySort == nil)

        let futurePreference = Data(#"{"id":"1D25B1E2-F9AC-4D68-9043-E5468118B94A","name":"First","marketplace":"uk","usesLegacySession":false,"librarySort":{"field":"futureField","direction":"descending"}}"#.utf8)
        let futureAccount = try JSONDecoder().decode(SavedAudibleAccount.self, from: futurePreference)
        check(futureAccount.librarySort == LibrarySort(field: .title, direction: .descending))

        let cafe = try matchingBook("Café Window", asin: "B000000001", authors: ["Ada Moss"])
        let river = try matchingBook("Across the River", asin: "B000000002", authors: ["Ada Moss", "Moss James"])
        let forest = try matchingBook("The Forest", asin: "B000000003", authors: ["Alba Lee"])
        let authors = LibraryFilterSuggestions(field: .author, books: [cafe, river])
        check(authors.matching("moss") == ["Moss James", "Ada Moss"])
        check(authors.matching("moss ada") == ["Ada Moss"])
        check(authors.matching("alba").isEmpty)
        check(LibraryFilterSuggestions(field: .author, books: [forest]).matching("alba") == ["Alba Lee"])
        let titles = LibraryFilterSuggestions(field: .title, books: [cafe, river])
        check(titles.matching("CAFE WINDOW") == ["Café Window"])
        check(titles.matching("Café Window").isEmpty)
        check(titles.matching(" ").isEmpty)

        let bookList = [cafe, river, forest]
        var filters = LibraryFilters()
        filters[.title] = "river"
        filters[.author] = "Ada"
        filters.status = .downloaded
        let status: (AudibleBook) -> LibraryDownloadStatus = { $0.id == river.id ? .notDownloaded : .downloaded }
        check(filters.rows(in: bookList, search: "", statusFor: status).isEmpty)
        let matching = filters.rows(in: bookList, search: " cAFE ", excluding: .title, statusFor: status)
        check(matching.map(\.id) == [cafe.id])
        check(LibraryFilterSuggestions(field: .title, books: matching.map(\.book)).matching("win") == [cafe.title])
        check(filters.rows(in: bookList, search: "forest", excluding: .title, statusFor: status).isEmpty)
        check(filters.rows(in: bookList, search: "river", excluding: .title, statusFor: status).isEmpty)
    }

    private static func checkLibraryAudioCategories() {
        for status in [LibraryDownloadStatus.partial, .missing, .notDownloaded] {
            check(LibraryAudioCategory(status: status, isDownloadable: true) == .toDownload)
            check(LibraryAudioCategory(status: status, isDownloadable: false) == .unavailable)
        }
        for isDownloadable in [true, false] {
            check(LibraryAudioCategory(status: .downloaded, isDownloadable: isDownloadable) == .downloaded)
            check(LibraryAudioCategory(status: .matched, isDownloadable: isDownloadable) == .matched)
        }
        check(LibraryAudioCategory(status: .unavailable, isDownloadable: false) == .unavailable)
    }

    private static func checkBundleIdentifierMigration() {
        let oldBundle = "DownAudible.ArchiveChecks.\(UUID()).old"
        let newBundle = "DownAudible.ArchiveChecks.\(UUID()).new"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: oldBundle)
            defaults.removePersistentDomain(forName: newBundle)
        }

        let accounts = Data("saved accounts fixture".utf8)
        defaults.setPersistentDomain(["Accounts": accounts, "HasFinishedOnboarding": true], forName: oldBundle)
        defaults.setPersistentDomain(["HasFinishedOnboarding": false], forName: newBundle)

        DownAudibleIdentity.migratePreferences(for: "OtherBundle", from: oldBundle, to: newBundle)
        check(defaults.persistentDomain(forName: newBundle)?["Accounts"] == nil)
        DownAudibleIdentity.migratePreferences(for: newBundle, from: oldBundle, to: newBundle)
        let migrated = defaults.persistentDomain(forName: newBundle) ?? [:]
        check(migrated["Accounts"] as? Data == accounts && migrated["HasFinishedOnboarding"] as? Bool == false)
        check(defaults.persistentDomain(forName: oldBundle)?["Accounts"] as? Data == accounts)

        var afterRemoval = migrated
        afterRemoval.removeValue(forKey: "Accounts")
        defaults.setPersistentDomain(afterRemoval, forName: newBundle)
        DownAudibleIdentity.migratePreferences(for: newBundle, from: oldBundle, to: newBundle)
        check(defaults.persistentDomain(forName: newBundle)?["Accounts"] == nil)

        check(DownAudibleIdentity.audibleKeychainService(for: "com.tbmw.downaudible") == "uk.co.ashleycox.DownAudible.audible")
        check(DownAudibleIdentity.audibleKeychainService(for: oldBundle) == oldBundle + ".audible")
        check(DownAudibleIdentity.audibleKeychainService(for: nil) == "DownAudible.audible")
    }

    private static func checkOutputNaming(root: URL) throws {
        let title = ArchiveTitle(title: "My Great Book", author: "Me", asin: "B000000001")
        let previous = ArchiveLayout(root: root, template: ArchiveLayout.defaultTemplate, filenameStyle: .asinUnicode)
        check(previous.filenameStem(for: title, format: "aax") == "B000000001 - My Great Book")
        check(previous.filenameStem(for: title, format: "aax", partNumber: 2) == "B000000001 - My Great Book - Part 2")
        check(previous.filenameStem(for: title, format: "m4b", chapterNumber: 1, chapterTitle: "Opening")
              == "My Great Book - 01 - Opening")
        check(previous.originalAAXFilename("AudibleTitle.AAX") == nil)

        let savedNaming = Data(#"{"filenameTemplate":"{title}","chapterFilenameTemplate":"{chapter}","whitespace":"underscores","letterCase":"uppercase","transliterate":true}"#.utf8)
        let migratedNaming = try JSONDecoder().decode(OutputNaming.self, from: savedNaming)
        check(!migratedNaming.keepOriginalAAXFilename && migratedNaming.filenameTemplate == "{title}")
        check(migratedNaming.whitespace == .underscores && migratedNaming.letterCase == .uppercase)

        let named = ArchiveTitle(
            title: "Écho du Monde", author: "Zoë  Bell", asin: "B000000002",
            metadata: ["seriesNumber": "2", "year": "2025"]
        )
        var options = OutputNaming()
        options.filenameTemplate = "{seriesNumber} {title} {partNumber}"
        options.chapterFilenameTemplate = "{chapterNumber} - {chapter} - {format}"
        options.whitespace = .underscores
        options.letterCase = .uppercase
        options.transliterate = true
        var custom = ArchiveLayout(
            root: root, template: "{format}/{author}/{year}/part {partNumber}/{chapterNumber} {chapter}", naming: options
        )
        let path = try custom.directory(
            for: named, format: "mp3", chapterNumber: 4, chapterTitle: "First/Chapter", partNumber: 3
        )
        check(path.path.hasSuffix("/MP3/ZOE_BELL/2025/PART_03/04_FIRST-CHAPTER"))
        check(custom.filenameStem(for: named, format: "aax", partNumber: 3) == "2_ECHO_DU_MONDE_03")
        let chapter = custom.filenameStem(
            for: named, format: "mp3", chapterNumber: 4, chapterTitle: "First/Chapter"
        )
        check(ArchiveLayout.filename(chapter) == "04_-_FIRST-CHAPTER_-_MP3")
        custom.naming.keepOriginalAAXFilename = true
        check(custom.originalAAXFilename("Écho du Monde.AAX") == "Écho du Monde.AAX")
        for invalid in ["../Book.aax", "folder\\Book.aax", ".Book.aax", " \n.aax", "Book.mp3"] {
            check(custom.originalAAXFilename(invalid) == nil)
        }
        check(custom.originalAAXFilename(String(repeating: "é", count: 120) + ".aax") == nil)
        check(custom.filenameStem(for: named, format: "aax", partNumber: 3) == "2_ECHO_DU_MONDE_03")
        check(try JSONDecoder().decode(ArchiveLayout.self, from: JSONEncoder().encode(custom)) == custom)
        custom.naming.chapterFilenameTemplate = "{chapter}/{chapterNumber}"
        check(!custom.isValid)
        custom.naming.chapterFilenameTemplate = "{unrecognised}"
        check(!custom.isValid)
    }

    private static func checkIncompleteStaging(in workspace: URL) throws {
        let manager = FileManager.default
        let root = workspace.appending(path: "Resume")
        let outside = workspace.appending(path: "Other")
        let asin = "B000000001"
        let first = "account/one"
        let second = "account/two"
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let userFile = root.appending(path: "Keep.m4b")
        let sentinel = outside.appending(path: "Keep.aax.partial")
        let bytes = Data("preserve".utf8)
        try bytes.write(to: userFile)
        try bytes.write(to: sentinel)

        let firstJob = IncompleteDownloads.folder(for: asin, account: first, root: root)
        let secondJob = IncompleteDownloads.folder(for: asin, account: second, root: root)
        let recreated = IncompleteDownloads.folder(for: asin, account: first, root: root.standardizedFileURL)
        check(firstJob == recreated && firstJob != secondJob)
        check(firstJob.deletingLastPathComponent().lastPathComponent == ".downaudible-incomplete")
        check(firstJob.lastPathComponent.count == 64)
        let audio = try IncompleteDownloads.audioFolder(for: asin, account: first, root: root, restart: false)
        let otherAudio = try IncompleteDownloads.audioFolder(for: asin, account: second, root: root, restart: false)
        let partial = audio.appending(path: "book.aax.partial")
        let otherPartial = otherAudio.appending(path: "book.aax.partial")
        let receipt = firstJob.appending(path: "receipt.json")
        try bytes.write(to: partial)
        try bytes.write(to: otherPartial)
        try bytes.write(to: receipt)
        check(IncompleteDownloads.containsAudio(for: asin, account: first, root: root))
        check(try IncompleteDownloads.audioFolder(for: asin, account: first, root: root, restart: false) == audio)
        check(try Data(contentsOf: partial) == bytes)

        check(try IncompleteDownloads.audioFolder(for: asin, account: first, root: root, restart: true) == audio)
        check(!IncompleteDownloads.containsAudio(for: asin, account: first, root: root))
        check(try Data(contentsOf: receipt) == bytes)
        check(try Data(contentsOf: userFile) == bytes)
        check(try Data(contentsOf: otherPartial) == bytes)
        try manager.createSymbolicLink(at: partial, withDestinationURL: sentinel)
        check(!IncompleteDownloads.containsAudio(in: firstJob))
        try manager.removeItem(at: audio)
        try manager.createSymbolicLink(at: audio, withDestinationURL: outside)
        check(!IncompleteDownloads.containsAudio(in: firstJob))
        do {
            _ = try IncompleteDownloads.audioFolder(for: asin, account: first, root: root, restart: true)
            fatalError("Restart followed an audio staging symlink")
        } catch ArchiveError.unsafeStaging {}
        try IncompleteDownloads.clear(for: asin, account: first, root: root)
        check(try Data(contentsOf: sentinel) == bytes)
        check(try Data(contentsOf: otherPartial) == bytes)

        try manager.createSymbolicLink(at: firstJob, withDestinationURL: outside)
        check(!IncompleteDownloads.containsAudio(in: firstJob))
        do {
            try IncompleteDownloads.clear(for: asin, account: first, root: root)
            fatalError("Clearing followed a job staging symlink")
        } catch ArchiveError.unsafeStaging {}
        let linkedRoot = workspace.appending(path: "Link")
        try manager.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        let container = IncompleteDownloads.folder(for: asin, account: first, root: linkedRoot)
            .deletingLastPathComponent()
        try manager.createSymbolicLink(at: container, withDestinationURL: outside)
        check(IncompleteDownloads.folders(in: linkedRoot).isEmpty)
        do {
            _ = try IncompleteDownloads.audioFolder(for: asin, account: first, root: linkedRoot, restart: true)
            fatalError("Restart followed a staging container symlink")
        } catch ArchiveError.unsafeStaging {}
        check(try Data(contentsOf: sentinel) == bytes)
    }

    private static func checkReplacingMissingAudio(in workspace: URL, book: AudibleBook) async throws {
        let defaults = UserDefaults.standard
        let originalIndex = defaults.object(forKey: "ArchiveIndex")
        defer { defaults.set(originalIndex, forKey: "ArchiveIndex") }
        let source = workspace.appending(path: "Matched.mp3")
        let layout = ArchiveLayout(root: workspace.appending(path: "Restored"), template: ArchiveLayout.defaultTemplate)
        let archive = ArchiveWorker(media: MediaTools(toolDirectory: nil))
        let account = "archive-check"
        try Data("First source".utf8).write(to: source)
        let initial = try await archive.download(
            book, account: account, audible: AudibleClient(), matches: [source], layout: layout,
            options: DownloadOptions(), existingFiles: .saveNewCopy, progress: { _, _ in }
        )
        try FileManager.default.removeItem(at: initial.url)
        let missing = await archive.inventory(for: [book.id], account: account, layout: layout)
        check(missing[book.id]?.missingFiles == [initial.url])

        let replacement = Data("A longer replacement source".utf8)
        try replacement.write(to: source)
        let restored = try await archive.download(
            book, account: account, audible: AudibleClient(), matches: [source], layout: layout,
            options: DownloadOptions(), existingFiles: .saveNewCopy, progress: { _, _ in }
        )
        check(restored.url == initial.url)
        check(try Data(contentsOf: restored.url) == replacement)
        let current = await archive.inventory(for: [book.id], account: account, layout: layout)
        check(current[book.id]?.files == [restored.url])
        check(current[book.id]?.missingFiles.isEmpty == true)
    }

    private static func checkMultilineExport(in workspace: URL) async throws {
        let book = try JSONDecoder().decode(AudibleBook.self, from: Data(
            #"{"asin":"B000000002","title":"Multiline","description":"Line one\r\nLine two","authors":[],"narrators":[],"hasPDF":false,"isDownloadable":true}"#.utf8
        ))
        for format in [LibraryExportFormat.csv, .tsv] {
            let path = workspace.appending(path: "Multiline.\(format.rawValue)")
            try await format.write([book], to: path)
            let contents = try String(contentsOf: path, encoding: .utf8)
            check(contents.contains("\"Line one\r\nLine two\""))
        }
    }

    private static func checkTransferQueue(
        in workspace: URL, book: AudibleBook, file: LocalAudioFile, layout: ArchiveLayout
    ) async throws {
        let path = workspace.appending(path: "Support/Transfers.json")
        let store = TransferQueueStore(path: path)
        check(try await store.load() == nil)
        let account = SavedAudibleAccount(id: UUID(), name: "Personal library", marketplace: .unitedKingdom)
        var options = DownloadOptions()
        options.convert = true
        options.downloadCover = true
        var conversion = ConversionPreferences()
        conversion.format = .mp3
        conversion.chapterMode = .separate
        let activation = "A1B2C3D4"
        var batch = TransferBatch(
            work: [.library(book, matches: [file.url]), .local(file)], account: account,
            apiOptions: AudibleAPIOptions(), layout: layout, options: options, conversion: conversion,
            appleBooks: .off, preferences: TransferPreferences(), jobLimit: 2
        )
        batch.activation = activation
        let partialRoot = workspace.appending(path: "Queued")
        let partial = IncompleteDownloads.folder(for: book.id, account: account.id.uuidString, root: partialRoot)
        let audioFolder = try IncompleteDownloads.audioFolder(
            for: book.id, account: account.id.uuidString, root: partialRoot, restart: false
        )
        let partialFile = audioFolder.appending(path: "book.aax.partial")
        try Data("partial".utf8).write(to: partialFile)
        let downloading = Transfer(
            title: book.title, status: .active("Downloading audio", 0.25),
            partialFolder: partial, restartPending: true, booksImportPending: true
        )
        let failed = Transfer(title: file.title, status: .failed("Fixture failed"))
        let snapshot = TransferQueueSnapshot(batch: batch, transfers: [downloading, failed])
        let empty = TransferQueueSnapshot(batch: nil, transfers: [])

        try await store.save(snapshot, revision: 4)
        try await store.save(empty, revision: 2)
        try await store.save(empty, revision: 4)
        let raw = try Data(contentsOf: path)
        let json = String(decoding: raw, as: UTF8.self)
        check(!json.contains(activation))
        for key in ["activation", "password", "session", "accessToken", "refreshToken", "adpToken"] {
            check(!json.contains("\"\(key)\""))
        }

        let reopened = TransferQueueStore(path: path)
        guard let saved = try await reopened.load(), let savedBatch = saved.batch else {
            fatalError("Transfer queue did not reopen")
        }
        check(savedBatch.account == account && savedBatch.activation == nil)
        check(savedBatch.layout == layout && savedBatch.options.downloadCover && savedBatch.options.makesConversion)
        check(savedBatch.conversion == conversion && savedBatch.jobLimit == 2)
        check(saved.transfers.map(\.id) == [downloading.id, failed.id])
        check(saved.transfers[0].partialFolder == partial && !saved.transfers[0].canRestart)
        check(saved.transfers[0].restartPending == true && saved.transfers[1].restartPending == nil)
        check(saved.transfers[0].booksImportPending == true && saved.transfers[1].booksImportPending == nil)
        check(saved.transfers[1].canRetry && saved.transfers[1].isFinished)
        var interrupted = saved.transfers[0]
        interrupted.status = .interrupted
        check(interrupted.canRestart)
        try FileManager.default.removeItem(at: partialFile)
        check(!interrupted.canRestart)
        guard case .library(let savedBook, let matches) = savedBatch.work[0],
              case .local(let savedFile) = savedBatch.work[1],
              case .active(let label, let progress) = saved.transfers[0].status else {
            fatalError("Transfer queue items changed on reload")
        }
        check(savedBook == book && matches == [file.url] && savedFile == file)
        check(label == "Downloading audio" && progress == 0.25)

        var legacyJSON = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        legacyJSON.removeValue(forKey: "history")
        let legacySnapshot = try JSONDecoder().decode(
            TransferQueueSnapshot.self, from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        check(legacySnapshot.history.isEmpty && legacySnapshot.batch?.repairsArchive == nil)
        check(legacySnapshot.transfers.map(\.id) == [downloading.id, failed.id])

        var repairBatch = batch
        repairBatch.repairsArchive = true
        let history = (0..<(TransferQueueSnapshot.historyLimit + 2)).map { index in
            TransferHistoryBatch(
                date: Date(timeIntervalSinceReferenceDate: Double(100 - index)), batch: repairBatch,
                transfers: [Transfer(title: book.title, status: .done(file.url, note: nil)), Transfer(title: file.title)]
            )
        }
        try await store.save(TransferQueueSnapshot(batch: nil, transfers: [], history: history), revision: 5)
        guard let withHistory = try await reopened.load() else { fatalError("Transfer history did not reopen") }
        check(withHistory.batch == nil && withHistory.transfers.isEmpty)
        check(withHistory.history.map(\.id) == history.prefix(TransferQueueSnapshot.historyLimit).map(\.id))
        check(withHistory.history[0].transfers.map(\.id) == history[0].transfers.map(\.id))
        check(withHistory.history[0].batch.repairsArchive == true && withHistory.history[0].batch.activation == nil)

        try await store.save(empty, revision: 6)
        let replaced = try await reopened.load()
        check(replaced?.batch == nil && replaced?.transfers.isEmpty == true && replaced?.history.isEmpty == true)

        let blockedFolder = workspace.appending(path: "Unavailable Queue Support")
        let blockedStore = TransferQueueStore(path: blockedFolder.appending(path: "Transfers.json"))
        try Data().write(to: blockedFolder)
        do {
            try await blockedStore.save(snapshot, revision: 1)
            fatalError("A failed queue write must be reported")
        } catch {
            check(error.localizedDescription.contains("couldn’t save its download queue"))
        }
        try FileManager.default.removeItem(at: blockedFolder)
        try await blockedStore.save(snapshot, revision: 1)
        check(try await blockedStore.load()?.transfers.map(\.id) == [downloading.id, failed.id])
    }

    @MainActor
    private static func checkArchiveWatcher(in workspace: URL, existsAtStart: Bool) async throws {
        let folder = workspace.appending(path: existsAtStart ? "Watched" : "New/Watched")
        if existsAtStart { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = folder.appending(path: "Deleted.m4b")
        let (events, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard let watcher = ArchiveWatcher(root: folder, changed: {
            continuation.yield(FileManager.default.fileExists(atPath: file.path))
        }) else {
            throw WatcherError.couldNotStart
        }
        defer {
            continuation.finish()
            withExtendedLifetime(watcher) {}
        }
        if !existsAtStart { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("audio".utf8).write(to: file)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var removed = false
                for await exists in events {
                    if removed && !exists { return }
                    if !removed && exists {
                        try FileManager.default.removeItem(at: file)
                        removed = true
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw WatcherError.noRemovalEvent
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private enum WatcherError: Error {
        case couldNotStart, noRemovalEvent
    }

    static func check(_ condition: Bool, line: UInt = #line) {
        precondition(condition, "Verification failed at line \(line)")
    }
}
