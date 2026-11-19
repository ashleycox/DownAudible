import AppKit
import SwiftUI

struct ConverterView: View {
    @Bindable var model: WorkspaceModel
    @State private var showingOptions = false
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

                Button(model.selectedFiles.isEmpty ? "Convert All" : "Convert Selected") {
                    let files = model.selectedFiles.isEmpty ? model.localFiles : model.localFiles.filter {
                        model.selectedFiles.contains($0.id)
                    }
                    model.startConversion(files)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConvert || model.localFiles.isEmpty)
            }
            .padding([.horizontal, .bottom], 12)
        }
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
                    Button("Done") { showingOptions = false }.keyboardShortcut(.defaultAction)
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
            let files = model.localFiles.filter { ids.contains($0.id) }
            let urls = files.map(\.url)
            Button("Convert") { model.startConversion(files) }
                .disabled(!canConvert || files.isEmpty)

            if !urls.isEmpty {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                if urls.contains(where: AppleBooks.supports) {
                    Button("Add to Apple Books") { Task { await model.addToAppleBooks(urls) } }
                }
                Button("Copy Path") { copyPaths(urls) }
            }
            Divider()
            Button("Remove from List") {
                model.selectedFiles = ids
                model.removeSelectedFiles()
            }
            .disabled(ids.isEmpty)
            Button("Clear List") {
                model.selectedFiles = Set(model.localFiles.map(\.id))
                model.removeSelectedFiles()
            }
        }
    }

    private var canConvert: Bool {
        !model.isTransferring && !model.isPreparingFiles && model.hasValidActivationBytes && model.layout.isValid
    }

    private func pickFiles() {
        let files = Panels.openAudio(allowFolders: false)
        if !files.isEmpty { Task { await model.addFiles(at: files) } }
    }

    private func pickFolder() {
        if let folder = Panels.openFolder() { Task { await model.addFiles(at: [folder]) } }
    }

    private func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
    }
}
