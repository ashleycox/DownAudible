import AppKit
import SwiftUI

struct TransfersView: View {
    var model: WorkspaceModel
    @State private var selection: Set<UUID> = []
    @State private var restartIDs: [UUID] = []
    @State private var confirmingRestart = false

    var body: some View {
        Group {
            if model.transfers.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.down.circle")
            } else {
                VStack(spacing: 0) {
                    List(model.transfers, selection: $selection) { transfer in
                        TransferRow(transfer: transfer, showProgress: model.transferPreferences.showProgress)
                            .tag(transfer.id)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        transferMenu(model.transfers.filter { ids.contains($0.id) })
                    }
                    Divider()
                    footer
                }
            }
        }
        .toolbar {
            if !model.transfers.isEmpty {
                ToolbarItem {
                    Menu("Transfer Actions", systemImage: "ellipsis.circle") {
                        Button("Restart Incomplete Downloads…") {
                            askToRestart(model.transfers.filter { $0.canRetry && $0.canRestart })
                        }
                        .disabled(!model.canRestart)
                        Button("Clear Completed", action: model.clearCompletedTransfers)
                            .disabled(!model.canClearCompleted)
                    }
                    .help("Transfer Actions")
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
        } message: { _ in
            Text("DownAudible will discard the temporary audio for these incomplete downloads. Files already saved in the archive stay available.")
        }
    }

    private func askToRestart(_ transfers: [Transfer]) {
        restartIDs = transfers.map(\.id)
        confirmingRestart = !restartIDs.isEmpty
    }

    private var footer: some View {
        HStack {
            if model.isTransferring && model.transferPreferences.showProgress {
                ProgressView(value: Double(model.finishedCount), total: Double(model.transfers.count))
                    .labelsHidden()
                    .accessibilityLabel("Batch progress")
                    .frame(maxWidth: 160)
            }
            Text("\(model.finishedCount) of \(model.transfers.count) finished")
                .foregroundStyle(.secondary)
            Spacer()
            if model.isTransferring {
                Button("Cancel Batch", role: .cancel) { model.cancelBatch() }
            } else if model.canRetry {
                Button("Retry Incomplete") { model.retryBatch() }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func transferMenu(_ items: [Transfer]) -> some View {
        let ids = items.map(\.id)
        let incomplete = items.filter(\.canRetry)
        let restartable = incomplete.filter(\.canRestart)
        let files = items.flatMap(\.files).filter { FileManager.default.fileExists(atPath: $0.path) }
        let partial = items.compactMap(\.partialFolder).filter { FileManager.default.fileExists(atPath: $0.path) }
        let errors = items.compactMap { transfer -> String? in
            switch transfer.status {
            case .failed(let error), .done(_, .some(let error)): "\(transfer.title)\n\(error)"
            default: nil
            }
        }

        if model.isTransferring && items.contains(where: { !$0.isFinished }) {
            Button(items.count == 1 ? "Cancel Transfer" : "Cancel Selected Transfers") {
                ids.forEach { model.cancelTransfer($0) }
            }
        }
        if !incomplete.isEmpty {
            Button("Retry") { model.retryTransfers(incomplete.map(\.id)) }
                .disabled(!model.canRetry)
        }
        if !restartable.isEmpty {
            Button("Restart Download…") { askToRestart(restartable) }
                .disabled(!model.canRestart)
        }
        if !files.isEmpty {
            Button("Show Output in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
            if files.contains(where: AppleBooks.supports) {
                Button("Add to Apple Books") { Task { await model.addToAppleBooks(files) } }
            }
        }
        if !partial.isEmpty {
            Button("Show Partial Files") { NSWorkspace.shared.activateFileViewerSelecting(partial) }
        }
        if !errors.isEmpty {
            Button(errors.count == 1 ? "Copy Error" : "Copy Errors") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(errors.joined(separator: "\n\n"), forType: .string)
            }
        }
        if !items.isEmpty {
            Divider()
            Button("Remove from List") { model.removeTransfers(ids) }.disabled(model.isTransferring)
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let showProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title).fontWeight(.medium)
                switch transfer.status {
                case .waiting:
                    status("Waiting")
                case .active(let name, let progress):
                    status(name)
                    if showProgress, let progress, progress.isFinite {
                        ProgressView(value: min(1, max(0, progress))).labelsHidden().accessibilityLabel(name)
                    }
                case .done(_, let note):
                    status(note ?? "Done")
                case .failed(let reason):
                    status(reason).textSelection(.enabled)
                case .cancelled:
                    status("Cancelled")
                case .interrupted:
                    status("Interrupted")
                case .stopped:
                    status("Stopped after an error")
                }
            }
            Spacer()
            if case .done(let url, let note) = transfer.status {
                if note != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Finished with a warning")
                }
                Button {
                    let paths = transfer.files.isEmpty ? [url] : transfer.files
                    NSWorkspace.shared.activateFileViewerSelecting(paths)
                } label: {
                    Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Show in Finder")
            } else if case .failed = transfer.status {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Failed")
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).font(.callout)
    }
}
