import SwiftUI

struct GeneralPreferencesView: View {
    @Bindable var softwareUpdater: SoftwareUpdater
    @AppStorage(HelpTags.preferenceKey) private var showsHelpTags = true

    var body: some View {
        Form {
            Section("Software Update") {
                Toggle("Check for updates automatically", isOn: $softwareUpdater.automaticallyChecksForUpdates)
                    .appHelp("Periodically check for a new version of DownAudible.")
                Toggle("Install updates automatically", isOn: $softwareUpdater.automaticallyDownloadsUpdates)
                    .disabled(!softwareUpdater.allowsAutomaticUpdates)
                    .appHelp("Download updates in the background and install them when you quit DownAudible.")
                Button("Check for Updates…", action: softwareUpdater.checkForUpdates)
                    .disabled(!softwareUpdater.canCheckForUpdates)
                    .appHelp("Check for a new version now.")
            }

            Section("Interface") {
                Toggle("Show Tooltips", isOn: $showsHelpTags)
                    .appHelp("Show descriptions when you point to DownAudible controls.")
            }
        }
        .formStyle(.grouped)
    }
}
