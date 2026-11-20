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
            .appHelp("Choose M4B for audiobook players, M4A for general audio players, or MP3 for broad compatibility.")
            Picker("Chapters", selection: $preferences.chapterMode) {
                ForEach(ConversionChapterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .appHelp("Save one audio file for the book or a separate file for each chapter.")
            if preferences.chapterMode == .single {
                Toggle("Keep chapter markers", isOn: $preferences.embedChapters)
                    .appHelp("Add chapter navigation to the converted audio when chapter information is available.")
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
                .appHelp("Copy compatible original audio or always encode a new audio stream.")
            } else if preferences.format != .mp3 {
                Toggle("Copy chapter audio when possible", isOn: $preferences.copyChapterAudio)
                    .disabled(!preferences.canCopyChapterAudio)
                    .appHelp("Split compatible AAC audio into chapter files without encoding it again.")
            }
            if preferences.format == .mp3 {
                Picker("Bitrate mode", selection: $preferences.mp3BitrateMode) {
                    ForEach(MP3BitrateMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .appHelp("Choose automatic, constant, or variable bitrate for MP3 exports.")
            }
            if preferences.format == .mp3 && preferences.mp3BitrateMode == .variable {
                Picker("Quality", selection: $preferences.mp3Quality) {
                    ForEach(MP3Quality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .appHelp("Choose the quality of variable-bitrate MP3 audio.")
            } else {
                Picker("Bitrate", selection: $preferences.bitrate) {
                    ForEach(ConversionBitrate.allCases) { bitrate in
                        Text(bitrate.displayName).tag(bitrate)
                    }
                }
                .appHelp("Choose how much data each second of encoded audio uses.")
            }
            Picker("Channels", selection: $preferences.channels) {
                ForEach(ConversionChannels.allCases) { channels in
                    Text(channels.displayName).tag(channels)
                }
            }
            .appHelp("Keep source channels or encode the audio as mono or stereo.")
            Picker("Sample rate", selection: $preferences.sampleRate) {
                ForEach(ConversionSampleRate.allCases) { rate in
                    Text(rate.displayName).tag(rate)
                }
            }
            .appHelp("Keep the source sampling rate or choose one for your audio player.")
        } header: {
            Text("Audio")
        } footer: {
            if preferences.hasIncompatibleBitrate {
                Text("Choose a lower bitrate or a higher sample rate.")
            } else if preferences.canCopyChapterAudio && preferences.copyChapterAudio {
                Text("Compatible chapters keep their original audio. Some players may play extra audio at a chapter boundary.")
            } else if preferences.chapterMode == .separate && preferences.format != .mp3 && !preferences.canCopyChapterAudio {
                Text("Set bitrate to Automatic and match the source channels and sample rate to copy chapter audio.")
            } else if preferences.chapterMode == .separate {
                Text("DownAudible encodes separate files so each one starts at its chapter marker.")
            } else if preferences.audioMode == .automatic {
                Text("Custom audio settings encode the audio.")
            }
        }

        Section("Book Details") {
            Toggle("Keep book metadata", isOn: $preferences.preserveMetadata)
                .appHelp("Write book details such as title, author, and narrator into the converted file.")
            Toggle("Embed cover image", isOn: $preferences.embedArtwork)
                .appHelp("Include the cover image in the converted audio file.")
        }

        if preferences.format == .mp3 {
            Section {
                Toggle("Move converted AAX files to Trash", isOn: $preferences.moveAAXToTrash)
                    .appHelp("Move the AAX source to the Mac’s Trash after the complete MP3 export is saved.")
            } header: {
                Text("Original Files")
            } footer: {
                Text("Applies to AAX files queued in Convert Files and saved DownAudible originals when Keep the original after conversion is off. The MP3 export must finish before the source moves to Trash.")
            }
        }
    }
}
