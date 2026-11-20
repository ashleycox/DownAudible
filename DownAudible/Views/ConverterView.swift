import AppKit
import SwiftUI

struct ConverterView: View {
    @Bindable var model: WorkspaceModel
    @Binding var showingOptions: Bool
    @State private var sortOrder = [KeyPathComparator(\LocalAudioFile.title, comparator: .localizedStandard)]

    var body: some View {
        VStack(spacing: 0) {
            if model.localFiles.isEmpty {
                ContentUnavailableView {
                    Label("Convert Audio Files", systemImage: "waveform")
                } description: {
                    Text("Choose an audio file or folder, or drag files here from Finder.")
                } actions: {
                    Button("Add Files…", systemImage: "plus", action: pickFiles)
                        .appHelp("Choose one or more audio files to add to the conversion list.")
                        .disabled(model.isPreparingFiles)
                    Button("Add Folder…", systemImage: "folder", action: pickFolder)
                        .appHelp("Scan a folder and its subfolders for supported audio files.")
                        .disabled(model.isPreparingFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filesTable
            }

            Divider()

            Form {
                DestinationPicker(directory: $model.outputDirectory)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        formatPicker
                        Spacer(minLength: 0)
                        conversionOptions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        formatPicker
                        conversionOptions
                    }
                }
                if model.localFiles.contains(where: { $0.format == "aax" }) {
                    SecureField("Activation bytes (optional)", text: $model.activationBytes)
                        .textFieldStyle(.roundedBorder)
                        .appHelp("Enter eight hexadecimal characters from the Audible account that downloaded these files, or leave this blank to use the active account.")
                    if !model.hasValidActivationBytes {
                        Text("Enter eight hexadecimal characters.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.columns)
            .padding(12)

            HStack {
                if model.isPreparingFiles {
                    ProgressView().controlSize(.small)
                        .appHelp("DownAudible is checking the audio files you added.")
                    Text("Reading audio files…").foregroundStyle(.secondary)
                } else if !model.selectedFiles.isEmpty {
                    Text("\(model.selectedFiles.count) selected").foregroundStyle(.secondary)
                }

                Spacer()

                Button(commandContext.convertTitle, action: commandContext.convert)
                    .buttonStyle(.borderedProminent)
                    .appHelp(commandContext.conversionHelp)
                    .disabled(!commandContext.canConvert)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .focusedSceneValue(\.conversionCommands, commandContext)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !model.isPreparingFiles, !files.isEmpty else { return false }
            Task { await model.addFiles(at: files) }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Menu("Add Audio", systemImage: "plus") {
                    Button("Add Files…", systemImage: "doc.badge.plus", action: pickFiles)
                        .appHelp("Choose one or more audio files to add to the conversion list.")
                    Button("Add Folder…", systemImage: "folder", action: pickFolder)
                        .appHelp("Scan a folder and its subfolders for supported audio files.")
                }
                .appHelp("Add audio files or a folder")
                .disabled(model.isPreparingFiles)
            }
        }
        .sheet(isPresented: $showingOptions) {
            VStack(spacing: 0) {
                Form {
                    ConversionPreferencesView(preferences: $model.conversionPreferences)
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingOptions = false }
                        .keyboardShortcut(.defaultAction)
                        .appHelp("Close Conversion Options and return to the audio files.")
                }
                .padding(12)
            }
            .frame(minWidth: 416, idealWidth: 520, minHeight: 320, idealHeight: 460)
        }
    }

    private var formatPicker: some View {
        Picker("Format", selection: $model.conversionPreferences.format) {
            ForEach(ConversionFormat.allCases) { format in
                Text(format.displayName).tag(format)
            }
        }
        .fixedSize()
        .appHelp("Choose the file type for the converted audio.")
    }

    private var conversionOptions: some View {
        HStack(spacing: 8) {
            Text(model.conversionPreferences.chapterMode.displayName)
                .foregroundStyle(.secondary)
            Button("Conversion Options…", systemImage: "slider.horizontal.3") { showingOptions = true }
                .appHelp("Choose how to split, encode, and tag the converted audio.")
        }
    }

    private var filesTable: some View {
        Table(model.localFiles.sorted(using: sortOrder), selection: $model.selectedFiles, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { file in
                Text(file.title).appHelp(file.url.path(percentEncoded: false))
            }
            .width(min: 132, ideal: 260)
            TableColumn("Author") { file in
                Text(file.author ?? "—")
                    .foregroundStyle(file.author == nil ? .secondary : .primary)
                    .appHelp(file.author ?? "This audio file has no author tag.")
            }
            .width(min: 88, ideal: 150)
            TableColumn("Format", value: \.format) { file in
                Text(file.format.uppercased())
                    .foregroundStyle(.secondary)
                    .appHelp("The source file uses the \(file.format.uppercased()) format.")
            }
            .width(min: 64, ideal: 72, max: 90)
        }
        .contextMenu(forSelectionType: LocalAudioFile.ID.self) { ids in
            ConversionActions(context: ConversionCommandContext(model: model, ids: ids))
        }
    }

    private var commandContext: ConversionCommandContext {
        ConversionCommandContext(model: model, ids: model.selectedFiles)
    }

    private func pickFiles() {
        let files = Panels.openAudio(allowFolders: false)
        if !files.isEmpty { Task { await model.addFiles(at: files) } }
    }

    private func pickFolder() {
        if let folder = Panels.openFolder() { Task { await model.addFiles(at: [folder]) } }
    }
}

extension FocusedValues {
    @Entry fileprivate var conversionCommands: ConversionCommandContext?
}

struct ConversionSelectionCommands: View {
    @FocusedValue(\.conversionCommands) private var context
    let showOptions: () -> Void

    var body: some View {
        Button("Conversion Options…", action: showOptions)
            .keyboardShortcut(context == nil ? nil : KeyboardShortcut("o", modifiers: [.control, .shift]))
            .appHelp("Open the conversion settings for audio files.")

        if let context {
            Divider()
            ConversionActions(context: context, inMenuBar: true)
        }
    }
}

@MainActor
private struct ConversionCommandContext {
    let model: WorkspaceModel
    let ids: Set<LocalAudioFile.ID>

    var files: [LocalAudioFile] { model.localFiles.filter { ids.contains($0.id) } }
    private var conversionFiles: [LocalAudioFile] { ids.isEmpty ? model.localFiles : files }
    var convertTitle: LocalizedStringKey { ids.isEmpty ? "Convert All" : "Convert Selected" }
    var conversionHelp: String {
        ids.isEmpty ? "Convert every audio file in the list." : "Convert the selected audio files."
    }
    var canConvert: Bool {
        guard model.didRestoreTransfers, !model.isTransferring, !model.isPreparingFiles, model.layout.isValid else { return false }
        let inputs = conversionFiles
        return !inputs.isEmpty && (model.hasValidActivationBytes || !inputs.contains { $0.format == "aax" })
    }

    func convert() { model.startConversion(conversionFiles) }

    func removeFiles(_ ids: Set<LocalAudioFile.ID>) {
        model.selectedFiles = ids
        model.removeSelectedFiles()
    }
}

private struct ConversionActions: View {
    let context: ConversionCommandContext
    var inMenuBar = false

    var body: some View {
        let files = context.files
        let urls = files.map(\.url)
        let canAddToBooks = urls.contains(where: AppleBooks.supports)
        let allFiles = context.model.localFiles

        Button(inMenuBar ? context.convertTitle : "Convert", action: context.convert)
            .keyboardShortcut(shortcut("v"))
            .appHelp(context.conversionHelp)
            .disabled(!context.canConvert || (!inMenuBar && files.isEmpty))

        if inMenuBar || !urls.isEmpty {
            Divider()
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                .keyboardShortcut(shortcut("s"))
                .appHelp("Select the source files in Finder.")
                .disabled(urls.isEmpty)
            if inMenuBar || canAddToBooks {
                Button("Add to Apple Books", systemImage: "book") { Task { await context.model.addToAppleBooks(urls) } }
                    .keyboardShortcut(shortcut("b"))
                    .appHelp("Open the selected audio files in Apple Books.")
                    .disabled(!canAddToBooks)
            }
            Button("Copy Path", systemImage: "doc.on.doc") { copyPaths(urls) }
                .keyboardShortcut(shortcut("c"))
                .appHelp("Copy the locations of the selected files to the clipboard.")
                .disabled(urls.isEmpty)
        }
        Divider()
        Button("Remove from List", systemImage: "minus.circle") { context.removeFiles(Set(files.map(\.id))) }
            .keyboardShortcut(shortcut(.delete))
            .appHelp("Take the selected files out of the conversion list.")
            .disabled(files.isEmpty)
        Button("Clear List") { context.removeFiles(Set(allFiles.map(\.id))) }
            .keyboardShortcut(shortcut("k"))
            .appHelp("Empty the conversion list.")
            .disabled(allFiles.isEmpty)
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        inMenuBar ? KeyboardShortcut(key, modifiers: [.control, .shift]) : nil
    }

    private func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
    }
}
