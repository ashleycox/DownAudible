import Foundation

actor ArchiveWorker {
    typealias Progress = @Sendable (String, Double?) async -> Void

    private struct Record: Codable {
        var originals: [StoredAudio] = []
        var converted: URL?
        var cover: URL?
        var covers: [String: URL]?
        var pdf: URL?
        var chapters: [String: URL]?
        var annotations: URL?
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
        progress: @escaping Progress
    ) async throws -> ExportReceipt {
        let title = ArchiveTitle(book)
        let key = recordKey(layout, account, book.id)
        guard activeRecords.insert(key).inserted else { throw WorkError.alreadyRunning }
        defer { activeRecords.remove(key) }

        let previous = existingRecord(key)
        var record = existingFiles == .reuse || !options.downloadAudio ? previous : Record()
        if !options.downloadAudio && existingFiles == .saveNewCopy {
            if options.downloadCover {
                for name in Self.requestedCoverNames(audible) { record.covers?.removeValue(forKey: name) }
                if audible.options.coverSizes.isEmpty { record.cover = nil }
            }
            if options.downloadPDF { record.pdf = nil }
            if options.downloadChapters { record.chapters?.removeValue(forKey: audible.options.chapterStyle.rawValue) }
            if options.downloadAnnotations { record.annotations = nil }
        }
        let needsConversion = options.makesM4B && !(record.converted.map(Self.isFile) ?? false)
        let staging = try makeStagingDirectory(in: layout.root)
        defer { try? FileManager.default.removeItem(at: staging) }

        var sources = record.originals.allSatisfy({ Self.isFile($0.url) })
            ? record.originals.map { Source(audio: $0) } : []
        if sources.isEmpty && (options.savesOriginal || needsConversion) {
            if matches.isEmpty {
                guard book.isDownloadable else { throw ArchiveError.unavailable }
                await progress("Downloading audio", nil)
                let download = try await audible.download(book, to: staging) { fraction in
                    await progress("Downloading audio", fraction)
                }
                sources = download.parts.map {
                    Source(audio: StoredAudio(url: $0.audio, asin: $0.asin), credentials: $0.credentials)
                }
                guard !sources.isEmpty else { throw ArchiveError.noAudio }
                if options.savesOriginal {
                    sources = try saveOriginals(sources, title: title, layout: layout)
                    record.originals = sources.map(\.audio)
                    save(record, for: key)
                }
            } else {
                guard matches.allSatisfy(Self.isFile) else { throw ArchiveError.missingLocalFiles }
                sources = matches.map { Source(audio: StoredAudio(url: $0, asin: nil)) }
                if options.savesOriginal && existingFiles == .saveNewCopy {
                    sources = try saveOriginals(sources, title: title, layout: layout, copy: true)
                    record.originals = sources.map(\.audio)
                    save(record, for: key)
                }
            }
        }
        try Task.checkCancellation()

        let sourceURL = sources.first?.audio.url ?? previous.originals.map(\.url).first(where: Self.isFile)
            ?? matches.first(where: Self.isFile)
        let sourceFormat = sourceURL?.pathExtension.lowercased()
        let extrasFormat = if options.makesM4B && !options.savesOriginal {
            "m4b"
        } else {
            sourceFormat ?? "extras"
        }
        var issues: [String] = []
        let artwork = try await getArtwork(
            book, audible: audible, staging: staging, title: title, layout: layout,
            format: extrasFormat, saveFiles: options.downloadCover, embed: needsConversion,
            record: &record, key: key, issues: &issues, progress: progress
        )

        if needsConversion {
            await progress("Preparing conversion", nil)
            let chapters = try await chapterMetadata(for: book, audible: audible)
            var inputs: [MediaInput] = []
            for source in sources {
                let credentials = try await mediaCredentials(
                    for: book, audio: StoredAudio(url: source.originalURL ?? source.audio.url, asin: source.audio.asin),
                    audible: audible, provided: source.credentials
                )
                inputs.append(MediaInput(url: source.audio.url, credentials: credentials))
            }

            let directory = try makeOutputDirectory(layout, title, format: "m4b")
            let destination = try availableURL(in: directory, title: title, layout: layout, extension: "m4b")
            let reservation = Self.reservationKey(destination)
            reservedFilenames.insert(reservation)
            defer { reservedFilenames.remove(reservation) }

            let metadata = MediaMetadata(
                title: book.title, subtitle: book.subtitle, authors: book.authors, narrators: book.narrators,
                description: book.description, publisher: book.publisher, releaseDate: book.releaseDate,
                asin: book.asin, series: book.series, seriesSequence: book.seriesSequence,
                language: book.language, genres: book.genres ?? [], chapters: chapters
            )
            try await media.convert(inputs, to: destination, metadata: metadata, artwork: artwork) { fraction in
                await progress("Converting to M4B", fraction)
            }
            record.converted = destination
            save(record, for: key)
        }

        if options.downloadPDF && book.hasPDF && !(record.pdf.map(Self.isFile) ?? false) {
            await progress("Downloading PDF", nil)
            do {
                let extras = try await audible.downloadExtras(book, to: staging, pdf: true, cover: false)
                if let pdf = extras.pdf {
                    record.pdf = try saveExtra(pdf, title: title, layout: layout, format: extrasFormat)
                    save(record, for: key)
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
        guard let output = (options.makesM4B ? record.converted : nil) ?? originals.first else {
            throw ArchiveError.noAudio
        }
        return ExportReceipt(url: output, original: originals, note: note)
    }

    func convert(
        _ file: LocalAudioFile,
        audible: AudibleClient,
        layout: ArchiveLayout,
        activationBytes: String?,
        existingFiles: ExistingFiles,
        progress: @escaping Progress
    ) async throws -> ExportReceipt {
        let key = recordKey(layout, "Local file", file.url.standardizedFileURL.path)
        guard activeRecords.insert(key).inserted else { throw WorkError.alreadyRunning }
        defer { activeRecords.remove(key) }

        var record = existingFiles == .reuse ? existingRecord(key) : Record()
        if let previous = record.converted, Self.isFile(previous) {
            let previousDate = try? previous.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let sourceDate = try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let previousDate, let sourceDate, previousDate >= sourceDate {
                return ExportReceipt(url: previous)
            }
        }

        guard Self.isFile(file.url) else { throw ArchiveError.missingLocalFiles }
        let title = ArchiveTitle(file)
        let credentials = try await mediaCredentials(
            for: nil, audio: StoredAudio(url: file.url, asin: file.asin), audible: audible, activationBytes: activationBytes
        )
        let directory = try makeOutputDirectory(layout, title, format: "m4b")
        let destination = try availableURL(in: directory, title: title, layout: layout, extension: "m4b")
        let reservation = Self.reservationKey(destination)
        reservedFilenames.insert(reservation)
        defer { reservedFilenames.remove(reservation) }

        try await media.convert(file.url, to: destination, credentials: credentials) { fraction in
            await progress("Converting to M4B", fraction)
        }
        record.converted = destination
        save(record, for: key)
        return ExportReceipt(url: destination)
    }

    func existingExports(for ids: [String], account: String, layout: ArchiveLayout) -> [String: [URL]] {
        var exports: [String: [URL]] = [:]
        for id in ids {
            let record = existingRecord(recordKey(layout, account, id))
            let originals = record.originals.map(\.url)
            if !originals.isEmpty && originals.allSatisfy(Self.isFile) {
                exports[id] = originals
            } else if let converted = record.converted, Self.isFile(converted) {
                exports[id] = [converted]
            }
        }
        return exports
    }

    private func getArtwork(
        _ book: AudibleBook, audible: AudibleClient, staging: URL, title: ArchiveTitle,
        layout: ArchiveLayout, format: String, saveFiles: Bool, embed: Bool,
        record: inout Record, key: String, issues: inout [String], progress: Progress
    ) async throws -> URL? {
        guard saveFiles || embed else { return nil }
        var saved = record.covers?.filter { Self.isFile($0.value) } ?? [:]
        if saved["cover"] == nil, let old = record.cover, Self.isFile(old) { saved["cover"] = old }
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
                    save(record, for: key)
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
        return candidates.compactMap { $0 }.first(where: Self.isFile)
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
        let chapters = options.downloadChapters && !(record.chapters?[chapterStyle].map(Self.isFile) ?? false)
        let annotations = options.downloadAnnotations && !(record.annotations.map(Self.isFile) ?? false)
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
                        save(record, for: key)
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
                        record.annotations = try saveExtra(
                            source, title: title, layout: layout, format: format, suffix: " - Notes"
                        )
                        save(record, for: key)
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
                let number = sources.count > 1 ? " - Part \(offset + 1)" : ""
                let format = source.audio.url.pathExtension.lowercased()
                let directory = try makeOutputDirectory(layout, title, format: format)
                let destination = try availableURL(in: directory, title: title, layout: layout, extension: format, suffix: number)
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
            for source in saved { try? FileManager.default.removeItem(at: source.audio.url) }
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
        in directory: URL, title: ArchiveTitle, layout: ArchiveLayout, extension ext: String, suffix: String = ""
    ) throws -> URL {
        let base = layout.filenameStyle.name(for: title)
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

    private static func isFile(_ url: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return info.isRegularFile == true && (info.fileSize ?? 0) > 0
    }

    private func recordKey(_ layout: ArchiveLayout, _ account: String, _ identifier: String) -> String {
        let components = [layout.root.standardizedFileURL.path, layout.template, account, identifier]
        return components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func existingRecord(_ key: String) -> Record {
        if !loaded {
            loaded = true
            if let data = defaults.data(forKey: Self.indexKey),
               let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
                records = stored
            }
        }
        return records[key] ?? Record()
    }

    private func save(_ record: Record, for key: String) {
        records[key] = record
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.indexKey)
        }
    }
}
