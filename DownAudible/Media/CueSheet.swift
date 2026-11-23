import Foundation

enum CueSheet {
    static func supports(_ source: URL) -> Bool {
        source.isFileURL && ["m4b", "m4a", "mp3"].contains(source.pathExtension.lowercased())
    }

    @concurrent static func write(for source: URL, tools: MediaTools = MediaTools()) async throws -> URL {
        guard supports(source) else { throw CueError.unsupportedFile }
        guard let revision = FileRevision(source) else { throw MediaError.sourceMissing }
        let workspace = try MediaTools.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let probe = try await MediaTools.probe(source, options: [], ffprobe: tools.executable(named: "ffprobe"), directory: workspace)
        let contents = try data(for: source, probe: probe)
        let directory = source.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try contents.write(to: temporary, options: .withoutOverwriting)
        for number in 1...10_000 {
            try Task.checkCancellation()
            guard FileRevision(source) == revision else { throw CueError.sourceChanged }
            let suffix = number == 1 ? "" : " (\(number))"
            let stem = ArchiveLayout.filename(source.lastPathComponent, maxBytes: 251 - suffix.utf8.count)
            let destination = directory.appending(path: "\(stem)\(suffix).cue")
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CueError.unusedName
    }

    static func data(for source: URL, probe: AudioProbe) throws -> Data {
        guard supports(source),
              source.lastPathComponent.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\\\r\n")) == nil else {
            throw CueError.unsupportedFile
        }
        guard !probe.chapters.isEmpty else { throw CueError.noChapters }
        guard probe.chapters.count <= 99 else { throw CueError.tooManyChapters }
        guard let duration = [probe.audio?.duration, probe.format.duration].compactMap(seconds).first(where: { $0 > 0 }) else {
            throw CueError.duration
        }
        let tags = probe.formatTags
        var lines = [("TITLE", tags["title"]), ("PERFORMER", tags["artist"] ?? tags["author"])].compactMap { tag, value in
            let text = cueText(value)
            return text.isEmpty ? nil : "\(tag) \"\(text)\""
        }
        let fileType = source.pathExtension.lowercased() == "mp3" ? "MP3" : "WAVE"
        lines.append("FILE \"\(source.lastPathComponent)\" \(fileType)")
        var previous: Int64 = -1
        for (index, chapter) in probe.chapters.enumerated() {
            guard let start = seconds(chapter.startTime), start < duration else { throw CueError.chapterStart }
            var decimalFrames = start * 75
            var rounded = Decimal.zero
            NSDecimalRound(&rounded, &decimalFrames, 0, .plain)
            let frames = NSDecimalNumber(decimal: rounded).int64Value
            guard rounded == Decimal(frames), frames > previous, rounded < duration * 75 else { throw CueError.cueIndex }
            previous = frames
            let minutes = frames / 4_500
            let rest = frames % 4_500
            let number = index + 1
            let text = cueText(chapter.tags?["title"])
            let title = text.isEmpty ? "Chapter \(number)" : text
            let timestamp = "\(twoDigits(minutes)):\(twoDigits(rest / 75)):\(twoDigits(rest % 75))"
            lines += ["  TRACK \(twoDigits(Int64(number))) AUDIO", "    TITLE \"\(title)\"", "    INDEX 01 \(timestamp)"]
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func seconds(_ text: String?) -> Decimal? {
        guard let text, let scalar = Double(text), scalar.isFinite, scalar >= 0,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return amount
    }

    private static func cueText(_ title: String?) -> String {
        (title ?? "").replacingOccurrences(of: "\"", with: "”").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func twoDigits(_ number: Int64) -> String {
        number < 10 ? "0\(number)" : String(number)
    }

    private enum CueError: LocalizedError {
        case unsupportedFile, sourceChanged, unusedName, noChapters, tooManyChapters, duration, chapterStart, cueIndex

        var errorDescription: String? {
            switch self {
            case .unsupportedFile: "Choose an M4B, M4A, or MP3 file with a name that can be used in a CUE sheet."
            case .sourceChanged: "The source audio changed while DownAudible was reading it. Try exporting again."
            case .unusedName: "DownAudible could not save the CUE sheet to an unused filename."
            case .noChapters: "This audio file has no embedded chapter markers."
            case .tooManyChapters: "A CUE sheet can contain at most 99 chapters."
            case .duration: "The audio file has no usable duration for a CUE sheet."
            case .chapterStart: "A chapter starts outside the audio timeline."
            case .cueIndex: "The chapter starts cannot be represented as distinct CUE indexes."
            }
        }
    }
}
