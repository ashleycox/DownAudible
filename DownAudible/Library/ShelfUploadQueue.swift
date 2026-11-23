import Foundation

nonisolated struct ShelfUpload: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case waiting, uploading, sent, failed

        var label: String {
            switch self {
            case .waiting: "Waiting"
            case .uploading: "Uploading"
            case .sent: "Sent"
            case .failed: "Needs attention"
            }
        }
    }

    var id = UUID()
    let book: ShelfBook
    let destination: ShelfDestination
    var stamps: [ShelfFileStamp]?
    var state = State.waiting
    var detail: String?
}

actor ShelfUploadQueue {
    private let file: URL
    private var entries: [ShelfUpload]?
    private var current: UUID?

    init(file: URL = URL.applicationSupportDirectory.appending(path: "DownAudible/AudiobookshelfUploads.json")) {
        self.file = file
    }

    func list() throws -> [ShelfUpload] {
        if let entries { return entries }
        do {
            entries = try JSONDecoder().decode([ShelfUpload].self, from: Data(contentsOf: file)).map { saved in
                var entry = saved
                if entry.state == .uploading { entry.state = .waiting }
                return entry
            }
        } catch CocoaError.fileReadNoSuchFile {
            entries = []
        }
        return entries ?? []
    }

    func add(_ books: [ShelfBook], to destination: ShelfDestination) throws {
        var snapshot = try list()
        for book in books {
            if let index = snapshot.firstIndex(where: { $0.destination == destination && $0.book.asin == book.asin }) {
                guard snapshot[index].state == .failed else { continue }
                snapshot[index] = try upload(for: book, to: destination)
            } else {
                snapshot.append(try upload(for: book, to: destination))
            }
        }
        try save(snapshot)
    }

    func repeatFailed(for destination: ShelfDestination) throws {
        var snapshot = try list()
        for index in snapshot.indices where snapshot[index].state == .failed && snapshot[index].destination == destination {
            snapshot[index].state = .waiting
            snapshot[index].detail = nil
        }
        try save(snapshot)
    }

    func clearSent() throws {
        try save(list().filter { $0.state != .sent })
    }

    func sendNext(to destination: ShelfDestination, token: String, didStart: @Sendable () async -> Void) async throws -> Bool {
        let snapshot = try list()
        guard current == nil, var entry = snapshot.first(where: { $0.state == .waiting && $0.destination == destination })
        else { return false }
        current = entry.id
        defer { current = nil }
        entry.state = .uploading
        try replace(entry)
        await didStart()
        do {
            let client = try ShelfClient(server: destination.server, token: token)
            let stamps = try entry.stamps ?? entry.book.files.map(ShelfFileStamp.init)
            let uploaded = try await client.upload(entry.book, to: destination, stamps: stamps)
            entry.state = .sent
            entry.detail = uploaded ? nil : "Already in library"
        } catch {
            entry.state = Task.isCancelled ? .waiting : .failed
            entry.detail = Task.isCancelled ? nil : error.localizedDescription
        }
        try replace(entry)
        return !Task.isCancelled
    }

    private func upload(for book: ShelfBook, to destination: ShelfDestination) throws -> ShelfUpload {
        ShelfUpload(book: book, destination: destination, stamps: try book.files.map(ShelfFileStamp.init))
    }

    private func replace(_ entry: ShelfUpload) throws {
        var snapshot = try list()
        guard let index = snapshot.firstIndex(where: { $0.id == entry.id }) else { return }
        snapshot[index] = entry
        try save(snapshot)
    }

    private func save(_ snapshot: [ShelfUpload]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        entries = snapshot
    }
}
