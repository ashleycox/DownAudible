import Foundation

@main
struct ArchiveChecks {
    static func main() async throws {
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: workspace) }
        let root = workspace.appending(path: "Books")
        let outside = workspace.appending(path: "Other")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let title = ArchiveTitle(title: "My Great Book", author: "Me", asin: "B000000001")
        let layout = ArchiveLayout(root: root, template: ArchiveLayout.defaultTemplate)
        check(try layout.directory(for: title, format: "aax").path.hasSuffix("/aax/Me/My Great Book"))
        check(try layout.directory(for: title, format: "m4b").path.hasSuffix("/m4b/Me/My Great Book"))
        check(!ArchiveLayout(root: root, template: "../{title}").isValid)
        check(!ArchiveLayout(root: root, template: "{typo}").isValid)
        let literal = ArchiveTitle(title: "{author}/Book", author: "Name/Name", asin: nil)
        check(try layout.directory(for: literal, format: "m4b").path.hasSuffix("/m4b/Name-Name/{author}-Book"))
        try manager.createSymbolicLink(at: root.appending(path: "aax"), withDestinationURL: outside)
        do {
            _ = try layout.directory(for: title, format: "aax")
            fatalError("Archive path escaped through a symlink")
        } catch ArchiveError.outsideDestination {}
        check(FilenameStyle.asinOnly.name(for: title) == "B000000001")
        check(ArchiveLayout.filename(String(repeating: "é", count: 160), maxBytes: 75).utf8.count == 74)

        let previous = Data(#"{"convert":false,"keepOriginal":true,"downloadPDF":false,"downloadCover":true}"#.utf8)
        let options = try JSONDecoder().decode(DownloadOptions.self, from: previous)
        check(options.savesOriginal && options.downloadAudio && options.downloadCover && !options.downloadChapters)

        let file = LocalAudioFile(url: root.appending(path: "Book.aax"), format: "aax", title: "Écho", author: "Me", asin: nil, durationSeconds: 10)
        check(LocalAudioIndex(files: [file]).match(title: "Echo", author: "me", asin: "B000000001") == file)
        check(LocalAudioIndex(files: [file, file]).match(title: "Echo", author: "me", asin: "B000000001") == nil)
        let book = try JSONDecoder().decode(AudibleBook.self, from: Data(#"{"asin":"B000000001","title":"One, \"Two\"","authors":["Me"],"narrators":[],"hasPDF":false,"isDownloadable":true}"#.utf8))
        let csv = workspace.appending(path: "Library.csv")
        try await LibraryExportFormat.csv.write([book], to: csv)
        check(try String(contentsOf: csv, encoding: .utf8).contains("\"One, \"\"Two\"\"\""))

        var preferences = TransferPreferences()
        preferences.logLevel = .errors
        let logFile = workspace.appending(path: "Transfers.txt")
        preferences.logFile = logFile
        var transfer = Transfer(title: "Me\nTest")
        transfer.status = .failed("Test")
        let log = TransferLog()
        try await log.record(transfer, preferences: preferences)
        try await log.record(transfer, preferences: preferences)
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        check(contents.split(separator: "\n").count == 2 && contents.contains("Me Test\tFailed: Test"))
        print("Archive paths, matching, preference migration, CSV export, and transfer logs passed.")
    }

    static func check(_ condition: Bool, line: UInt = #line) {
        precondition(condition, "Verification failed at line \(line)")
    }
}
