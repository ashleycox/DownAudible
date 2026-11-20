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
        let supported = urls.filter(supports)
        guard !supported.isEmpty else { throw Issue.unsupportedFiles }
        let files = supported.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { throw Issue.missingFiles }
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") else {
            throw Issue.unavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = true
        do {
            _ = try await workspace.open(files, withApplicationAt: app, configuration: configuration)
        } catch {
            try Task.checkCancellation()
            throw Issue.openFailed
        }
    }

    private enum Issue: LocalizedError {
        case unsupportedFiles, missingFiles, unavailable, openFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFiles: "Choose a supported audio file or convert it to M4B before sending it to Books."
            case .missingFiles: "The audio files are missing. Reconnect their drive or locate the files in Finder."
            case .unavailable: "DownAudible couldn’t find the Books app on this Mac."
            case .openFailed: "DownAudible couldn’t open the files in Books. Open Books and try importing the audio from Finder."
            }
        }
    }
}
