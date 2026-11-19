import AppKit

enum AppleBooksDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, original, m4b

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .original: "Original Audible file"
        case .m4b: "M4B"
        }
    }
}

@MainActor
enum AppleBooks {
    static func supports(_ url: URL) -> Bool {
        ["aax", "aaxc", "aa", "m4b", "m4a", "mp3"].contains(url.pathExtension.lowercased())
    }

    static func open(_ urls: [URL], activate: Bool) async throws {
        let files = urls.filter { supports($0) && FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { throw Issue.noPlayableFiles }
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") else {
            throw Issue.unavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = true
        _ = try await workspace.open(files, withApplicationAt: app, configuration: configuration)
    }

    private enum Issue: LocalizedError {
        case noPlayableFiles, unavailable

        var errorDescription: String? {
            switch self {
            case .noPlayableFiles: "Choose an audio file that still exists."
            case .unavailable: "DownAudible couldn’t find the Books app on this Mac."
            }
        }
    }
}
