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

    var errorDescription: String? {
        switch self {
        case .unknownDuration: "DownAudible couldn’t determine the duration of the source audio."
        case .sourceChanged: "The source audio or its chapters have changed. Open Edit Book again to update your choices."
        case .emptySelection: "Keep at least one section to convert the book."
        case .unsupportedConversion: "Book edits require a single M4B file."
        }
    }
}
