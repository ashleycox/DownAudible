import Foundation

enum BookPreviewPosition: Equatable, Sendable {
    case start, end
}

struct BookEditSection: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let sourceIndex: Int
    let title: String
    let range: Range<Int64>
    fileprivate let chapterIndex: Int?

    var durationMilliseconds: Int64 { range.upperBound - range.lowerBound }

    func previewRange(at position: BookPreviewPosition) -> Range<Int64> {
        let duration = min(durationMilliseconds, 10_000)
        return switch position {
        case .start: range.lowerBound..<(range.lowerBound + duration)
        case .end: (range.upperBound - duration)..<range.upperBound
        }
    }

    static func partPreview(_ sections: [Self]) -> Self? {
        guard let first = sections.first, let last = sections.last, first.sourceIndex == last.sourceIndex else { return nil }
        return Self(
            id: first.id, sourceIndex: first.sourceIndex, title: "Part \(first.sourceIndex + 1)",
            range: first.range.lowerBound..<last.range.upperBound, chapterIndex: nil
        )
    }
}

struct BookEditingLayout: Codable, Hashable, Sendable {
    let sections: [BookEditSection]
    let sourceCount: Int

    init(probes: [AudioProbe], chapters: [MediaChapter]) throws {
        let markers = chapters.indices.map { index in
            let chapter = chapters[index]
            let end = chapter.startMilliseconds + chapter.durationMilliseconds
            let nextStart = chapters.indices.contains(index + 1) ? chapters[index + 1].startMilliseconds : end
            return chapter.startMilliseconds..<min(end, nextStart)
        }
        var sections: [BookEditSection] = []
        var offset: Int64 = 0
        var markerIndex = 0
        for (sourceIndex, probe) in probes.enumerated() {
            guard let duration = probe.durationMilliseconds, duration > 0 else { throw BookEditError.unknownDuration }
            let (sourceEnd, overflow) = offset.addingReportingOverflow(duration)
            guard !overflow else { throw BookEditError.unknownDuration }
            var position = offset
            while position < sourceEnd {
                while markers.indices.contains(markerIndex), markers[markerIndex].upperBound <= position {
                    markerIndex += 1
                }
                let next = markers.indices.contains(markerIndex) ? markers[markerIndex] : nil
                let chapterIndex: Int?
                let end: Int64
                let title: String
                if let next, next.contains(position) {
                    chapterIndex = markerIndex
                    end = min(next.upperBound, sourceEnd)
                    title = chapters[markerIndex].title
                } else {
                    chapterIndex = nil
                    end = min(next?.lowerBound ?? sourceEnd, sourceEnd)
                    title = if position == offset && end == sourceEnd {
                        "Part \(sourceIndex + 1)"
                    } else if position == offset {
                        "Opening audio"
                    } else if end == sourceEnd {
                        "Closing audio"
                    } else {
                        "Audio between chapters"
                    }
                }
                sections.append(BookEditSection(
                    id: sections.count, sourceIndex: sourceIndex, title: title,
                    range: (position - offset)..<(end - offset), chapterIndex: chapterIndex
                ))
                position = end
            }
            offset = sourceEnd
        }
        self.sections = sections
        sourceCount = probes.count
    }
}

struct BookEdit: Codable, Hashable, Sendable {
    let layout: BookEditingLayout
    let excludedSections: Set<Int>
    var chapterRepair: ChapterRepairSelection? = nil
}

nonisolated struct ChapterRepair: Decodable, Sendable {
    let asin: String?
    let runtimeMilliseconds: Int64
    let chapters: [MediaChapter]
    let separatedChapters: [MediaChapter]?

    func selection(separatingAnnouncements: Bool) -> ChapterRepairSelection {
        ChapterRepairSelection(
            asin: asin, runtimeMilliseconds: runtimeMilliseconds,
            chapters: (separatingAnnouncements ? separatedChapters : nil) ?? chapters
        )
    }
}

nonisolated struct ChapterRepairSelection: Codable, Hashable, Sendable {
    let asin: String?
    let runtimeMilliseconds: Int64
    let chapters: [MediaChapter]

    func markers(for probes: [AudioProbe]) throws -> [MediaChapter] {
        guard !probes.isEmpty, !probes.contains(where: { MediaTags.isEditedBook($0.formatTags) }) else {
            throw BookEditError.chapterRepairNeedsCompleteAudio
        }
        if let asin, probes.contains(where: { probe in
            guard let tag = MediaTools.taggedIdentifier(in: probe.formatTags) else { return false }
            return asin.caseInsensitiveCompare(tag) != .orderedSame
        }) {
            throw BookEditError.chapterRepairWrongEdition
        }
        guard !chapters.isEmpty, (1...2_592_000_000).contains(runtimeMilliseconds) else {
            throw BookEditError.chapterRepairMetadata
        }
        var duration: Int64 = 0
        for probe in probes {
            guard let length = probe.durationMilliseconds, (1...2_592_000_000).contains(length),
                  duration <= 2_592_000_000 - length else { throw BookEditError.unknownDuration }
            duration += length
        }
        // Allow for encoder padding and rounding without applying a map to shortened audio.
        let tolerance = min(2_000, max(250, runtimeMilliseconds / 1_000))
        guard abs(runtimeMilliseconds - duration) <= tolerance else { throw BookEditError.chapterRepairDuration }

        var priorEnd: Int64 = 0
        return try chapters.map { chapter in
            let start = chapter.startMilliseconds
            let (end, overflow) = start.addingReportingOverflow(chapter.durationMilliseconds)
            guard !overflow, start >= priorEnd, start < min(end, duration), end <= runtimeMilliseconds,
                  !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BookEditError.chapterRepairMetadata
            }
            priorEnd = end
            let sourceEnd = end == runtimeMilliseconds ? duration : min(end, duration)
            return MediaChapter(
                startMilliseconds: start, durationMilliseconds: sourceEnd - start, title: chapter.title
            )
        }
    }
}

struct BookEditSelection: Sendable {
    struct Segment: Sendable {
        let sourceIndex: Int
        var range: Range<Int64>
    }

    let segments: [Segment]
    let chapters: [MediaChapter]
    let durationMilliseconds: Int64

    init(edit: BookEdit, layout: BookEditingLayout) throws {
        guard edit.layout == layout, edit.excludedSections.isSubset(of: layout.sections.map(\.id)) else {
            throw BookEditError.sourceChanged
        }
        var segments: [Segment] = []
        var chapters: [MediaChapter] = []
        var offset: Int64 = 0
        var previousChapter: Int?
        for section in layout.sections where !edit.excludedSections.contains(section.id) {
            if let previous = segments.last, previous.sourceIndex == section.sourceIndex,
               previous.range.upperBound == section.range.lowerBound {
                segments[segments.count - 1].range = previous.range.lowerBound..<section.range.upperBound
            } else {
                segments.append(Segment(sourceIndex: section.sourceIndex, range: section.range))
            }
            if let chapterIndex = section.chapterIndex {
                if previousChapter == chapterIndex {
                    chapters[chapters.count - 1].durationMilliseconds += section.durationMilliseconds
                } else {
                    chapters.append(MediaChapter(
                        startMilliseconds: offset, durationMilliseconds: section.durationMilliseconds, title: section.title
                    ))
                }
            }
            previousChapter = section.chapterIndex
            offset += section.durationMilliseconds
        }
        guard !segments.isEmpty else { throw BookEditError.emptySelection }
        self.segments = segments
        self.chapters = chapters
        durationMilliseconds = offset
    }
}

enum BookEditError: LocalizedError {
    case unknownDuration
    case sourceChanged
    case emptySelection
    case unsupportedConversion
    case chapterRepairDuration
    case chapterRepairNeedsCompleteAudio
    case chapterRepairWrongEdition
    case chapterRepairMetadata

    var errorDescription: String? {
        switch self {
        case .unknownDuration: "DownAudible couldn’t determine the duration of the source audio."
        case .sourceChanged: "The source audio or its chapters have changed. Open Edit Book again to update your choices."
        case .emptySelection: "Keep at least one section to convert the book."
        case .unsupportedConversion: "Book edits require a single M4B file."
        case .chapterRepairDuration: "The chapter runtime does not match this audio. Choose chapter data for this edition and make sure every part is present."
        case .chapterRepairNeedsCompleteAudio: "Chapter repair needs the complete audiobook. Open the original or an unabridged copy before repairing it."
        case .chapterRepairWrongEdition: "The chapter data belongs to a different Audible edition."
        case .chapterRepairMetadata: "The chapter data has invalid or overlapping time ranges."
        }
    }
}
