import Foundation

struct SavedLibraryView: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    let search: String
    let sort: LibrarySort
    let filters: LibraryFilters
}

struct LibraryOrganization: Codable, Sendable {
    private var views: [UUID: [SavedLibraryView]] = [:]
    private var tags: [UUID: [String: [String]]] = [:]

    func savedViews(for account: UUID) -> [SavedLibraryView] {
        (views[account] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    mutating func save(_ view: SavedLibraryView, for account: UUID) {
        var entries = views[account] ?? []
        if let index = entries.firstIndex(where: { Self.sameName($0.name, view.name) }) {
            var replacement = view
            replacement.id = entries[index].id
            entries[index] = replacement
        } else {
            entries.append(view)
        }
        views[account] = entries
    }

    mutating func rename(_ view: UUID, to name: String, for account: UUID) {
        guard let entries = views[account], let index = entries.firstIndex(where: { $0.id == view }),
              !entries.contains(where: { $0.id != view && Self.sameName($0.name, name) }) else { return }
        views[account]?[index].name = name
    }

    mutating func remove(_ view: UUID, for account: UUID) {
        views[account]?.removeAll { $0.id == view }
    }

    func tags(for book: String, account: UUID) -> [String] {
        tags[account]?[book] ?? []
    }

    func tags(for account: UUID) -> [String] {
        Self.uniqueTags((tags[account] ?? [:]).values.flatMap { $0 })
    }

    mutating func changeTags(_ values: [String], for books: [String], account: UUID, adding: Bool) {
        var libraryTags = tags[account] ?? [:]
        for book in books {
            let previous = libraryTags[book] ?? []
            let updated = adding ? Self.uniqueTags(previous + values) : previous.filter { tag in
                !values.contains { Self.sameName(tag, $0) }
            }
            libraryTags[book] = updated.isEmpty ? nil : updated
        }
        tags[account] = libraryTags
    }

    mutating func removeAccount(_ account: UUID) {
        views[account] = nil
        tags[account] = nil
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    static func uniqueTags<S: Sequence>(_ names: S) -> [String] where S.Element == String {
        var result: [String] = []
        for name in names {
            let tag = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, !result.contains(where: { sameName($0, tag) }) { result.append(tag) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
