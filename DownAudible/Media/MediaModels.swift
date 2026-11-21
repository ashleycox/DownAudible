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

struct MediaChapter: Codable, Hashable, Sendable {
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
    case sourceMissing
    case sourcePermissionDenied
    case noAudioTrack
    case unreadableAudio
    case activationRequired
    case voucherRequired
    case voucherRejected
    case conversionFailed
    case destinationFull
    case destinationPermissionDenied
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
        case .sourceMissing:
            "The source file is missing. Reconnect its drive or add the file again from its current location."
        case .sourcePermissionDenied:
            "DownAudible can’t read the source file. Check its permissions in Finder or choose another copy."
        case .noAudioTrack:
            "The source file contains no audio track. Choose a file that plays in an audio player."
        case .unreadableAudio:
            "DownAudible can’t open the audio in this file. Check that the file is complete and plays in an audio player."
        case .activationRequired:
            "This AAX file needs activation bytes from the Audible account that downloaded it."
        case .voucherRequired:
            "This AAXC file needs the voucher saved with the original download."
        case .voucherRejected:
            "DownAudible couldn’t read the AAXC audio with the saved voucher. Check that the voucher belongs to this file, or download a fresh copy."
        case .conversionFailed:
            "The conversion tool couldn’t finish creating the audio. Check that the source plays, then try converting it again."
        case .destinationFull:
            "Conversion ran out of storage. Free space on your Mac or on the destination drive, then try again."
        case .destinationPermissionDenied:
            "DownAudible can’t write the converted audio to this destination. Check the folder’s permissions or choose another folder."
        case .destinationExists:
            "An audio file with that name already exists in the destination."
        case .incompatibleAudioSettings:
            "That bitrate is too high for the channel count and sample rate. Choose a lower bitrate or a higher sample rate."
        case .invalidDestinations:
            "DownAudible couldn’t find a separate destination for each audio file."
        }
    }

    static func conversionFailure(from diagnostics: Data) -> Self {
        let lines = String(decoding: diagnostics, as: UTF8.self).lowercased().split(separator: "\n")
        if lines.contains(where: { $0.hasSuffix("no space left on device") || $0.hasSuffix("disk quota exceeded") }) {
            return .destinationFull
        }
        if lines.contains(where: { $0.hasSuffix("read-only file system") }) ||
            lines.contains(where: { $0.contains("opening output") && $0.hasSuffix("permission denied") }) {
            return .destinationPermissionDenied
        }
        return .conversionFailed
    }
}
