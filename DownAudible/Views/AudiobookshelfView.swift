import SwiftUI

struct AudiobookshelfPreferencesView: View {
    @Bindable var model: WorkspaceModel
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var result = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $address, prompt: Text("https://audiobookshelf.example.com"))
                    .autocorrectionDisabled()
                SecureField("API token", text: $token, prompt: Text(address == model.shelfSettings.server && !address.isEmpty
                    ? "Use saved token" : "Enter a token"))
                Button("Connect…") { connect() }
                    .disabled(connecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Forget Saved Token") { forget() }
                    .disabled(connecting || model.shelfSettings.server.isEmpty)
                if connecting { ProgressView("Connecting…").controlSize(.small) }
                if !result.isEmpty { Text(result).textSelection(.enabled) }
            }

            Section("Destination") {
                if model.shelfLibraries.isEmpty {
                    LabeledContent("Book library", value: model.shelfSettings.libraryName)
                    LabeledContent("Server folder", value: model.shelfSettings.folderName)
                } else {
                    Picker("Book library", selection: Binding(
                        get: { model.shelfSettings.libraryID },
                        set: model.useShelfLibrary
                    )) {
                        ForEach(model.shelfLibraries) { library in Text(library.name).tag(library.id) }
                    }
                    Picker("Server folder", selection: Binding(
                        get: { model.shelfSettings.folderID },
                        set: model.useShelfFolder
                    )) {
                        ForEach(folders) { folder in Text(folder.fullPath).tag(folder.id) }
                    }
                    .disabled(folders.isEmpty)
                }
            }

            Section("Uploads") {
                Toggle("Upload new downloads automatically", isOn: $model.shelfSettings.autoUpload)
                    .disabled(model.shelfSettings.destination == nil)
                Toggle("Include companion PDFs", isOn: $model.shelfSettings.includePDFs)
                Text("Uploads use saved M4B, M4A and MP3 audio. Choose Upload to Audiobookshelf from Library to send existing copies.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if address.isEmpty { address = model.shelfSettings.server } }
    }

    private var folders: [ShelfLibrary.Folder] {
        model.shelfLibraries.first { $0.id == model.shelfSettings.libraryID }?.folders ?? []
    }

    private func connect() {
        let server = address
        let secret = token
        connecting = true
        result = ""
        Task {
            defer { connecting = false }
            do {
                try await model.connectShelf(server: server, token: secret)
                address = model.shelfSettings.server
                token = ""
                result = model.shelfLibraries.isEmpty ? "Connected. This account has no book libraries." : "Connected to Audiobookshelf."
            } catch {
                result = error.localizedDescription
            }
        }
    }

    private func forget() {
        do {
            try model.forgetShelfToken()
            address = ""
            token = ""
            result = "Audiobookshelf token removed."
        } catch {
            result = error.localizedDescription
        }
    }
}

struct ShelfUploadsView: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audiobookshelf Uploads").font(.headline)
            if model.shelfUploads.isEmpty {
                ContentUnavailableView("No Audiobookshelf uploads", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.shelfUploads) { upload in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(upload.book.title)
                        Text(upload.state.label).foregroundStyle(.secondary)
                        if let detail = upload.detail {
                            Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack {
                Button("Queue All Saved Books") { Task { await model.queueShelfBooks(model.books) } }
                    .disabled(model.books.isEmpty || model.shelfSettings.destination == nil)
                Button("Retry Failed Uploads") { Task { await model.retryShelfUploads() } }
                    .disabled(!model.shelfUploads.contains { $0.state == .failed && $0.destination == model.shelfSettings.destination })
                Button("Clear Sent") { Task { await model.clearSentShelfUploads() } }
                    .disabled(!model.shelfUploads.contains { $0.state == .sent })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 340)
        .task { await model.refreshShelfUploads() }
    }
}
