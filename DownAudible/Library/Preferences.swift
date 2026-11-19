import Foundation

struct SavedAudibleAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let marketplace: AudibleMarketplace
    var usesLegacySession = false
}

struct TransferPreferences: Codable, Sendable {
    var jobLimit = 3
    var conversionJobLimit = 2
    var continueAfterError = true
    var showProgress = true
    var existingFiles = ExistingFiles.reuse
    var logLevel = TransferLogLevel.off
    var logFile: URL?
}

enum ExistingFiles: String, Codable, Sendable, CaseIterable, Identifiable {
    case reuse
    case saveNewCopy

    var id: Self { self }

    var displayName: String {
        switch self {
        case .reuse: "Reuse completed files"
        case .saveNewCopy: "Save another copy"
        }
    }
}

enum FilenameStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case unicode
    case ascii
    case asinUnicode
    case asinASCII
    case asinOnly

    var id: Self { self }

    var displayName: String {
        switch self {
        case .unicode: "Title"
        case .ascii: "Title (ASCII)"
        case .asinUnicode: "ASIN and title"
        case .asinASCII: "ASIN and title (ASCII)"
        case .asinOnly: "ASIN only"
        }
    }

    func name(for book: ArchiveTitle) -> String {
        let title = switch self {
        case .ascii, .asinASCII: Self.ascii(book.title)
        default: book.title
        }
        guard book.asin != ArchiveTitle.unknownASIN else { return title }
        return switch self {
        case .asinUnicode, .asinASCII: "\(book.asin) - \(title)"
        case .asinOnly: book.asin
        default: title
        }
    }

    static func ascii(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let plain = latin.folding(options: .diacriticInsensitive, locale: nil)
        return plain.unicodeScalars.map { $0.isASCII ? String($0) : "" }.joined()
    }
}

enum TransferLogLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case errors
    case results

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .errors: "Errors only"
        case .results: "Transfer results"
        }
    }
}
