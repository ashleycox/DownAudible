import Foundation

enum MediaTags {
    private static let nativeKeys: Set<String> = [
        "title", "artist", "album_artist", "composer", "album", "date", "encoding_tool",
        "comment", "genre", "copyright", "grouping", "lyrics", "description", "synopsis",
        "show", "episode_id", "network", "keywords", "episode_sort", "season_number",
        "media_type", "hd_video", "gapless_playback", "compilation", "track", "disc",
        "tempo", "location", "creation_time"
    ]
    private static let containerKeys: Set<String> = ["major_brand", "minor_version", "compatible_brands"]

    static func file(
        _ url: URL,
        tags: [String: String],
        chapters: [MediaChapter],
        output: ConversionOutput,
        outputCount: Int
    ) throws {
        var tags = tags
        if !tags.isEmpty, let number = output.chapterNumber, let title = output.chapterTitle {
            tags["title"] = title
            tags["track"] = "\(number)/\(outputCount)"
        }
        var fields = [";FFMETADATA1"]
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            fields.append("\(escaped(key))=\(escaped(value))")
        }
        for chapter in chapters {
            let end = chapter.startMilliseconds + chapter.durationMilliseconds
            fields.append("[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(chapter.startMilliseconds)\nEND=\(end)")
            fields.append("title=\(escaped(chapter.title))")
        }
        try Data((fields.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    static func values(
        probes: [AudioProbe], source: URL, metadata: MediaMetadata, format: ConversionFormat
    ) -> [String: String] {
        var tags: [String: String] = [:]
        let customPrefix = format == .mp3 ? "" : "com.apple.iTunes:"
        for probe in probes {
            for (name, value) in (probe.format.tags ?? [:]) {
                let lower = name.lowercased()
                guard !containerKeys.contains(lower), !value.isEmpty else { continue }
                let key = nativeKeys.contains(lower) ? lower : customPrefix + name
                if tags[key] == nil { tags[key] = value }
            }
        }

        let sourceTags = probes[0].formatTags
        if let title = metadata.title, !title.isEmpty {
            tags["title"] = title
        } else if tags["title"] == nil {
            tags["title"] = sourceTags["parent_title"] ?? source.deletingPathExtension().lastPathComponent
        }
        tags["album"] = tags["album"] ?? tags["title"]
        if !metadata.authors.isEmpty {
            let authors = metadata.authors.joined(separator: ", ")
            tags["artist"] = authors
            tags["album_artist"] = authors
        } else {
            tags["artist"] = tags["artist"] ?? sourceTags["author"]
            tags["album_artist"] = tags["album_artist"] ?? tags["artist"]
        }
        if !metadata.narrators.isEmpty {
            let narrators = metadata.narrators.joined(separator: ", ")
            tags["composer"] = tags["composer"] ?? narrators
            tags[customPrefix + "NARRATOR"] = narrators
        }
        if let description = metadata.description, !description.isEmpty {
            tags["description"] = description
            tags["synopsis"] = description
        }
        tags["date"] = metadata.releaseDate ?? tags["date"] ?? sourceTags["pubdate"]
        tags["genre"] = tags["genre"] ?? (metadata.genres.isEmpty ? "Audiobook" : metadata.genres.joined(separator: ", "))
        if format == .m4b {
            tags["media_type"] = "2"
        } else {
            tags["media_type"] = nil
        }

        let libraryTags: [String: String?] = [
            "SUBTITLE": metadata.subtitle,
            "PUBLISHER": metadata.publisher,
            "ASIN": metadata.asin,
            "SERIES": metadata.series,
            "SERIES-PART": metadata.seriesSequence,
            "LANGUAGE": metadata.language,
            "GENRES": metadata.genres.isEmpty ? nil : metadata.genres.joined(separator: ", ")
        ]
        for (name, value) in libraryTags {
            if let value, !value.isEmpty {
                tags[customPrefix + name] = value
            }
        }
        return tags
    }

    static func markers(probes: [AudioProbe], supplied: [MediaChapter], title: String?) -> [MediaChapter] {
        var embedded: [MediaChapter] = []
        var offset: Int64 = 0
        var hasKnownDuration = true
        for (index, probe) in probes.enumerated() {
            let audioDuration = probe.durationMilliseconds
            let chapters = normalized(probe.chapterMarkers(numberingFrom: embedded.count + 1), through: audioDuration)
            let duration = audioDuration ?? chapters.last.map {
                $0.startMilliseconds + $0.durationMilliseconds
            }
            if chapters.isEmpty, let duration, duration > 0 {
                embedded.append(MediaChapter(
                    startMilliseconds: offset,
                    durationMilliseconds: duration,
                    title: probes.count > 1 ? "Part \(index + 1)" : (title ?? "Audiobook")
                ))
            } else {
                for var chapter in chapters {
                    let start = chapter.startMilliseconds.addingReportingOverflow(offset)
                    guard !start.overflow else { continue }
                    chapter.startMilliseconds = start.partialValue
                    embedded.append(chapter)
                }
            }
            guard let duration else {
                hasKnownDuration = false
                break
            }
            let end = offset.addingReportingOverflow(duration)
            guard !end.overflow else {
                hasKnownDuration = false
                break
            }
            offset = end.partialValue
        }

        let suppliedMarkers = normalized(supplied)
        let suppliedEnd = suppliedMarkers.last.map { $0.startMilliseconds + $0.durationMilliseconds }
        let supplied = normalized(suppliedMarkers, through: hasKnownDuration ? offset : nil)
        let sourceChaptersAreNamed = probes.allSatisfy { probe in
            !probe.chapters.isEmpty && probe.chapters.allSatisfy { chapter in
                guard let title = chapter.tags?["title"] else { return false }
                return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        if let end = suppliedEnd,
           !hasKnownDuration || abs(Double(end) - Double(offset)) <= 15_000,
           supplied.count > embedded.count || (!sourceChaptersAreNamed && supplied.count >= embedded.count) {
            return supplied
        }
        return normalized(embedded)
    }

    private static func normalized(_ markers: [MediaChapter], through duration: Int64? = nil) -> [MediaChapter] {
        var result: [MediaChapter] = []
        for var marker in markers.sorted(by: { $0.startMilliseconds < $1.startMilliseconds }) {
            guard marker.startMilliseconds >= 0, marker.durationMilliseconds > 0,
                  !marker.startMilliseconds.addingReportingOverflow(marker.durationMilliseconds).overflow,
                  result.last?.startMilliseconds != marker.startMilliseconds else { continue }
            if let duration {
                guard marker.startMilliseconds < duration else { continue }
                marker.durationMilliseconds = min(marker.durationMilliseconds, duration - marker.startMilliseconds)
            }
            result.append(marker)
        }
        return result
    }

    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value.replacingOccurrences(of: "\r\n", with: "\n") {
            if character == "\0" { continue }
            if character == "\\" || character == "=" || character == ";" || character == "#" || character == "\n" {
                result.append("\\")
            }
            result.append(character == "\r" ? " " : character)
        }
        return result
    }
}
