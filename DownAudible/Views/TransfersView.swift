import AppKit
import SwiftUI

struct TransfersView: View {
    var model: WorkspaceModel
    @Binding var requestingBatchRestart: Bool
    @State private var selection: Set<UUID> = []
    @State private var restartIDs: [UUID] = []
    @State private var confirmingRestart = false

    var body: some View {
        Group {
            if model.transfers.isEmpty {
                ContentUnavailableView(
                    "No Downloads", systemImage: WorkspacePage.transfers.icon,
                    description: Text("Downloads and conversions appear here when you start them.")
                )
            } else {
                VStack(spacing: 0) {
                    List(model.transfers, selection: $selection) { transfer in
                        TransferRow(transfer: transfer, showProgress: model.transferPreferences.showProgress)
                            .tag(transfer.id)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        TransferSelectionActions(selection: selectedTransfers(ids))
                    }
                    Divider()
                    footer
                }
            }
        }
        .focusedSceneValue(\.transferSelection, selectedTransfers(selection))
        .toolbar {
            if !model.transfers.isEmpty {
                ToolbarItem {
                    Menu("Download Actions", systemImage: "ellipsis.circle") {
                        Button("Restart Incomplete Downloads…", systemImage: "arrow.counterclockwise",
                               action: askToRestartBatch)
                            .disabled(!model.canRestart)
                            .appHelp("Review restarting unfinished downloads from the beginning.")
                        Button("Clear Completed", systemImage: "checkmark.circle", action: model.clearCompletedTransfers)
                            .disabled(!model.canClearCompleted)
                            .appHelp("Remove successful jobs from the list and keep their saved files.")
                    }
                    .labelStyle(.iconOnly)
                    .appHelp("Download Actions")
                }
            }
        }
        .confirmationDialog(
            "Restart from the beginning?",
            isPresented: $confirmingRestart,
            titleVisibility: .visible,
            presenting: restartIDs
        ) { ids in
            Button("Restart Downloads") { model.retryTransfers(ids, restartIncomplete: true) }
                .keyboardShortcut(.defaultAction)
                .appHelp("Discard the selected partial downloads and start them again.")
        } message: { _ in
            Text("DownAudible will discard the temporary audio for these incomplete downloads. Files already saved in the archive stay available.")
        }
        .onChange(of: requestingBatchRestart, initial: true) {
            guard requestingBatchRestart else { return }
            requestingBatchRestart = false
            askToRestartBatch()
        }
    }

    private func askToRestartBatch() {
        askToRestart(model.transfers.filter(\.canRestart))
    }

    private func askToRestart(_ transfers: [Transfer]) {
        restartIDs = transfers.map(\.id)
        confirmingRestart = !restartIDs.isEmpty
    }

    private func selectedTransfers(_ ids: Set<UUID>) -> TransferSelection {
        TransferSelection(model: model, items: model.transfers.filter { ids.contains($0.id) }, askToRestart: askToRestart)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.finishedCount.formatted()) of \(model.transfers.count.formatted()) finished")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if model.isTransferring && model.transferPreferences.showProgress {
                    ProgressView(value: Double(model.finishedCount), total: Double(model.transfers.count))
                        .labelsHidden()
                        .accessibilityLabel("Batch progress")
                        .frame(maxWidth: 160)
                        .appHelp("Shows how much of the current batch has finished.")
                }
            }
            Spacer()
            if model.isTransferring {
                Button("Cancel Batch", role: .cancel) { model.cancelBatch() }
                    .appHelp("Stop running jobs and leave unfinished work available to retry.")
            } else if model.canRetry {
                Button("Retry Incomplete") { model.retryBatch() }
                    .appHelp("Retry unfinished jobs and resume usable partial downloads.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension FocusedValues {
    @Entry fileprivate var transferSelection: TransferSelection?
}

struct TransferSelectionCommands: View {
    @FocusedValue(\.transferSelection) private var selection

    var body: some View {
        if let selection {
            Divider()
            TransferSelectionActions(selection: selection, inMenuBar: true)
        }
    }
}

private struct TransferSelection {
    let model: WorkspaceModel
    let items: [Transfer]
    let askToRestart: ([Transfer]) -> Void
}

private struct TransferSelectionActions: View {
    let selection: TransferSelection
    var inMenuBar = false

    var body: some View {
        let model = selection.model
        let items = selection.items
        let ids = items.map(\.id)
        let incomplete = items.filter(\.canRetry)
        let restartable = items.filter(\.canRestart)
        let files = items.flatMap(\.files).filter { FileManager.default.fileExists(atPath: $0.path) }
        let partial = items.compactMap(\.partialFolder).filter { FileManager.default.fileExists(atPath: $0.path) }
        let errors = items.compactMap { transfer -> String? in
            switch transfer.status {
            case .failed(let error), .done(_, .some(let error)): "\(transfer.title)\n\(error)"
            default: nil
            }
        }
        let canCancel = model.isTransferring && items.contains { !$0.isFinished }
        let canAddToBooks = files.contains(where: AppleBooks.supports)

        if inMenuBar || canCancel {
            Button(items.count == 1 ? "Cancel Transfer" : "Cancel Selected Transfers") {
                ids.forEach { model.cancelTransfer($0) }
            }
            .keyboardShortcut(shortcut("x"))
            .disabled(!canCancel)
            .appHelp("Stop the selected transfer jobs.")
        }
        if inMenuBar || !incomplete.isEmpty {
            Button(inMenuBar ? "Retry Selected Transfers" : "Retry") { model.retryTransfers(incomplete.map(\.id)) }
                .keyboardShortcut(shortcut("r"))
                .disabled(incomplete.isEmpty || !model.canRetry)
                .appHelp("Retry the selected unfinished jobs and reuse any valid partial downloads.")
        }
        if inMenuBar || !restartable.isEmpty {
            Button(inMenuBar ? "Restart Selected Downloads…" : "Restart Download…") { selection.askToRestart(restartable) }
                .keyboardShortcut(shortcut("d"))
                .disabled(restartable.isEmpty || !model.canRestart)
                .appHelp("Review restarting these selected downloads from the beginning.")
        }
        if inMenuBar || !files.isEmpty {
            Button("Show Output in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                .keyboardShortcut(shortcut("f"))
                .disabled(files.isEmpty)
                .appHelp("Reveal saved files from the selected jobs.")
        }
        if inMenuBar || canAddToBooks {
            Button("Add to Apple Books", systemImage: "books.vertical") { Task { await model.addToAppleBooks(files) } }
                .keyboardShortcut(shortcut("b"))
                .disabled(!canAddToBooks)
                .appHelp("Send the selected saved audio files to Apple Books.")
        }
        if inMenuBar || !partial.isEmpty {
            Button("Show Partial Files") { NSWorkspace.shared.activateFileViewerSelecting(partial) }
                .keyboardShortcut(shortcut("p"))
                .disabled(partial.isEmpty)
                .appHelp("Reveal the folders containing incomplete downloads.")
        }
        if inMenuBar || !errors.isEmpty {
            Button(errors.count == 1 ? "Copy Error" : "Copy Errors") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(errors.joined(separator: "\n\n"), forType: .string)
            }
            .keyboardShortcut(shortcut("e"))
            .disabled(errors.isEmpty)
            .appHelp("Copy the selected job titles and error details.")
        }
        if inMenuBar || !items.isEmpty {
            Divider()
            Button("Remove from List") { model.removeTransfers(ids) }
                .keyboardShortcut(shortcut(.delete))
                .disabled(items.isEmpty || model.isTransferring)
                .appHelp("Remove the selected entries from Downloads and keep files already saved.")
        }
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        inMenuBar ? KeyboardShortcut(key, modifiers: [.control, .shift]) : nil
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let showProgress: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: statusSymbol)
                .imageScale(.large)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title)
                    .font(.headline)
                switch transfer.status {
                case .waiting:
                    status("Waiting")
                case .active(let name, let progress):
                    status(name)
                    if showProgress, let progress, progress.isFinite {
                        ProgressView(value: min(1, max(0, progress)))
                            .labelsHidden()
                            .accessibilityLabel("Job progress")
                            .appHelp("Shows progress for this job.")
                    }
                case .done(_, let note):
                    if let note {
                        status(note).accessibilityLabel("Finished with a warning. \(note)")
                    } else {
                        status("Done")
                    }
                case .failed(let reason):
                    status(reason)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Failed. \(reason)")
                case .cancelled:
                    status("Cancelled")
                case .interrupted:
                    status("Interrupted")
                case .stopped:
                    status("Stopped after an error")
                }
            }
            Spacer()
            if case .done(let url, _) = transfer.status {
                Button("Show in Finder", systemImage: "folder") {
                    let paths = transfer.files.isEmpty ? [url] : transfer.files
                    NSWorkspace.shared.activateFileViewerSelecting(paths)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .appHelp("Show in Finder")
            }
        }
        .padding(.vertical, 8)
    }

    private var statusSymbol: String {
        switch transfer.status {
        case .waiting: "clock"
        case .active: "circle.dotted"
        case .done(_, nil): "checkmark.circle"
        case .done, .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .interrupted: "pause.circle"
        case .stopped: "stop.circle"
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).font(.callout)
    }
}
