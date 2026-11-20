import Foundation

struct LibraryFilterSuggestions {
    private struct Candidate {
        let value: String
        var occurrences = 1
    }

    private let candidates: [String: Candidate]

    init(field: LibraryFilters.Field, books: [AudibleBook]) {
        var candidates: [String: Candidate] = [:]
        for book in books {
            for value in field.values(for: book) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let folded = Self.fold(trimmed)
                guard !folded.isEmpty else { continue }
                if candidates[folded] == nil {
                    candidates[folded] = Candidate(value: trimmed)
                } else {
                    candidates[folded]?.occurrences += 1
                }
            }
        }
        self.candidates = candidates
    }

    func matching(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = Self.fold(trimmed)
        guard !query.isEmpty else { return [] }
        let words = query.split(whereSeparator: \.isWhitespace)
        let matches = candidates.compactMap { value, candidate -> (Candidate, Int)? in
            guard candidate.value != trimmed else { return nil }
            if value == query { return (candidate, 0) }
            if value.hasPrefix(query) { return (candidate, 1) }
            if let range = value.range(of: query) {
                if range.lowerBound == value.startIndex { return (candidate, 1) }
                let preceding = value[value.index(before: range.lowerBound)]
                return (candidate, preceding.isLetter || preceding.isNumber ? 3 : 2)
            }
            if words.count > 1, words.allSatisfy({ value.contains($0) }) { return (candidate, 4) }
            return nil
        }
        return matches.sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.0.occurrences != right.0.occurrences { return left.0.occurrences > right.0.occurrences }
            let order = left.0.value.localizedStandardCompare(right.0.value)
            return order == .orderedSame ? left.0.value < right.0.value : order == .orderedAscending
        }.prefix(6).map { $0.0.value }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
