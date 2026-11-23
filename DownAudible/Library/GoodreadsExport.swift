import Foundation

nonisolated struct GoodreadsExport: Identifiable, Sendable {
    struct Entry: Identifiable, Sendable {
        enum Identifier: Hashable, Sendable {
            case isbn(String), asin(String)

            var displayName: String {
                switch self {
                case .isbn(let isbn): "ISBN \(isbn)"
                case .asin(let asin): "ASIN \(asin)"
                }
            }
        }

        let id: Int
        let book: AudibleBook
        let identifier: Identifier?
        let duplicate: Bool

        var status: String {
            if duplicate { return "Duplicate edition" }
            return identifier == nil ? "No valid ISBN or ASIN" : "Ready"
        }

        var listening: LibraryFilters.Listening {
            if book.isFinished != true, let percent = book.percentComplete, percent > 100 { return .unknown }
            return .status(for: book)
        }

        var shelf: String {
            switch listening {
            case .finished: "read"
            case .started: "currently-reading"
            case .unstarted: "to-read"
            case .unknown: ""
            }
        }

        var isExportable: Bool { identifier != nil && !duplicate }
    }

    let id = UUID()
    let entries: [Entry]
    var readyCount: Int { entries.count(where: \.isExportable) }

    init(_ books: [AudibleBook]) {
        var identifiers: Set<Entry.Identifier> = []
        entries = books.enumerated().map { index, book in
            let isbn = Self.isbn(book.isbn).map(Entry.Identifier.isbn)
            let asin = Self.asin(book.asin).map(Entry.Identifier.asin)
            let match = isbn ?? asin
            let keys = [isbn, asin].compactMap { $0 }
            let duplicate = keys.contains(where: identifiers.contains)
            identifiers.formUnion(keys)
            return Entry(id: index, book: book, identifier: match, duplicate: duplicate)
        }
    }

    @concurrent func write(to url: URL) async throws {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withFullDate]
        let rows = entries.compactMap { entry -> [String]? in
            guard entry.isExportable, let identifier = entry.identifier else { return nil }
            let isbn: String
            let asin: String
            switch identifier {
            case .isbn(let value): (isbn, asin) = (value, "")
            case .asin(let value): (isbn, asin) = ("", value)
            }
            let value = entry.book.dateAdded ?? ""
            let added = value.count == 10 || value.dropFirst(10).first == "T" ? String(value.prefix(10)) : ""
            let date = dates.date(from: added)
            return [LibraryExportFormat.spreadsheetText(entry.book.title),
                    LibraryExportFormat.spreadsheetText(entry.book.authors.joined(separator: ", ")),
                    isbn, asin, entry.shelf,
                    date.map(dates.string(from:)) == added ? added.replacingOccurrences(of: "-", with: "/") : "", ""]
        }
        let data = LibraryExportFormat.csv.delimitedData(
            headers: ["Title", "Author", "ISBN", "ASIN", "Exclusive Shelf", "Date Added", "Date Read"], rows: rows
        )
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    private static func isbn(_ value: String?) -> String? {
        let digits = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().utf8.filter { $0 != 32 && $0 != 45 }
        let checksum: Int
        switch digits.count {
        case 10:
            guard digits.dropLast().allSatisfy(isDigit), let last = digits.last, isDigit(last) || last == 88 else { return nil }
            checksum = digits.dropLast().enumerated().reduce(last == 88 ? 10 : Int(last - 48)) { total, digit in
                total + (10 - digit.offset) * Int(digit.element - 48)
            } % 11
        case 13:
            guard digits.starts(with: [57, 55, 56]) || digits.starts(with: [57, 55, 57]),
                  digits.allSatisfy(isDigit) else { return nil }
            checksum = digits.enumerated().reduce(0) { total, digit in
                total + (digit.offset.isMultiple(of: 2) ? 1 : 3) * Int(digit.element - 48)
            } % 10
        default:
            return nil
        }
        return checksum == 0 ? String(decoding: digits, as: UTF8.self) : nil
    }

    private static func asin(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == 10,
              trimmed.utf8.allSatisfy({ isDigit($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return trimmed.uppercased()
    }

    private static func isDigit(_ value: UInt8) -> Bool { (48...57).contains(value) }
}
