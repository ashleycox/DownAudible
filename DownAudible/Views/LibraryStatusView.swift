import SwiftUI

struct LibraryStatusView: View {
    let model: WorkspaceModel
    @State private var selection: Scope? = .all
    @State private var sortOrder = [KeyPathComparator(\Row.title, comparator: .localizedStandard)]

    #if HELP_SCREENSHOTS
    init(model: WorkspaceModel, unavailableOnly: Bool = false) {
        self.model = model
        _selection = State(initialValue: unavailableOnly ? .category(.unavailable) : .all)
    }
    #endif

    var body: some View {
        Group {
            if model.signedIn {
                library
            } else {
                ContentUnavailableView(
                    "Your Audible Library", systemImage: "books.vertical",
                    description: Text("Sign in from Library to see your audiobook status.")
                )
            }
        }
        .frame(minWidth: 768, minHeight: 400)
        .onChange(of: model.activeAccountID) { selection = .all }
    }

    private var library: some View {
        let transfers = model.activeLibraryAudioTransfers
        let rows = model.books.map { book in
            Row(
                book: book, status: model.downloadStatus(for: book),
                transfer: transfers[book.id], missingFileCount: model.missingOutputFiles(for: book).count
            )
        }
        let groups = Dictionary(grouping: rows, by: \.category)
        let scope = selection ?? .all
        return HSplitView {
            List(selection: $selection) {
                Section("Library") {
                    categoryRow(.all, count: rows.count)
                    categoryRow(.category(.toDownload), count: groups[.toDownload]?.count ?? 0)
                }
                Section("Already Have Audio") {
                    categoryRow(.category(.downloaded), count: groups[.downloaded]?.count ?? 0)
                    categoryRow(.category(.matched), count: groups[.matched]?.count ?? 0)
                }
                Section("Audible Availability") {
                    categoryRow(.category(.unavailable), count: groups[.unavailable]?.count ?? 0)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Library status categories")
            .frame(minWidth: 176, idealWidth: 192, maxWidth: 224)

            VStack(alignment: .leading, spacing: 0) {
                header(scope)
                Divider()
                booksTable(
                    scope.category.map { groups[$0, default: []] } ?? rows,
                    showsTransfers: !transfers.isEmpty
                )
            }
            .frame(minWidth: 540)
        }
    }

    private func categoryRow(_ scope: Scope, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(scope.title, systemImage: scope.icon)
            Spacer(minLength: 4)
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .appHelp(scope.explanation)
        .tag(scope)
    }

    private func header(_ scope: Scope) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(scope.title, systemImage: scope.icon)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let account = model.activeAccount {
                    Label(account.name, systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .appHelp(account.name)
                }
            }
            Text(scope.explanation)
                .foregroundStyle(.secondary)
            if let activity {
                ProgressView(activity)
                    .controlSize(.small)
                    .appHelp("DownAudible is checking the state of the library or its saved files.")
            }
        }
        .padding(16)
    }

    private var activity: String? {
        if model.isRefreshing { return "Refreshing library…" }
        if model.isScanning { return "Matching audio files…" }
        if model.isCheckingFiles { return "Checking saved files…" }
        return nil
    }

    private func booksTable(_ rows: [Row], showsTransfers: Bool) -> some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                Text(row.title).appHelp(row.title)
            }
            .width(min: 116, ideal: 184)
            TableColumn("Author", value: \.author) { row in
                Text(row.author).appHelp(row.author)
            }
            .width(min: 64, ideal: 104)
            TableColumn("Local Audio", value: \.localAudio) { row in
                Label(row.localAudio, systemImage: row.audioIcon)
                    .lineLimit(1)
                    .appHelp(row.audioDetails.isEmpty ? row.localAudio : row.audioDetails)
                    .accessibilityValue(row.audioDetails)
            }
            .width(min: 140, ideal: 152)
            TableColumn("Audible Download", value: \.availability) { row in
                Text(row.availability)
                    .appHelp(row.availabilityDetails)
                    .accessibilityValue(row.availabilityDetails)
            }
            .width(min: 112, ideal: 126)
            if showsTransfers {
                TableColumn("Transfer") { row in
                    Text(row.transferStage).appHelp(row.transferStage)
                }
                .width(min: 84, ideal: 96)
            }
        }
        .overlay {
            if rows.isEmpty && activity == nil {
                ContentUnavailableView("No Audiobooks in This Category", systemImage: "books.vertical")
            }
        }
    }

    private enum Scope: Hashable {
        case all
        case category(LibraryAudioCategory)

        var category: LibraryAudioCategory? {
            if case .category(let category) = self { category } else { nil }
        }

        var title: String {
            switch self {
            case .all: "All Audiobooks"
            case .category(.toDownload): "To Download"
            case .category(.downloaded): "Downloaded"
            case .category(.matched): "Matched"
            case .category(.unavailable): "Unavailable"
            }
        }

        var icon: String {
            switch self {
            case .all: "books.vertical"
            case .category(.toDownload): LibraryDownloadStatus.notDownloaded.systemImage
            case .category(.downloaded): LibraryDownloadStatus.downloaded.systemImage
            case .category(.matched): LibraryDownloadStatus.matched.systemImage
            case .category(.unavailable): LibraryDownloadStatus.unavailable.systemImage
            }
        }

        var explanation: String {
            switch self {
            case .all: "Compare your saved audio with the titles available to download from Audible."
            case .category(.toDownload): "Download Missing uses these titles. Queued and active titles stay here until a local copy is available."
            case .category(.downloaded): "At least one complete audio copy is saved in your archive."
            case .category(.matched): "Audio is available from a file or folder you matched to the library."
            case .category(.unavailable): "These titles need a local copy and Audible marks their downloads as unavailable."
            }
        }
    }

    private struct Row: Identifiable {
        let book: AudibleBook
        let status: LibraryDownloadStatus
        let transfer: Transfer.Status?
        let missingFileCount: Int

        var id: AudibleBook.ID { book.id }
        var title: String { book.title }
        var author: String { book.authors.formatted(.list(type: .and)) }
        var category: LibraryAudioCategory {
            LibraryAudioCategory(status: status, isDownloadable: book.isDownloadable)
        }
        var localAudio: String { status == .unavailable ? "No local audio" : status.displayName }
        var audioIcon: String { missingFileCount == 0 ? status.systemImage : "exclamationmark.triangle" }
        var audioDetails: String {
            if missingFileCount == 0 { return "" }
            return missingFileCount == 1 ? "1 saved file missing" : "\(missingFileCount.formatted()) saved files missing"
        }

        var availability: String {
            if book.isDownloadable { return "Available" }
            return switch book.downloadUnavailableReason {
            case .podcastSeries: "Podcast series"
            case .offlineRestricted: "Offline restricted"
            case .unpublished: "Unpublished"
            case nil: "Unavailable"
            }
        }

        var availabilityDetails: String {
            if book.isDownloadable { return "Audible offers this title for download." }
            return switch book.downloadUnavailableReason {
            case .podcastSeries: "Audible offers individual podcast episodes for download when available."
            case .offlineRestricted: "Audible marks this title as unavailable for offline use."
            case .unpublished: "Audible has yet to publish this title."
            case nil: "Audible marks this title as unavailable to download."
            }
        }

        var transferStage: String {
            switch transfer {
            case .waiting: "Queued"
            case .active: "In progress"
            default: ""
            }
        }
    }
}
