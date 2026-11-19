import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaTools: Sendable {
    private static let localFormats: Set<String> = ["aax", "aaxc", "aa", "mp3"]
    private let toolDirectory: URL?

    init(toolDirectory: URL? = Bundle.main.resourceURL?.appending(path: "MediaSupport", directoryHint: .isDirectory)) {
        self.toolDirectory = toolDirectory
    }

    @concurrent func scan(_ url: URL) async throws -> [LocalAudioFile] {
        let ffprobe = try executable(named: "ffprobe")
        let files = try Self.audioFiles(at: url)
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

    @concurrent func convert(
        _ source: URL,
        to destination: URL,
        credentials: MediaCredentials = .init(),
        metadata: MediaMetadata = .init(),
        artwork: URL? = nil,
        progress: @escaping MediaProcess.Progress = { _ in }
    ) async throws {
        try await convert(
            [MediaInput(url: source, credentials: credentials)],
            to: destination,
            metadata: metadata,
            artwork: artwork,
            progress: progress
        )
    }

    @concurrent func convert(
        _ inputs: [MediaInput],
        to destination: URL,
        metadata: MediaMetadata = .init(),
        artwork: URL? = nil,
        progress: @escaping MediaProcess.Progress = { _ in }
    ) async throws {
        guard !inputs.isEmpty else { throw MediaError.noInput }
        let manager = FileManager.default
        let staged = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).m4b")

        guard !manager.fileExists(atPath: destination.path) else { throw MediaError.destinationExists }
        let ffmpeg = try executable(named: "ffmpeg")
        let ffprobe = try executable(named: "ffprobe")
        let directory = try Self.workspace()
        defer {
            try? manager.removeItem(at: staged)
            try? manager.removeItem(at: directory)
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        await progress(nil)
        var probes: [AudioProbe] = []
        var options: [[String]] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let decryption = try Self.decryptionOptions(for: input, at: index, in: directory)
            probes.append(try await Self.probe(input.url, options: decryption, ffprobe: ffprobe, directory: directory))
            if input.url.pathExtension.lowercased() == "aaxc" {
                try await Self.validateVoucher(ffmpeg, for: input.url, options: decryption, directory: directory)
            }
            options.append(decryption)
        }
        let tags = try MediaTags.file(in: directory, probes: probes, inputs: inputs, metadata: metadata)
        let durations = probes.compactMap(\.durationSeconds)
        let duration = durations.count == probes.count ? durations.reduce(0, +) : nil
        let parts = inputs.count > 1
        let profile = Self.outputProfile(for: probes)

        let audioArguments: [String]
        if parts {
            let manifest = try await Self.renderParts(
                inputs, probes: probes, options: options, profile: profile,
                ffmpeg: ffmpeg, directory: directory, progress: progress
            )
            audioArguments = ["-f", "concat", "-safe", "1", "-i", manifest.path]
        } else {
            audioArguments = options[0] + ["-i", inputs[0].url.path]
        }

        let externalCover = try Self.validatedArtwork(artwork, in: directory)
        let embeddedCover = Self.coverInput(artwork: nil, inputs: inputs, probes: probes, options: options)
        let coverChoices = externalCover.map {
            [Self.coverInput(artwork: $0, inputs: inputs, probes: probes, options: options), embeddedCover]
        } ?? [embeddedCover]
        for (index, cover) in coverChoices.enumerated() {
            let tagsIndex = cover.arguments.isEmpty ? 1 : 2
            var args = audioArguments + cover.arguments + [
                "-f", "ffmetadata", "-i", tags.path,
                "-map", "0:a:0", "-map_metadata", String(tagsIndex),
                "-map_chapters", String(tagsIndex)
            ]
            args += parts ? ["-c:a", "copy"] : Self.codecOptions(for: inputs[0].url, profile: profile)
            if let stream = cover.stream {
                args += ["-map", stream, "-c:v", "copy", "-disposition:v", "attached_pic"]
            }
            args += ["-movflags", "+faststart", "-f", "ipod", staged.path]
            do {
                try await Self.encode(
                    ffmpeg, arguments: args, directory: directory, duration: duration,
                    progress: { value in
                        await progress(value.map { parts ? 0.6 + 0.4 * $0 : $0 })
                    }
                )
                break
            } catch MediaError.conversionFailed where index + 1 < coverChoices.count {
                if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
            }
        }
        let output = try await Self.probe(staged, options: [], ffprobe: ffprobe, directory: directory)
        guard output.audio != nil, output.durationSeconds != nil else { throw MediaError.conversionFailed }

        try Task.checkCancellation()
        let renameError = staged.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return EINVAL }
                return renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        if renameError == ENOTSUP {
            do {
                try manager.moveItem(at: staged, to: destination)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw MediaError.destinationExists
            }
        } else if renameError == EEXIST {
            throw MediaError.destinationExists
        } else if renameError != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
        }
        await progress(1)
    }

    private func executable(named name: String) throws -> URL {
        guard let url = toolDirectory?.appending(path: name),
              FileManager.default.isExecutableFile(atPath: url.path) else { throw MediaError.toolsMissing }
        return url
    }

    private static func audioFiles(at url: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isRegularFile == true && localFormats.contains(url.pathExtension.lowercased()) {
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
            guard localFormats.contains(file.pathExtension.lowercased()),
                  let attributes = try? file.resourceValues(forKeys: keys),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            files.append(file.standardizedFileURL)
        }
        return files
    }

    private static func workspace() throws -> URL {
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
        return LocalAudioFile(
            url: url, format: url.pathExtension.lowercased(),
            title: title ?? (fallback.isEmpty ? stem : fallback), author: artist, asin: asin,
            durationSeconds: inspection?.durationSeconds
        )
    }

    private static func decryptionOptions(for input: MediaInput, at index: Int, in directory: URL) throws -> [String] {
        let credentials = input.credentials
        switch input.url.pathExtension.lowercased() {
        case "aaxc":
            guard credentials.hasVoucher, let key = credentials.audibleKey, let iv = credentials.audibleIV else {
                throw MediaError.voucherRequired
            }
            let keyFile = directory.appending(path: "key-\(index)")
            let ivFile = directory.appending(path: "iv-\(index)")
            try Data(key.utf8).write(to: keyFile)
            try Data(iv.utf8).write(to: ivFile)
            return ["-/audible_key", keyFile.path, "-/audible_iv", ivFile.path]
        case "aax":
            guard credentials.hasActivationBytes, let activation = credentials.activationBytes else {
                throw MediaError.activationRequired
            }
            let activationFile = directory.appending(path: "activation-\(index)")
            try Data(activation.utf8).write(to: activationFile)
            return ["-/activation_bytes", activationFile.path]
        default:
            return []
        }
    }

    private static func probe(
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

    private static func validateVoucher(
        _ ffmpeg: URL, for url: URL, options: [String], directory: URL
    ) async throws {
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-xerror"] + options + [
            "-i", url.path, "-map", "0:a:0", "-frames:a", "3", "-f", "null", "-"
        ]
        let (status, _, _) = try await MediaProcess.run(ffmpeg, arguments: args, workingDirectory: directory)
        guard status == 0 else { throw MediaError.voucherRequired }
    }

    private static func outputProfile(for probes: [AudioProbe]) -> [String] {
        let streams = probes.compactMap(\.audio)
        if let first = streams.first, first.codecName == "aac",
           streams.allSatisfy({ $0.concatParameters == first.concatParameters }) {
            return ["-c:a", "copy"]
        }
        let channels = min(2, streams.compactMap(\.channels).max() ?? 1)
        let sampleRates = streams.compactMap { $0.sampleRate.flatMap(Int.init) }
        let largestRate = sampleRates.max() ?? 44_100
        let supportedRates = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000]
        let rate = supportedRates.first { $0 >= largestRate } ?? 96_000
        return ["-c:a", "aac", "-ar", String(rate), "-ac", String(channels), "-b:a", channels == 2 ? "128k" : "64k"]
    }

    private static func validatedArtwork(_ url: URL?, in directory: URL) throws -> URL? {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...25_000_000).contains(size),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8_192).contains(width), (1...8_192).contains(height) else { return nil }
        let identifier = type as String
        guard [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(identifier) else {
            return nil
        }
        let webP = identifier == UTType.webP.identifier
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: webP ? 4_096 : 64
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        let copy = directory.appending(path: identifier == UTType.jpeg.identifier ? "cover.jpg" : "cover.png")
        if webP {
            guard let destination = CGImageDestinationCreateWithURL(copy as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? copy : nil
        }
        try data.write(to: copy)
        return copy
    }

    private static func coverInput(
        artwork: URL?, inputs: [MediaInput], probes: [AudioProbe], options: [[String]]
    ) -> (arguments: [String], stream: String?) {
        if let artwork {
            return (["-i", artwork.path], "1:v:0")
        }
        if inputs.count == 1, let cover = probes[0].artwork {
            return ([], "0:\(cover.index)")
        }
        for (index, probe) in probes.enumerated() {
            if let cover = probe.artwork {
                return (options[index] + ["-i", inputs[index].url.path], "1:\(cover.index)")
            }
        }
        return ([], nil)
    }

    private static func codecOptions(for url: URL, profile: [String]) -> [String] {
        // Legacy AA packets can restart their timestamps at each chapter boundary.
        if url.pathExtension.lowercased() == "aa" && profile != ["-c:a", "copy"] {
            return ["-af", "asetpts=N/SR/TB"] + profile
        }
        return profile
    }

    private static func renderParts(
        _ inputs: [MediaInput], probes: [AudioProbe], options: [[String]], profile: [String],
        ffmpeg: URL, directory: URL, progress: @escaping MediaProcess.Progress
    ) async throws -> URL {
        var lines = ["ffconcat version 1.0"]
        for (index, input) in inputs.enumerated() {
            let filename = "part-\(index).m4a"
            let part = directory.appending(path: filename)
            let args = options[index] + [
                "-i", input.url.path, "-map", "0:a:0", "-map_metadata", "-1", "-map_chapters", "-1"
            ] + codecOptions(for: input.url, profile: profile) + ["-avoid_negative_ts", "make_zero", "-use_editlist", "0", "-f", "ipod", part.path]
            try await encode(
                ffmpeg, arguments: args, directory: directory, duration: probes[index].durationSeconds,
                progress: { value in
                    await progress(value.map { 0.6 * (Double(index) + $0) / Double(inputs.count) })
                }
            )
            lines.append("file '\(filename)'")
        }
        let url = directory.appending(path: "parts.ffconcat")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private static func encode(
        _ ffmpeg: URL, arguments: [String], directory: URL, duration: Double?, progress: @escaping MediaProcess.Progress
    ) async throws {
        let prefix = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-xerror", "-progress", "pipe:1"]
        let (status, _, _) = try await MediaProcess.run(
            ffmpeg, arguments: prefix + arguments, workingDirectory: directory,
            progress: progress, durationSeconds: duration
        )
        guard status == 0 else { throw MediaError.conversionFailed }
    }
}
