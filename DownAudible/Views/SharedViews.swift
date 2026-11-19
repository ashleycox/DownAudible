import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum Panels {
    private static let extensions = ["aax", "aaxc", "aa", "mp3"]

    static func openFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openAudio(allowFolders: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = allowFolders
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = extensions.map {
            UTType(filenameExtension: $0) ?? .data
        }
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

struct DestinationPicker: View {
    @Binding var directory: URL

    var body: some View {
        LabeledContent("Save to") {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(directory.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(directory.path(percentEncoded: false))
                Button("Choose…") {
                    if let selected = Panels.openFolder() { directory = selected }
                }
                .accessibilityLabel("Choose destination folder")
            }
        }
    }
}

struct AboutView: View {
    private let repository = URL(string: "https://github.com/ashleycox/DownAudible")!
    private let website = URL(string: "https://ashleycox.co.uk")!

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("DownAudible")
                .font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .foregroundStyle(.secondary)
            Link("Developed by Ashley Cox", destination: website)
                .padding(.top, 8)
            Link("View on GitHub", destination: repository)
        }
        .padding(32)
        .frame(minWidth: 300)
    }
}
