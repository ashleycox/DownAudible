import Foundation

struct ConversionPreferences: Codable, Hashable, Sendable {
    var format = ConversionFormat.m4b
    var chapterMode = ConversionChapterMode.single
    var audioMode = ConversionAudioMode.automatic
    var bitrate = ConversionBitrate.automatic
    var channels = ConversionChannels.automatic
    var sampleRate = ConversionSampleRate.automatic
    var mp3BitrateMode = MP3BitrateMode.automatic
    var mp3Quality = MP3Quality.high
    var embedArtwork = true
    var preserveMetadata = true
    var embedChapters = true

    var summary: String { "\(format.displayName) · \(chapterMode.displayName)" }

    var hasIncompatibleBitrate: Bool {
        guard sampleRate != .automatic, !(format == .mp3 && mp3BitrateMode == .variable) else { return false }
        let channelCount = channels == .automatic ? format.maximumChannels : channels.rawValue
        return bitrate.rawValue > format.maximumBitrate(at: sampleRate.rawValue, channels: channelCount)
    }

    var outputRecipe: Self {
        var recipe = self
        if format != .mp3 { recipe.mp3BitrateMode = .automatic }
        if recipe.mp3BitrateMode != .variable {
            recipe.mp3Quality = .high
        } else {
            recipe.bitrate = .automatic
        }
        if chapterMode == .separate {
            recipe.embedChapters = false
            recipe.audioMode = .encode
        }
        return recipe
    }
}

enum ConversionFormat: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case m4b, m4a, mp3

    var id: Self { self }
    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }
    var codecName: String { self == .mp3 ? "mp3" : "aac" }
    var muxer: String { self == .mp3 ? "mp3" : "ipod" }
    var maximumChannels: Int { self == .mp3 ? 2 : 6 }

    func maximumBitrate(at sampleRate: Int, channels: Int) -> Int {
        if self == .mp3 {
            return sampleRate >= 32_000 ? 320 : (sampleRate >= 16_000 ? 160 : 64)
        }
        // AAC allows up to 6,144 bits per channel per 1,024-sample frame.
        return sampleRate * channels * 6 / 1_000
    }
}

enum ConversionChapterMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case single, separate

    var id: Self { self }
    var displayName: String {
        switch self {
        case .single: "One file"
        case .separate: "Separate chapter files"
        }
    }
}

enum ConversionAudioMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic, encode

    var id: Self { self }
    var displayName: String {
        switch self {
        case .automatic: "Copy audio when possible"
        case .encode: "Always encode"
        }
    }
}

enum ConversionBitrate: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic = 0
    case kbps32 = 32
    case kbps48 = 48
    case kbps64 = 64
    case kbps80 = 80
    case kbps96 = 96
    case kbps112 = 112
    case kbps128 = 128
    case kbps160 = 160
    case kbps192 = 192
    case kbps224 = 224
    case kbps256 = 256
    case kbps320 = 320

    var id: Self { self }
    var displayName: String { self == .automatic ? "Automatic" : "\(rawValue) kbps" }
}

enum ConversionChannels: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic = 0
    case mono = 1
    case stereo = 2

    var id: Self { self }
    var displayName: String {
        switch self {
        case .automatic: "Match source"
        case .mono: "Mono"
        case .stereo: "Stereo"
        }
    }
}

enum ConversionSampleRate: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic = 0
    case hz8000 = 8_000
    case hz11025 = 11_025
    case hz12000 = 12_000
    case hz16000 = 16_000
    case hz22050 = 22_050
    case hz24000 = 24_000
    case hz32000 = 32_000
    case hz44100 = 44_100
    case hz48000 = 48_000

    var id: Self { self }
    var displayName: String {
        guard self != .automatic else { return "Match source" }
        let kiloHertz = Double(rawValue) / 1_000
        return "\(kiloHertz.formatted(.number.precision(.fractionLength(0...3)))) kHz"
    }
}

enum MP3BitrateMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic, constant, variable

    var id: Self { self }
    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .constant: "Constant (CBR)"
        case .variable: "Variable (VBR)"
        }
    }
}

enum MP3Quality: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case highest = 0
    case high = 2
    case medium = 4
    case small = 6
    case smallest = 8

    var id: Self { self }
    var displayName: String {
        switch self {
        case .highest: "Highest quality (V0)"
        case .high: "High quality (V2)"
        case .medium: "Medium quality (V4)"
        case .small: "Smaller file (V6)"
        case .smallest: "Smallest file (V8)"
        }
    }
}

struct ConversionOutput: Hashable, Sendable {
    let chapterNumber: Int?
    let chapterTitle: String?
}
