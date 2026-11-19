import Foundation

struct AudioEncoding: Sendable {
    let copiesAudio: Bool
    let channels: Int
    let sampleRate: Int
    let arguments: [String]

    init(
        preferences: ConversionPreferences, probes: [AudioProbe],
        slicing: Bool, containsLegacyAudio: Bool
    ) throws {
        let format = preferences.format
        let streams = probes.compactMap(\.audio)
        let sourceChannels = streams.compactMap(\.channels).max() ?? 1
        channels = preferences.channels == .automatic
            ? min(format.maximumChannels, sourceChannels)
            : preferences.channels.rawValue

        let rates = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
            + (format == .mp3 ? [] : [64_000, 88_200, 96_000])
        let sourceRate = streams.compactMap { $0.sampleRate.flatMap(Int.init) }.max() ?? 44_100
        let preferredRate = rates.first { $0 >= sourceRate } ?? (format == .mp3 ? 48_000 : 96_000)
        let variableMP3 = format == .mp3 && preferences.mp3BitrateMode == .variable
        let customMP3Mode = format == .mp3 && preferences.mp3BitrateMode != .automatic
        let explicitBitrate = variableMP3 ? 0 : preferences.bitrate.rawValue
        let passthrough = preferences.audioMode == .automatic && !slicing && !containsLegacyAudio
            && explicitBitrate == 0 && !customMP3Mode
            && preferences.channels == .automatic && preferences.sampleRate == .automatic

        if passthrough, let first = streams.first, first.codecName == format.codecName,
           streams.allSatisfy({ $0.concatParameters == first.concatParameters }) {
            copiesAudio = true
            sampleRate = preferredRate
            arguments = ["-c:a", "copy"]
            return
        }

        copiesAudio = false
        let outputChannels = channels
        let limits = { sampleRate in format.maximumBitrate(at: sampleRate, channels: outputChannels) }
        if preferences.sampleRate != .automatic {
            sampleRate = preferences.sampleRate.rawValue
        } else if explicitBitrate > limits(preferredRate) {
            guard let compatibleRate = rates.first(where: { $0 >= preferredRate && limits($0) >= explicitBitrate }) else {
                throw MediaError.incompatibleAudioSettings
            }
            sampleRate = compatibleRate
        } else {
            sampleRate = preferredRate
        }
        guard explicitBitrate <= limits(sampleRate) else { throw MediaError.incompatibleAudioSettings }

        var arguments = [
            "-c:a", format == .mp3 ? "libmp3lame" : "aac",
            "-ar", String(sampleRate), "-ac", String(channels)
        ]
        if variableMP3 {
            arguments += ["-q:a", String(preferences.mp3Quality.rawValue)]
        } else {
            let defaultBitrate = channels == 1 ? 64 : 128
            let bitrate = explicitBitrate > 0 ? explicitBitrate : min(defaultBitrate, limits(sampleRate))
            arguments += ["-b:a", "\(bitrate)k"]
        }
        self.arguments = arguments
    }
}
