import AppKit
import SwiftUI

struct TransfersView: View {
    private struct RestartRequest {
        let ids: [UUID]
        let historyID: UUID?
    }

    var model: WorkspaceModel
    @Binding var requestingBatchRestart: Bool
    @State private var selection: Set<UUID> = []
    @State private var restartRequest: RestartRequest?
    @State private var notificationScrollTarget: UUID?
    @State private var missingNotificationJobs = false

    var body: some View {
        let selected = selectedTransfers(selection)

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !model.transferHistory.isEmpty {
                    historyPicker
                    Divider()
                }
                if missingNotificationJobs {
                    Label("These jobs are no longer in Downloads.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .appHelp("The jobs were removed from Downloads or are no longer in Recent Batches.")
                }
                if model.displayedTransfers.isEmpty {
                    ContentUnavailableView(
                        "No Downloads", systemImage: WorkspacePage.transfers.icon,
                        description: Text("Downloads and conversions appear here when you start them.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transferList(selected: selected, scrollProxy: proxy)
                    Divider()
                    footer
                }
            }
            .onChange(of: model.didRestoreTransfers ? model.transferNotificationSelection : nil, initial: true) { _, request in
                guard let request else { return }
                model.selectHistoryForNotification(request.transferIDs)
                let matchingIDs = model.displayedTransfers.lazy.map(\.id).filter { request.transferIDs.contains($0) }
                selection = Set(matchingIDs)
                notificationScrollTarget = matchingIDs.first
                missingNotificationJobs = !request.transferIDs.isEmpty && matchingIDs.isEmpty
                model.didShowNotifiedTransfers(request.id)
            }
            .onChange(of: model.displayedTransfers.map(\.id)) { _, ids in selection.formIntersection(ids) }
        }
        .focusedSceneValue(\.transferSelection, selected)
        .toolbar {
            ToolbarItem {
                Menu("Download Actions", systemImage: "ellipsis.circle") {
                    Button("Restart Incomplete Downloads…", systemImage: "arrow.counterclockwise",
                           action: askToRestartBatch)
                        .disabled(!model.canRestart)
                        .appHelp("Review restarting unfinished downloads from the beginning.")
                    Button("Clear Completed", systemImage: "checkmark.circle", action: model.clearCompletedTransfers)
                        .disabled(!model.canClearCompleted)
                        .appHelp("Remove successful jobs from the list and keep their saved files.")
                    Divider()
                    TransferRemoveButton(selection: selected)
                }
                .labelStyle(.iconOnly)
                .appHelp("Download Actions")
            }
        }
        .confirmationDialog(
            "Restart from the beginning?",
            isPresented: Binding { restartRequest != nil } set: { if !$0 { restartRequest = nil } },
            titleVisibility: .visible,
            presenting: restartRequest
        ) { request in
            Button("Restart Downloads") {
                model.retryTransfers(request.ids, restartIncomplete: true, historyID: request.historyID)
            }
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

    private func transferList(selected: TransferSelection, scrollProxy: ScrollViewProxy) -> some View {
        List(model.displayedTransfers, selection: $selection) { transfer in
            TransferRow(transfer: transfer, showProgress: model.transferPreferences.showProgress,
                        canRemove: model.canRemoveTransfers) {
                model.removeTransfers([transfer.id], historyID: selected.historyID)
            }
            .tag(transfer.id)
            .id(transfer.id)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            TransferSelectionActions(selection: selectedTransfers(ids))
        }
        .onDeleteCommand(perform: selected.canRemove ? { selected.remove() } : nil)
        .task(id: notificationScrollTarget) {
            guard let target = notificationScrollTarget else { return }
            scrollProxy.scrollTo(target)
            notificationScrollTarget = nil
        }
    }

    private var historyPicker: some View {
        HStack {
            Picker("Show", selection: Binding { model.transferHistorySelection } set: { id in
                selection.removeAll()
                notificationScrollTarget = nil
                missingNotificationJobs = false
                model.selectTransferHistory(id)
            }) {
                Text("Current Batch").tag(Optional<UUID>.none)
                Section("Recent Batches") {
                    ForEach(model.transferHistory) { entry in
                        let date = entry.date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
                        let scope = entry.batch.work.first?.isDownload == true
                            ? entry.batch.account?.name ?? "Audible" : "Convert Files"
                        let count = entry.transfers.count
                        Text("\(date) · \(scope) · \(count.formatted()) \(count == 1 ? "job" : "jobs")")
                            .tag(Optional(entry.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .appHelp("Switch between the current batch and earlier downloads or conversions.")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func askToRestartBatch() {
        askToRestart(model.displayedTransfers.filter(\.canRestart), historyID: model.transferHistorySelection)
    }

    private func askToRestart(_ transfers: [Transfer], historyID: UUID?) {
        guard !transfers.isEmpty else { return }
        restartRequest = RestartRequest(ids: transfers.map(\.id), historyID: historyID)
    }

    private func selectedTransfers(_ ids: Set<UUID>) -> TransferSelection {
        let historyID = model.transferHistorySelection
        return TransferSelection(model: model, items: model.displayedTransfers.filter { ids.contains($0.id) }, historyID: historyID) {
            askToRestart($0, historyID: historyID)
        }
    }

    private var footer: some View {
        let transfers = model.displayedTransfers
        let completed = transfers.count { if case .done = $0.status { true } else { false } }
        let isRunning = model.transferHistorySelection == nil && model.isTransferring
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(completed.formatted()) of \(transfers.count.formatted()) completed")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .appHelp("Counts jobs that saved their output, including jobs with a warning.")
                if isRunning && model.transferPreferences.showProgress {
                    let finished = transfers.count(where: \.isFinished)
                    ProgressView(value: Double(finished), total: Double(transfers.count))
                        .labelsHidden()
                        .accessibilityLabel("Batch progress")
                        .frame(maxWidth: 160)
                        .appHelp("Shows how much of the current batch has finished.")
                }
            }
            Spacer()
            if isRunning {
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

@MainActor
private struct TransferSelection {
    let model: WorkspaceModel
    let items: [Transfer]
    let historyID: UUID?
    let askToRestart: ([Transfer]) -> Void

    var canRemove: Bool { model.canRemoveTransfers && !items.isEmpty }

    func remove() { model.removeTransfers(items.map(\.id), historyID: historyID) }
}

private struct TransferRemoveButton: View {
    let selection: TransferSelection

    var body: some View {
        Button("Remove from List", systemImage: "minus.circle", action: selection.remove)
            .disabled(!selection.canRemove)
            .appHelp("Remove the selected entries from Downloads and keep files already saved.")
    }
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
        let canCancel = selection.historyID == nil && model.isTransferring && items.contains { !$0.isFinished }
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
            Button(inMenuBar ? "Retry Selected Transfers" : "Retry") {
                model.retryTransfers(incomplete.map(\.id), historyID: selection.historyID)
            }
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
            let cueFiles = files.filter(CueSheet.supports)
            if items.count == 1, cueFiles.count == 1, let audio = cueFiles.first {
                Button("Export CUE Sheet…") { Task { await model.exportCue(for: audio) } }
                    .appHelp("Save a chapter sheet beside the selected audio file.")
            }
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
            TransferRemoveButton(selection: selection)
                .keyboardShortcut(shortcut(.delete))
        }
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: [.control, .shift])
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let showProgress: Bool
    let canRemove: Bool
    let remove: () -> Void

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
                    if let retry = transfer.audibleRetry {
                        status("\(retry.reason) · Retries after \(retry.until.formatted(date: .abbreviated, time: .shortened))")
                    } else if let retry = transfer.paceResumeAt {
                        status("Waiting for download limit · Checks again \(retry.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        status("Waiting")
                    }
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
            if canRemove {
                Button("Remove from List", systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(transfer.title) from list")
                    .appHelp("Remove from List")
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
