import CryptoKit
import Foundation

actor ArchiveWorker {
    typealias Progress = @Sendable (String, Double?) async -> Void

    private struct Record: Codable {
        var originals: [StoredAudio] = []
        var converted: URL?
        var conversions: [String: [URL]]?
        var history: [[URL]]?
        var fileSizes: [URL: Int]?
        var requestID: UUID?
        var cover: URL?
        var covers: [String: URL]?
        var pdf: URL?
        var chapters: [String: URL]?
        var annotations: URL?

        var audioGroups: [[URL]] {
            let groups = [originals.map(\.url), converted.map { [$0] } ?? []]
                + (conversions.map { Array($0.values) } ?? []) + (history ?? [])
            return groups.filter { !$0.isEmpty }
        }

        var knownFiles: Set<URL> {
            var files = Set(audioGroups.joined())
            if let fileSizes { files.formUnion(fileSizes.keys) }
            for file in [cover, pdf, annotations].compactMap({ $0 }) { files.insert(file) }
            if let covers { files.formUnion(covers.values) }
            if let chapters { files.formUnion(chapters.values) }
            return files
        }

        func contains(_ url: URL) -> Bool {
            guard let bytes = ArchiveWorker.fileSize(url) else { return false }
            return fileSizes?[url].map { $0 == bytes } ?? true
        }

        func outputs(for preferences: ConversionPreferences, key: String) -> [URL] {
            let urls = conversions?[key] ?? (preferences == ConversionPreferences() ? converted.map { [$0] } ?? [] : [])
            return urls.allSatisfy(contains) ? urls : []
        }

        mutating func addConversion(_ urls: [URL], key: String) {
            let previous = conversions?[key] ?? []
            if !previous.isEmpty, previous != urls { history = (history ?? []) + [previous] }
            if conversions == nil { conversions = [:] }
            conversions?[key] = urls
        }
    }

    private struct Source {
        let audio: StoredAudio
        let credentials: AudibleConversionCredentials?
        let originalURL: URL?

        init(audio: StoredAudio, credentials: AudibleConversionCredentials? = nil, originalURL: URL? = nil) {
            self.audio = audio
            self.credentials = credentials
            self.originalURL = originalURL
        }
    }

    private enum WorkError: LocalizedError {
        case alreadyRunning
        case noExtras(String?)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "This audiobook already has a transfer in progress."
            case .noExtras(let message): message ?? "None of the selected extras are available for this title."
            }
        }
    }

    private static let indexKey = "ArchiveIndex"
    private let defaults = UserDefaults.standard
    private let media: MediaTools
    private var records: [String: Record] = [:]
    private var loaded = false
    private var activeRecords: Set<String> = []
    private var reservedFilenames: Set<String> = []
    private var conversionReservations: [UUID: [String]] = [:]

    init(media: MediaTools) {
        self.media = media
    }

    func download(
        _ book: AudibleBook,
        account: String,
        audible: AudibleClient,
        matches: [URL],
        layout: ArchiveLayout,
        options: DownloadOptions,
        existingFiles: ExistingFiles,
        conversion: ConversionPreferences = .init(),
        requestID: UUID? = nil,
        restartIncomplete: Bool = false,
        didRestart: @escaping @Sendable () async -> Void = {},
        progress: @escaping Progress
    ) async throws -> ExportReceipt {
        let title = ArchiveTitle(book)
        let key = recordKey(layout, account, book.id)
        let jobKey = IncompleteDownloads.folder(for: book.id, account: account, root: layout.root).path
        guard activeRecords.insert(jobKey).inserted else { throw WorkError.alreadyRunning }
        defer { activeRecords.remove(jobKey) }

        let previous = existingRecord(key)
        let restartsAudio = restartIncomplete && options.downloadAudio
            && IncompleteDownloads.containsAudio(for: book.id, account: account, root: layout.root)
        let sameAttempt = requestID != nil && requestID == previous.requestID
        let reuse = (existingFiles == .reuse || sameAttempt) && !restartsAudio
        var record = reuse || !options.downloadAudio
            ? previous
            : Record(history: previous.audioGroups, fileSizes: previous.fileSizes)
        record.requestID = requestID
        if !options.downloadAudio && existingFiles == .saveNewCopy && !sameAttempt {
            if options.downloadCover {
                for name in Self.requestedCoverNames(audible) { record.covers?.removeValue(forKey: name) }
                if audible.options.coverSizes.isEmpty { record.cover = nil }
            }
            if options.downloadPDF { record.pdf = nil }
            if options.downloadChapters { record.chapters?.removeValue(forKey: audible.options.chapterStyle.rawValue) }
            if options.downloadAnnotations { record.annotations = nil }
        }
        let recipe = try Self.recipeKey(conversion)
        var converted = options.makesConversion ? record.outputs(for: conversion, key: recipe) : []
        let needsConversion = options.makesConversion && converted.isEmpty
        var addedOriginal: [URL] = []
        var addedConverted: [URL] = []
        var usesAudioStaging = false
        let staging = try makeStagingDirectory(in: layout.root)
        defer { try? FileManager.default.removeItem(at: staging) }

        var sources = record.originals.allSatisfy({ record.contains($0.url) })
            ? record.originals.map { Source(audio: $0) } : []
        if sources.isEmpty && (options.savesOriginal || needsConversion) {
            if matches.isEmpty {
                guard book.isDownloadable else { throw ArchiveError.unavailable }
                let audioDirectory = try IncompleteDownloads.audioFolder(
                    for: book.id, account: account, root: layout.root, restart: restartIncomplete
                )
                usesAudioStaging = true
                if restartIncomplete { await didRestart() }
                await progress("Downloading audio", nil)
                let download = try await audible.download(book, to: audioDirectory) { fraction in
                    await progress("Downloading audio", fraction)
                }
                sources = download.parts.map {
                    Source(audio: StoredAudio(url: $0.audio, asin: $0.asin), credentials: $0.credentials)
                }
                guard !sources.isEmpty else { throw ArchiveError.noAudio }
                if options.savesOriginal {
                    sources = try saveOriginals(sources, title: title, layout: layout)
                    record.originals = sources.map(\.audio)
                    addedOriginal = record.originals.map(\.url)
                    save(&record, for: key, written: addedOriginal)
                    try IncompleteDownloads.clear(for: book.id, account: account, root: layout.root)
                    usesAudioStaging = false
                }
            } else {
                guard matches.allSatisfy(Self.isFile) else { throw ArchiveError.missingLocalFiles }
                sources = matches.map { Source(audio: StoredAudio(url: $0, asin: nil)) }
                if options.savesOriginal && existingFiles == .saveNewCopy {
                    sources = try saveOriginals(sources, title: title, layout: layout, copy: true)
                    record.originals = sources.map(\.audio)
                    addedOriginal = record.originals.map(\.url)
                    save(&record, for: key, written: addedOriginal)
                }
            }
        }
        try Task.checkCancellation()

        let sourceURL = sources.first?.audio.url ?? previous.originals.map(\.url).first(where: Self.isFile)
            ?? matches.first(where: Self.isFile)
        let sourceFormat = sourceURL?.pathExtension.lowercased()
        let extrasFormat = if options.makesConversion && !options.savesOriginal {
            conversion.format.fileExtension
        } else {
            sourceFormat ?? "extras"
        }
        var issues: [String] = []
        let artwork = try await getArtwork(
            book, audible: audible, staging: staging, title: title, layout: layout,
            format: extrasFormat, saveFiles: options.downloadCover, embed: needsConversion && conversion.embedArtwork,
            record: &record, key: key, issues: &issues, progress: progress
        )

        if needsConversion {
            await progress("Preparing conversion", nil)
            let needsChapters = conversion.embedChapters || conversion.chapterMode == .separate
            let chapters = needsChapters ? try await chapterMetadata(for: book, audible: audible) : []
            var inputs: [MediaInput] = []
            for source in sources {
                let credentials = try await mediaCredentials(
                    for: book, audio: StoredAudio(url: source.originalURL ?? source.audio.url, asin: source.audio.asin),
                    audible: audible, provided: source.credentials
                )
                inputs.append(MediaInput(url: source.audio.url, credentials: credentials))
            }

            let metadata = MediaMetadata(
                title: book.title, subtitle: book.subtitle, authors: book.authors, narrators: book.narrators,
                description: book.description, publisher: book.publisher, releaseDate: book.releaseDate,
                asin: book.asin, series: book.series, seriesSequence: book.seriesSequence,
                language: book.language, genres: book.genres ?? [], chapters: chapters
            )
            converted = try await convertAudio(
                inputs, title: title, layout: layout, preferences: conversion,
                metadata: metadata, artwork: artwork, progress: progress
            )
            addedConverted = converted
            record.addConversion(converted, key: recipe)
            save(&record, for: key, written: converted)
            if usesAudioStaging {
                try IncompleteDownloads.clear(for: book.id, account: account, root: layout.root)
            }
        }

        if options.downloadPDF && book.hasPDF && !(record.pdf.map(record.contains) ?? false) {
            await progress("Downloading PDF", nil)
            do {
                let extras = try await audible.downloadExtras(book, to: staging, pdf: true, cover: false)
                if let pdf = extras.pdf {
                    let destination = try saveExtra(pdf, title: title, layout: layout, format: extrasFormat)
                    record.pdf = destination
                    save(&record, for: key, written: [destination])
                } else {
                    issues.append("Audible didn’t return the PDF.")
                }
            } catch {
                try Task.checkCancellation()
                issues.append("Couldn’t download the PDF.")
            }
        }

        try await getJSONExtras(
            book, audible: audible, staging: staging, title: title, layout: layout, format: extrasFormat,
            options: options, record: &record, key: key, issues: &issues, progress: progress
        )

        let originals = options.savesOriginal ? sources.map(\.audio.url) : []
        let note = issues.isEmpty ? nil : issues.joined(separator: " ")
        if !options.downloadAudio {
            guard let output = firstExtra(in: record, options: options, audible: audible) else {
                throw WorkError.noExtras(note)
            }
            return ExportReceipt(url: output, note: note)
        }
        guard let output = converted.first ?? originals.first else { throw ArchiveError.noAudio }
        return ExportReceipt(
            url: output, original: originals, converted: converted,
            addedOriginal: addedOriginal, addedConverted: addedConverted, note: note
        )
    }

    func convert(
        _ file: LocalAudioFile,
        audible: AudibleClient,
        layout: ArchiveLayout,
        activationBytes: String?,
        existingFiles: ExistingFiles,
        conversion: ConversionPreferences = .init(),
        requestID: UUID? = nil,
        progress: @escaping Progress
    ) async throws -> ExportReceipt {
        let key = recordKey(layout, "Local file", file.url.standardizedFileURL.path)
        guard activeRecords.insert(key).inserted else { throw WorkError.alreadyRunning }
        defer { activeRecords.remove(key) }

        let previous = existingRecord(key)
        let sameAttempt = requestID != nil && requestID == previous.requestID
        var record = existingFiles == .reuse || sameAttempt
            ? previous
            : Record(history: previous.audioGroups, fileSizes: previous.fileSizes)
        record.requestID = requestID
        let recipe = try Self.recipeKey(conversion)
        let written = record.outputs(for: conversion, key: recipe)
        let sourceDate = try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let sourceDate, let first = written.first, written.allSatisfy({ output in
            guard let date = try? output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return false
            }
            return date >= sourceDate
        }) {
            return ExportReceipt(url: first, converted: written)
        }

        guard Self.isFile(file.url) else { throw ArchiveError.missingLocalFiles }
        let credentials = try await mediaCredentials(
            for: nil, audio: StoredAudio(url: file.url, asin: file.asin), audible: audible, activationBytes: activationBytes
        )
        let converted = try await convertAudio(
            [MediaInput(url: file.url, credentials: credentials)],
            title: ArchiveTitle(file), layout: layout, preferences: conversion, progress: progress
        )
        guard let first = converted.first else { throw ArchiveError.noAudio }
        record.addConversion(converted, key: recipe)
        save(&record, for: key, written: converted)
        return ExportReceipt(url: first, converted: converted, addedConverted: converted)
    }

    private func convertAudio(
        _ inputs: [MediaInput], title: ArchiveTitle, layout: ArchiveLayout,
        preferences: ConversionPreferences, metadata: MediaMetadata = .init(), artwork: URL? = nil,
        progress: @escaping Progress
    ) async throws -> [URL] {
        let conversionID = UUID()
        defer {
            let reservations = conversionReservations.removeValue(forKey: conversionID) ?? []
            reservedFilenames.subtract(reservations)
        }
        let format = preferences.format.fileExtension
        return try await media.convert(inputs, preferences: preferences, metadata: metadata, artwork: artwork) { outputs in
            try await self.reserve(outputs, for: title, layout: layout, format: format, id: conversionID)
        } progress: { fraction in
            await progress("Converting to \(format.uppercased())", fraction)
        }
    }

    private func reserve(
        _ outputs: [ConversionOutput], for title: ArchiveTitle, layout: ArchiveLayout, format: String, id: UUID
    ) throws -> [URL] {
        try outputs.map { output in
            let directory = try layout.directory(
                for: title, format: format, chapterNumber: output.chapterNumber, chapterTitle: output.chapterTitle
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = try availableURL(
                in: directory, title: title, layout: layout, extension: format,
                chapterNumber: output.chapterNumber, chapterTitle: output.chapterTitle
            )
            let reservation = Self.reservationKey(url)
            reservedFilenames.insert(reservation)
            conversionReservations[id, default: []].append(reservation)
            return url
        }
    }

    private static func recipeKey(_ preferences: ConversionPreferences) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(preferences.outputRecipe))
        return digest.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    func inventory(
        for ids: [String], account: String, layout: ArchiveLayout
    ) -> [String: ArchiveInventoryItem] {
        loadRecords()
        let root = layout.root.standardizedFileURL.path
        let ids = Set(ids)
        var inventory: [String: ArchiveInventoryItem] = [:]
        for (key, record) in records {
            guard let parts = Self.recordParts(key), parts.root == root, parts.account == account,
                  ids.contains(parts.asin) else { continue }
            var item = inventory[parts.asin, default: ArchiveInventoryItem()]
            item.hadAudio = item.hadAudio || !record.audioGroups.isEmpty
            for group in record.audioGroups where group.allSatisfy(record.contains) {
                for path in group where !item.files.contains(path) { item.files.append(path) }
            }
            let originals = record.originals.map(\.url)
            if item.originals.isEmpty, originals.allSatisfy(record.contains) { item.originals = originals }
            item.missingFiles.append(contentsOf: record.knownFiles.filter { !record.contains($0) })
            inventory[parts.asin] = item
        }
        for id in partialFolders(for: ids, account: account, root: layout.root).keys {
            inventory[id, default: ArchiveInventoryItem()].hasPartial = true
        }
        return inventory
    }

    func partialFolders(for ids: Set<String>, account: String, root: URL) -> [String: URL] {
        let incomplete = IncompleteDownloads.folders(in: root)
        guard !incomplete.isEmpty else { return [:] }
        var folders: [String: URL] = [:]
        for id in ids {
            let folder = IncompleteDownloads.folder(for: id, account: account, root: root)
            if incomplete.contains(folder.lastPathComponent), IncompleteDownloads.containsAudio(in: folder) {
                folders[id] = folder
            }
        }
        return folders
    }

    func validMatches(_ matches: [String: [URL]]) -> [String: [URL]] {
        matches.filter { !$0.value.isEmpty && $0.value.allSatisfy(Self.isFile) }
    }

    private func getArtwork(
        _ book: AudibleBook, audible: AudibleClient, staging: URL, title: ArchiveTitle,
        layout: ArchiveLayout, format: String, saveFiles: Bool, embed: Bool,
        record: inout Record, key: String, issues: inout [String], progress: Progress
    ) async throws -> URL? {
        guard saveFiles || embed else { return nil }
        var saved = record.covers?.filter { record.contains($0.value) } ?? [:]
        if saved["cover"] == nil, let old = record.cover, record.contains(old) { saved["cover"] = old }
        let largestFirst = saved.keys.sorted {
            Self.coverSize($0) > Self.coverSize($1)
        }
        let savedArtwork = largestFirst.compactMap { saved[$0] }.first
        let requested = Self.requestedCoverNames(audible)
        let missingCoverFiles = saveFiles && requested.contains { saved[$0] == nil }
        guard missingCoverFiles || (embed && savedArtwork == nil) else { return savedArtwork }

        await progress("Getting cover", nil)
        var artwork = savedArtwork
        do {
            let extras = try await audible.downloadExtras(book, to: staging, pdf: false, cover: true)
            artwork = extras.cover ?? artwork
            if saveFiles {
                for source in extras.covers {
                    try Task.checkCancellation()
                    let name = source.deletingPathExtension().lastPathComponent
                    guard saved[name] == nil else { continue }
                    let size = Self.coverSize(name)
                    let suffix = size > 0 ? " - Cover \(size)" : ""
                    let destination = try saveExtra(source, title: title, layout: layout, format: format, suffix: suffix)
                    saved[name] = destination
                    record.covers = saved
                    save(&record, for: key, written: [destination])
                    if artwork == source { artwork = destination }
                }
                if extras.failed.contains("cover") {
                    issues.append("Couldn’t download every cover.")
                }
            }
        } catch {
            try Task.checkCancellation()
            if saveFiles { issues.append("Couldn’t save every cover.") }
        }
        return artwork
    }

    private func firstExtra(in record: Record, options: DownloadOptions, audible: AudibleClient) -> URL? {
        var candidates: [URL?] = []
        if options.downloadPDF { candidates.append(record.pdf) }
        if options.downloadCover {
            let names = Self.requestedCoverNames(audible).sorted { Self.coverSize($0) > Self.coverSize($1) }
            candidates += names.map { name in
                record.covers?[name] ?? (name == "cover" ? record.cover : nil)
            }
        }
        if options.downloadChapters { candidates.append(record.chapters?[audible.options.chapterStyle.rawValue]) }
        if options.downloadAnnotations { candidates.append(record.annotations) }
        return candidates.compactMap { $0 }.first(where: record.contains)
    }

    private static func requestedCoverNames(_ audible: AudibleClient) -> [String] {
        audible.options.coverSizes.isEmpty ? ["cover"] : audible.options.coverSizes.map { "cover-\($0)" }
    }

    private static func coverSize(_ fileName: String) -> Int {
        guard fileName.hasPrefix("cover-") else { return 0 }
        return Int(fileName.dropFirst("cover-".count)) ?? 0
    }

    private func getJSONExtras(
        _ book: AudibleBook, audible: AudibleClient, staging: URL, title: ArchiveTitle,
        layout: ArchiveLayout, format: String, options: DownloadOptions,
        record: inout Record, key: String, issues: inout [String], progress: Progress
    ) async throws {
        let chapterStyle = audible.options.chapterStyle.rawValue
        let chapters = options.downloadChapters && !(record.chapters?[chapterStyle].map(record.contains) ?? false)
        let annotations = options.downloadAnnotations && !(record.annotations.map(record.contains) ?? false)
        guard chapters || annotations else { return }

        await progress("Downloading chapters and notes", nil)
        do {
            let extras = try await audible.downloadJSONExtras(book, to: staging, chapters: chapters, annotations: annotations)
            if chapters {
                do {
                    if let source = extras.chapters {
                        let destination = try saveExtra(
                            source, title: title, layout: layout, format: format, suffix: " - Chapters"
                        )
                        var saved = record.chapters ?? [:]
                        saved[chapterStyle] = destination
                        record.chapters = saved
                        save(&record, for: key, written: [destination])
                    } else if extras.failed.contains("chapters") {
                        issues.append("Couldn’t download the chapter list.")
                    }
                } catch {
                    try Task.checkCancellation()
                    issues.append("Couldn’t save the chapter list.")
                }
            }
            if annotations {
                do {
                    if let source = extras.annotations {
                        let destination = try saveExtra(
                            source, title: title, layout: layout, format: format, suffix: " - Notes"
                        )
                        record.annotations = destination
                        save(&record, for: key, written: [destination])
                    } else if extras.failed.contains("annotations") {
                        issues.append("Couldn’t download the notes.")
                    }
                } catch {
                    try Task.checkCancellation()
                    issues.append("Couldn’t save the notes.")
                }
            }
        } catch {
            try Task.checkCancellation()
            if chapters { issues.append("Couldn’t download the chapter list.") }
            if annotations { issues.append("Couldn’t download the notes.") }
        }
    }

    private func chapterMetadata(for book: AudibleBook, audible: AudibleClient) async throws -> [MediaChapter] {
        do {
            return try await audible.chapters(for: book).map {
                MediaChapter(
                    startMilliseconds: $0.startMilliseconds,
                    durationMilliseconds: $0.durationMilliseconds,
                    title: $0.title
                )
            }
        } catch {
            try Task.checkCancellation()
            return []
        }
    }

    private func mediaCredentials(
        for book: AudibleBook?,
        audio: StoredAudio,
        audible: AudibleClient,
        provided: AudibleConversionCredentials? = nil,
        activationBytes: String? = nil
    ) async throws -> MediaCredentials {
        let format = audio.url.pathExtension.lowercased()
        if format == "aax", let activationBytes {
            return MediaCredentials(activationBytes: activationBytes)
        }
        guard format == "aax" || format == "aaxc" else { return .init() }
        let credentials: AudibleConversionCredentials?
        if let provided, provided.activationBytes != nil || provided.contentKey != nil {
            credentials = provided
        } else {
            do {
                credentials = try await audible.conversionCredentials(for: book, audio: audio.url, partASIN: audio.asin)
            } catch {
                try Task.checkCancellation()
                if format == "aaxc" { throw error }
                credentials = nil
            }
        }
        return MediaCredentials(
            activationBytes: credentials?.activationBytes,
            audibleKey: credentials?.contentKey,
            audibleIV: credentials?.contentIV
        )
    }

    private func saveOriginals(
        _ sources: [Source],
        title: ArchiveTitle,
        layout: ArchiveLayout,
        copy: Bool = false
    ) throws -> [Source] {
        var saved: [Source] = []
        do {
            for (offset, source) in sources.enumerated() {
                try Task.checkCancellation()
                let part = sources.count > 1 ? offset + 1 : nil
                let format = source.audio.url.pathExtension.lowercased()
                let directory = try layout.directory(for: title, format: format, partNumber: part)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = try availableURL(in: directory, title: title, layout: layout, extension: format, partNumber: part)
                if copy {
                    try FileManager.default.copyItem(at: source.audio.url, to: destination)
                } else {
                    try FileManager.default.moveItem(at: source.audio.url, to: destination)
                }
                saved.append(Source(
                    audio: StoredAudio(url: destination, asin: source.audio.asin),
                    credentials: source.credentials, originalURL: copy ? source.audio.url : nil
                ))
            }
        } catch {
            for (original, written) in zip(sources, saved) {
                if copy {
                    try? FileManager.default.removeItem(at: written.audio.url)
                } else {
                    try? FileManager.default.moveItem(at: written.audio.url, to: original.audio.url)
                }
            }
            throw error
        }
        return saved
    }

    private func saveExtra(
        _ source: URL,
        title: ArchiveTitle,
        layout: ArchiveLayout,
        format: String,
        suffix: String = ""
    ) throws -> URL {
        try Task.checkCancellation()
        let directory = try makeOutputDirectory(layout, title, format: format)
        let destination = try availableURL(
            in: directory, title: title, layout: layout, extension: source.pathExtension, suffix: suffix
        )
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private func makeOutputDirectory(_ layout: ArchiveLayout, _ title: ArchiveTitle, format: String) throws -> URL {
        let directory = try layout.directory(for: title, format: format)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStagingDirectory(in root: URL) throws -> URL {
        let url = root.appending(component: ".downaudible-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func availableURL(
        in directory: URL, title: ArchiveTitle, layout: ArchiveLayout, extension ext: String, suffix: String = "",
        chapterNumber: Int? = nil, chapterTitle: String? = nil, partNumber: Int? = nil
    ) throws -> URL {
        let base = layout.filenameStem(
            for: title, format: ext, chapterNumber: chapterNumber, chapterTitle: chapterTitle, partNumber: partNumber
        )
        let asin = ArchiveLayout.filename(title.asin, maxBytes: 12)
        let maxLength = min(layout.filenameLength, 255)
        for number in 0...1_000 {
            var collision = switch number {
            case 0: ""
            case 1: " (\(asin))"
            default: " (\(asin)) \(number)"
            }
            let extensionPart = ext.isEmpty ? "" : ".\(ext)"
            if number > 0 && (title.asin == ArchiveTitle.unknownASIN ||
                              maxLength - (suffix + collision + extensionPart).utf8.count < 7) {
                collision = " (\(number + 1))"
            }
            let tail = suffix + collision + extensionPart
            let budget = maxLength - tail.utf8.count
            guard budget >= "Unknown".utf8.count else { throw ArchiveError.filenameExhausted }
            let name = ArchiveLayout.filename(base, maxBytes: budget) + tail
            let path = directory.appending(component: name)
            let info = try? path.resourceValues(forKeys: [.isSymbolicLinkKey])
            if !reservedFilenames.contains(Self.reservationKey(path)),
               !FileManager.default.fileExists(atPath: path.path), info?.isSymbolicLink != true {
                return path
            }
        }
        throw ArchiveError.filenameExhausted
    }

    private static func reservationKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isFile(_ url: URL) -> Bool { fileSize(url) != nil }

    private static func fileSize(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size > 0 else { return nil }
        return size
    }

    private func recordKey(_ layout: ArchiveLayout, _ account: String, _ identifier: String) -> String {
        let components = [layout.root.standardizedFileURL.path, layout.template, account, identifier]
        return components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func recordParts(_ key: String) -> (root: String, account: String, asin: String)? {
        var bytes = key.utf8[...]
        var parts: [String] = []
        for _ in 0..<4 {
            guard let separator = bytes.firstIndex(of: 58),
                  let length = Int(String(decoding: bytes[..<separator], as: UTF8.self)),
                  length >= 0 else { return nil }
            bytes = bytes[bytes.index(after: separator)...]
            guard let end = bytes.index(bytes.startIndex, offsetBy: length, limitedBy: bytes.endIndex) else { return nil }
            parts.append(String(decoding: bytes[..<end], as: UTF8.self))
            bytes = bytes[end...]
        }
        return (parts[0], parts[2], parts[3])
    }

    private func loadRecords() {
        guard !loaded else { return }
        loaded = true
        if let data = defaults.data(forKey: Self.indexKey),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = stored
        }
    }

    private func existingRecord(_ key: String) -> Record {
        loadRecords()
        return records[key] ?? Record()
    }

    private func save(_ record: inout Record, for key: String, written: [URL]) {
        var sizes = record.fileSizes ?? [:]
        for url in written { sizes[url] = Self.fileSize(url) }
        for url in record.knownFiles where sizes[url] == nil { sizes[url] = Self.fileSize(url) }
        record.fileSizes = sizes
        records[key] = record
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.indexKey)
        }
    }
}
