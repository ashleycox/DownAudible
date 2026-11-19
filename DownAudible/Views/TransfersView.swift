import AppKit
import SwiftUI

struct TransfersView: View {
    var model: WorkspaceModel

    var body: some View {
        if model.transfers.isEmpty {
            ContentUnavailableView("No Transfers", systemImage: "arrow.down.circle")
        } else {
            VStack(spacing: 0) {
                List(model.transfers) { transfer in
                    TransferRow(transfer: transfer, showProgress: model.transferPreferences.showProgress)
                }
                Divider()
                HStack {
                    if model.isTransferring && model.transferPreferences.showProgress {
                        ProgressView(value: Double(model.finishedCount), total: Double(model.transfers.count))
                            .labelsHidden()
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
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let showProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title)
                    .fontWeight(.medium)
                switch transfer.status {
                case .waiting:
                    status("Waiting")
                case .active(let name, let progress):
                    status(name)
                    if showProgress, let progress, progress.isFinite {
                        ProgressView(value: min(1, max(0, progress)))
                            .labelsHidden()
                            .accessibilityLabel(name)
                    }
                case .done(_, let note):
                    status(note ?? "Done")
                case .failed(let reason):
                    status(reason)
                        .textSelection(.enabled)
                case .cancelled:
                    status("Cancelled")
                case .stopped:
                    status("Stopped after an error")
                }
            }
            Spacer()
            if case .done(let url, let note) = transfer.status {
                if note != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Some extras couldn’t be saved")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
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
        Text(text)
            .foregroundStyle(.secondary)
            .font(.callout)
    }
}
