import AppKit
import SwiftUI

struct ConverterView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if model.localFiles.isEmpty {
                ContentUnavailableView {
                    Label("Convert Audio Files", systemImage: "waveform")
                } description: {
                    Text("Choose an AAX, AAXC, or AA file, or add a folder to convert several books at once.")
                } actions: {
                    Button("Add Files…", action: pickFiles)
                        .disabled(model.isPreparingFiles)
                    Button("Add Folder…", action: pickFolder)
                        .disabled(model.isPreparingFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.localFiles, selection: $model.selectedFiles) {
                    TableColumn("Title") { file in
                        Text(file.title)
                            .help(file.url.path(percentEncoded: false))
                    }
                    TableColumn("Author") { file in
                        Text(file.author ?? "—")
                            .foregroundStyle(file.author == nil ? .secondary : .primary)
                    }
                    TableColumn("Format") { file in
                        Text(file.format.uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 64, ideal: 72, max: 90)
                }
                .contextMenu(forSelectionType: LocalAudioFile.ID.self) { ids in
                    if ids.count == 1, let file = model.localFiles.first(where: { ids.contains($0.id) }) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        }
                    }
                    Button("Remove from List", role: .destructive) {
                        model.selectedFiles = ids
                        model.removeSelectedFiles()
                    }
                    .disabled(ids.isEmpty)
                }
            }

            Divider()
            Form {
                DestinationPicker(directory: $model.outputDirectory)
                if model.localFiles.contains(where: { $0.format == "aax" }) {
                    SecureField("Activation bytes (optional)", text: $model.activationBytes)
                        .textFieldStyle(.roundedBorder)
                        .help("Use eight hexadecimal characters from the Audible account that downloaded these files. Leave this blank to use your signed-in account.")
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
                    Text("Reading audio files…")
                        .foregroundStyle(.secondary)
                } else if !model.selectedFiles.isEmpty {
                    Text("\(model.selectedFiles.count) selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.selectedFiles.isEmpty ? "Convert All" : "Convert Selected") {
                    let files = model.selectedFiles.isEmpty ? model.localFiles : model.localFiles.filter {
                        model.selectedFiles.contains($0.id)
                    }
                    model.startConversion(files)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.localFiles.isEmpty || model.isTransferring || model.isPreparingFiles || !model.hasValidActivationBytes)
            }
            .padding([.horizontal, .bottom], 12)
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
    }

    private func pickFiles() {
        let files = Panels.openAudio(allowFolders: false)
        if !files.isEmpty { Task { await model.addFiles(at: files) } }
    }

    private func pickFolder() {
        if let folder = Panels.openFolder() {
            Task { await model.addFiles(at: [folder]) }
        }
    }
}
