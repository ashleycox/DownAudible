import Foundation

struct ArchiveLayout: Equatable, Sendable {
    static let defaultTemplate = "{format}/{author}/{title}"
    static let tokens = ["format", "author", "title", "asin"]

    let root: URL
    let template: String
    var filenameStyle: FilenameStyle = .unicode
    var filenameLength = 230

    var isValid: Bool {
        let components = template.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 12 else { return false }
        return components.allSatisfy { component in
            guard !component.trimmingCharacters(in: .whitespaces).isEmpty,
                  component != ".", component != "..",
                  component.utf8.count <= 240,
                  component.rangeOfCharacter(from: .controlCharacters) == nil else {
                return false
            }
            let literal = Self.tokens.reduce(String(component)) { text, token in
                text.replacingOccurrences(of: "{\(token)}", with: "")
            }
            return !literal.contains("{") && !literal.contains("}")
        }
    }

    func directory(for book: ArchiveTitle, format: String) throws -> URL {
        guard isValid else { throw ArchiveError.invalidTemplate }
        let values = [
            "title": book.title, "author": book.author,
            "format": format, "asin": book.asin
        ]
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory = resolvedRoot
        for component in template.split(separator: "/") {
            var value = ""
            var remaining = component[...]
            while let start = remaining.firstIndex(of: "{"),
                  let end = remaining[start...].firstIndex(of: "}") {
                value += String(remaining[..<start])
                let token = String(remaining[remaining.index(after: start)..<end])
                value += values[token, default: ""]
                remaining = remaining[remaining.index(after: end)...]
            }
            value += String(remaining)
            let next = directory.appending(component: Self.filename(value), directoryHint: .isDirectory)
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

    static func filename(_ value: String, maxBytes: Int = 180) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var name = value.components(separatedBy: invalid).joined(separator: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        var bytes = 0
        let prefix = name.prefix { character in
            bytes += character.utf8.count
            return bytes <= maxBytes
        }
        return prefix.isEmpty ? "Unknown" : String(prefix)
    }
}

struct ArchiveTitle: Sendable {
    static let unknownASIN = "No ASIN"

    let title: String
    let author: String
    let asin: String

    init(title: String, author: String?, asin: String?) {
        self.title = title.isEmpty ? "Untitled" : title
        self.author = author.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Author"
        self.asin = asin.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unknownASIN
    }

    init(_ book: AudibleBook) {
        self.init(title: book.title, author: book.authors.first, asin: book.asin)
    }

    init(_ file: LocalAudioFile) {
        self.init(title: file.title, author: file.author, asin: file.asin)
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

    var errorDescription: String? {
        switch self {
        case .invalidTemplate:
            "Use folder names and the listed placeholders, separated by slashes."
        case .outsideDestination:
            "A folder in this template is a broken link or points outside the destination."
        case .unavailable:
            "Audible isn’t offering this title for download."
        case .noAudio:
            "No audiobook files were found. Choose an AAX, AAXC, or AA file, or a folder containing them."
        case .missingLocalFiles:
            "The matched files are missing. Choose the files again or remove the match."
        case .invalidActivation:
            "Enter the eight hexadecimal characters from your Audible activation bytes."
        case .filenameExhausted:
            "DownAudible couldn’t find a free filename in the destination folder."
        }
    }
}
