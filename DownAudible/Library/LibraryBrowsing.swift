import Foundation

struct LibrarySort: Codable, Hashable, Sendable {
    var field: LibrarySortField
    var direction: LibrarySortDirection

    private enum CodingKeys: CodingKey { case field, direction }

    init(field: LibrarySortField = .title, direction: LibrarySortDirection = .ascending) {
        self.field = field
        self.direction = direction
    }

    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(
            field: (try? values?.decode(LibrarySortField.self, forKey: .field)) ?? .title,
            direction: (try? values?.decode(LibrarySortDirection.self, forKey: .direction)) ?? .ascending
        )
    }
}

enum LibrarySortField: String, Codable, Sendable, CaseIterable, Identifiable {
    case title, author, narrator, series, purchaseDate, releaseYear, duration, downloadStatus

    var id: Self { self }

    var displayName: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .narrator: "Narrator"
        case .series: "Series"
        case .purchaseDate: "Purchase Date"
        case .releaseYear: "Release Year"
        case .duration: "Length"
        case .downloadStatus: "Download Status"
        }
    }

    func orderName(_ direction: LibrarySortDirection) -> String {
        let ascending = direction == .ascending
        switch self {
        case .purchaseDate, .releaseYear: return ascending ? "Oldest First" : "Newest First"
        case .duration: return ascending ? "Shortest First" : "Longest First"
        default: return ascending ? "A–Z" : "Z–A"
        }
    }

    var column: (KeyPath<LibraryRow, String> & Sendable)? {
        switch self {
        case .title: \LibraryRow.title
        case .author: \LibraryRow.authors
        case .narrator: \LibraryRow.narrators
        case .downloadStatus: \LibraryRow.statusLabel
        default: nil
        }
    }

    func sorted(_ rows: [LibraryRow], direction: LibrarySortDirection) -> [LibraryRow] {
        switch self {
        case .title:
            ordered(rows, direction: direction, key: { $0.title }, compare: textOrder)
        case .author:
            ordered(rows, direction: direction, key: { $0.book.authors.first }, compare: textOrder)
        case .narrator:
            ordered(rows, direction: direction, key: { $0.book.narrators.first }, compare: textOrder)
        case .series:
            ordered(rows, direction: direction, key: { $0.book.series }, compare: textOrder)
        case .purchaseDate:
            ordered(rows, direction: direction, key: { Self.purchaseDate($0.book.purchaseDate) }, compare: naturalOrder)
        case .releaseYear:
            ordered(rows, direction: direction, key: { Self.releaseYear($0.book.releaseDate) }, compare: naturalOrder)
        case .duration:
            ordered(rows, direction: direction, key: { $0.book.durationSeconds }, compare: naturalOrder)
        case .downloadStatus:
            ordered(rows, direction: direction, key: { $0.statusLabel }, compare: textOrder)
        }
    }

    private func ordered<Key>(
        _ rows: [LibraryRow], direction: LibrarySortDirection,
        key: (LibraryRow) -> Key?, compare: (Key, Key) -> ComparisonResult
    ) -> [LibraryRow] {
        let first: ComparisonResult = direction == .ascending ? .orderedAscending : .orderedDescending
        return rows.map { (row: $0, key: key($0)) }.sorted { left, right in
            switch (left.key, right.key) {
            case let (left?, right?):
                let order = compare(left, right)
                if order != .orderedSame { return order == first }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            let byTitle = textOrder(left.row.title, right.row.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return left.row.id < right.row.id
        }.map(\.row)
    }

    private func textOrder(_ left: String, _ right: String) -> ComparisonResult {
        left.localizedStandardCompare(right)
    }

    private func naturalOrder<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
        if left < right { return .orderedAscending }
        return left == right ? .orderedSame : .orderedDescending
    }

    private static func purchaseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(value) { return date }
        guard value.count == 10 else { return nil }
        return try? Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash).parse(value)
    }

    fileprivate static func releaseYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        let yearText = value.prefix(4)
        guard yearText.count == 4, yearText.utf8.allSatisfy({ (48...57).contains($0) }),
              value.dropFirst(4).first.map({ $0 == "-" }) ?? true,
              let year = Int(yearText), year > 0 else { return nil }
        return year
    }
}

enum LibrarySortDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case ascending, descending

    var id: Self { self }
    var tableOrder: SortOrder { self == .ascending ? .forward : .reverse }
}

struct LibraryFilters: Equatable {
    static let suggestionsPreferenceKey = "ShowsLibraryFilterSuggestions"

    enum Field: String, CaseIterable, Identifiable {
        case title, author, series, narrator, genre, language, releaseYear

        var id: Self { self }

        var displayName: String {
            switch self {
            case .title: "Title"
            case .author: "Author"
            case .series: "Series"
            case .narrator: "Narrator"
            case .genre: "Genre"
            case .language: "Language"
            case .releaseYear: "Release Year"
            }
        }

        func values(for book: AudibleBook) -> [String] {
            switch self {
            case .title: [book.title] + (book.subtitle.map { [$0] } ?? [])
            case .author: book.authors
            case .series: book.series.map { [$0] } ?? []
            case .narrator: book.narrators
            case .genre: book.genres ?? []
            case .language: book.language.map { [$0] } ?? []
            case .releaseYear: LibrarySortField.releaseYear(book.releaseDate).map { [String($0)] } ?? []
            }
        }

        func matches(_ book: AudibleBook, text: String) -> Bool {
            if self == .releaseYear {
                guard let year = Int(text) else { return false }
                return LibrarySortField.releaseYear(book.releaseDate) == year
            }
            return values(for: book).contains { $0.localizedStandardContains(text) }
        }
    }

    private var text: [Field: String] = [:]
    var status: LibraryDownloadStatus?

    var isEmpty: Bool { text.isEmpty && status == nil }

    subscript(field: Field) -> String? {
        get { text[field] }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text[field] = value.isEmpty ? nil : value
        }
    }

    var summary: [String] {
        var values = Field.allCases.compactMap { field in text[field].map { "\(field.displayName) “\($0)”" } }
        if let status { values.append(status.displayName) }
        return values
    }

    func matches(_ book: AudibleBook) -> Bool {
        text.allSatisfy { $0.key.matches(book, text: $0.value) }
    }
}

struct LibraryRow: Identifiable {
    let book: AudibleBook
    let status: LibraryDownloadStatus
    let missingFiles: [URL]

    var id: String { book.id }
    var title: String { book.title }
    var authors: String { book.authors.isEmpty ? "—" : book.authors.formatted(.list(type: .and)) }
    var narrators: String { book.narrators.isEmpty ? "—" : book.narrators.formatted(.list(type: .and)) }
    var statusLabel: String { status.displayName }
    var statusSymbol: String { missingFiles.isEmpty ? status.systemImage : "exclamationmark.triangle" }
    var missingFilesDescription: String {
        switch missingFiles.count {
        case 0: ""
        case 1: "1 saved file missing"
        default: "\(missingFiles.count.formatted()) saved files missing"
        }
    }
    var statusDetails: String {
        guard !missingFiles.isEmpty else { return statusLabel }
        return "\(missingFilesDescription). \(missingFiles.map(\.lastPathComponent).formatted(.list(type: .and)))"
    }

    func matches(_ query: String) -> Bool {
        [title, authors, narrators, book.asin, book.subtitle ?? "", book.series ?? ""].contains {
            $0.localizedStandardContains(query)
        }
    }
}
