import SwiftUI

struct ConversionPreferencesView: View {
    @Binding var preferences: ConversionPreferences

    var body: some View {
        Section {
            Picker("File format", selection: $preferences.format) {
                ForEach(ConversionFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            Picker("Chapters", selection: $preferences.chapterMode) {
                ForEach(ConversionChapterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if preferences.chapterMode == .single {
                Toggle("Keep chapter markers", isOn: $preferences.embedChapters)
            }
        } header: {
            Text("Output")
        }

        Section {
            if preferences.chapterMode == .single {
                Picker("Encoding", selection: $preferences.audioMode) {
                    ForEach(ConversionAudioMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            if preferences.format == .mp3 {
                Picker("Bitrate mode", selection: $preferences.mp3BitrateMode) {
                    ForEach(MP3BitrateMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            if preferences.format == .mp3 && preferences.mp3BitrateMode == .variable {
                Picker("Quality", selection: $preferences.mp3Quality) {
                    ForEach(MP3Quality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
            } else {
                Picker("Bitrate", selection: $preferences.bitrate) {
                    ForEach(ConversionBitrate.allCases) { bitrate in
                        Text(bitrate.displayName).tag(bitrate)
                    }
                }
            }
            Picker("Channels", selection: $preferences.channels) {
                ForEach(ConversionChannels.allCases) { channels in
                    Text(channels.displayName).tag(channels)
                }
            }
            Picker("Sample rate", selection: $preferences.sampleRate) {
                ForEach(ConversionSampleRate.allCases) { rate in
                    Text(rate.displayName).tag(rate)
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            if preferences.hasIncompatibleBitrate {
                Text("Choose a lower bitrate or a higher sample rate.")
            } else if preferences.chapterMode == .separate {
                Text("DownAudible encodes separate files so each one starts at its chapter marker.")
            } else if preferences.audioMode == .automatic {
                Text("Custom audio settings encode the audio.")
            }
        }

        Section("Book Details") {
            Toggle("Keep book metadata", isOn: $preferences.preserveMetadata)
            Toggle("Embed cover image", isOn: $preferences.embedArtwork)
        }
    }
}
