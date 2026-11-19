import Foundation
import UniformTypeIdentifiers

enum LibraryExportFormat: String, Sendable {
    case json
    case csv
    case tsv

    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        }
    }

    @concurrent func write(_ books: [AudibleBook], to path: URL) async throws {
        let contents: Data
        switch self {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            contents = try encoder.encode(books)
        case .csv, .tsv:
            let header = [
                "ASIN", "Title", "Subtitle", "Authors", "Narrators", "Series", "Series Number",
                "Publisher", "Language", "Genres", "Release Date", "Purchased", "Added to Library",
                "Duration (Seconds)", "Cover", "PDF Available", "Download Available", "Description"
            ]
            let rows = books.map { book -> [String] in
                [
                    book.asin, book.title, book.subtitle ?? "", book.authors.joined(separator: ", "),
                    book.narrators.joined(separator: ", "), book.series ?? "", book.seriesSequence ?? "",
                    book.publisher ?? "", book.language ?? "", book.genres?.joined(separator: ", ") ?? "",
                    book.releaseDate ?? "", book.purchaseDate ?? "", book.dateAdded ?? "",
                    book.durationSeconds.map(String.init) ?? "", book.coverURL?.absoluteString ?? "",
                    String(book.hasPDF), String(book.isDownloadable), book.description ?? ""
                ]
            }
            let separator = self == .csv ? "," : "\t"
            let text = ([header] + rows).map { row in
                row.map { Self.field($0, separator: separator) }.joined(separator: separator)
            }.joined(separator: "\r\n")
            contents = Data((text + "\r\n").utf8)
        }
        try Task.checkCancellation()
        try contents.write(to: path, options: .atomic)
    }

    private static func field(_ value: String, separator: String) -> String {
        if value.contains(separator) || value.contains("\"") || value.contains("\r") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
