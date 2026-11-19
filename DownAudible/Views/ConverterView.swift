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
                    Button("Add Files…", action: pickFiles).disabled(model.isPreparingFiles)
                    Button("Add Folder…", action: pickFolder).disabled(model.isPreparingFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filesTable
            }

            Divider()

            Form {
                DestinationPicker(directory: $model.outputDirectory)
                HStack(spacing: 8) {
                    Picker("Format", selection: $model.conversionPreferences.format) {
                        ForEach(ConversionFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .fixedSize()
                    Text(model.conversionPreferences.chapterMode.displayName)
                        .foregroundStyle(.secondary)
                    Button("Conversion Options…") { showingOptions = true }
                }
                if model.localFiles.contains(where: { $0.format == "aax" }) {
                    SecureField("Activation bytes (optional)", text: $model.activationBytes)
                        .textFieldStyle(.roundedBorder)
                        .help("Enter eight hexadecimal characters from the Audible account that downloaded these files, or leave this blank to use the active account.")
                    if !model.hasValidActivationBytes {
                        Text("Enter eight hexadecimal characters.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)

            HStack {
                if model.isPreparingFiles {
                    ProgressView().controlSize(.small)
                    Text("Reading audio files…").foregroundStyle(.secondary)
                } else if !model.selectedFiles.isEmpty {
                    Text("\(model.selectedFiles.count) selected").foregroundStyle(.secondary)
                }

                Spacer()

                Button(commandContext.convertTitle, action: commandContext.convert)
                    .buttonStyle(.borderedProminent)
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
                Menu {
                    Button("Add Files…", action: pickFiles)
                    Button("Add Folder…", action: pickFolder)
                } label: {
                    Label("Add Audio", systemImage: "plus")
                }
                .help("Add audio files or a folder")
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
                }
                .padding(12)
            }
            .frame(width: 520, height: 460)
        }
    }

    private var filesTable: some View {
        Table(model.localFiles.sorted(using: sortOrder), selection: $model.selectedFiles, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { file in
                Text(file.title).help(file.url.path(percentEncoded: false))
            }
            TableColumn("Author") { file in
                Text(file.author ?? "—")
                    .foregroundStyle(file.author == nil ? .secondary : .primary)
            }
            TableColumn("Format", value: \.format) { file in
                Text(file.format.uppercased()).foregroundStyle(.secondary)
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
    var convertTitle: LocalizedStringKey { ids.isEmpty ? "Convert All" : "Convert Selected" }
    var canConvert: Bool {
        !model.isTransferring && !model.isPreparingFiles && model.hasValidActivationBytes && model.layout.isValid
            && !(ids.isEmpty ? model.localFiles : files).isEmpty
    }

    func convert() { model.startConversion(ids.isEmpty ? model.localFiles : files) }

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
            .disabled(!context.canConvert || (!inMenuBar && files.isEmpty))

        if inMenuBar || !urls.isEmpty {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                .keyboardShortcut(shortcut("s"))
                .disabled(urls.isEmpty)
            if inMenuBar || canAddToBooks {
                Button("Add to Apple Books") { Task { await context.model.addToAppleBooks(urls) } }
                    .keyboardShortcut(shortcut("b"))
                    .disabled(!canAddToBooks)
            }
            Button("Copy Path") { copyPaths(urls) }
                .keyboardShortcut(shortcut("c"))
                .disabled(urls.isEmpty)
        }
        Divider()
        Button("Remove from List") { context.removeFiles(Set(files.map(\.id))) }
            .keyboardShortcut(shortcut(.delete))
            .disabled(files.isEmpty)
        Button("Clear List") { context.removeFiles(Set(allFiles.map(\.id))) }
            .keyboardShortcut(shortcut("k"))
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
