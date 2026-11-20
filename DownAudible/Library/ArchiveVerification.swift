import Foundation

struct ArchiveVerificationIssue: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case missing, incomplete, unreadable

        var title: String {
            switch self {
            case .missing: "Missing audio"
            case .incomplete: "Incomplete audio"
            case .unreadable: "Unreadable audio"
            }
        }
    }

    let book: AudibleBook
    let kind: Kind
    let files: [URL]

    var id: AudibleBook.ID { book.id }
    var canRepair: Bool { book.isDownloadable }
}

struct ArchiveVerificationReport {
    let accountID: UUID
    let layout: ArchiveLayout
    let checkedCount: Int
    let issues: [ArchiveVerificationIssue]
}

enum ArchiveVerificationError: LocalizedError {
    case folderUnavailable, archiveChanged, transfersRunning

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            "DownAudible can’t open the archive folder. Reconnect its drive or check the destination in Settings > Files."
        case .archiveChanged:
            "The account or archive destination changed. Verify the archive again before starting a repair."
        case .transfersRunning:
            "Wait for the current transfers to finish, then try again."
        }
    }
}

struct ArchiveAudioVerifier {
    private let ffmpeg: URL
    private let ffprobe: URL
    private let directory: URL
    private var readability: [URL: Bool] = [:]

    init(media: MediaTools, directory: URL) throws {
        ffmpeg = try media.executable(named: "ffmpeg")
        ffprobe = try media.executable(named: "ffprobe")
        self.directory = directory
    }

    mutating func problem(for file: URL, expectedSize: Int?) async throws -> ArchiveVerificationIssue.Kind? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .unreadable }
        guard let size = attributes[.size] as? Int, size > 0,
              expectedSize.map({ $0 == size }) ?? true else { return .incomplete }
        if readability[file] == nil { readability[file] = try await canRead(file) }
        return readability[file] == true ? nil : .unreadable
    }

    private func canRead(_ file: URL) async throws -> Bool {
        do {
            switch file.pathExtension.lowercased() {
            case "aa", "aax", "aaxc":
                // These files can be inspected without asking for account credentials.
                let probe = try await MediaTools.probe(
                    file, options: [], ffprobe: ffprobe, directory: directory, metadataOnly: true
                )
                return (probe.durationMilliseconds ?? 0) > 0
            default:
                let command = ["-nostdin", "-v", "error", "-xerror"]
                    + MediaTools.audioInput(file, options: [])
                    + ["-map", "0:a:0", "-vn", "-sn", "-dn", "-f", "null", "-"]
                let (status, _, diagnostic) = try await MediaProcess.run(
                    ffmpeg, arguments: command, workingDirectory: directory
                )
                return status == 0 && diagnostic.isEmpty
            }
        } catch is MediaError {
            return false
        }
    }
}
