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

struct LocalAudioFile: Identifiable, Codable, Hashable, Sendable {
    let url: URL
    let format: String
    let title: String
    let author: String?
    let asin: String?
    let durationSeconds: Double?
    var metadata: [String: String]? = nil
    var isSegment: Bool? = nil
    var collectionTitle: String? = nil
    var collectionAuthor: String? = nil

    var id: URL { url }
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
    case incompatibleAudioSettings
    case invalidDestinations

    var errorDescription: String? {
        switch self {
        case .toolsMissing:
            "The conversion tools are missing. Rebuild or reinstall DownAudible."
        case .noInput:
            "Choose an AAX, AAXC, AA, MP3, M4A, or M4B file to convert."
        case .unsupportedFile:
            "Choose an AAX, AAXC, AA, MP3, M4A, or M4B file, or a folder containing those files."
        case .unreadableAudio:
            "The audio could not be read. Check that the file is complete and try again."
        case .activationRequired:
            "This AAX file needs activation bytes from the Audible account that downloaded it."
        case .voucherRequired:
            "This AAXC file needs the voucher saved with the original download."
        case .conversionFailed:
            "The audio could not be converted. Check that the files are complete and the destination has enough space."
        case .destinationExists:
            "An audio file with that name already exists in the destination."
        case .incompatibleAudioSettings:
            "That bitrate is too high for the channel count and sample rate. Choose a lower bitrate or a higher sample rate."
        case .invalidDestinations:
            "DownAudible couldn’t find a separate destination for each audio file."
        }
    }
}
