import Foundation

struct MediaCredentials: Sendable {
    var activationBytes: String?
    var audibleKey: String?
    var audibleIV: String?

    var hasActivationBytes: Bool {
        Self.isHex(activationBytes, count: 8)
    }

    var hasVoucher: Bool {
        Self.isHex(audibleKey, count: 32) && Self.isHex(audibleIV, count: 32)
    }

    private static func isHex(_ value: String?, count: Int) -> Bool {
        guard let value, value.utf8.count == count else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

struct MediaInput: Sendable {
    var url: URL
    var credentials = MediaCredentials()
}

struct MediaMetadata: Sendable {
    var title: String?
    var subtitle: String?
    var authors: [String] = []
    var narrators: [String] = []
    var description: String?
    var publisher: String?
    var releaseDate: String?
    var asin: String?
    var series: String?
    var seriesSequence: String?
    var language: String?
    var genres: [String] = []
    var chapters: [MediaChapter] = []
}

struct MediaChapter: Hashable, Sendable {
    var startMilliseconds: Int64
    var durationMilliseconds: Int64
    var title: String
}

struct LocalAudioFile: Identifiable, Hashable, Sendable {
    let url: URL
    let format: String
    let title: String
    let author: String?
    let asin: String?
    let durationSeconds: Double?

    var id: URL { url }

    static func searchKey(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct LocalAudioIndex: Sendable {
    private let byIdentifier: [String: [LocalAudioFile]]
    private let byTitle: [String: [LocalAudioFile]]

    init(files: [LocalAudioFile]) {
        var identifiers: [String: [LocalAudioFile]] = [:]
        var titles: [String: [LocalAudioFile]] = [:]
        for file in files {
            if let asin = file.asin {
                identifiers[asin.uppercased(), default: []].append(file)
            }
            titles[LocalAudioFile.searchKey(file.title), default: []].append(file)
        }
        byIdentifier = identifiers
        byTitle = titles
    }

    func match(title: String, author: String?, asin: String) -> LocalAudioFile? {
        if let matches = byIdentifier[asin.uppercased()] {
            return matches.count == 1 ? matches.first : nil
        }

        let title = LocalAudioFile.searchKey(title)
        guard !title.isEmpty, let matches = byTitle[title] else { return nil }
        let author = author.map(LocalAudioFile.searchKey) ?? ""
        if !author.isEmpty {
            let byAuthor = matches.filter { file in
                file.author.map(LocalAudioFile.searchKey) == author
            }
            if !byAuthor.isEmpty {
                guard byAuthor.count == 1, let file = byAuthor.first, file.asin == nil else { return nil }
                return file
            }
        }

        guard matches.count == 1, let file = matches.first, file.asin == nil else { return nil }
        return author.isEmpty || file.author == nil ? file : nil
    }
}

enum MediaError: LocalizedError {
    case toolsMissing
    case noInput
    case unsupportedFile
    case unreadableAudio
    case activationRequired
    case voucherRequired
    case conversionFailed
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .toolsMissing:
            "The conversion tools are missing. Rebuild or reinstall DownAudible."
        case .noInput:
            "Choose an AAX, AAXC, AA, or MP3 file to convert."
        case .unsupportedFile:
            "Choose an AAX, AAXC, AA, or MP3 file, or a folder containing those files."
        case .unreadableAudio:
            "The audio could not be read. Check that the file is complete and try again."
        case .activationRequired:
            "This AAX file needs activation bytes from the Audible account that downloaded it."
        case .voucherRequired:
            "This AAXC file needs the voucher saved with the original download."
        case .conversionFailed:
            "The audio could not be converted. Check that the files are complete and the destination has enough space."
        case .destinationExists:
            "An M4B with that name already exists in the destination."
        }
    }
}
