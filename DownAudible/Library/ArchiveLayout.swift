import Foundation

struct OutputNaming: Codable, Equatable, Sendable {
    var filenameTemplate = ""
    var chapterFilenameTemplate = "{title} - {chapterNumber} - {chapter}"
    var whitespace = NamingWhitespace.preserve
    var letterCase = NamingLetterCase.preserve
    var transliterate = false

    func apply(to text: String) -> String {
        var text = transliterate ? FilenameStyle.ascii(text) : text
        switch whitespace {
        case .preserve: break
        case .hyphens, .underscores:
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: whitespace == .hyphens ? "-" : "_")
        }
        return switch letterCase {
        case .preserve: text
        case .lowercase: text.lowercased()
        case .uppercase: text.uppercased()
        }
    }
}

enum NamingWhitespace: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve, hyphens, underscores

    var id: Self { self }
    var displayName: String {
        switch self {
        case .preserve: "Keep spaces"
        case .hyphens: "Use hyphens"
        case .underscores: "Use underscores"
        }
    }
}

enum NamingLetterCase: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve, lowercase, uppercase

    var id: Self { self }
    var displayName: String {
        switch self {
        case .preserve: "Keep original case"
        case .lowercase: "Lowercase"
        case .uppercase: "Uppercase"
        }
    }
}

struct ArchiveLayout: Codable, Equatable, Sendable {
    static let defaultTemplate = "{format}/{author}/{title}"
    static let tokens = [
        "title", "subtitle", "author", "authors", "narrator", "narrators", "series", "seriesNumber",
        "publisher", "year", "language", "asin", "format", "chapter", "chapterNumber", "partNumber"
    ]

    let root: URL
    let template: String
    var filenameStyle: FilenameStyle = .unicode
    var filenameLength = 230
    var naming = OutputNaming()

    var isValid: Bool {
        let components = template.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.count <= 12
            && components.allSatisfy { Self.validComponent(String($0)) }
            && (naming.filenameTemplate.isEmpty || Self.validComponent(naming.filenameTemplate))
            && (naming.chapterFilenameTemplate.isEmpty || Self.validComponent(naming.chapterFilenameTemplate))
    }

    func directory(
        for book: ArchiveTitle, format: String, chapterNumber: Int? = nil,
        chapterTitle: String? = nil, partNumber: Int? = nil
    ) throws -> URL {
        guard isValid else { throw ArchiveError.invalidTemplate }
        let values = substitutions(book, format: format, chapterNumber: chapterNumber, chapterTitle: chapterTitle, partNumber: partNumber)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory = resolvedRoot
        for component in template.split(separator: "/") {
            let value = Self.render(component, values: values)
            let next = directory.appending(component: Self.filename(naming.apply(to: value)), directoryHint: .isDirectory)
            let resolved = next.resolvingSymlinksInPath()
            guard resolved.pathComponents.starts(with: resolvedRoot.pathComponents) else {
                throw ArchiveError.outsideDestination
            }
            if resolved.path == next.path,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: next.path)) != nil {
                throw ArchiveError.outsideDestination
            }
            directory = resolved
        }
        return directory
    }

    func filenameStem(
        for book: ArchiveTitle, format: String, chapterNumber: Int? = nil,
        chapterTitle: String? = nil, partNumber: Int? = nil
    ) -> String {
        let values = substitutions(book, format: format, chapterNumber: chapterNumber, chapterTitle: chapterTitle, partNumber: partNumber)
        let pattern = chapterNumber == nil ? naming.filenameTemplate : naming.chapterFilenameTemplate
        var stem: String
        if pattern.isEmpty {
            stem = filenameStyle.name(for: book)
            if let chapterNumber {
                stem += " - \(Self.number(chapterNumber))"
                if let chapterTitle, !chapterTitle.isEmpty { stem += " - \(chapterTitle)" }
            }
        } else {
            stem = Self.render(pattern[...], values: values)
        }
        if let partNumber, !pattern.contains("{partNumber}") { stem += " - Part \(partNumber)" }
        let cleaned = naming.apply(to: stem)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? naming.apply(to: filenameStyle.name(for: book))
            : cleaned
    }

    private func substitutions(
        _ book: ArchiveTitle, format: String, chapterNumber: Int?, chapterTitle: String?, partNumber: Int?
    ) -> [String: String] {
        var values = book.metadata
        values["title"] = book.title
        values["author"] = book.author
        values["asin"] = book.asin
        values["format"] = format
        values["chapter"] = chapterTitle
        values["chapterNumber"] = chapterNumber.map(Self.number)
        values["partNumber"] = partNumber.map(Self.number)
        return values
    }

    private static func number(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    private static func validComponent(_ component: String) -> Bool {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !component.contains("/"),
              component.utf8.count <= 240, component.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        let literal = tokens.reduce(component) { text, token in text.replacingOccurrences(of: "{\(token)}", with: "") }
        return !literal.contains("{") && !literal.contains("}")
    }

    private static func render(_ pattern: Substring, values: [String: String]) -> String {
        var result = ""
        var remaining = pattern
        while let start = remaining.firstIndex(of: "{"),
              let end = remaining[start...].firstIndex(of: "}") {
            result += String(remaining[..<start])
            let token = String(remaining[remaining.index(after: start)..<end])
            result += values[token, default: ""]
            remaining = remaining[remaining.index(after: end)...]
        }
        return result + remaining
    }

    static func filename(_ value: String, maxBytes: Int = 180) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var name = value.components(separatedBy: invalid).joined(separator: "-")
        let trim = CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)
        name = name.trimmingCharacters(in: trim)
        var bytes = 0
        let prefix = name.prefix { character in
            bytes += character.utf8.count
            return bytes <= maxBytes
        }
        let shortened = String(prefix).trimmingCharacters(in: trim)
        return shortened.isEmpty ? "Unknown" : shortened
    }
}

struct ArchiveTitle: Sendable {
    static let unknownASIN = "No ASIN"

    let title: String
    let author: String
    let asin: String
    let metadata: [String: String]

    init(title: String, author: String?, asin: String?, metadata: [String: String] = [:]) {
        self.title = title.isEmpty ? "Untitled" : title
        self.author = author.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Author"
        self.asin = asin.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unknownASIN
        self.metadata = metadata
    }

    init(_ book: AudibleBook) {
        let attributes: [String: String?] = [
            "subtitle": book.subtitle, "authors": book.authors.joined(separator: ", "),
            "narrator": book.narrators.first, "narrators": book.narrators.joined(separator: ", "),
            "series": book.series, "seriesNumber": book.seriesSequence, "publisher": book.publisher,
            "year": book.releaseDate.map { String($0.prefix(4)) }, "language": book.language
        ]
        self.init(title: book.title, author: book.authors.first, asin: book.asin, metadata: attributes.compactMapValues { $0 })
    }

    init(_ file: LocalAudioFile) {
        var metadata = file.metadata ?? [:]
        if metadata["authors"] == nil { metadata["authors"] = file.author }
        self.init(title: file.title, author: file.author, asin: file.asin, metadata: metadata)
    }
}

enum ArchiveError: LocalizedError {
    case invalidTemplate
    case outsideDestination
    case unavailable
    case noAudio
    case missingLocalFiles
    case invalidActivation
    case filenameExhausted
    case unsafeStaging

    var errorDescription: String? {
        switch self {
        case .invalidTemplate:
            "Check the folder and filename templates. Use the listed placeholders and put slashes only in the folder template."
        case .outsideDestination:
            "A folder in this template is a broken link or points outside the destination."
        case .unavailable:
            "Audible isn’t offering this title for download."
        case .noAudio:
            "No supported audio files were found."
        case .missingLocalFiles:
            "The matched files are missing. Choose the files again or remove the match."
        case .invalidActivation:
            "Enter the eight hexadecimal characters from your Audible activation bytes."
        case .filenameExhausted:
            "DownAudible couldn’t find a free filename in the destination folder."
        case .unsafeStaging:
            "The folder for incomplete downloads is a link. Choose another destination or restore that folder."
        }
    }
}
