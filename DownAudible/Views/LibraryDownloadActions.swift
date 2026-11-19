import SwiftUI

struct LibraryDownloadCommands: View {
    @FocusedValue(\.libraryWorkspaceActions) private var libraryContext
    let model: WorkspaceModel
    let activateLibrary: () -> Void

    var body: some View {
        Menu("Download") {
            LibraryDownloadActions(model: model, activateLibrary: activateLibrary)
            if libraryContext != nil {
                Divider()
                LibraryRestartAction(model: model, books: model.selectedAudiobooks, inMenuBar: true)
            }
        }
    }
}

struct LibraryDownloadActions: View {
    let model: WorkspaceModel
    var activateLibrary: (() -> Void)?

    var body: some View {
        let selection = model.selectedAudiobooks
        Button("Download Selected") { request(selection) }
            .keyboardShortcut(shortcut("d"))
            .disabled(!model.canRequestDownloads || selection.isEmpty)
        Button("Download Selected As…") { request(selection, customizing: true) }
            .keyboardShortcut(shortcut("d", modifiers: [.command, .option]))
            .disabled(!model.canRequestDownloads || selection.isEmpty)
        Divider()
        Button("Download Missing") { requestMissing() }
            .keyboardShortcut(shortcut("d", modifiers: [.command, .shift]))
            .disabled(!model.canDownloadMissing)
        Button("Download Missing As…") { requestMissing(customizing: true) }
            .keyboardShortcut(shortcut("d", modifiers: [.command, .option, .shift]))
            .disabled(!model.canDownloadMissing)
        Divider()
        Button("Download Entire Library") { request(model.books) }
            .keyboardShortcut(shortcut("l", modifiers: [.command, .shift]))
            .disabled(!model.canRequestDownloads || model.books.isEmpty)
        Button("Download Entire Library As…") { request(model.books, customizing: true) }
            .keyboardShortcut(shortcut("l", modifiers: [.command, .option, .shift]))
            .disabled(!model.canRequestDownloads || model.books.isEmpty)
    }

    private func shortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> KeyboardShortcut? {
        activateLibrary == nil ? nil : KeyboardShortcut(key, modifiers: modifiers)
    }

    private func request(_ books: [AudibleBook], customizing: Bool = false) {
        activateLibrary?()
        model.requestDownloads(books, customizing: customizing)
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
        let incomplete = books.filter { model.downloadStatus(for: $0) == .partial }
        if inMenuBar || !incomplete.isEmpty {
            Button("Restart Incomplete Downloads…") { model.restartDownloads(incomplete) }
                .keyboardShortcut(inMenuBar ? KeyboardShortcut("d", modifiers: [.command, .control, .shift]) : nil)
                .disabled(!model.canRequestDownloads || incomplete.isEmpty)
        }
    }
}
