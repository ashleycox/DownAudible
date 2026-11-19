import SwiftUI

struct GeneralPreferencesView: View {
    @Bindable var softwareUpdater: SoftwareUpdater

    var body: some View {
        Form {
            Section("Software Update") {
                Toggle("Check for updates automatically", isOn: $softwareUpdater.automaticallyChecksForUpdates)
                Toggle("Install updates automatically", isOn: $softwareUpdater.automaticallyDownloadsUpdates)
                    .disabled(!softwareUpdater.allowsAutomaticUpdates)
                Button("Check for Updates…", action: softwareUpdater.checkForUpdates)
                    .disabled(!softwareUpdater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }
}
