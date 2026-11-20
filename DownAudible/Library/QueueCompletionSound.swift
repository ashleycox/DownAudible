import AVFoundation
import Foundation

nonisolated struct QueueCompletionSound: Codable, Sendable {
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, system, builtIn, custom

        var id: Self { self }

        var displayName: String {
            switch self {
            case .off: "Off"
            case .system: "macOS Sound"
            case .builtIn: "Built-in Chime"
            case .custom: "Custom Audio File"
            }
        }
    }

    enum Chime: String, Codable, CaseIterable, Identifiable, Sendable {
        case softBell, risingNotes, warmChord
        case woodTap, fallingNotes, brightPing, gentlePulse, twoTone, airySweep, marimba

        var id: Self { self }

        var displayName: String {
            switch self {
            case .softBell: "Soft Bell"
            case .risingNotes: "Rising Notes"
            case .warmChord: "Warm Chord"
            case .woodTap: "Wood Tap"
            case .fallingNotes: "Falling Notes"
            case .brightPing: "Bright Ping"
            case .gentlePulse: "Gentle Pulse"
            case .twoTone: "Two Tone"
            case .airySweep: "Airy Sweep"
            case .marimba: "Marimba"
            }
        }

        fileprivate var resourceName: String { "Completion-\(rawValue)" }
    }

    struct CustomFile: Codable, Sendable {
        let id: UUID
        let name: String
        let fileExtension: String

        fileprivate var storageName: String {
            let suffix = fileExtension.lowercased()
            return suffix.isEmpty || !suffix.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
                ? id.uuidString
                : "\(id.uuidString).\(suffix)"
        }
    }

    var source = Source.off
    var systemName = "Glass"
    var chime = Chime.softBell
    var customFile: CustomFile?
}

nonisolated enum QueueSoundError: LocalizedError {
    case unreadableFile, cannotSaveFile, unavailable, playback

    var errorDescription: String? {
        switch self {
        case .unreadableFile: "Choose an audio file that DownAudible can play, such as a WAV, AIFF, M4A or MP3."
        case .cannotSaveFile: "DownAudible couldn’t save a copy of this sound in Application Support."
        case .unavailable: "The selected sound is unavailable. Choose another sound in Settings > Notifications."
        case .playback: "DownAudible couldn’t play the selected sound. Choose another sound or check your audio output."
        }
    }
}

@MainActor
final class QueueCompletionSoundPlayer: NSObject, AVAudioPlayerDelegate {
    nonisolated static let systemSounds: [URL] = {
        let directory = URL(filePath: "/System/Library/Sounds", directoryHint: .isDirectory)
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        )
        return (files ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            systemName(for: $0).localizedStandardCompare(systemName(for: $1)) == .orderedAscending
        }
    }()

    nonisolated static func systemName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    nonisolated private static var customDirectory: URL {
        URL.applicationSupportDirectory
            .appending(component: "DownAudible", directoryHint: .isDirectory)
            .appending(component: "CompletionSounds", directoryHint: .isDirectory)
    }

    private var player: AVAudioPlayer?
    private var pending: [QueueCompletionSound] = []

    func play(_ preference: QueueCompletionSound) throws {
        guard let next = try audioPlayer(for: preference) else { return }
        player?.stop()
        do {
            try start(next)
        } catch {
            playNext()
            throw error
        }
    }

    func enqueue(_ sounds: [QueueCompletionSound]) {
        pending.append(contentsOf: sounds.filter { $0.source != .off })
        playNext()
    }

    private func playNext() {
        guard player == nil else { return }
        while !pending.isEmpty {
            let sound = pending.removeFirst()
            if let next = try? audioPlayer(for: sound), (try? start(next)) != nil { return }
        }
    }

    private func start(_ next: AVAudioPlayer) throws {
        next.delegate = self
        player = next
        guard next.play() else {
            player = nil
            throw QueueSoundError.playback
        }
    }

    private func audioPlayer(for preference: QueueCompletionSound) throws -> AVAudioPlayer? {
        let url: URL?
        switch preference.source {
        case .off:
            return nil
        case .system:
            url = Self.systemSounds.first { Self.systemName(for: $0) == preference.systemName }
        case .builtIn:
            url = Bundle.main.url(forResource: preference.chime.resourceName, withExtension: "wav")
        case .custom:
            url = preference.customFile.map { Self.customDirectory.appending(component: $0.storageName) }
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw QueueSoundError.unavailable
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { throw QueueSoundError.playback }
        return player
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finished(ObjectIdentifier(player))
    }

    nonisolated private func finished(_ player: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == player else { return }
            self.player = nil
            playNext()
        }
    }

    @concurrent static func importCustomSound(from source: URL) async throws -> QueueCompletionSound.CustomFile {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }

        guard let attributes = try? source.resourceValues(forKeys: [.isRegularFileKey]),
              attributes.isRegularFile == true else { throw QueueSoundError.unreadableFile }
        let file = QueueCompletionSound.CustomFile(
            id: UUID(), name: source.lastPathComponent, fileExtension: source.pathExtension
        )
        let destination = customDirectory.appending(component: file.storageName)
        do {
            try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw QueueSoundError.cannotSaveFile
        }
        guard let check = try? AVAudioPlayer(contentsOf: destination), check.duration > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw QueueSoundError.unreadableFile
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        return file
    }

    nonisolated static func removeCustomSound(_ file: QueueCompletionSound.CustomFile) {
        try? FileManager.default.removeItem(at: customDirectory.appending(component: file.storageName))
    }
}
