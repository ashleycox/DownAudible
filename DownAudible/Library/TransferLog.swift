import Foundation

actor TransferLog {
    static let defaultURL = URL.applicationSupportDirectory
        .appending(component: "DownAudible", directoryHint: .isDirectory)
        .appending(component: "Transfers.log")

    func record(_ transfer: Transfer, preferences: TransferPreferences) throws {
        guard preferences.logLevel != .off else { return }
        let url = preferences.logFile ?? Self.defaultURL
        let details: String
        switch transfer.status {
        case .failed(let reason):
            details = "Failed: \(reason)"
        case .done(_, let note) where note != nil:
            details = "Completed with warnings: \(note ?? "")"
        case .done where preferences.logLevel == .results:
            details = "Completed"
        default:
            return
        }

        let title = transfer.title.components(separatedBy: .newlines).joined(separator: " ")
        let message = details.components(separatedBy: .newlines).joined(separator: " ")
        let line = Data("\(Date.now.ISO8601Format())\t\(title)\t\(message)\n".utf8)
        if preferences.logFile == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try line.write(to: url, options: .withoutOverwriting)
                return
            } catch CocoaError.fileWriteFileExists {
                // Another writer may have created the file.
            }
        }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
