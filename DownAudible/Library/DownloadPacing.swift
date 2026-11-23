import Foundation

nonisolated struct DownloadPacing: Codable, Sendable {
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, all, plus

        var id: Self { self }

        var label: String {
            switch self {
            case .off: "Off"
            case .all: "All titles"
            case .plus: "Audible Plus only"
            }
        }
    }

    enum Unit: String, Codable, CaseIterable, Identifiable, Sendable {
        case books, megabytes, gigabytes

        var id: Self { self }

        var label: String {
            switch self {
            case .books: "Books"
            case .megabytes: "MB"
            case .gigabytes: "GB"
            }
        }
    }

    var scope = Scope.off
    var unit = Unit.books
    var limit = 50

    fileprivate var capacity: Int64 {
        let quantity = Int64(max(1, min(100_000, limit)))
        switch unit {
        case .books: return quantity
        case .megabytes: return quantity * 1_000_000
        case .gigabytes: return quantity * 1_000_000_000
        }
    }

    fileprivate func includes(_ plus: Bool) -> Bool { scope == .all || (scope == .plus && plus) }
}

nonisolated struct DownloadMeter: Sendable {
    let pacer: DownloadPacer
    let settings: DownloadPacing
    let job: UUID
}

actor DownloadPacer {
    nonisolated struct Deferred: Error {
        let until: Date
    }

    private nonisolated struct Entry: Codable, Sendable {
        let job: UUID
        let date: Date
        let plus: Bool
        let books: Int64
        let bytes: Int64
    }

    private nonisolated struct Reservation: Sendable {
        let job: UUID
        let plus: Bool
        let enforcesLimit: Bool
    }

    private enum StoreError: LocalizedError {
        case read, write

        var errorDescription: String? {
            switch self {
            case .read: "DownAudible couldn’t read its daily download usage. Check the application data folder."
            case .write: "DownAudible couldn’t save its daily download usage. Check the application data folder."
            }
        }
    }

    private let file: URL
    private var entries: [Entry]?
    private var unreadable = false
    private var reserved: [UUID: Reservation] = [:]

    init(file: URL = URL.applicationSupportDirectory.appending(path: "DownAudible/DownloadUsage.json")) {
        self.file = file
    }

    func begin(_ settings: DownloadPacing, job: UUID, plus: Bool, now: Date = .now) throws -> UUID? {
        let cutoff = now.addingTimeInterval(-86_400)
        if entries == nil {
            do {
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
            } catch CocoaError.fileReadNoSuchFile {
                entries = []
            } catch {
                entries = []
                unreadable = true
            }
        }
        let recent = (entries ?? []).filter { $0.date > cutoff }
        entries = recent
        let applies = settings.includes(plus)
        if applies {
            guard !unreadable else { throw StoreError.read }
            try check(settings, job: job, recent: recent, now: now)
        }
        let permit = UUID()
        reserved[permit] = Reservation(job: job, plus: plus, enforcesLimit: applies)
        return permit
    }

    func complete(_ permit: UUID?, bytes: Int64, now: Date = .now) throws {
        guard let permit, let reservation = reserved.removeValue(forKey: permit), bytes > 0 else { return }
        var recent = (entries ?? []).filter { $0.date > now.addingTimeInterval(-86_400) }
        let first = !recent.contains { $0.job == reservation.job && $0.books == 1 }
        recent.append(Entry(job: reservation.job, date: now, plus: reservation.plus, books: first ? 1 : 0, bytes: bytes))
        entries = recent
        guard !unreadable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recent).write(to: file, options: .atomic)
        } catch {
            if reservation.enforcesLimit { throw StoreError.write }
        }
    }

    func release(_ permit: UUID?) {
        if let permit { reserved.removeValue(forKey: permit) }
    }

    private func check(_ settings: DownloadPacing, job: UUID, recent: [Entry], now: Date) throws {
        let byBook = settings.unit == .books
        if byBook, recent.contains(where: { $0.job == job && $0.books == 1 }) { return }
        let active = reserved.values.count { settings.includes($0.plus) }
        let counted = recent.filter { settings.includes($0.plus) }.sorted { $0.date < $1.date }
        let quantities = counted.map { max(0, byBook ? $0.books : $0.bytes) }
        var total = quantities.reduce(0, +)
        if total >= settings.capacity {
            for (entry, quantity) in zip(counted, quantities) {
                total -= quantity
                if total < settings.capacity { throw Deferred(until: entry.date.addingTimeInterval(86_400)) }
            }
        }
        if active > 0 && (!byBook || total + Int64(active) >= settings.capacity) {
            throw Deferred(until: now.addingTimeInterval(1))
        }
    }
}
