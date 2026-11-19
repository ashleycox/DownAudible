import Foundation

enum WorkspacePage: String, CaseIterable, Identifiable {
    case library = "Library"
    case transfers = "Transfers"
    case convert = "Convert Files"

    var id: Self { self }

    var icon: String {
        switch self {
        case .library: "books.vertical"
        case .transfers: "arrow.down.circle"
        case .convert: "waveform"
        }
    }
}

struct DownloadOptions: Codable, Sendable {
    var downloadAudio = true
    var convert = false
    var keepOriginal = true
    var downloadPDF = false
    var downloadCover = false
    var downloadChapters = false
    var downloadAnnotations = false

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadAudio = try values.decodeIfPresent(Bool.self, forKey: .downloadAudio) ?? true
        convert = try values.decodeIfPresent(Bool.self, forKey: .convert) ?? false
        keepOriginal = try values.decodeIfPresent(Bool.self, forKey: .keepOriginal) ?? true
        downloadPDF = try values.decodeIfPresent(Bool.self, forKey: .downloadPDF) ?? false
        downloadCover = try values.decodeIfPresent(Bool.self, forKey: .downloadCover) ?? false
        downloadChapters = try values.decodeIfPresent(Bool.self, forKey: .downloadChapters) ?? false
        downloadAnnotations = try values.decodeIfPresent(Bool.self, forKey: .downloadAnnotations) ?? false
    }

    var makesConversion: Bool { downloadAudio && convert }
    var savesOriginal: Bool { downloadAudio && (!convert || keepOriginal) }
    var hasSelection: Bool { downloadAudio || downloadPDF || downloadCover || downloadChapters || downloadAnnotations }
}

struct Transfer: Codable, Identifiable, Sendable {
    enum Status: Codable, Sendable {
        case waiting
        case active(String, Double?)
        case done(URL, note: String?)
        case failed(String)
        case cancelled
        case interrupted
        case stopped
    }

    var id = UUID()
    let title: String
    var status: Status = .waiting
    var files: [URL] = []
    var canRestart = false
    var partialFolder: URL?
    var restartPending: Bool?

    var isFinished: Bool {
        switch status {
        case .waiting, .active: false
        case .done, .failed, .cancelled, .interrupted, .stopped: true
        }
    }

    var canRetry: Bool {
        switch status {
        case .failed, .cancelled, .interrupted, .stopped: true
        case .done(_, let note): note != nil
        default: false
        }
    }
}

struct DownloadRequest: Identifiable {
    let id = UUID()
    let books: [AudibleBook]
    var restartsIncomplete = false
    var requestsAudio = false
}

struct StoredAudio: Codable, Sendable {
    let url: URL
    let asin: String?
}

struct LocalMatches: Codable {
    var directory: URL?
    var automatic: [String: [URL]] = [:]
    var manual: [String: [URL]] = [:]
    var excluded: Set<String> = []

    func files(for id: String) -> [URL] {
        if let files = manual[id] { return files }
        if excluded.contains(id) { return [] }
        return automatic[id] ?? []
    }
}

struct ExportReceipt: Sendable {
    let url: URL
    var original: [URL] = []
    var converted: [URL] = []
    var addedOriginal: [URL] = []
    var addedConverted: [URL] = []
    var note: String?

    var audioFiles: [URL] { original + converted }
}

enum LibraryDownloadStatus: CaseIterable, Identifiable, Sendable {
    case downloaded, matched, partial, missing, notDownloaded, unavailable

    var id: Self { self }

    var displayName: String {
        switch self {
        case .downloaded: "Downloaded"
        case .matched: "Matched"
        case .partial: "Incomplete"
        case .missing: "Files missing"
        case .notDownloaded: "Not downloaded"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .downloaded: "checkmark.circle"
        case .matched: "link"
        case .partial: "arrow.down.circle.dotted"
        case .missing: "exclamationmark.triangle"
        case .notDownloaded: "arrow.down.circle"
        case .unavailable: "minus.circle"
        }
    }
}

enum LibraryAudioCategory: Sendable {
    case toDownload, downloaded, matched, unavailable

    init(status: LibraryDownloadStatus, isDownloadable: Bool) {
        self = switch status {
        case .downloaded: .downloaded
        case .matched: .matched
        case .unavailable: .unavailable
        case .partial, .missing, .notDownloaded: isDownloadable ? .toDownload : .unavailable
        }
    }
}

struct ArchiveInventoryItem: Sendable {
    var files: [URL] = []
    var originals: [URL] = []
    var missingFiles: [URL] = []
    var hadAudio = false
    var hasPartial = false
}
