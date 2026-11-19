import Foundation

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

        let previous = Data(#"{"convert":false,"keepOriginal":true,"downloadPDF":false,"downloadCover":true}"#.utf8)
        let options = try JSONDecoder().decode(DownloadOptions.self, from: previous)
        check(options.savesOriginal && options.downloadAudio && options.downloadCover && !options.downloadChapters)

        let file = LocalAudioFile(url: root.appending(path: "Book.aax"), format: "aax", title: "Écho", author: "Me", asin: nil, durationSeconds: 10)
        check(LocalAudioIndex(files: [file]).match(title: "Echo", author: "me", asin: "B000000001") == file)
        check(LocalAudioIndex(files: [file, file]).match(title: "Echo", author: "me", asin: "B000000001") == nil)
        let book = try JSONDecoder().decode(AudibleBook.self, from: Data(#"{"asin":"B000000001","title":"One, \"Two\"","authors":["Me"],"narrators":[],"hasPDF":false,"isDownloadable":true}"#.utf8))
        check(book.downloadUnavailableReason == nil)
        checkLibraryAudioCategories()
        let csv = workspace.appending(path: "Library.csv")
        try await LibraryExportFormat.csv.write([book], to: csv)
        check(try String(contentsOf: csv, encoding: .utf8).contains("\"One, \"\"Two\"\"\""))
        try await checkTransferQueue(in: workspace, book: book, file: file, layout: layout)

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
        print("Archive naming, incomplete transfers, queue persistence, file watching, matching, library status, preference migration, CSV export, and logs passed.")
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

    private static func checkOutputNaming(root: URL) throws {
        let title = ArchiveTitle(title: "My Great Book", author: "Me", asin: "B000000001")
        let previous = ArchiveLayout(root: root, template: ArchiveLayout.defaultTemplate, filenameStyle: .asinUnicode)
        check(previous.filenameStem(for: title, format: "aax") == "B000000001 - My Great Book")
        check(previous.filenameStem(for: title, format: "aax", partNumber: 2) == "B000000001 - My Great Book - Part 2")
        check(previous.filenameStem(for: title, format: "m4b", chapterNumber: 1, chapterTitle: "Opening")
              == "My Great Book - 01 - Opening")

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
        let partial = workspace.appending(path: "Resume/Partial")
        let downloading = Transfer(
            title: book.title, status: .active("Downloading audio", 0.25),
            canRestart: true, partialFolder: partial, restartPending: true
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
        check(saved.transfers[0].partialFolder == partial && saved.transfers[0].canRestart)
        check(saved.transfers[0].restartPending == true && saved.transfers[1].restartPending == nil)
        check(saved.transfers[1].canRetry && saved.transfers[1].isFinished)
        guard case .library(let savedBook, let matches) = savedBatch.work[0],
              case .local(let savedFile) = savedBatch.work[1],
              case .active(let label, let progress) = saved.transfers[0].status else {
            fatalError("Transfer queue items changed on reload")
        }
        check(savedBook == book && matches == [file.url] && savedFile == file)
        check(label == "Downloading audio" && progress == 0.25)
        try await store.save(empty, revision: 5)
        let replaced = try await reopened.load()
        check(replaced?.batch == nil && replaced?.transfers.isEmpty == true)
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
