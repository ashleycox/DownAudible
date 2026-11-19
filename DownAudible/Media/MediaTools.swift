import Foundation

struct MediaTools: Sendable {
    private static let originals: Set<String> = ["aax", "aaxc", "aa", "mp3"]
    private static let unprotectedFormats: Set<String> = ["m4a", "m4b"]
    private let toolDirectory: URL?

    init(toolDirectory: URL? = Bundle.main.resourceURL?.appending(path: "MediaSupport", directoryHint: .isDirectory)) {
        self.toolDirectory = toolDirectory
    }

    @concurrent func scan(_ url: URL, includeConverted: Bool = false) async throws -> [LocalAudioFile] {
        let ffprobe = try executable(named: "ffprobe")
        let formats = includeConverted ? Self.originals.union(Self.unprotectedFormats) : Self.originals
        let files = try Self.audioFiles(at: url, formats: formats)
        let directory = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }

        return try await withThrowingTaskGroup(of: LocalAudioFile.self) { group in
            var pending = files.makeIterator()
            let analyze: @Sendable (URL) async throws -> LocalAudioFile = { file in
                let inspection: AudioProbe?
                do {
                    inspection = try await Self.probe(
                        file, options: [], ffprobe: ffprobe, directory: directory, metadataOnly: true
                    )
                } catch is MediaError {
                    // Keep the file available for manual matching if its tags are unreadable.
                    inspection = nil
                }
                return Self.localFile(file, inspection: inspection)
            }
            for _ in 0..<4 {
                guard let file = pending.next() else { break }
                group.addTask { try await analyze(file) }
            }

            var result: [LocalAudioFile] = []
            for try await file in group {
                result.append(file)
                if let next = pending.next() {
                    group.addTask { try await analyze(next) }
                }
            }
            return result.sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
            }
        }
    }

    func executable(named name: String) throws -> URL {
        guard let url = toolDirectory?.appending(path: name),
              FileManager.default.isExecutableFile(atPath: url.path) else { throw MediaError.toolsMissing }
        return url
    }

    private static func audioFiles(at url: URL, formats: Set<String>) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isRegularFile == true && formats.contains(url.pathExtension.lowercased()) {
            return [url.standardizedFileURL]
        }
        guard values.isDirectory == true,
              let entries = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { throw MediaError.unsupportedFile }

        var files: [URL] = []
        for case let file as URL in entries {
            try Task.checkCancellation()
            guard formats.contains(file.pathExtension.lowercased()),
                  let attributes = try? file.resourceValues(forKeys: keys),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            files.append(file.standardizedFileURL)
        }
        return files
    }

    static func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DownAudible-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static func localFile(_ url: URL, inspection: AudioProbe?) -> LocalAudioFile {
        let tags = inspection?.formatTags ?? [:]
        let stem = url.deletingPathExtension().lastPathComponent
        let candidates = tags["asin"] ?? tags["audible_asin"] ?? tags["audibleasin"] ?? tags["com.apple.itunes:asin"]
        let asinRange = stem.range(of: "(?i)(?<![A-Z0-9])B0[A-Z0-9]{8}(?![A-Z0-9])", options: .regularExpression)
        let asin = candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .flatMap { $0.count == 10 ? $0 : nil }
            ?? asinRange.map { stem[$0].uppercased() }
        let title = [tags["title"], tags["parent_title"], tags["album"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let artist = [tags["artist"], tags["author"], tags["album_artist"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        var fallback = stem
        if let asinRange {
            fallback.removeSubrange(asinRange)
        }
        fallback = fallback
            .replacingOccurrences(of: "[]", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
        let format = url.pathExtension.lowercased()
        let authors = sourceTag(["authors", "artist", "author", "album_artist"], in: tags)
        let audiobook = ["aa", "aax", "aaxc", "m4b"].contains(format)
            || tags["genre"]?.localizedCaseInsensitiveContains("audiobook") == true
        let narrator = sourceTag(["narrator", "narrated_by", "read_by", "reader", "nrt"], in: tags)
            ?? (audiobook ? tags["composer"] : nil)
        let narrators = sourceTag(["narrators"], in: tags) ?? narrator
        let releaseDate = sourceTag(["date", "release_date", "pubdate", "year"], in: tags)
        let year = releaseDate.flatMap { date in
            date.range(of: #"(?<!\d)\d{4}(?!\d)"#, options: .regularExpression).map { String(date[$0]) }
        }
        let streamLanguage = inspection?.audio?.tags?["language"]
        let fields: [String: String?] = [
            "authors": authors,
            "subtitle": sourceTag(["subtitle"], in: tags),
            "narrator": narrator,
            "narrators": narrators,
            "series": sourceTag(["series", "series_title"], in: tags),
            "seriesNumber": sourceTag(["series-part", "series_part", "series_number", "series_sequence"], in: tags),
            "publisher": sourceTag(["publisher", "provider"], in: tags),
            "year": year,
            "language": sourceTag(["language", "lang"], in: tags) ?? (streamLanguage == "und" ? nil : streamLanguage)
        ]
        let metadata = fields.compactMapValues { $0 }
        let totalTracks = tags["track"]?.split(separator: "/").dropFirst().first.flatMap { Int($0) }
        return LocalAudioFile(
            url: url, format: format, title: title ?? (fallback.isEmpty ? stem : fallback),
            author: artist, asin: asin, durationSeconds: inspection?.durationSeconds,
            metadata: metadata.isEmpty ? nil : metadata, isSegment: totalTracks.map { $0 > 1 }
        )
    }

    private static func sourceTag(_ names: [String], in tags: [String: String]) -> String? {
        names.lazy.compactMap { key in
            (tags[key] ?? tags["com.apple.itunes:" + key])?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
    }

    static func probe(
        _ url: URL, options: [String], ffprobe: URL, directory: URL, metadataOnly: Bool = false
    ) async throws -> AudioProbe {
        let mode = metadataOnly ? ["-nofind_stream_info"] : ["-analyzeduration", "1000000", "-probesize", "65536"]
        let args = ["-v", "error"] + mode + [
            "-show_format", "-show_streams", "-show_chapters", "-show_data_hash", "sha256", "-of", "json"
        ] + options + ["-i", url.path]
        let (status, data, diagnostics) = try await MediaProcess.run(ffprobe, arguments: args, workingDirectory: directory)
        let error = String(decoding: diagnostics, as: UTF8.self)
        if error.contains("[aax] mismatch in checksums") || error.contains("[aax] error in drm blob decryption") {
            throw MediaError.activationRequired
        }
        guard status == 0, let result = try? JSONDecoder().decode(AudioProbe.self, from: data), result.audio != nil else {
            throw MediaError.unreadableAudio
        }
        return result
    }

}
