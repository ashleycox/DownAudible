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
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw QueueError.readFailed
        }
        guard let snapshot = try? JSONDecoder().decode(TransferQueueSnapshot.self, from: data),
              (snapshot.batch?.work.count ?? 0) == snapshot.transfers.count else { throw QueueError.incomplete }
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
