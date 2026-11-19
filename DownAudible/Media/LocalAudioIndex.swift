import Foundation

struct LocalAudioIndex: Sendable {
    private enum Evidence: Int, Comparable {
        case folder, title, titleAndAuthor, identifier

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Candidate: Sendable {
        let file: LocalAudioFile
        let titles: Set<String>
        let authors: Set<String>
        let filename: String
        let compactFilename: String?
        let folderTitle: String
        let folderAuthor: String
        let isInFormatFolder: Bool

        init(_ file: LocalAudioFile) {
            self.file = file
            titles = Set([file.title, file.collectionTitle].compactMap { $0 }.map(titleKey)).subtracting([""])
            authors = Set([file.author, file.collectionAuthor].compactMap { $0 }.map(key)).subtracting([""])
            let stem = file.url.deletingPathExtension().lastPathComponent
            filename = titleKey(filenameTitle(stem))
            compactFilename = stem.range(of: LocalAudioIndex.audibleFilenameSuffix, options: .regularExpression) == nil
                ? nil : filename.replacingOccurrences(of: " ", with: "")
            let folder = file.url.deletingLastPathComponent()
            let authorFolder = folder.deletingLastPathComponent()
            folderTitle = titleKey(folder.lastPathComponent)
            folderAuthor = key(authorFolder.lastPathComponent)
            isInFormatFolder = authorFolder.deletingLastPathComponent().lastPathComponent.lowercased() == file.format
        }

        var isAudibleOriginal: Bool { ["aa", "aax", "aaxc"].contains(file.format) }

        func evidence(for names: BookNames, duration: Int?) -> Evidence? {
            guard file.asin == nil, matchesDuration(duration) else { return nil }
            let authorInTags = !authors.isDisjoint(with: names.authors)
            let hasTitle = !titles.isDisjoint(with: names.titles)
                || names.titles.contains(filename)
                || compactFilename.map(names.compactTitles.contains) == true
            let hasFolderAuthor = names.authors.contains(folderAuthor)
            let hasBookFolder = hasFolderAuthor && names.titles.contains(folderTitle)
            // Some apps use an artist tag for the narrator. The archive path can corroborate a matching title.
            if !names.authors.isEmpty, !authors.isEmpty, !authorInTags {
                return isInFormatFolder && hasBookFolder && hasTitle ? .folder : nil
            }
            if hasTitle {
                return authorInTags || hasFolderAuthor ? .titleAndAuthor : .title
            }
            if names.filenamesWithAuthor.contains(filename) { return .titleAndAuthor }
            if hasBookFolder,
               isAudibleOriginal || (file.durationSeconds != nil && (duration ?? 0) > 0) {
                return .folder
            }
            return nil
        }

        func matchesDuration(_ duration: Int?) -> Bool {
            guard let duration, duration > 0, let actual = file.durationSeconds else { return true }
            let expected = Double(duration)
            let tolerance = min(120, max(5, expected * 0.03))
            return abs(actual - expected) <= tolerance
        }
    }

    private struct Match {
        let candidate: Candidate
        let evidence: Evidence
    }

    private struct BookNames {
        let titles: Set<String>
        let compactTitles: Set<String>
        let authors: Set<String>
        let filenamesWithAuthor: Set<String>

        init(title: String, subtitle: String?, authors: [String]) {
            var titles: Set<String> = [titleKey(title)]
            if let subtitle, !subtitle.isEmpty { titles.insert(titleKey("\(title): \(subtitle)")) }
            titles.remove("")
            let authorKeys = Set((authors + [authors.joined(separator: ", ")]).map(key)).subtracting([""])
            self.titles = titles
            self.authors = authorKeys
            compactTitles = Set(titles.map { $0.replacingOccurrences(of: " ", with: "") })
            filenamesWithAuthor = Set(authorKeys.flatMap { author in
                titles.flatMap { title in ["\(author) \(title)", "\(title) \(author)"] }
            })
        }
    }

    private static let audibleFilenameSuffix = #"(?i)_AAXC?(?:_[0-9]+)*$"#
    private static let filenameIdentifier = #"(?i)(?<![A-Z0-9])B0[A-Z0-9]{8}(?![A-Z0-9])"#
    private let candidates: [Candidate]
    private let byIdentifier: [String: [Int]]
    private let byTitle: [String: [Int]]
    private let byCompactFilename: [String: [Int]]

    init(files: [LocalAudioFile]) {
        let candidates = files.filter { $0.isSegment != true }.map(Candidate.init)
        self.candidates = candidates
        var identifiers: [String: [Int]] = [:]
        var titles: [String: [Int]] = [:]
        var compactFilenames: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            if let asin = candidate.file.asin {
                identifiers[asin.uppercased(), default: []].append(index)
                continue
            }
            for title in candidate.titles.union([candidate.filename, candidate.folderTitle]) where !title.isEmpty {
                titles[title, default: []].append(index)
            }
            if let title = candidate.compactFilename, !title.isEmpty {
                compactFilenames[title, default: []].append(index)
            }
        }
        byIdentifier = identifiers
        byTitle = titles
        byCompactFilename = compactFilenames
    }

    func matches(for books: [AudibleBook]) throws -> [String: [URL]] {
        var selected: [String: URL] = [:]
        var claims: [URL: Int] = [:]
        for book in books {
            try Task.checkCancellation()
            let titles = titleMatches(for: book)
            let identifiers = byIdentifier[book.asin.uppercased()]
            let possibilities = identifiers.map { indices in
                indices.map { candidates[$0] }
                    .filter { $0.matchesDuration(book.durationSeconds) }
                    .map { Match(candidate: $0, evidence: .identifier) }
            } ?? titles
            selected[book.id] = Self.preferred(possibilities)?.url

            // Count possible claims even when another edition has an identified copy of its own.
            let allMatches = identifiers == nil ? titles : titles + possibilities
            for url in Set(allMatches.map(\.candidate.file.url)) {
                claims[url, default: 0] += 1
            }
        }
        return selected.filter { claims[$0.value] == 1 }.mapValues { [$0] }
    }

    private func titleMatches(for book: AudibleBook) -> [Match] {
        let names = BookNames(title: book.title, subtitle: book.subtitle, authors: book.authors)
        let indices = Set(names.titles.union(names.filenamesWithAuthor).flatMap { byTitle[$0, default: []] })
            .union(names.compactTitles.flatMap { byCompactFilename[$0, default: []] })
        return indices.compactMap { index in
            let candidate = candidates[index]
            return candidate.evidence(for: names, duration: book.durationSeconds)
                .map { Match(candidate: candidate, evidence: $0) }
        }
    }

    private static func preferred(_ matches: [Match]) -> LocalAudioFile? {
        guard let strongest = matches.map(\.evidence).max() else { return nil }
        let best = matches.filter { $0.evidence == strongest }.map(\.candidate)
        if best.count == 1 { return best.first?.file }
        let originals = best.filter(\.isAudibleOriginal)
        return originals.count == 1 ? originals.first?.file : nil
    }

    static func identifier(inFilename stem: String) -> String? {
        stem.range(of: filenameIdentifier, options: .regularExpression).map { stem[$0].uppercased() }
    }

    static func filenameTitle(_ stem: String) -> String {
        stem.replacingOccurrences(of: audibleFilenameSuffix, with: "", options: .regularExpression)
            .replacingOccurrences(of: filenameIdentifier, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_[]()")))
    }

    private static func titleKey(_ text: String) -> String {
        key(text.replacingOccurrences(of: #"(?i)\s*(?:\(unabridged\)|\[unabridged\]|-\s+unabridged)\s*$"#,
                                      with: "", options: .regularExpression))
    }

    private static func key(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
