import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: WorkspaceModel
    let showsStatusBar: Bool
    @Binding var filters: LibraryFilters
    @AppStorage("LibrarySortField") private var sortField = LibrarySortField.title
    @AppStorage("LibrarySortDirection") private var sortDirection = LibrarySortDirection.ascending
    @FocusState private var searchFocused: Bool
    @State private var search = ""
    @State private var showingSearch = false
    @State private var editingFilter: LibraryFilters.Field?
    @State private var showingSignIn = false
    @State private var addingAccount = false
    @State private var showingImport = false

    var body: some View {
        Group {
            if model.signedIn {
                library
                    .searchable(text: $search, isPresented: $showingSearch, prompt: "Search Library")
                    .searchFocused($searchFocused)
            } else {
                ContentUnavailableView {
                    Label("Your Audible Library", systemImage: "books.vertical")
                } description: {
                    Text("Sign in to see your audiobooks and choose what to download.")
                } actions: {
                    Button("Sign In…") { openSignIn(adding: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSwitchAccounts)
                    Button("Import from Audible CLI…") { showingImport = true }
                        .disabled(!model.canSwitchAccounts)
                }
            }
        }
        .sheet(isPresented: $showingSignIn) {
            AudibleSignInView(model: model, addingAccount: addingAccount)
        }
        .sheet(isPresented: $showingImport) {
            AudibleCLIImportView(model: model)
        }
        .sheet(item: $editingFilter) { field in
            LibraryTextFilterView(field: field, value: filters[field]) { filters[field] = $0 }
        }
        .toolbar {
            if model.signedIn {
                ToolbarItemGroup {
                    Button("Refresh Library", systemImage: "arrow.clockwise", action: refresh)
                        .disabled(model.isRefreshing || model.isScanning)
                        .help("Refresh Library")

                    Menu("Sort Library", systemImage: "arrow.up.arrow.down") {
                        LibrarySortItems(actions: browseActions)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue("\(sortField.displayName), \(sortField.orderName(sortDirection))")
                    .help("Sort Library")

                    Menu {
                        LibraryFilterItems(actions: browseActions)
                    } label: {
                        Label("Filter Library", systemImage: filters.isEmpty
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue(filters.summary.formatted(.list(type: .and)))
                    .help("Filter Library")

                    Menu("Download", systemImage: "arrow.down.to.line") {
                        LibraryDownloadActions(model: model)
                    }
                    .disabled(model.books.isEmpty || !model.canRequestDownloads)
                    .labelStyle(.iconOnly)
                    .help("Download audiobooks")

                    Menu("Library Actions", systemImage: "ellipsis.circle") {
                        Button("Library Status", systemImage: "info.circle") { openWindow(id: "library-status") }
                        Button("Recheck Saved Files", systemImage: "arrow.clockwise") {
                            Task { await model.recheckFiles() }
                        }
                            .disabled(model.isScanning || model.isRefreshing || model.isCheckingFiles)
                        Divider()
                        LibraryFolderActions(model: model)
                        let selection = model.selectedAudiobooks
                        if !selection.isEmpty {
                            Divider()
                            LibraryBookActions(model: model, books: selection)
                        }
                        if model.activeAudibleClient != nil {
                            Divider()
                            Button("Audible Tools…", systemImage: "wrench.and.screwdriver") {
                                openWindow(id: "audible-tools")
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .help("Library Actions")
                }
            }
            if !model.accounts.isEmpty {
                ToolbarItem {
                    accountMenu
                }
            }
        }
        .focusedSceneValue(\.libraryWorkspaceActions, LibraryWorkspaceActions(
            find: {
                showingSearch = true
                searchFocused = true
            },
            signIn: { openSignIn(adding: model.signedIn) },
            importAccount: { showingImport = true }
        ))
        .focusedSceneValue(\.libraryBrowseActions, model.signedIn ? browseActions : nil)
        .onChange(of: model.activeAccount?.id) {
            search = ""
        }
    }

    private var browseActions: LibraryBrowseActions {
        LibraryBrowseActions(field: $sortField, direction: $sortDirection, filters: $filters) { editingFilter = $0 }
    }

    private var tableSortOrder: Binding<[KeyPathComparator<LibraryRow>]> {
        Binding {
            guard let column = sortField.column else { return [] }
            return [KeyPathComparator(column, comparator: .localizedStandard, order: sortDirection.tableOrder)]
        } set: { order in
            guard let primary = order.first,
                  let field = LibrarySortField.allCases.first(where: { $0.column == primary.keyPath }) else { return }
            sortField = field
            sortDirection = primary.order == .forward ? .ascending : .descending
        }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    Task { await model.switchAccount(to: account) }
                } label: {
                    if model.activeAccount?.id == account.id {
                        Label(account.name, systemImage: "checkmark")
                    } else {
                        Text(account.name)
                    }
                }
                .disabled(!model.canSwitchAccounts || model.activeAccount?.id == account.id)
            }
            Divider()
            Button("Add Account…") { openSignIn(adding: true) }
                .disabled(!model.canSwitchAccounts)
            Button("Import from Audible CLI…") { showingImport = true }
                .disabled(!model.canSwitchAccounts)
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
            if model.signedIn {
                Button("Sign Out", action: model.signOut)
                    .disabled(!model.canRemoveAccounts)
            }
        } label: {
            Label(model.activeAccount?.name ?? "Audible Accounts", systemImage: "person.crop.circle")
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel("Audible Accounts")
        .accessibilityValue(model.activeAccount?.name ?? "")
        .help(model.activeAccount?.name ?? "Audible Accounts")
    }

    private var library: some View {
        let rows = visibleRows
        return VStack(spacing: 0) {
            if !filters.isEmpty {
                activeFilters
                Divider()
            }
            Table(rows, selection: $model.selectedBooks, sortOrder: tableSortOrder) {
                TableColumn("Title", value: \.title) { row in
                    Text(row.title)
                        .help(row.title)
                }
                .width(min: 128, ideal: 280)
                TableColumn("Author", value: \.authors)
                    .width(min: 80, ideal: 144)
                TableColumn("Narrator", value: \.narrators)
                    .width(min: 80, ideal: 144)
                TableColumn("Download Status", value: \.statusLabel) { row in
                    Label(row.statusLabel, systemImage: row.statusSymbol)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(row.statusDetails)
                        .accessibilityValue(row.missingFilesDescription)
                }
                .width(min: 124, ideal: 144, max: 180)
            }
            .contextMenu(forSelectionType: AudibleBook.ID.self) { ids in
                let books = rows.filter { ids.contains($0.id) }.map(\.book)
                if !books.isEmpty {
                    Button("Download") { model.requestDownloads(books) }
                        .disabled(!model.canRequestDownloads)
                    Button("Download As…") { model.requestDownloads(books, customizing: true) }
                        .disabled(!model.canRequestDownloads)
                    LibraryRestartAction(model: model, books: books)
                    Divider()
                    LibraryBookActions(model: model, books: books)
                }
            }
            .overlay {
                if rows.isEmpty { emptyLibrary }
            }
            .onChange(of: Set(rows.map(\.id)), initial: true) { _, visibleIDs in
                model.selectedBooks.formIntersection(visibleIDs)
            }

            if showsStatusBar {
                Divider()
                libraryStatus(visibleCount: rows.count)
            }
        }
    }

    private var activeFilters: some View {
        let summary = filters.summary.formatted(.list(type: .and))
        return HStack(spacing: 8) {
            Label(summary, systemImage: "line.3.horizontal.decrease.circle.fill")
                .lineLimit(1)
                .help(summary)
                .accessibilityLabel("Active filters. \(summary)")
            Spacer(minLength: 8)
            Button("Clear Filters") { filters = LibraryFilters() }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if model.isRefreshing && model.books.isEmpty {
            ProgressView("Loading your library…")
                .controlSize(.regular)
        } else if model.books.isEmpty {
            ContentUnavailableView("No Audiobooks", systemImage: "books.vertical", description: Text("Your library is empty."))
        } else if !filters.isEmpty {
            ContentUnavailableView("No Matching Audiobooks", systemImage: "line.3.horizontal.decrease.circle", description: Text("Change the filters or search to show more books."))
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private func libraryStatus(visibleCount: Int) -> some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusSummary(visibleCount: visibleCount)
                    Spacer(minLength: 12)
                    matchedFolder
                }
                VStack(alignment: .leading, spacing: 4) {
                    statusSummary(visibleCount: visibleCount)
                    matchedFolder
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Library Status", systemImage: "info.circle") { openWindow(id: "library-status") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Library Status")
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func statusSummary(visibleCount: Int) -> some View {
        HStack(spacing: 8) {
            if let activity {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(activity)
            } else {
                if visibleCount == model.books.count {
                    Text(visibleCount == 1 ? "1 audiobook" : "\(visibleCount.formatted()) audiobooks")
                } else {
                    Text("\(visibleCount.formatted()) of \(model.books.count.formatted()) audiobooks")
                }
                Text("·").accessibilityHidden(true)
                Text("\(model.selectedBooks.count.formatted()) selected")
                Text("·").accessibilityHidden(true)
                Text("\(model.missingBooks.count.formatted()) to download")
            }
        }
    }

    private var activity: String? {
        if model.isScanning { return "Matching audio files…" }
        if model.isRefreshing { return "Refreshing library…" }
        if model.isCheckingFiles { return "Checking saved files…" }
        return nil
    }

    @ViewBuilder
    private var matchedFolder: some View {
        if let folder = model.localMatches.directory {
            Label(folder.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("Matched folder \(folder.lastPathComponent)")
                .help(folder.path(percentEncoded: false))
        }
    }

    private var visibleRows: [LibraryRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = model.books.compactMap { book -> LibraryRow? in
            guard filters.matches(book) else { return nil }
            let status = model.downloadStatus(for: book)
            guard filters.status.map({ $0 == status }) ?? true else { return nil }
            let row = LibraryRow(book: book, status: status, missingFiles: model.missingOutputFiles(for: book))
            return query.isEmpty || row.matches(query) ? row : nil
        }
        return sortField.sorted(rows, direction: sortDirection)
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    private func openSignIn(adding: Bool) {
        addingAccount = adding
        showingSignIn = true
    }
}

struct AudibleSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let model: WorkspaceModel
    let addingAccount: Bool

    @FocusState private var addressFocused: Bool
    @State private var address = ""
    @State private var issue: WorkspaceModel.Notice?
    @State private var marketplace: AudibleMarketplace
    @State private var accountName: String
    @State private var legacyUsername = false
    @State private var attempt: AudibleSignIn?
    private let reconnecting: Bool

    init(model: WorkspaceModel, addingAccount: Bool = false) {
        self.model = model
        self.addingAccount = addingAccount
        reconnecting = !addingAccount && model.activeAccount != nil
        _marketplace = State(initialValue: model.activeAccount?.marketplace ?? model.marketplace)
        _accountName = State(initialValue: addingAccount ? "" : (model.activeAccount?.name ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign In to Audible")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if let attempt {
                Text("Sign in through your browser. When the final page loads, copy the full address from the address bar and paste it below.")
                Button("Open Sign-In Page", systemImage: "safari") {
                    addressFocused = true
                    openURL(attempt.url)
                }
                .keyboardShortcut("b", modifiers: [.control, .shift])
                .disabled(model.signInBusy)

                SecureField("Browser address", text: $address, prompt: Text("Paste the browser address"))
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .disabled(model.signInBusy)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if reconnecting {
                        LabeledContent("Account", value: accountName)
                        LabeledContent("Marketplace", value: marketplace.displayName)
                    } else {
                        LabeledContent("Account name") {
                            TextField("Account name", text: $accountName, prompt: Text("Optional"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker("Marketplace", selection: $marketplace) {
                            ForEach(AudibleMarketplace.allCases) { marketplace in
                                Text(marketplace.displayName).tag(marketplace)
                            }
                        }
                    }
                    if marketplace.supportsLegacySignIn {
                        Toggle("Sign in with a legacy Audible username", isOn: $legacyUsername)
                            .toggleStyle(.checkbox)
                    }
                }
                .disabled(model.signInBusy)
            }

            if let issue {
                Label(issue.message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(issue.title). \(issue.message)")
            }

            HStack {
                if model.signInBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Signing in")
                }
                if attempt != nil {
                    Button("Start Again", action: reset)
                        .keyboardShortcut("n", modifiers: [.control, .shift])
                        .disabled(model.signInBusy)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.signInBusy)

                if let attempt {
                    Button("Sign In") { finish(attempt) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.signInBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Continue", action: begin)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.signInBusy)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(model.signInBusy)
        .onDisappear {
            if let attempt, model.signIn?.url == attempt.url {
                model.signIn = nil
            }
        }
    }

    private func begin() {
        issue = nil
        Task {
            guard model.signIn == nil else {
                issue = WorkspaceModel.Notice(
                    title: "Sign-in already open",
                    message: "Finish signing in from the other window."
                )
                return
            }
            await model.beginSignIn(
                marketplace: marketplace, name: accountName.trimmingCharacters(in: .whitespacesAndNewlines),
                legacyUsername: legacyUsername && marketplace.supportsLegacySignIn, addingAccount: addingAccount
            )
            attempt = model.signIn
            if attempt == nil { readIssue() }
        }
    }

    private func finish(_ attempt: AudibleSignIn) {
        issue = nil
        Task {
            if await model.finishSignIn(attempt, redirect: address) {
                address = ""
                dismiss()
            } else {
                readIssue()
            }
        }
    }

    private func reset() {
        model.signIn = nil
        attempt = nil
        address = ""
        issue = nil
    }

    private func readIssue() {
        issue = model.notice
        model.notice = nil
    }
}

struct DownloadOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    let request: DownloadRequest

    @State private var options: DownloadOptions
    @State private var directory: URL
    @State private var template: String

    init(model: WorkspaceModel, request: DownloadRequest) {
        self.model = model
        self.request = request
        var options = model.downloadOptions
        if request.requestsAudio { options.downloadAudio = true }
        _options = State(initialValue: options)
        _directory = State(initialValue: model.outputDirectory)
        _template = State(initialValue: model.folderTemplate)
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                form.padding(24)
                ScrollView { form.padding(24) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.restartsIncomplete ? "Restart" : "Download", action: startDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!layout.isValid || !options.hasSelection || !model.canStartDownloads)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560)
        .frame(minHeight: 280, maxHeight: 520)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if request.books.count == 1, let book = request.books.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.restartsIncomplete ? "Restart Download" : "Download Audiobook")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(book.title).foregroundStyle(.secondary)
                }
            } else {
                Text(request.restartsIncomplete
                     ? "Restart \(request.books.count.formatted()) Downloads"
                     : "Download \(request.books.count.formatted()) Audiobooks")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Download audio", isOn: $options.downloadAudio)
                    .disabled(request.restartsIncomplete)
                Toggle("Convert to \(model.conversionPreferences.format.displayName)", isOn: $options.convert)
                    .disabled(!options.downloadAudio)
                if options.downloadAudio && options.convert {
                    Toggle("Keep the original after conversion", isOn: $options.keepOriginal)
                        .padding(.leading, 20)
                    Text(model.conversionPreferences.chapterMode.displayName)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.leading, 20)
                }
                Toggle("Download companion PDFs when available", isOn: $options.downloadPDF)
                Toggle("Save cover images as separate files", isOn: $options.downloadCover)
                Toggle("Save chapters as JSON", isOn: $options.downloadChapters)
                Toggle("Save annotations as JSON", isOn: $options.downloadAnnotations)
            }
            .toggleStyle(.checkbox)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                DestinationPicker(directory: $directory)
                    .disabled(request.restartsIncomplete)
                LabeledContent("Folder template") {
                    TextField("Folder template", text: $template)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                Text("Use fields such as {format}, {author}, {title}, and {asin}. Separate folders with /.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !layout.isValid {
                    Label("Check the folder and filename templates in Settings.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else if let book = request.books.first {
                    destinationPreview(for: book)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var layout: ArchiveLayout {
        ArchiveLayout(root: directory, template: template, filenameStyle: model.filenameStyle,
                      filenameLength: model.filenameLength, naming: model.outputNaming)
    }

    private func destinationPreview(for book: AudibleBook) -> some View {
        let preferredFormat = model.apiOptions.format == .aaxcOnly ? "aaxc" : "aax"
        let existingFormat = request.restartsIncomplete ? nil
            : model.previewSourceFormat(for: book, downloadingAudio: options.downloadAudio)
        let sourceFormat = existingFormat ?? preferredFormat
        let usesAudibleFilename = layout.naming.keepOriginalAAXFilename && sourceFormat == "aax" && existingFormat == nil
        return VStack(alignment: .leading, spacing: 4) {
            Text("Example paths")
                .font(.callout.bold())
            if options.savesOriginal, let path = previewPath(for: book, format: sourceFormat, folderOnly: usesAudibleFilename) {
                Text(path).help(path)
                if usesAudibleFilename {
                    Text("Uses Audible’s AAX filename when available.")
                        .font(.callout)
                        .lineLimit(nil)
                }
            }
            if options.makesConversion, let path = previewPath(
                for: book, format: model.conversionPreferences.format.fileExtension,
                separateChapter: model.conversionPreferences.chapterMode == .separate
            ) {
                Text(path).help(path)
            }
            if !options.downloadAudio && options.hasSelection,
               let path = previewPath(for: book, format: existingFormat ?? "extras", folderOnly: true) {
                Text(path).help(path)
            }
        }
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.top, 4)
    }

    private func previewPath(
        for book: AudibleBook, format: String, separateChapter: Bool = false, folderOnly: Bool = false
    ) -> String? {
        let title = ArchiveTitle(book)
        let chapterNumber = separateChapter ? 1 : nil
        let chapterTitle = separateChapter ? "First Chapter" : nil
        return layout.previewPath(
            for: title, format: format, chapterNumber: chapterNumber, chapterTitle: chapterTitle, folderOnly: folderOnly
        )
    }

    private func startDownload() {
        guard layout.isValid, options.hasSelection, model.canStartDownloads else { return }
        model.outputDirectory = directory
        model.folderTemplate = template
        model.downloadOptions = options
        dismiss()
        model.startDownloads(for: request.books, options: options, restartsIncomplete: request.restartsIncomplete)
    }
}
