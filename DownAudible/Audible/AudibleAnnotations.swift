import Foundation

nonisolated struct AudibleAnnotationReport: Decodable, Sendable {
    let entries: [AudibleAnnotation]
}

nonisolated struct AudibleAnnotation: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case bookmark, note

        var label: String { self == .bookmark ? "Bookmark" : "Note" }
    }

    enum ExportFormat: String, CaseIterable, Sendable {
        case csv, markdown

        var label: String { self == .csv ? "CSV" : "Markdown" }
        var fileExtension: String { self == .csv ? "csv" : "md" }
    }

    let kind: Kind
    let positionMilliseconds: Int64?
    let text: String

    var timestamp: String {
        guard let milliseconds = positionMilliseconds, milliseconds >= 0 else { return "" }
        let seconds = milliseconds / 1_000
        return "\(seconds / 3_600):" + String(format: "%02d:%02d", Int(seconds / 60 % 60), Int(seconds % 60))
    }

    func matches(_ search: String) -> Bool {
        let fields = [kind.label, timestamp, text].joined(separator: " ")
        return search.split(whereSeparator: \.isWhitespace).allSatisfy { fields.localizedStandardContains(String($0)) }
    }

    @concurrent static func export(_ entries: [Self], book: AudibleBook, as format: ExportFormat, to url: URL) async throws {
        let data: Data
        switch format {
        case .csv:
            data = LibraryExportFormat.csv.delimitedData(headers: ["Type", "Position", "Text"], rows: entries.map {
                [$0.kind.label, $0.timestamp, LibraryExportFormat.spreadsheetText($0.text)]
            })
        case .markdown:
            let title = book.title.split(whereSeparator: \.isNewline).joined(separator: " ")
            var lines = ["# Audible annotations", "", "    \(title)", "    ASIN \(book.asin)"]
            for entry in entries {
                let position = entry.timestamp.isEmpty ? "Unknown position" : entry.timestamp
                lines += ["", "## \(entry.kind.label) · \(position)"]
                if !entry.text.isEmpty {
                    let note = entry.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    lines += [""] + note.map { "    \($0)" }
                }
            }
            lines.append("")
            data = Data(lines.joined(separator: "\n").utf8)
        }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
