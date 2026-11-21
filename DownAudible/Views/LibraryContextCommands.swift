import AppKit
import SwiftUI

struct LibraryWorkspaceActions {
    let find: () -> Void
    let signIn: () -> Void
    let importAccount: () -> Void
    let visibleBooks: [AudibleBook]
}

extension FocusedValues {
    @Entry var libraryWorkspaceActions: LibraryWorkspaceActions?
}

struct LibraryContextCommands: View {
    @FocusedValue(\.libraryWorkspaceActions) private var actions
    let model: WorkspaceModel

    var body: some View {
        if let actions {
            Button("Find in Library", action: actions.find)
                .keyboardShortcut("f")
                .disabled(!model.signedIn)
                .appHelp("Focus the search field for finding books in this library.")

            Menu("File Matching") {
                LibraryFolderActions(model: model, inMenuBar: true)
            }
            .disabled(!model.signedIn)
            .appHelp("Find existing audiobook files and match them to your library.")

            Menu("Selected Books") {
                LibraryBookActions(model: model, books: model.selectedAudiobooks, inMenuBar: true)
            }
            .disabled(model.selectedBooks.isEmpty)
            .appHelp("Show actions for the currently selected audiobooks.")

            Menu("Audible Accounts") {
                Button(model.signedIn ? "Add Account…" : "Sign In…", action: actions.signIn)
                    .keyboardShortcut("a", modifiers: [.control, .shift])
                    .disabled(!model.canSwitchAccounts)
                    .appHelp("Start connecting an Audible account.")
                Button("Import from Audible CLI…", action: actions.importAccount)
                    .keyboardShortcut("i", modifiers: [.control, .shift])
                    .disabled(!model.canSwitchAccounts)
                    .appHelp("Connect an Audible account using a saved CLI login.")
                Button("Sign Out", action: model.signOut)
                    .keyboardShortcut("q", modifiers: [.control, .shift])
                    .disabled(!model.signedIn || !model.canRemoveAccounts)
                    .appHelp("Clear the saved sign-in for this account.")
            }
            .appHelp("Connect another Audible account or manage the current sign-in.")
        }
    }
}

struct LibraryVisibleExportCommands: View {
    @FocusedValue(\.libraryWorkspaceActions) private var context
    let model: WorkspaceModel

    var body: some View {
        if let context {
            LibraryVisibleExportMenu(model: model, books: context.visibleBooks)
        }
    }
}

struct LibraryVisibleExportMenu: View {
    let model: WorkspaceModel
    let books: [AudibleBook]

    var body: some View {
        Menu("Export Visible Results") {
            ForEach(LibraryExportFormat.allCases) { format in
                Button("\(format.rawValue.uppercased())…") {
                    Task { await model.exportLibrary(format, visibleBooks: books) }
                }
                .appHelp("Save the audiobooks shown in the table as \(format.rawValue.uppercased()).")
            }
        }
        .disabled(books.isEmpty || model.isRefreshing)
        .appHelp("Export the titles shown in the library table in their current order.")
    }
}

struct LibraryFolderActions: View {
    let model: WorkspaceModel
    var inMenuBar = false

    var body: some View {
        let folder = model.localMatches.directory
        let busy = model.isScanning || model.isRefreshing
        Button("Match Existing Folder…") {
            if let folder = Panels.openFolder() { scan(folder) }
        }
        .keyboardShortcut(shortcut("f"))
        .disabled(busy)
        .appHelp("Scan a folder for files that match your audiobooks.")

        if inMenuBar || folder != nil {
            Button("Rescan Matched Folder") {
                if let folder { scan(folder) }
            }
            .keyboardShortcut(shortcut("r"))
            .disabled(busy || folder == nil)
            .appHelp("Look for new, changed, or removed audio in the matched folder.")
            Button("Show Matched Folder in Finder") {
                if let folder { NSWorkspace.shared.open(folder) }
            }
            .keyboardShortcut(shortcut("o"))
            .disabled(folder == nil)
            .appHelp("Open the matched audio folder in Finder.")
            Button("Stop Matching This Folder", action: model.unlinkFolder)
                .keyboardShortcut(shortcut("u"))
                .disabled(busy || folder == nil)
                .appHelp("Disconnect the matched folder and keep its files on disk.")
        }
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        inMenuBar ? KeyboardShortcut(key, modifiers: [.control, .shift]) : nil
    }

    private func scan(_ folder: URL) {
        Task { await model.scanMatches(in: folder) }
    }
}

struct LibraryBookActions: View {
    let model: WorkspaceModel
    let books: [AudibleBook]
    var inMenuBar = false

    var body: some View {
        if books.count == 1, let book = books.first {
            Button("Edit Book…", systemImage: "scissors") { model.editBook(book) }
                .disabled(!model.canOpenBookEditor)
                .appHelp("Preview parts or chapters and choose which sections to include in a new M4B.")
            matchActions(book)
        }
        let files = Array(Set(books.flatMap { model.localAudio(for: $0) + model.exportedFiles[$0.id, default: []] }))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if inMenuBar || !files.isEmpty {
            Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                .keyboardShortcut(shortcut("s"))
                .disabled(files.isEmpty)
                .appHelp("Reveal the available audio files for the selected audiobooks.")
            let supported = files.filter { AppleBooks.supports($0) }
            if inMenuBar || !supported.isEmpty {
                appleBooksActions(supported, originals: Set(books.flatMap { model.originalFiles(for: $0) }))
                    .disabled(supported.isEmpty)
            }
        }
        Divider()
        if inMenuBar || books.count == 1 {
            Button("Copy Title") {
                if let book = books.first { copy(book.title) }
            }
            .keyboardShortcut(shortcut("t"))
            .disabled(books.count != 1)
            .appHelp("Copy the selected audiobook’s title to the clipboard.")
        }
        Button(books.count > 1 ? "Copy ASINs" : "Copy ASIN") {
            copy(books.map(\.asin).joined(separator: "\n"))
        }
        .keyboardShortcut(shortcut("c"))
        .disabled(books.isEmpty)
        .appHelp("Copy the selected books’ Audible product identifiers.")
    }

    private func appleBooksActions(_ urls: [URL], originals: Set<URL>) -> some View {
        let original = urls.filter { originals.contains($0) }
        let m4b = urls.filter { !originals.contains($0) && $0.pathExtension.lowercased() == "m4b" }
        let other = urls.filter { !originals.contains($0) && $0.pathExtension.lowercased() != "m4b" }
        return Menu("Add to Apple Books") {
            booksButton("Original Files", urls: original, key: "1")
            booksButton("M4B Files", urls: m4b, key: "2")
            booksButton("Other Audio", urls: other, key: "3")
        }
        .appHelp("Send saved audio for the selected books to Apple Books.")
    }

    @ViewBuilder
    private func booksButton(_ title: String, urls: [URL], key: KeyEquivalent) -> some View {
        if inMenuBar || !urls.isEmpty {
            Button(title) { Task { await model.addToAppleBooks(urls) } }
                .keyboardShortcut(shortcut(key))
                .disabled(urls.isEmpty)
                .appHelp("Send this type of saved audio to Apple Books.")
        }
    }

    @ViewBuilder
    private func matchActions(_ book: AudibleBook) -> some View {
        let hasMatch = !model.localAudio(for: book).isEmpty
        Button(hasMatch ? "Change Matched Files…" : "Match to Audio Files…") {
            let urls = Panels.openAudio(allowFolders: false)
            if !urls.isEmpty { model.match(book, to: urls) }
        }
        .keyboardShortcut(shortcut("m"))
        .disabled(model.isScanning)
        .appHelp("Choose an audio file or several parts to associate with this book.")
        if inMenuBar || hasMatch {
            Button("Remove File Match") { model.removeMatch(book) }
                .keyboardShortcut(shortcut(.delete))
                .disabled(model.isScanning || !hasMatch)
                .appHelp("Remove this book’s file association and leave the audio on disk.")
        }
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        inMenuBar ? KeyboardShortcut(key, modifiers: [.control, .shift]) : nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
