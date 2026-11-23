import Foundation
import UniformTypeIdentifiers

enum LibraryExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case csv
    case tsv
    case xlsx

    var id: String { rawValue }

    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .xlsx: UTType(filenameExtension: "xlsx") ?? .spreadsheet
        }
    }

    @concurrent func write(_ books: [AudibleBook], to path: URL, wishlist: Bool = false) async throws {
        let contents: Data
        switch self {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            contents = try encoder.encode(books)
        case .csv, .tsv, .xlsx:
            let sharedColumns = [
                "ASIN", "Title", "Subtitle", "Authors", "Narrators", "Series", "Series Number",
                "Publisher", "Language", "Genres", "Release Date", "Date Added",
                "Duration (Seconds)", "Rating", "Rating Count", "Finished", "Percent Complete",
                "Cover", "Description"
            ]
            let header = wishlist ? sharedColumns : sharedColumns + ["Purchased", "PDF Available", "Download Available"]
            let rows = books.map { book -> [String] in
                let fields = [
                    book.asin, book.title, book.subtitle ?? "", book.authors.joined(separator: ", "),
                    book.narrators.joined(separator: ", "), book.series ?? "", book.seriesSequence ?? "",
                    book.publisher ?? "", book.language ?? "", book.genres?.joined(separator: ", ") ?? "",
                    book.releaseDate ?? "", book.dateAdded ?? "",
                    book.durationSeconds.map { String($0) } ?? "", book.rating.map { String($0) } ?? "",
                    book.ratingCount.map { String($0) } ?? "", book.isFinished.map { String($0) } ?? "",
                    book.percentComplete.map { String($0) } ?? "", book.coverURL?.absoluteString ?? "",
                    book.description ?? ""
                ]
                return wishlist ? fields : fields + [
                    book.purchaseDate ?? "", String(book.hasPDF), String(book.isDownloadable)
                ]
            }
            if self == .xlsx {
                contents = try SpreadsheetExport.data(headers: header, rows: rows, title: wishlist ? "Wish List" : "Library")
            } else {
                contents = delimitedData(headers: header, rows: rows)
            }
        }
        try Task.checkCancellation()
        try contents.write(to: path, options: .atomic)
    }

    func delimitedData(headers: [String], rows: [[String]]) -> Data {
        let separator = self == .csv ? "," : "\t"
        let text = ([headers] + rows).map { row in
            row.map { Self.field($0, separator: separator) }.joined(separator: separator)
        }.joined(separator: "\r\n")
        return Data((text + "\r\n").utf8)
    }

    static func spreadsheetText(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        if value.hasPrefix("\t") || value.hasPrefix("\n") || value.hasPrefix("\r") ||
            first.map({ "=+-@".contains($0) }) == true { return "'" + value }
        return value
    }

    private static func field(_ value: String, separator: String) -> String {
        if value.contains(separator) || value.contains("\"") || value.rangeOfCharacter(from: .newlines) != nil {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
