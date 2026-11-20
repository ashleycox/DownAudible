import SwiftUI

struct ArchiveVerificationButton: View {
    let model: WorkspaceModel

    var body: some View {
        Button("Verify and Repair Archive…") {
            model.showingArchiveVerification = true
        }
        .disabled(!model.canVerifyArchive)
        .appHelp("Check the current account’s saved audio and queue repairs for selected titles.")
    }
}

struct ArchiveVerificationView: View {
    private enum Phase {
        case checking
        case finished(ArchiveVerificationReport)
        case failed(String)
    }

    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.checking
    @State private var scan = UUID()
    @State private var checkedCount = 0
    @State private var totalCount = 0
    @State private var selection: Set<AudibleBook.ID> = []
    @State private var repairError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify and Repair Archive")
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            switch phase {
            case .checking:
                checking
            case .finished(let report):
                results(report)
            case .failed(let error):
                failure(error)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 480)
        .task(id: scan) { await verify() }
        .alert("Couldn’t Start Repair", isPresented: Binding(
            get: { repairError != nil },
            set: { if !$0 { repairError = nil } }
        )) {
            Button("OK", role: .cancel) { repairError = nil }
                .appHelp("Close this error and return to the archive report.")
        } message: {
            Text(repairError ?? "")
        }
    }

    private var checking: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            if totalCount > 0 {
                ProgressView(value: Double(checkedCount), total: Double(totalCount)) {
                    Text("Checking \(checkedCount) of \(totalCount) audiobooks")
                }
                .appHelp("Progress through the current account’s audiobooks.")
            } else {
                ProgressView("Preparing to check audio…")
                    .appHelp("DownAudible is locating files for this account.")
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appHelp("Stop checking files and close the archive report.")
            }
        }
    }

    private func results(_ report: ArchiveVerificationReport) -> some View {
        let repairable = Set(report.issues.filter(\.canRepair).map(\.id))
        let selected = selection.intersection(repairable)
        return VStack(alignment: .leading, spacing: 12) {
            if report.issues.isEmpty {
                ContentUnavailableView(
                    "No Archive Issues Found", systemImage: "checkmark.circle",
                    description: Text("Checked \(report.checkedCount) audiobooks.")
                )
            } else {
                Text("\(report.issues.count) of \(report.checkedCount) checked audiobooks need attention.")
                    .foregroundStyle(.secondary)
                List(report.issues, selection: $selection) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.book.title).fontWeight(.medium)
                        Text(issue.canRepair ? issue.kind.title : "\(issue.kind.title) · Unavailable from Audible")
                            .foregroundStyle(.secondary)
                        ForEach(issue.files, id: \.self) { file in
                            Text(file.path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(issue.id)
                    .appHelp("Select this title to include it in the repair.")
                }
                .accessibilityLabel("Archive issues")
                .appHelp("Shows titles without a complete readable copy and the affected file paths.")
            }
            HStack {
                if !repairable.isEmpty {
                    Button("Select All Repairable") { selection = repairable }
                        .disabled(selected == repairable)
                        .appHelp("Select every title Audible can supply again.")
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appHelp("Close the report.")
                if !repairable.isEmpty {
                    Button(selected.count > 1 ? "Repair \(selected.count) Titles" : "Repair Selected") {
                        do {
                            try model.startArchiveRepair(report, selecting: selected)
                            dismiss()
                        } catch {
                            repairError = error.localizedDescription
                        }
                    }
                    .disabled(selected.isEmpty)
                    .appHelp("Queue the selected titles using your download and conversion settings.")
                }
            }
        }
    }

    private func failure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ContentUnavailableView(
                "Couldn’t Verify the Archive", systemImage: "exclamationmark.triangle", description: Text(error)
            )
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appHelp("Close the archive report.")
                Button("Retry") { scan = UUID() }
                    .appHelp("Try checking the current account’s archive again.")
            }
        }
    }

    private func verify() async {
        phase = .checking
        totalCount = 0
        checkedCount = 0
        selection = []
        do {
            let report = try await model.verifyArchive { checked, total in
                checkedCount = checked
                totalCount = total
            }
            if !Task.isCancelled { phase = .finished(report) }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }
}
