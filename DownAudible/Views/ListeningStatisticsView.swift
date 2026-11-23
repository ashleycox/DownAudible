import AppKit
import SwiftUI

struct ListeningStatisticsWindow: View {
    let model: WorkspaceModel
    var initialMonths: [AudibleListeningMonth] = []
    @State private var selected: UUID?

    var body: some View {
        let accounts = model.signedInCatalogAccounts
        let account = accounts.first { $0.id == selected } ?? accounts.first
        if let account {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Audible account", selection: Binding(get: { account.id }, set: { selected = $0 })) {
                    ForEach(accounts) { Text("\($0.name) (\($0.marketplace.displayName))").tag($0.id) }
                }
                .padding([.top, .horizontal], 20)
                ListeningStatisticsView(client: model.listeningClient(for: account), initialMonths: initialMonths)
                    .id(account.id)
            }
            .onAppear { selected = selected ?? model.activeAccountID }
        } else {
            ContentUnavailableView("Sign In to Audible", systemImage: "person.crop.circle")
        }
    }
}

private struct ListeningStatisticsView: View {
    let client: AudibleClient
    @Environment(\.dismiss) private var dismiss
    @State private var months: [AudibleListeningMonth]
    @State private var hasLoaded: Bool
    @State private var startYear = 2010
    @State private var filterYear: Int?
    @State private var filterMonth: Int?
    @State private var hideEmpty = false
    @State private var loading: Task<Void, Never>?
    @State private var issue: String?

    init(client: AudibleClient, initialMonths: [AudibleListeningMonth]) {
        self.client = client
        _months = State(initialValue: initialMonths)
        _hasLoaded = State(initialValue: !initialMonths.isEmpty)
    }

    private var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: .now) }
    private var years: [Int] { Set(months.compactMap(\.year)).sorted(by: >) }
    private var visibleMonths: [AudibleListeningMonth] {
        months.filter { month in
            (filterYear == nil || filterYear == month.year) && (filterMonth == nil || filterMonth == month.monthNumber)
                && (!hideEmpty || month.durationMilliseconds > 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LabeledContent("Start year") {
                    TextField("Start year", value: $startYear, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 72)
                        .disabled(loading != nil)
                }
                .fixedSize()
                Button("Load Statistics", action: load)
                    .disabled(loading != nil || !(1997...currentYear).contains(startYear))
                if loading != nil {
                    ProgressView("Loading…").controlSize(.small)
                    Button("Cancel Loading") { loading?.cancel() }
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("Year", selection: $filterYear) {
                    Text("All years").tag(nil as Int?)
                    ForEach(years, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }
                Picker("Month", selection: $filterMonth) {
                    Text("All months").tag(nil as Int?)
                    ForEach(Array(Calendar(identifier: .gregorian).monthSymbols.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(Optional(index + 1))
                    }
                }
                Toggle("Hide months with no listening", isOn: $hideEmpty)
                Spacer()
            }
            .disabled(!hasLoaded)
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if visibleMonths.isEmpty {
                ContentUnavailableView(
                    hasLoaded ? "No Matching Months" : "Load Listening Statistics",
                    systemImage: "calendar",
                    description: Text(hasLoaded ? "Change the filters or choose an earlier start year."
                        : "Choose a start year to see your monthly listening time from Audible.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visibleMonths) {
                    TableColumn("Month", value: \.month)
                    TableColumn("Listening Time", value: \.listeningTime)
                }
                .accessibilityLabel("Monthly listening statistics")
            }
            HStack {
                let count = visibleMonths.count
                let total = AudibleListeningMonth.description(milliseconds: visibleMonths.map(\.durationMilliseconds).reduce(0, +))
                Text("\(count.formatted()) \(count == 1 ? "month" : "months") · \(total)").foregroundStyle(.secondary)
                Spacer()
                Menu("Export…") {
                    ForEach(LibraryExportFormat.allCases) { format in
                        Button(format == .xlsx ? "Excel…" : "\(format.rawValue.uppercased())…") { export(format) }
                    }
                }
                .disabled(visibleMonths.isEmpty)
                .appHelp("Export the months shown using the current filters.")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 390)
        .onDisappear { loading?.cancel() }
    }

    private func load() {
        guard loading == nil, (1997...currentYear).contains(startYear) else { return }
        let year = startYear
        issue = nil
        loading = Task {
            defer { loading = nil }
            do {
                let values = try await client.listeningStatistics(startYear: year)
                try Task.checkCancellation()
                months = values
                if let filterYear, !years.contains(filterYear) { self.filterYear = nil }
                hasLoaded = true
            } catch is CancellationError {
                return
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    private func export(_ format: LibraryExportFormat) {
        let visible = visibleMonths
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "listening-stats.\(format.rawValue)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let path = panel.url else { return }
        Task {
            do { try await AudibleListeningMonth.export(visible, as: format, to: path) }
            catch { issue = error.localizedDescription }
        }
    }
}
