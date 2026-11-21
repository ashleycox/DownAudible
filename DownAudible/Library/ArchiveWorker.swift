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
        var aaxCleanup: AAXCleanup?
        var removedOriginals: Set<URL>?
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
            return files.subtracting(removedOriginals ?? [])
        }

        func contains(_ url: URL) -> Bool {
            guard removedOriginals?.contains(url) != true, let bytes = ArchiveWorker.fileSize(url) else { return false }
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

        mutating func retireBrokenCopies() {
            guard let history else { return }
            var kept: [[URL]] = []
            var broken: Set<URL> = []
            for group in history {
                if group.allSatisfy(contains) {
                    kept.append(group)
                } else {
                    broken.formUnion(group)
                }
            }
            self.history = kept
            let retired = broken.subtracting(audioGroups.joined())
            for url in retired { fileSizes?.removeValue(forKey: url) }
        }

        mutating func markOriginalsRemoved(_ urls: Set<URL>) -> Bool {
            var storedOriginals = Set(originals.map(\.url))
            storedOriginals.formUnion((history ?? []).joined())
            let removed = urls.intersection(storedOriginals)
            guard !removed.isEmpty else { return false }
            // A surviving part is still on disk, but the original multipart group is no longer complete.
            let intentionallyRemoved = (removedOriginals ?? []).union(removed)
            if originals.allSatisfy({ intentionallyRemoved.contains($0.url) }) { originals = [] }
            history?.removeAll { $0.allSatisfy(intentionallyRemoved.contains) }
            let labelled = intentionallyRemoved.intersection(audioGroups.joined())
            removedOriginals = labelled.isEmpty ? nil : labelled
            for url in removed { fileSizes?.removeValue(forKey: url) }
            return true
        }
    }

    private struct AAXCleanup: Codable {
        let recipe: String
        let sources: [AAXOriginal]
        // Older records did not identify the outputs. They cannot authorize a move to Trash.
        let outputs: [AAXOutput]?

        init(recipe: String, sources: [AAXOriginal], converted: [URL]) {
            self.recipe = recipe
            self.sources = sources
            let fingerprints = converted.compactMap(AAXOutput.init)
            outputs = fingerprints.count == converted.count ? fingerprints : nil
        }

        func verifies(_ converted: [URL]) -> Bool {
            guard let outputs, outputs.map(\.url) == converted else { return false }
            return outputs.allSatisfy(\.isCurrent) && outputs.allSatisfy { AAXOutput(url: $0.url) == $0 }
                && outputs.allSatisfy(\.isCurrent)
        }
    }

    private struct AAXOutput: Codable, Equatable {
        let url: URL
        private let digest: Data
        private let revision: FileRevision

        var isCurrent: Bool { FileRevision(url) == revision }

        init?(url: URL) {
            guard url.pathExtension.lowercased() == "mp3", let before = FileRevision(url),
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hash = SHA256()
            do {
                while !Task.isCancelled, let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                    hash.update(data: data)
                }
            } catch {
                return nil
            }
            guard !Task.isCancelled, FileRevision(url) == before else { return nil }
            self.url = url
            digest = Data(hash.finalize())
            revision = before
        }
    }

    private struct AAXOriginal: Codable, Equatable {
        let url: URL
        private let resolvedPath: String
        private let inode: UInt64
        private let device: UInt64
        private let bytes: UInt64
        private let modified: Date

        init?(url: URL) {
            guard url.isFileURL, url.pathExtension.lowercased() == "aax",
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let bytes = attributes[.size] as? NSNumber, bytes.uint64Value > 0,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.url = url
            resolvedPath = url.resolvingSymlinksInPath().path
            self.inode = inode.uint64Value
            self.device = device.uint64Value
            self.bytes = bytes.uint64Value
            self.modified = modified
        }

        var isMissing: Bool {
            do {
                return try !url.checkResourceIsReachable()
            } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
                return true
            } catch {
                return false
            }
        }

        func isInArchive(_ root: URL) -> Bool {
            let directory = root.resolvingSymlinksInPath().path
            return resolvedPath.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
        }
    }

    private struct Source {
        let audio: StoredAudio
        let credentials: AudibleConversionCredentials?
        let originalURL: URL?
        let originalFilename: String?

        init(
            audio: StoredAudio, credentials: AudibleConversionCredentials? = nil,
            originalURL: URL? = nil, originalFilename: String? = nil
        ) {
            self.audio = audio
            self.credentials = credentials
            self.originalURL = originalURL
            self.originalFilename = originalFilename
        }
    }

    private enum WorkError: LocalizedError {
        case alreadyRunning
        case noExtras(String?)
        case editSourceChanged

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "This audiobook already has a transfer in progress."
            case .noExtras(let message): message ?? "Audible did not list the selected extras for this title."
            case .editSourceChanged: "An audio source has changed or moved. Open Edit Book again to review the current audio."
            }
        }
    }

    private static let indexKey = "ArchiveIndex"
    private let defaults = UserDefaults.standard
    private let media: MediaTools
    private let trashItem: @Sendable (URL) throws -> Void
    private var records: [String: Record] = [:]
    private var loaded = false
    private var activeRecords: Set<String> = []
    private var reservedFilenames: Set<String> = []
    private var conversionReservations: [UUID: [String]] = [:]

    init(
        media: MediaTools,
        trashItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.media = media
        self.trashItem = trashItem
    }

    enum FeedbackMilestone: Sendable {
        case downloading
        case downloaded
        case preparingConversion
        case converted
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
        repairAudio: Bool = false,
        restartIncomplete: Bool = false,
        didRestart: @escaping @Sendable () async -> Void = {},
        feedback: @escaping @Sendable (FeedbackMilestone) async -> Void = { _ in },
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
        let reuse = (sameAttempt || (existingFiles == .reuse && !repairAudio)) && !restartsAudio
        var record = reuse || !options.downloadAudio
            ? previous
            : Record(history: previous.audioGroups, fileSizes: previous.fileSizes, removedOriginals: previous.removedOriginals)
        if repairAudio && !reuse {
            record = previous
            record.history = previous.audioGroups
            record.originals = []
            record.converted = nil
            record.conversions = nil
        }
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
        let cleansUpAAX = !repairAudio && conversion.cleansUpAAX && options.makesConversion && !options.keepOriginal
        if !sameAttempt || !cleansUpAAX { record.aaxCleanup = nil }
        var converted = options.makesConversion ? record.outputs(for: conversion, key: recipe) : []
        let needsConversion = options.makesConversion && converted.isEmpty
        var addedOriginal: [URL] = []
        var addedConverted: [URL] = []
        var usesAudioStaging = false
        var issues: [String] = []
        let staging = try makeStagingDirectory(in: layout.root)
        defer { try? FileManager.default.removeItem(at: staging) }

        var sources = record.originals.allSatisfy({ record.contains($0.url) })
            ? record.originals.map { Source(audio: $0) } : []
        if sources.isEmpty && (options.savesOriginal || needsConversion) {
            if matches.isEmpty {
                await feedback(.downloading)
                if !book.isDownloadable {
                    switch book.downloadUnavailableReason {
                    case .podcastSeries: throw AudibleError.podcastSeries
                    case .offlineRestricted: throw AudibleError.offlineRestricted
                    case .unpublished: throw AudibleError.notPublished
                    case nil: throw ArchiveError.unavailable
                    }
                }
                let audioDirectory = try IncompleteDownloads.audioFolder(
                    for: book.id, account: account, root: layout.root, restart: restartIncomplete
                )
                usesAudioStaging = true
                if restartIncomplete { await didRestart() }
                sources = try await downloadSources(book, audible: audible, to: audioDirectory, progress: progress)
                if options.savesOriginal {
                    sources = try saveOriginals(sources, title: title, layout: layout)
                    record.originals = sources.map(\.audio)
                    addedOriginal = record.originals.map(\.url)
                    save(&record, for: key, written: addedOriginal)
                    do {
                        try IncompleteDownloads.clear(for: book.id, account: account, root: layout.root)
                    } catch {
                        issues.append(error.localizedDescription)
                    }
                    usesAudioStaging = false
                }
                await feedback(.downloaded)
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
        let artwork = try await getArtwork(
            book, audible: audible, staging: staging, title: title, layout: layout,
            format: extrasFormat, saveFiles: options.downloadCover, embed: needsConversion && conversion.embedArtwork,
            record: &record, key: key, issues: &issues, feedback: feedback, progress: progress
        )

        if needsConversion {
            await feedback(.preparingConversion)
            await progress("Preparing conversion", nil)
            let needsChapters = conversion.embedChapters || conversion.chapterMode == .separate
            let chapters = needsChapters ? try await chapterMetadata(for: book, audible: audible) : []
            let metadata = Self.bookMetadata(book, chapters: chapters)
            func convertSources(_ sources: [Source]) async throws -> [URL] {
                var inputs: [MediaInput] = []
                for source in sources {
                    let audio = StoredAudio(url: source.originalURL ?? source.audio.url, asin: source.audio.asin)
                    let credentials = try await mediaCredentials(
                        for: book, audio: audio, audible: audible, provided: source.credentials
                    )
                    inputs.append(MediaInput(url: source.audio.url, credentials: credentials))
                }
                return try await convertAudio(
                    inputs, audible: audible, title: title, layout: layout, preferences: conversion,
                    metadata: metadata, artwork: artwork, progress: progress
                )
            }

            let originalsToTrash: [AAXOriginal] = if cleansUpAAX {
                Self.archivedAAXSources(sources, in: record, root: layout.root)
            } else {
                []
            }
            do {
                converted = try await convertSources(sources)
                record.aaxCleanup = originalsToTrash.isEmpty ? nil
                    : AAXCleanup(recipe: recipe, sources: originalsToTrash, converted: converted)
            } catch {
                try Task.checkCancellation()
                guard audible.options.format == .preferAAX, book.isDownloadable,
                      sources.contains(where: { $0.audio.url.pathExtension.lowercased() == "aax" }),
                      (error as? AudibleError) == .activation || (error as? MediaError) == .activationRequired else {
                    throw error
                }
                await feedback(.downloading)
                let audioDirectory = try IncompleteDownloads.audioFolder(
                    for: book.id, account: account, root: layout.root, restart: false
                )
                usesAudioStaging = true
                let fallback = try await downloadSources(
                    book, audible: audible, to: audioDirectory, format: .aaxcOnly, progress: progress
                )
                await feedback(.downloaded)
                await feedback(.preparingConversion)
                converted = try await convertSources(fallback)
                record.aaxCleanup = nil
            }
            addedConverted = converted
            record.addConversion(converted, key: recipe)
            save(&record, for: key, written: converted)
            await feedback(.converted)
            if usesAudioStaging {
                do {
                    try IncompleteDownloads.clear(for: book.id, account: account, root: layout.root)
                } catch {
                    issues.append(error.localizedDescription)
                }
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
                    await feedback(.downloaded)
                } else {
                    let reason = extras.failed["PDF"] ?? .extraUnavailable
                    issues.append("Couldn’t download the PDF. \(reason.localizedDescription)")
                }
            } catch {
                try Task.checkCancellation()
                let action = error is ArchiveError ? "save" : "download"
                issues.append("Couldn’t \(action) the PDF. \(error.localizedDescription)")
            }
        }

        try await getJSONExtras(
            book, audible: audible, staging: staging, title: title, layout: layout, format: extrasFormat,
            options: options, record: &record, key: key, issues: &issues, feedback: feedback, progress: progress
        )

        let replacement = converted.isEmpty ? record.originals.map(\.url) : converted
        if repairAudio && !replacement.isEmpty && replacement.allSatisfy(record.contains) {
            // Complete copies and extra files stay indexed. Repair never deletes files from disk.
            record.retireBrokenCopies()
            save(&record, for: key, written: [])
        }
        let cleanup = try finishAAXCleanup(record: &record, key: key, recipe: recipe, converted: converted)
        issues.append(contentsOf: cleanup.issues)
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
            addedOriginal: addedOriginal, addedConverted: addedConverted,
            removedAAX: cleanup.removed, note: note
        )
    }

    private func downloadSources(
        _ book: AudibleBook, audible: AudibleClient, to directory: URL,
        format: AudibleDownloadFormat? = nil, progress: @escaping Progress
    ) async throws -> [Source] {
        let status = format == .aaxcOnly ? "Downloading AAXC audio for conversion" : "Downloading audio"
        await progress(status, nil)
        let download = try await audible.download(book, to: directory, format: format) { fraction in
            await progress(status, fraction)
        }
        return download.parts.map {
            Source(
                audio: StoredAudio(url: $0.audio, asin: $0.asin), credentials: $0.credentials,
                originalFilename: $0.originalFilename
            )
        }
    }

    func convert(
        _ file: LocalAudioFile,
        audible: AudibleClient,
        layout: ArchiveLayout,
        activationBytes: String?,
        existingFiles: ExistingFiles,
        conversion: ConversionPreferences = .init(),
        requestID: UUID? = nil,
        feedback: @escaping @Sendable (FeedbackMilestone) async -> Void = { _ in },
        progress: @escaping Progress
    ) async throws -> ExportReceipt {
        let key = recordKey(layout, "Local file", file.url.standardizedFileURL.path)
        guard activeRecords.insert(key).inserted else { throw WorkError.alreadyRunning }
        defer { activeRecords.remove(key) }

        let previous = existingRecord(key)
        let sameAttempt = requestID != nil && requestID == previous.requestID
        var record = existingFiles == .reuse || sameAttempt
            ? previous
            : Record(history: previous.audioGroups, fileSizes: previous.fileSizes, removedOriginals: previous.removedOriginals)
        record.requestID = requestID
        let recipe = try Self.recipeKey(conversion)
        let written = record.outputs(for: conversion, key: recipe)
        if sameAttempt, conversion.cleansUpAAX, record.aaxCleanup?.recipe == recipe, let first = written.first {
            let cleanup = try finishAAXCleanup(
                record: &record, key: key, recipe: recipe, converted: written, forgetArchivedOriginals: true
            )
            return ExportReceipt(
                url: first, converted: written, removedAAX: cleanup.removed,
                note: cleanup.issues.isEmpty ? nil : cleanup.issues.joined(separator: " ")
            )
        }
        let sourceDate = try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let sourceDate, let first = written.first, written.allSatisfy({ output in
            guard let date = try? output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return false
            }
            return date >= sourceDate
        }) {
            return ExportReceipt(url: first, converted: written)
        }

        await feedback(.preparingConversion)
        guard Self.isFile(file.url) else { throw MediaError.sourceMissing }
        let original = conversion.cleansUpAAX ? AAXOriginal(url: file.url) : nil
        let credentials = try await mediaCredentials(
            for: nil, audio: StoredAudio(url: file.url, asin: file.asin), audible: audible, activationBytes: activationBytes
        )
        let converted = try await convertAudio(
            [MediaInput(url: file.url, credentials: credentials)], audible: activationBytes == nil ? audible : nil,
            title: ArchiveTitle(file), layout: layout, preferences: conversion, progress: progress
        )
        guard let first = converted.first else { throw ArchiveError.noAudio }
        record.aaxCleanup = original.map { AAXCleanup(recipe: recipe, sources: [$0], converted: converted) }
        record.addConversion(converted, key: recipe)
        save(&record, for: key, written: converted)
        await feedback(.converted)
        let cleanup = try finishAAXCleanup(
            record: &record, key: key, recipe: recipe, converted: converted, forgetArchivedOriginals: true
        )
        return ExportReceipt(
            url: first, converted: converted, addedConverted: converted, removedAAX: cleanup.removed,
            note: cleanup.issues.isEmpty ? nil : cleanup.issues.joined(separator: " ")
        )
    }

    func prepareBookEdit(
        _ origin: BookEditOrigin, localAudio: [StoredAudio], account: String?, audible: AudibleClient,
        layout: ArchiveLayout, activationBytes: String?
    ) async throws -> PreparedBookEdit? {
        let audio: [StoredAudio]
        if localAudio.isEmpty, let book = origin.book, let account {
            let record = existingRecord(recordKey(layout, account, book.id))
            if !record.originals.isEmpty, record.originals.allSatisfy({ record.contains($0.url) }) {
                audio = record.originals
            } else {
                let completeFiles = record.audioGroups.lazy.filter { $0.count == 1 }.compactMap(\.first)
                    .filter { ["m4b", "m4a", "mp3"].contains($0.pathExtension.lowercased()) && record.contains($0) }
                let converted = completeFiles.first { $0.pathExtension.lowercased() == "m4b" } ?? completeFiles.first
                audio = converted.map { [StoredAudio(url: $0, asin: nil)] } ?? []
            }
        } else {
            audio = localAudio
        }
        guard !audio.isEmpty else { return nil }
        let sources = try audio.map { item in
            guard let revision = FileRevision(item.url) else { throw MediaError.sourceMissing }
            return BookEditSource(audio: item, revision: revision)
        }
        let inputs = try await editingInputs(sources, book: origin.book, audible: audible, activationBytes: activationBytes)
        // A different edition or a separately delivered part can have different chapter offsets.
        let chapters: [MediaChapter] = if localAudio.isEmpty, audio.count == 1,
                                          let book = origin.book, audio[0].asin == book.asin {
            try await chapterMetadata(for: book, audible: audible)
        } else {
            []
        }
        var metadata = Self.bookMetadata(origin.book, chapters: chapters)
        metadata.title = origin.title
        let sections = try await media.bookEditingLayout(
            inputs, metadata: metadata, refreshActivation: Self.editingActivation(audible, override: activationBytes)
        )
        return PreparedBookEdit(sources: sources, audibleChapters: chapters, layout: sections)
    }

    func previewBookSection(
        _ section: BookEditSection, at position: BookPreviewPosition, source: BookEditSource,
        book: AudibleBook?, audible: AudibleClient,
        activationBytes: String?, to destination: URL
    ) async throws {
        let inputs = try await editingInputs([source], book: book, audible: audible, activationBytes: activationBytes)
        try await media.previewBookSection(
            section, at: position, input: inputs[0], to: destination,
            refreshActivation: Self.editingActivation(audible, override: activationBytes)
        )
    }

    func convertEditedBook(
        _ work: BookEditWork, audible: AudibleClient, layout: ArchiveLayout, activationBytes: String?,
        conversion: ConversionPreferences, requestID: UUID,
        feedback: @escaping @Sendable (FeedbackMilestone) async -> Void, progress: @escaping Progress
    ) async throws -> ExportReceipt {
        // A shortened export should never count as a complete Library copy.
        let key = recordKey(layout, "Edited books", requestID.uuidString)
        guard activeRecords.insert(key).inserted else { throw WorkError.alreadyRunning }
        defer { activeRecords.remove(key) }
        var record = existingRecord(key)
        let recipe = try Self.recipeKey(conversion)
        let saved = record.outputs(for: conversion, key: recipe)
        if let first = saved.first { return ExportReceipt(url: first, converted: saved) }

        await feedback(.preparingConversion)
        let inputs = try await editingInputs(work.sources, book: work.origin.book, audible: audible, activationBytes: activationBytes)
        var metadata = Self.bookMetadata(work.origin.book, chapters: work.audibleChapters)
        metadata.title = work.origin.title
        let converted = try await convertAudio(
            inputs, audible: activationBytes == nil ? audible : nil, title: work.origin.archiveTitle,
            layout: layout, preferences: conversion, metadata: metadata, bookEdit: work.edit,
            filenameSuffix: work.edit.excludedSections.isEmpty ? "" : " - Edited", progress: progress
        )
        guard let first = converted.first else { throw ArchiveError.noAudio }
        record.addConversion(converted, key: recipe)
        save(&record, for: key, written: converted)
        await feedback(.converted)
        return ExportReceipt(url: first, converted: converted, addedConverted: converted)
    }

    private func editingInputs(
        _ sources: [BookEditSource], book: AudibleBook?, audible: AudibleClient, activationBytes: String?
    ) async throws -> [MediaInput] {
        var inputs: [MediaInput] = []
        for source in sources {
            try Task.checkCancellation()
            guard FileRevision(source.audio.url) == source.revision else { throw WorkError.editSourceChanged }
            let credentials = try await mediaCredentials(
                for: book, audio: source.audio, audible: audible, activationBytes: activationBytes
            )
            inputs.append(MediaInput(url: source.audio.url, credentials: credentials, expectedRevision: source.revision))
        }
        guard inputs.allSatisfy(\.sourceRevisionMatches) else { throw WorkError.editSourceChanged }
        return inputs
    }

    private static func editingActivation(
        _ audible: AudibleClient, override: String?
    ) -> (@Sendable () async throws -> String)? {
        guard override == nil else { return nil }
        return {
            do {
                return try await audible.activationBytes(refresh: true)
            } catch AudibleError.notSignedIn {
                throw MediaError.activationRequired
            }
        }
    }

    private static func bookMetadata(_ book: AudibleBook?, chapters: [MediaChapter]) -> MediaMetadata {
        guard let book else { return MediaMetadata(chapters: chapters) }
        return MediaMetadata(
            title: book.title, subtitle: book.subtitle, authors: book.authors, narrators: book.narrators,
            description: book.description, publisher: book.publisher, releaseDate: book.releaseDate,
            asin: book.asin, series: book.series, seriesSequence: book.seriesSequence,
            language: book.language, genres: book.genres ?? [], chapters: chapters
        )
    }

    private static func archivedAAXSources(_ sources: [Source], in record: Record, root: URL) -> [AAXOriginal] {
        let archived = Set(record.originals.map(\.url))
        return sources.compactMap { source in
            guard archived.contains(source.audio.url), let original = AAXOriginal(url: source.audio.url),
                  original.isInArchive(root) else { return nil }
            return original
        }
    }

    private func finishAAXCleanup(
        record: inout Record, key: String, recipe: String, converted: [URL], forgetArchivedOriginals: Bool = false
    ) throws -> (removed: Set<URL>, issues: [String]) {
        guard let cleanup = record.aaxCleanup, cleanup.recipe == recipe, !converted.isEmpty else { return ([], []) }
        try Task.checkCancellation()
        guard converted.allSatisfy(record.contains), cleanup.verifies(converted) else {
            try Task.checkCancellation()
            return ([], [
                "The MP3 export changed or could not be verified. The AAX files were kept. "
                    + "In Settings > Files, set If a file is already saved to Save another copy, then start a new conversion."
            ])
        }

        var removed: Set<URL> = []
        var changed = false
        var moveFailed = false
        var outputChanged = false
        for original in cleanup.sources {
            // Leave any remaining files in place if cancellation arrives during a multipart cleanup.
            guard !Task.isCancelled else { break }
            if original.isMissing {
                removed.insert(original.url)
                continue
            }
            guard AAXOriginal(url: original.url) == original else {
                changed = true
                continue
            }
            guard cleanup.outputs?.allSatisfy(\.isCurrent) == true else {
                outputChanged = true
                break
            }
            guard !Task.isCancelled else { break }
            do {
                try trashItem(original.url)
                removed.insert(original.url)
            } catch {
                moveFailed = true
            }
        }

        var changedRecords = record.markOriginalsRemoved(removed)
        if forgetArchivedOriginals && !removed.isEmpty {
            for otherKey in records.keys where otherKey != key {
                guard var other = records[otherKey], other.markOriginalsRemoved(removed) else { continue }
                records[otherKey] = other
                changedRecords = true
            }
        }
        if changedRecords { save(&record, for: key, written: []) }
        var issues: [String] = []
        if changed { issues.append("The MP3 export was saved. An AAX source changed during conversion and was kept.") }
        if outputChanged { issues.append("The MP3 export changed during cleanup. The remaining AAX files were kept.") }
        if moveFailed || Task.isCancelled {
            issues.append("The MP3 export was saved. Some AAX files are still in place. Check that their folder allows moving files to Trash, or move them in Finder.")
        }
        return (removed, issues)
    }

    private func convertAudio(
        _ inputs: [MediaInput], audible: AudibleClient?, title: ArchiveTitle, layout: ArchiveLayout,
        preferences: ConversionPreferences, metadata: MediaMetadata = .init(), artwork: URL? = nil,
        bookEdit: BookEdit? = nil, filenameSuffix: String = "",
        progress: @escaping Progress
    ) async throws -> [URL] {
        let conversionID = UUID()
        defer {
            let reservations = conversionReservations.removeValue(forKey: conversionID) ?? []
            reservedFilenames.subtract(reservations)
        }
        let format = preferences.format.fileExtension
        let converting = "Converting to \(format.uppercased())"
        let refreshActivation: (@Sendable () async throws -> String)?
        if let audible {
            refreshActivation = {
                await progress("Refreshing Audible activation bytes", nil)
                let activation: String
                do {
                    activation = try await audible.activationBytes(refresh: true)
                } catch AudibleError.notSignedIn {
                    throw MediaError.activationRequired
                }
                try Task.checkCancellation()
                await progress(converting, nil)
                return activation
            }
        } else {
            refreshActivation = nil
        }
        return try await media.convert(
            inputs, preferences: preferences, metadata: metadata, artwork: artwork,
            refreshActivation: refreshActivation, bookEdit: bookEdit
        ) { outputs in
            try await self.reserve(outputs, for: title, layout: layout, format: format, suffix: filenameSuffix, id: conversionID)
        } progress: { fraction in
            await progress(converting, fraction)
        }
    }

    private func reserve(
        _ outputs: [ConversionOutput], for title: ArchiveTitle, layout: ArchiveLayout, format: String,
        suffix: String, id: UUID
    ) throws -> [URL] {
        try outputs.map { output in
            let directory = try layout.directory(
                for: title, format: format, chapterNumber: output.chapterNumber, chapterTitle: output.chapterTitle
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = try availableURL(
                in: directory, title: title, layout: layout, extension: format, suffix: suffix,
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

    func verifyArchive(
        books: [AudibleBook], account: String, layout: ArchiveLayout, matches: [String: [URL]],
        progress: @Sendable (Int, Int) async -> Void
    ) async throws -> [ArchiveVerificationIssue] {
        try Task.checkCancellation()
        guard (try? layout.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isReadableFile(atPath: layout.root.path) else {
            throw ArchiveVerificationError.folderUnavailable
        }
        loadRecords()
        let directory = try MediaTools.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        var verifier = try ArchiveAudioVerifier(media: media, directory: directory)
        let root = layout.root.standardizedFileURL.path
        let ids = Set(books.map(\.id))
        var recordsByBook: [String: [Record]] = [:]
        for (key, record) in records {
            guard let parts = Self.recordParts(key), parts.root == root, parts.account == account,
                  ids.contains(parts.asin) else { continue }
            recordsByBook[parts.asin, default: []].append(record)
        }
        let partials = partialFolders(for: ids, account: account, root: layout.root)
        var issues: [ArchiveVerificationIssue] = []
        await progress(0, books.count)
        for (index, book) in books.enumerated() {
            try Task.checkCancellation()
            let records = recordsByBook[book.id, default: []]
            var groups: [([URL], [URL: Int])] = []
            for record in records {
                let removed = record.removedOriginals ?? []
                for group in record.audioGroups where removed.isDisjoint(with: group) {
                    groups.append((group, record.fileSizes ?? [:]))
                }
            }
            if let matched = matches[book.id], !matched.isEmpty { groups.append((matched, [:])) }
            var files: Set<URL> = []
            var kind: ArchiveVerificationIssue.Kind = partials[book.id] == nil ? .missing : .incomplete
            var hasCompleteCopy = false
            for (group, sizes) in groups {
                var problems: [ArchiveVerificationIssue.Kind] = []
                for file in group {
                    try Task.checkCancellation()
                    guard let problem = try await verifier.problem(for: file, expectedSize: sizes[file]) else { continue }
                    files.insert(file)
                    problems.append(problem)
                }
                if problems.isEmpty {
                    hasCompleteCopy = true
                    break
                }
                if problems.contains(.unreadable) {
                    kind = .unreadable
                } else if kind == .missing && (problems.count < group.count || problems.contains(.incomplete)) {
                    kind = .incomplete
                }
            }
            if !hasCompleteCopy, book.isDownloadable || !groups.isEmpty || partials[book.id] != nil {
                issues.append(ArchiveVerificationIssue(
                    book: book, kind: kind,
                    files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                ))
            }
            await progress(index + 1, books.count)
        }
        try Task.checkCancellation()
        return issues
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
        record: inout Record, key: String, issues: inout [String],
        feedback: @Sendable (FeedbackMilestone) async -> Void, progress: Progress
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
                    await feedback(.downloaded)
                    if artwork == source { artwork = destination }
                }
            }
            if let reason = extras.failed["cover"], saveFiles || artwork == nil {
                issues.append("Couldn’t download the requested cover art. \(reason.localizedDescription)")
            }
        } catch {
            try Task.checkCancellation()
            if saveFiles || artwork == nil {
                let action = error is ArchiveError ? "save" : "download"
                issues.append("Couldn’t \(action) the requested cover art. \(error.localizedDescription)")
            }
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
        record: inout Record, key: String, issues: inout [String],
        feedback: @Sendable (FeedbackMilestone) async -> Void, progress: Progress
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
                        await feedback(.downloaded)
                    } else if let reason = extras.failed["chapters"] {
                        issues.append("Couldn’t download the chapter list. \(reason.localizedDescription)")
                    }
                } catch {
                    try Task.checkCancellation()
                    issues.append("Couldn’t save the chapter list. \(error.localizedDescription)")
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
                        await feedback(.downloaded)
                    } else if let reason = extras.failed["annotations"] {
                        issues.append("Couldn’t download the notes. \(reason.localizedDescription)")
                    }
                } catch {
                    try Task.checkCancellation()
                    issues.append("Couldn’t save the notes. \(error.localizedDescription)")
                }
            }
        } catch {
            try Task.checkCancellation()
            let files = chapters ? (annotations ? "the chapter list and notes" : "the chapter list") : "the notes"
            issues.append("Couldn’t download \(files). \(error.localizedDescription)")
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
                let destination = try availableURL(
                    in: directory, title: title, layout: layout, extension: format, partNumber: part,
                    originalFilename: source.originalFilename
                )
                if copy {
                    do {
                        try FileManager.default.copyItem(at: source.audio.url, to: destination)
                    } catch CocoaError.fileReadNoPermission {
                        throw ArchiveError.matchedFileUnreadable
                    } catch CocoaError.fileReadNoSuchFile {
                        throw ArchiveError.missingLocalFiles
                    }
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
            throw ArchiveError.storageFailure(error, otherwise: .cannotSaveOutput)
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
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw ArchiveError.storageFailure(error, otherwise: .cannotSaveOutput)
        }
        return destination
    }

    private func makeOutputDirectory(_ layout: ArchiveLayout, _ title: ArchiveTitle, format: String) throws -> URL {
        let directory = try layout.directory(for: title, format: format)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.storageFailure(error, otherwise: .cannotSaveOutput)
        }
        return directory
    }

    private func makeStagingDirectory(in root: URL) throws -> URL {
        let url = root.appending(component: ".downaudible-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ArchiveError.storageFailure(error, otherwise: .stagingUnavailable)
        }
        return url
    }

    private func availableURL(
        in directory: URL, title: ArchiveTitle, layout: ArchiveLayout, extension ext: String, suffix: String = "",
        chapterNumber: Int? = nil, chapterTitle: String? = nil, partNumber: Int? = nil, originalFilename: String? = nil
    ) throws -> URL {
        let original = ext == "aax" ? layout.originalAAXFilename(originalFilename) : nil
        let base = original.map { String($0.dropLast(4)) } ?? layout.filenameStem(
            for: title, format: ext, chapterNumber: chapterNumber, chapterTitle: chapterTitle, partNumber: partNumber
        )
        let extensionPart = original.map { String($0.suffix(4)) } ?? (ext.isEmpty ? "" : ".\(ext)")
        let asin = ArchiveLayout.filename(title.asin, maxBytes: 12)
        let maxLength = min(layout.filenameLength, 255)
        for number in 0...1_000 {
            var collision = switch number {
            case 0: ""
            case 1: " (\(asin))"
            default: " (\(asin)) \(number)"
            }
            if number > 0 && (title.asin == ArchiveTitle.unknownASIN ||
                              maxLength - (suffix + collision + extensionPart).utf8.count < 7) {
                collision = " (\(number + 1))"
            }
            let tail = suffix + collision + extensionPart
            let budget = maxLength - tail.utf8.count
            guard budget >= "Unknown".utf8.count else { throw ArchiveError.filenameExhausted }
            let name = (number == 0 ? original : nil) ?? (ArchiveLayout.filename(base, maxBytes: budget) + tail)
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
        if let intentionallyRemoved = record.removedOriginals {
            let stillRemoved = intentionallyRemoved.intersection(record.audioGroups.joined()).subtracting(written)
            record.removedOriginals = stillRemoved.isEmpty ? nil : stillRemoved
        }
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
