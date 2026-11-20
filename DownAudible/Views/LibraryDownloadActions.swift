import SwiftUI

struct LibraryDownloadCommands: View {
    @FocusedValue(\.libraryWorkspaceActions) private var libraryContext
    let model: WorkspaceModel
    let activateLibrary: () -> Void

    var body: some View {
        Menu("Download") {
            LibraryDownloadActions(model: model, visibleBooks: libraryContext?.visibleBooks, activateLibrary: activateLibrary)
            if libraryContext != nil, !model.canAddToDownloadQueue {
                Divider()
                LibraryRestartAction(model: model, books: model.selectedAudiobooks, inMenuBar: true)
            }
        }
        .appHelp("Choose which books to download and what to save.")
    }
}

struct LibraryDownloadActions: View {
    let model: WorkspaceModel
    var visibleBooks: [AudibleBook]?
    var activateLibrary: (() -> Void)?

    var body: some View {
        let selection = visibleBooks?.filter { model.selectedBooks.contains($0.id) } ?? model.selectedAudiobooks
        if model.canAddToDownloadQueue {
            Button("Add Selected to Queue…") { reviewQueueAdditions(selection) }
                .keyboardShortcut(shortcut("d"))
                .appHelp("Add the selected audiobooks using the running batch’s destination and options.")
                .disabled(model.downloadQueueAdditions(from: selection).isEmpty)
            if let visibleBooks {
                Button("Add Visible Results to Queue…") { reviewQueueAdditions(visibleBooks) }
                    .appHelp("Add the visible audiobooks using the running batch’s destination and options.")
                    .disabled(model.downloadQueueAdditions(from: visibleBooks).isEmpty)
            }
        } else {
            downloadActions(selection: selection)
        }
    }

    @ViewBuilder
    private func downloadActions(selection: [AudibleBook]) -> some View {
        Button("Download Selected") {
            activateLibrary?()
            model.requestSelectedDownloads(selection)
        }
            .keyboardShortcut(shortcut("d"))
            .appHelp("Download the selected audiobooks with the saved download options.")
            .disabled(!model.canRequestDownloads || selection.isEmpty)
        Button("Download Selected As…") { reviewOptions(for: selection) }
            .keyboardShortcut(shortcut("d", modifiers: [.command, .option]))
            .appHelp("Choose what to save for the selected audiobooks before downloading.")
            .disabled(!model.canRequestDownloads || selection.isEmpty)
        if let visibleBooks {
            Button("Download Visible Results…") {
                activateLibrary?()
                model.reviewBulkDownload(visibleBooks, scope: .visibleResults)
            }
            .disabled(!model.canRequestDownloads || visibleBooks.isEmpty)
            .appHelp("Review how many titles are visible and download only those titles using the saved options.")
        }
        Divider()
        Button("Download Missing") { requestMissing() }
            .keyboardShortcut(shortcut("d", modifiers: [.command, .shift]))
            .appHelp("Queue eligible titles across the library whose audio is missing, incomplete, or unsaved.")
            .disabled(!model.canDownloadMissing)
        Button("Download Missing As…") { requestMissing(customizing: true) }
            .keyboardShortcut(shortcut("d", modifiers: [.command, .option, .shift]))
            .appHelp("Review the destination and file options before downloading missing audio.")
            .disabled(!model.canDownloadMissing)
        Divider()
        Button("Download Entire Library") {
            activateLibrary?()
            model.reviewBulkDownload(model.books, scope: .entireLibrary)
        }
            .keyboardShortcut(shortcut("l", modifiers: [.command, .shift]))
            .appHelp("Queue all titles in the loaded library with the saved options.")
            .disabled(!model.canRequestDownloads || model.books.isEmpty)
        Button("Download Entire Library As…") { reviewOptions(for: model.books) }
            .keyboardShortcut(shortcut("l", modifiers: [.command, .option, .shift]))
            .appHelp("Review the destination and file options for the whole loaded library.")
            .disabled(!model.canRequestDownloads || model.books.isEmpty)
    }

    private func shortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> KeyboardShortcut? {
        activateLibrary == nil ? nil : KeyboardShortcut(key, modifiers: modifiers)
    }

    private func reviewOptions(for books: [AudibleBook]) {
        activateLibrary?()
        model.requestDownloads(books, customizing: true)
    }

    private func reviewQueueAdditions(_ books: [AudibleBook]) {
        activateLibrary?()
        model.reviewAddingToDownloadQueue(books)
    }

    private func requestMissing(customizing: Bool = false) {
        activateLibrary?()
        model.requestMissingDownloads(customizing: customizing)
    }
}

struct LibraryRestartAction: View {
    let model: WorkspaceModel
    let books: [AudibleBook]
    var inMenuBar = false

    var body: some View {
        let incomplete = books.filter { model.hasIncompleteDownload(for: $0) }
        if inMenuBar || !incomplete.isEmpty {
            Button("Restart Incomplete Downloads…") { model.restartDownloads(incomplete) }
                .keyboardShortcut(inMenuBar ? KeyboardShortcut("d", modifiers: [.command, .control, .shift]) : nil)
                .appHelp("Start these downloads over from byte zero.")
                .disabled(!model.canRequestDownloads || incomplete.isEmpty)
        }
    }
}
