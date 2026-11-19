import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension MediaTools {
    @concurrent func convert(
        _ inputs: [MediaInput],
        preferences: ConversionPreferences,
        metadata: MediaMetadata = .init(),
        artwork: URL? = nil,
        destinations: @escaping @Sendable ([ConversionOutput]) async throws -> [URL],
        progress: @escaping MediaProcess.Progress = { _ in }
    ) async throws -> [URL] {
        guard let firstInput = inputs.first else { throw MediaError.noInput }
        let preferences = preferences.outputRecipe
        let manager = FileManager.default
        let ffmpeg = try executable(named: "ffmpeg")
        let ffprobe = try executable(named: "ffprobe")
        let workspace = try Self.workspace()
        defer { try? manager.removeItem(at: workspace) }

        await progress(nil)
        let sources = try await Self.prepare(inputs, ffmpeg: ffmpeg, ffprobe: ffprobe, workspace: workspace)
        let probes = sources.map(\.probe)
        let tags = MediaTags.values(
            probes: probes, source: firstInput.url, metadata: metadata, format: preferences.format
        )
        let chapters = MediaTags.markers(probes: probes, supplied: metadata.chapters, title: tags["title"])
        let duration = Self.duration(of: probes)
        let clips = Self.clips(for: preferences.chapterMode, chapters: chapters, duration: duration)
        let encoding = try AudioEncoding(
            preferences: preferences, probes: probes, slicing: clips[0].range != nil,
            containsLegacyAudio: sources.contains(where: \.legacyClock)
        )
        let output = try await destinations(clips.map(\.output))
        let staged = try Self.stagedOutput(output, count: clips.count, format: preferences.format)
        defer { staged.forEach { try? manager.removeItem(at: $0.temporary) } }

        let audio = try await Self.prepareAudio(
            sources, encoding: encoding, format: preferences.format, slicing: clips[0].range != nil,
            ffmpeg: ffmpeg, duration: duration, workspace: workspace, progress: progress
        )
        let coverChoices = Self.coverInputs(
            artwork: artwork, sources: sources, audio: audio,
            requested: preferences.embedArtwork, workspace: workspace
        )
        var elapsed = 0.0
        for (index, pair) in zip(clips, staged).enumerated() {
            try Task.checkCancellation()
            let (clip, file) = pair
            let metadataFile = workspace.appending(path: "metadata-\(index).ffmetadata")
            try MediaTags.file(
                metadataFile, tags: preferences.preserveMetadata ? tags : [:],
                chapters: preferences.embedChapters ? chapters : [],
                output: clip.output, outputCount: clips.count
            )
            let seconds = clip.range.map { Double($0.count) / 1_000 } ?? duration.map { Double($0) / 1_000 }
            let start = elapsed
            try await Self.write(
                file.temporary, clip: clip, audio: audio, encoding: encoding, format: preferences.format,
                coverChoices: coverChoices, metadata: metadataFile, ffmpeg: ffmpeg, workspace: workspace,
                duration: seconds, progress: { fraction in
                    guard let fraction else { return }
                    let step = seconds ?? 1
                    let total = duration.map { Double($0) / 1_000 } ?? Double(clips.count)
                    let scale = 1 - audio.preparationShare
                    await progress(audio.preparationShare + scale * min(0.99, (start + step * fraction) / total))
                }
            )
            let result = try await Self.probe(file.temporary, options: [], ffprobe: ffprobe, directory: workspace)
            guard result.audio?.codecName == preferences.format.codecName, result.durationSeconds != nil else {
                throw MediaError.conversionFailed
            }
            elapsed += seconds ?? 1
        }

        try Self.publish(staged)
        await progress(1)
        return output
    }

    private struct PreparedSource {
        let url: URL
        let options: [String]
        let probe: AudioProbe

        var arguments: [String] { options + ["-i", url.path] }
        var legacyClock: Bool { url.pathExtension.lowercased() == "aa" }
    }

    private struct AudioSource: Sendable {
        let arguments: [String]
        let inputCount: Int
        let filter: String?
        let direct: Bool
        let legacyClock: Bool
        let preparationShare: Double

        var map: String { filter == nil ? "0:a:0" : "[book]" }
    }

    private struct CoverInput {
        var arguments: [String] = []
        var stream: String?
    }

    private struct Clip {
        let output: ConversionOutput
        let range: Range<Int64>?
    }

    private struct StagedOutput {
        let destination: URL
        let temporary: URL
    }

    private static func prepare(
        _ inputs: [MediaInput], ffmpeg: URL, ffprobe: URL, workspace: URL
    ) async throws -> [PreparedSource] {
        var sources: [PreparedSource] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let options = try decryptionOptions(for: input, at: index, in: workspace)
            let probe = try await probe(input.url, options: options, ffprobe: ffprobe, directory: workspace)
            if input.url.pathExtension.lowercased() == "aaxc" {
                try await validateVoucher(ffmpeg, for: input.url, options: options, directory: workspace)
            }
            sources.append(PreparedSource(url: input.url, options: options, probe: probe))
        }
        return sources
    }

    private static func duration(of probes: [AudioProbe]) -> Int64? {
        var total: Int64 = 0
        for probe in probes {
            guard let duration = probe.durationMilliseconds else { return nil }
            let sum = total.addingReportingOverflow(duration)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total > 0 ? total : nil
    }

    private static func clips(
        for mode: ConversionChapterMode, chapters: [MediaChapter], duration: Int64?
    ) -> [Clip] {
        let whole = Clip(output: ConversionOutput(chapterNumber: nil, chapterTitle: nil), range: nil)
        guard mode == .separate, let duration, duration > 0 else { return [whole] }
        var boundaries = chapters.filter { $0.startMilliseconds < duration }
            .map { ($0.startMilliseconds, $0.title) }
        guard let first = boundaries.first else { return [whole] }
        if first.0 > 0 {
            boundaries.insert((0, "Introduction"), at: 0)
        }
        return boundaries.indices.map { index in
            let (start, title) = boundaries[index]
            let next = index + 1
            let end = boundaries.indices.contains(next) ? boundaries[next].0 : duration
            return Clip(output: ConversionOutput(chapterNumber: next, chapterTitle: title), range: start..<end)
        }
    }

    private static func stagedOutput(
        _ destinations: [URL], count: Int, format: ConversionFormat
    ) throws -> [StagedOutput] {
        let keys = Set(destinations.map { $0.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() })
        guard destinations.count == count, keys.count == count, destinations.allSatisfy(\.isFileURL) else {
            throw MediaError.invalidDestinations
        }
        return try destinations.map { destination in
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw MediaError.destinationExists }
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return StagedOutput(
                destination: destination,
                temporary: directory.appending(path: ".\(UUID().uuidString).\(format.fileExtension)")
            )
        }
    }

    private static func publish(_ files: [StagedOutput]) throws {
        var published: [URL] = []
        do {
            for file in files {
                try Task.checkCancellation()
                try moveExclusively(file.temporary, to: file.destination)
                published.append(file.destination)
            }
        } catch {
            for url in published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func moveExclusively(_ source: URL, to destination: URL) throws {
        let renameError = source.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return EINVAL }
                return renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        if renameError == ENOTSUP {
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw MediaError.destinationExists
            }
        } else if renameError == EEXIST {
            throw MediaError.destinationExists
        } else if renameError != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
        }
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

    private static func validateVoucher(
        _ ffmpeg: URL, for url: URL, options: [String], directory: URL
    ) async throws {
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-xerror"] + options + [
            "-i", url.path, "-map", "0:a:0", "-frames:a", "3", "-f", "null", "-"
        ]
        let (status, _, _) = try await MediaProcess.run(ffmpeg, arguments: args, workingDirectory: directory)
        guard status == 0 else { throw MediaError.voucherRequired }
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

    private static func prepareAudio(
        _ sources: [PreparedSource],
        encoding: AudioEncoding,
        format: ConversionFormat,
        slicing: Bool,
        ffmpeg: URL,
        duration: Int64?,
        workspace: URL,
        progress: @escaping MediaProcess.Progress
    ) async throws -> AudioSource {
        let multiple = sources.count > 1
        let first = sources[0]
        if slicing && (multiple || first.legacyClock) {
            let assembly = assemble(sources, encoding: encoding)
            let continuous = workspace.appending(path: "continuous.flac")
            let share = 0.35
            let filter = audioFilter(for: assembly, encoding: encoding)
            try await encode(
                ffmpeg, arguments: assembly.arguments + filter + [
                    "-map", assembly.map, "-map_metadata", "-1", "-map_chapters", "-1",
                    "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24",
                    "-ar", String(encoding.sampleRate), "-ac", String(encoding.channels),
                    "-f", "flac", continuous.path
                ], directory: workspace, duration: duration.map { Double($0) / 1_000 },
                progress: { await progress($0.map { share * $0 }) }
            )
            return AudioSource(
                arguments: ["-i", continuous.path], inputCount: 1, filter: nil,
                direct: false, legacyClock: false, preparationShare: share
            )
        }
        if multiple && encoding.copiesAudio {
            let share = 0.6
            let manifest = try await renderParts(
                sources, format: format, ffmpeg: ffmpeg, directory: workspace,
                progress: { await progress($0.map { share * $0 }) }
            )
            return AudioSource(
                arguments: ["-f", "concat", "-safe", "1", "-i", manifest.path], inputCount: 1,
                filter: nil, direct: false, legacyClock: false, preparationShare: share
            )
        }
        return assemble(sources, encoding: encoding)
    }

    private static func assemble(_ sources: [PreparedSource], encoding: AudioEncoding) -> AudioSource {
        guard sources.count > 1 else {
            return AudioSource(
                arguments: sources[0].arguments, inputCount: 1, filter: nil, direct: true,
                legacyClock: sources[0].legacyClock, preparationShare: 0
            )
        }
        let rate = encoding.sampleRate
        let channels = encoding.channels
        let normalized = sources.indices.map { index in
            "[\(index):a:0]aformat=sample_rates=\(rate):channel_layouts=\(channels)c,asetpts=N/SR/TB[a\(index)]"
        }
        let pads = sources.indices.map { "[a\($0)]" }.joined()
        let graph = (normalized + ["\(pads)concat=n=\(sources.count):v=0:a=1[book]"]).joined(separator: ";")
        return AudioSource(
            arguments: sources.flatMap(\.arguments), inputCount: sources.count,
            filter: graph, direct: false, legacyClock: false, preparationShare: 0
        )
    }

    private static func audioFilter(for audio: AudioSource, encoding: AudioEncoding) -> [String] {
        if let filter = audio.filter { return ["-filter_complex", filter] }
        if audio.legacyClock && !encoding.copiesAudio { return ["-af", "asetpts=N/SR/TB"] }
        return []
    }

    private static func coverInputs(
        artwork: URL?, sources: [PreparedSource], audio: AudioSource, requested: Bool, workspace: URL
    ) -> [CoverInput] {
        guard requested else { return [CoverInput()] }
        var choices: [CoverInput] = []
        if let artwork = try? validatedArtwork(artwork, in: workspace) {
            choices.append(CoverInput(arguments: ["-i", artwork.path], stream: "\(audio.inputCount):v:0"))
        }
        for source in sources {
            guard let cover = source.probe.artwork else { continue }
            if audio.direct {
                choices.append(CoverInput(stream: "0:\(cover.index)"))
            } else {
                choices.append(CoverInput(arguments: source.arguments, stream: "\(audio.inputCount):\(cover.index)"))
            }
            break
        }
        choices.append(CoverInput())
        return choices
    }

    private static func write(
        _ destination: URL, clip: Clip, audio: AudioSource, encoding: AudioEncoding,
        format: ConversionFormat, coverChoices: [CoverInput], metadata: URL, ffmpeg: URL, workspace: URL,
        duration: Double?, progress: @escaping MediaProcess.Progress
    ) async throws {
        for (index, cover) in coverChoices.enumerated() {
            let metadataIndex = audio.inputCount + (cover.arguments.isEmpty ? 0 : 1)
            var args: [String] = []
            if let clip = clip.range, clip.lowerBound > 0 {
                args += ["-ss", String(Double(clip.lowerBound) / 1_000)]
            }
            args += audio.arguments + cover.arguments + ["-f", "ffmetadata", "-i", metadata.path]
            args += audioFilter(for: audio, encoding: encoding) + [
                "-map", audio.map, "-map_metadata", String(metadataIndex), "-map_chapters", String(metadataIndex)
            ]
            args += encoding.arguments
            if let clip = clip.range {
                args += ["-t", String(Double(clip.count) / 1_000)]
            }
            if let stream = cover.stream {
                args += ["-map", stream, "-c:v", "copy", "-disposition:v", "attached_pic"]
                if format == .mp3 {
                    args += ["-metadata:s:v", "comment=Cover (front)"]
                }
            }
            // ID3v2.3 keeps long chapter titles and chapter tables readable by more players.
            args += format == .mp3 ? ["-id3v2_version", "3"] : ["-movflags", "+faststart"]
            args += ["-f", format.muxer, destination.path]
            do {
                try await encode(ffmpeg, arguments: args, directory: workspace, duration: duration, progress: progress)
                return
            } catch MediaError.conversionFailed where index + 1 < coverChoices.count {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
            }
        }
    }

    private static func renderParts(
        _ sources: [PreparedSource], format: ConversionFormat,
        ffmpeg: URL, directory: URL, progress: @escaping MediaProcess.Progress
    ) async throws -> URL {
        var lines = ["ffconcat version 1.0"]
        for (index, source) in sources.enumerated() {
            let filename = "part-\(index).\(format == .mp3 ? "mp3" : "m4a")"
            let part = directory.appending(path: filename)
            var args = source.arguments + [
                "-map", "0:a:0", "-map_metadata", "-1", "-map_chapters", "-1",
                "-c:a", "copy", "-avoid_negative_ts", "make_zero"
            ]
            if format != .mp3 { args += ["-use_editlist", "0"] }
            args += ["-f", format.muxer, part.path]
            try await encode(
                ffmpeg, arguments: args, directory: directory, duration: source.probe.durationSeconds,
                progress: { value in
                    await progress(value.map { (Double(index) + $0) / Double(sources.count) })
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
