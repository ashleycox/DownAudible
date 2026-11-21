import Foundation

enum TransferWork: Codable, Sendable {
    case library(AudibleBook, matches: [URL])
    case local(LocalAudioFile)
    case editedBook(BookEditWork)

    var title: String {
        switch self {
        case .library(let book, _): book.title
        case .local(let file): file.title
        case .editedBook(let work): work.origin.title
        }
    }

    var bookID: AudibleBook.ID? {
        if case .library(let book, _) = self { return book.id }
        return nil
    }

    var isDownload: Bool { bookID != nil }

    var acceptsEnteredActivation: Bool {
        switch self {
        case .library: false
        case .local(let file): file.format == "aax"
        case .editedBook(let work):
            work.origin.book == nil && work.sources.contains { $0.audio.url.pathExtension.lowercased() == "aax" }
        }
    }
}

enum BookEditOrigin: Codable, Sendable {
    case library(AudibleBook)
    case local(ArchiveTitle)

    var book: AudibleBook? {
        if case .library(let book) = self { return book }
        return nil
    }

    var title: String { archiveTitle.title }

    var archiveTitle: ArchiveTitle {
        switch self {
        case .library(let book): ArchiveTitle(book)
        case .local(let title): title
        }
    }
}

struct BookEditSource: Codable, Sendable {
    let audio: StoredAudio
    let revision: FileRevision
}

struct PreparedBookEdit: Sendable {
    let sources: [BookEditSource]
    let audibleChapters: [MediaChapter]
    let layout: BookEditingLayout
}

struct BookEditWork: Codable, Sendable {
    let origin: BookEditOrigin
    let sources: [BookEditSource]
    let audibleChapters: [MediaChapter]
    let edit: BookEdit
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
    var repairsArchive: Bool? = nil
    var startedAt: Date? = nil

    // An activation code entered in Convert Files is only held for this session.
    var activation: String? = nil

    enum CodingKeys: CodingKey {
        case work, account, apiOptions, layout, options, conversion, appleBooks, preferences, jobLimit, repairsArchive, startedAt
    }
}

struct TransferHistoryBatch: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var batch: TransferBatch
    var transfers: [Transfer]
}

struct TransferQueueSnapshot: Codable, Sendable {
    static let historyLimit = 10

    var batch: TransferBatch?
    var transfers: [Transfer]
    let history: [TransferHistoryBatch]

    init(batch: TransferBatch?, transfers: [Transfer], history: [TransferHistoryBatch] = []) {
        self.batch = batch
        self.transfers = transfers
        self.history = Array(history.prefix(Self.historyLimit))
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        batch = try values.decodeIfPresent(TransferBatch.self, forKey: .batch)
        transfers = try values.decode([Transfer].self, forKey: .transfers)
        history = Array((try values.decodeIfPresent([TransferHistoryBatch].self, forKey: .history) ?? [])
            .prefix(Self.historyLimit))
    }
}

actor TransferQueueStore {
    private enum QueueError: LocalizedError {
        case readFailed, incomplete, writeFailed, noSpace

        var errorDescription: String? {
            switch self {
            case .readFailed: "DownAudible couldn’t read its saved download queue. Check that you can access the Library/Application Support/DownAudible folder in your home folder."
            case .incomplete: "The saved download queue is incomplete or damaged. Start a new download from Library or add your local audio again in Convert Files."
            case .writeFailed: "DownAudible couldn’t save its download queue. Check that you can write to the Library/Application Support/DownAudible folder in your home folder."
            case .noSpace: "Your Mac ran out of space while saving the download queue. Free up space so DownAudible can resume transfers after it closes."
            }
        }
    }

    private let path: URL
    private var lastRevision = 0

    init(path: URL = URL.applicationSupportDirectory
        .appending(component: "DownAudible", directoryHint: .isDirectory)
        .appending(component: "Transfers.json")) {
        self.path = path
    }

    func load() throws -> TransferQueueSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw QueueError.readFailed
        }
        guard let snapshot = try? JSONDecoder().decode(TransferQueueSnapshot.self, from: data),
              (snapshot.batch?.work.count ?? 0) == snapshot.transfers.count,
              snapshot.history.allSatisfy({ $0.batch.work.count == $0.transfers.count }) else {
            throw QueueError.incomplete
        }
        return snapshot
    }

    func save(_ snapshot: TransferQueueSnapshot, revision: Int) throws {
        guard revision > lastRevision else { return }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
        } catch CocoaError.fileWriteOutOfSpace {
            throw QueueError.noSpace
        } catch {
            throw QueueError.writeFailed
        }
        lastRevision = revision
    }
}
