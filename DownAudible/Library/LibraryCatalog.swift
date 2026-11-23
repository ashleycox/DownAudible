import Foundation

nonisolated struct LibraryCatalog: Codable, Sendable {
    struct Query: Codable, Equatable, Sendable {
        let start: Date?
        let end: Date?
        let podcasts: AudiblePodcastMode

        init(_ options: AudibleAPIOptions) {
            start = options.purchaseStart
            end = options.purchaseEnd
            podcasts = options.podcasts
        }
    }

    struct Changes: Codable, Sendable {
        let added: [AudibleBook]
        let removed: [AudibleBook]
        let updated: [AudibleBook]

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && updated.isEmpty }
    }

    let books: [AudibleBook]
    let refreshed: Date
    let query: Query
    let changes: Changes?

    init(books: [AudibleBook], query: Query, previous: LibraryCatalog?, refreshed: Date = .now) {
        self.books = books
        self.refreshed = refreshed
        self.query = query
        guard let previous, previous.query == query else {
            changes = nil
            return
        }
        let before = Dictionary(previous.books.map { ($0.asin, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(books.map(\.asin))
        changes = Changes(
            added: books.filter { before[$0.asin] == nil },
            removed: previous.books.filter { !after.contains($0.asin) },
            updated: books.filter { book in
                guard let old = before[book.asin] else { return false }
                return old.title != book.title || old.authors != book.authors || old.narrators != book.narrators
                    || old.series != book.series || old.seriesSequence != book.seriesSequence
                    || old.isDownloadable != book.isDownloadable || old.isAudiblePlus != book.isAudiblePlus
                    || old.downloadUnavailableReason != book.downloadUnavailableReason
                    || old.isIndefinite != book.isIndefinite || old.hasPDF != book.hasPDF
            }
        )
    }
}

actor LibraryCatalogStore {
    private let file: URL

    init(file: URL = URL.applicationSupportDirectory.appending(path: "DownAudible/LibraryCatalog.json")) {
        self.file = file
    }

    func load() throws -> [UUID: LibraryCatalog] {
        do {
            return try JSONDecoder().decode([UUID: LibraryCatalog].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
    }

    func save(_ catalogs: [UUID: LibraryCatalog]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(catalogs).write(to: file, options: .atomic)
    }
}

nonisolated struct AudibleRetryDelay: Codable, Sendable {
    let reason: String
    let until: Date

    init?(error: any Error, now: Date = .now) {
        guard let audible = error as? AudibleError else { return nil }
        let duration: TimeInterval
        switch audible {
        case .rateLimited:
            reason = "Audible is limiting requests."
            duration = 15 * 60
        case .licenseThrottled:
            reason = "Audible is limiting download licenses."
            duration = 60 * 60
        case .serverUnavailable:
            reason = "Audible returned a temporary server error."
            duration = 5 * 60
        default: return nil
        }
        until = now.addingTimeInterval(duration)
    }
}
