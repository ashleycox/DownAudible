import Foundation

enum TransferWork: Codable, Sendable {
    case library(AudibleBook, matches: [URL])
    case local(LocalAudioFile)

    var title: String {
        switch self {
        case .library(let book, _): book.title
        case .local(let file): file.title
        }
    }

    var bookID: AudibleBook.ID? {
        if case .library(let book, _) = self { return book.id }
        return nil
    }

    var isDownload: Bool { bookID != nil }
}

struct TransferBatch: Codable, Sendable {
    var work: [TransferWork]
    let account: SavedAudibleAccount?
    let apiOptions: AudibleAPIOptions
    let layout: ArchiveLayout
    let options: DownloadOptions
    let conversion: ConversionPreferences
    let appleBooks: AppleBooksDestination
    let preferences: TransferPreferences
    let jobLimit: Int

    // An activation code entered in Convert Files is only held for this session.
    var activation: String? = nil

    enum CodingKeys: CodingKey {
        case work, account, apiOptions, layout, options, conversion, appleBooks, preferences, jobLimit
    }
}

struct TransferQueueSnapshot: Codable, Sendable {
    var batch: TransferBatch?
    var transfers: [Transfer]
}

actor TransferQueueStore {
    private let path: URL
    private var lastRevision = 0

    init(path: URL = URL.applicationSupportDirectory
        .appending(component: "DownAudible", directoryHint: .isDirectory)
        .appending(component: "Transfers.json")) {
        self.path = path
    }

    func load() throws -> TransferQueueSnapshot? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(TransferQueueSnapshot.self, from: Data(contentsOf: path))
    }

    func save(_ snapshot: TransferQueueSnapshot, revision: Int) throws {
        guard revision > lastRevision else { return }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
        lastRevision = revision
    }
}
