import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum Panels {
    private static let extensions = ["aax", "aaxc", "aa", "mp3", "m4a", "m4b"]

    static func openFolder(allowCreation: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = allowCreation
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
                Label {
                    Text(directory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .help(directory.path(percentEncoded: false))
                Button("Choose…") {
                    if let selected = Panels.openFolder(allowCreation: true) { directory = selected }
                }
                .fixedSize()
                .keyboardShortcut("y", modifiers: [.control, .shift])
                .accessibilityLabel("Choose destination folder")
            }
        }
    }
}

extension ArchiveLayout {
    func previewPath(
        for book: ArchiveTitle, format: String, chapterNumber: Int? = nil,
        chapterTitle: String? = nil, folderOnly: Bool = false
    ) -> String? {
        guard let location = try? directory(
            for: book, format: format, chapterNumber: chapterNumber, chapterTitle: chapterTitle
        ) else { return nil }
        let baseURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let folders = Array(location.pathComponents.dropFirst(baseURL.pathComponents.count))
        if folderOnly { return folders.joined(separator: "/") + "/" }

        let stem = filenameStem(for: book, format: format, chapterNumber: chapterNumber, chapterTitle: chapterTitle)
        let suffix = "." + format
        let budget = min(filenameLength, 255) - suffix.utf8.count
        guard budget >= "Unknown".utf8.count else { return nil }
        let filename = Self.filename(stem, maxBytes: budget) + suffix
        return (folders + [filename]).joined(separator: "/")
    }
}

enum DownAudibleLinks {
    static let repository = URL(string: "https://github.com/ashleycox/DownAudible")!
    static let website = URL(string: "https://ashleycox.co.uk")!
    static let donation = URL(string: "https://www.paypal.com/donate/?hosted_button_id=WMLX4PLED9PRE")!
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("DownAudible")
                .font(.title2.bold())
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
            }
            Link("Developed by Ashley Cox", destination: DownAudibleLinks.website)
                .keyboardShortcut("w", modifiers: [.control, .shift])
                .padding(.top, 8)
            Link("View on GitHub", destination: DownAudibleLinks.repository)
                .keyboardShortcut("g", modifiers: [.control, .shift])
            Divider()
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("If this app has helped you, a donation is one way to support my work. There’s no pressure or hard sell. DownAudible is and always will be free.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("Make a donation", destination: DownAudibleLinks.donation)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 380)
    }
}
