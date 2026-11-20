import CryptoKit
import Foundation

enum IncompleteDownloads {
    private static let folderName = ".downaudible-incomplete"

    static func folder(for id: String, account: String, root: URL) -> URL {
        let identity = "\(account.utf8.count):\(account)\(id.utf8.count):\(id)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { byte in
            (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }.joined()
        return container(in: root).appending(component: key, directoryHint: .isDirectory)
    }

    static func folders(in root: URL) -> Set<String> {
        let container = container(in: root)
        guard (try? refuseLink(container)) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: container.path) else { return [] }
        return Set(names)
    }

    private static func container(in root: URL) -> URL {
        root.standardizedFileURL.resolvingSymlinksInPath()
            .appending(component: folderName, directoryHint: .isDirectory)
    }

    static func audioFolder(for id: String, account: String, root: URL, restart: Bool) throws -> URL {
        let folder = folder(for: id, account: account, root: root)
        let audio = folder.appending(component: "audio", directoryHint: .isDirectory)
        try check(folder)
        try refuseLink(audio)
        if restart, FileManager.default.fileExists(atPath: audio.path) {
            do {
                try FileManager.default.removeItem(at: audio)
            } catch {
                throw ArchiveError.storageFailure(error, otherwise: .cannotRestart)
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: audio, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ArchiveError.storageFailure(error, otherwise: .stagingUnavailable)
        }
        return audio
    }

    static func containsAudio(for id: String, account: String, root: URL) -> Bool {
        containsAudio(in: folder(for: id, account: account, root: root))
    }

    static func containsAudio(in folder: URL) -> Bool {
        let audio = folder.appending(component: "audio", directoryHint: .isDirectory)
        guard (try? check(folder)) != nil, (try? refuseLink(audio)) != nil,
              let files = try? FileManager.default.contentsOfDirectory(
                at: audio, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return false
        }
        let extensions: Set<String> = ["partial", "aax", "aaxc", "aa", "mp3"]
        return files.contains { url in
            guard extensions.contains(url.pathExtension.lowercased()),
                  let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else {
                return false
            }
            return info.isRegularFile == true && info.isSymbolicLink != true && (info.fileSize ?? 0) > 0
        }
    }

    static func clear(for id: String, account: String, root: URL) throws {
        let folder = folder(for: id, account: account, root: root)
        try check(folder)
        if FileManager.default.fileExists(atPath: folder.path) {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                throw ArchiveError.storageFailure(error, otherwise: .cannotClearStaging)
            }
        }
    }

    private static func check(_ folder: URL) throws {
        try refuseLink(folder.deletingLastPathComponent())
        try refuseLink(folder)
    }

    private static func refuseLink(_ directory: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil {
            throw ArchiveError.unsafeStaging
        }
    }
}
