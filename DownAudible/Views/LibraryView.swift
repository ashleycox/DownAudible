import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: WorkspaceModel
    let showsStatusBar: Bool
    @Binding var sort: LibrarySort
    @Binding var filters: LibraryFilters
    @AppStorage("LibraryColumnCustomization") private var columnCustomization: TableColumnCustomization<LibraryRow>
    @AppStorage(LibraryFilters.suggestionsPreferenceKey) private var showsFilterSuggestions = true
    @FocusState private var searchFocused: Bool
    @State private var search = ""
    @State private var showingSearch = false
    @State private var editingFilter: LibraryFilters.Field?
    @State private var organizationSheet: LibraryOrganizationSheet?
    @State private var showingCatalogChanges = false
    @State private var showingAllAccounts = false
    @State private var showingSignIn = false
    @State private var addingAccount = false
    @State private var showingImport = false

    var body: some View {
        let rows = model.signedIn ? visibleRows : []
        let visibleBooks = rows.map(\.book)
        Group {
            if model.signedIn {
                library(rows: rows)
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
                        .appHelp("Connect your Audible account to load its library.")
                    Button("Import Account…") { showingImport = true }
                        .disabled(!model.canSwitchAccounts)
                        .appHelp("Use a saved Audible CLI or OpenAudible sign-in to connect your account.")
                }
            }
        }
        #if HELP_SCREENSHOTS
        .onAppear {
            if let query = model.helpScreenshotSearch {
                search = query
                showingSearch = true
            }
        }
        #endif
        .sheet(isPresented: $showingSignIn) {
            AudibleSignInView(model: model, addingAccount: addingAccount)
        }
        .sheet(isPresented: $showingImport) {
            AudibleAccountImportView(model: model)
        }
        .sheet(item: $editingFilter) { field in
            LibraryTextFilterView(field: field, value: filters[field], suggestions: suggestions(for: field)) { filters[field] = $0 }
        }
        .sheet(item: $organizationSheet) { sheet in
            switch sheet {
            case .save(let account):
                LibrarySaveViewSheet(saved: model.libraryOrganization.savedViews(for: account)) { name in
                    let view = SavedLibraryView(name: name, search: search, sort: sort, filters: filters)
                    model.libraryOrganization.save(view, for: account)
                }
            case .manage(let account):
                LibraryManageViewsSheet(model: model, account: account)
            case .tags(let account, let books):
                LibraryTagsSheet(model: model, account: account, books: books)
            }
        }
        .sheet(isPresented: $showingCatalogChanges) { LibraryChangesView(snapshot: model.currentCatalog) }
        .sheet(isPresented: $showingAllAccounts) { AllAccountsLibraryView(model: model) }
        .toolbar {
            if model.signedIn {
                ToolbarItemGroup {
                    Button("Refresh Library", systemImage: "arrow.clockwise", action: refresh)
                        .disabled(!model.canRefreshLibrary)
                        .appHelp("Fetch the latest information from your Audible library.")

                    Menu(LibraryBrowseMenu.sort.rawValue, systemImage: "arrow.up.arrow.down") {
                        LibrarySortItems(actions: browseActions)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue("\(sort.field.displayName), \(sort.field.orderName(sort.direction))")
                    .appHelp("Choose how audiobooks are ordered. Open this menu with Shift–Command–S.")

                    Menu {
                        LibraryFilterItems(actions: browseActions)
                        Menu("Saved Views") { LibrarySavedViewItems(actions: browseActions) }
                    } label: {
                        Label(LibraryBrowseMenu.filter.rawValue, systemImage: filters.isEmpty
                              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue(filters.summary.formatted(.list(type: .and)))
                    .appHelp("Narrow the library by book details or download status. Open this menu with Shift–Command–F.")

                    Menu("Download", systemImage: "arrow.down.to.line") {
                        LibraryDownloadActions(model: model, visibleBooks: visibleBooks)
                    }
                    .disabled(model.books.isEmpty || !(model.canRequestDownloads || model.canAddToDownloadQueue))
                    .labelStyle(.iconOnly)
                    .appHelp("Choose which audiobooks to download and whether to review the batch settings first.")

                    Menu("Library Actions", systemImage: "ellipsis.circle") {
                        Button("Library Status", systemImage: "info.circle") { openWindow(id: "library-status") }
                            .appHelp("See which books have saved audio, need a download, or are unavailable.")
                        Button("Recheck Saved Files", systemImage: "arrow.clockwise") {
                            Task { await model.recheckFiles() }
                        }
                            .disabled(model.isScanning || model.isRefreshing || model.isCheckingFiles)
                            .appHelp("Check that audio files in the archive and matched folder are still present.")
                        ArchiveVerificationButton(model: model)
                        Button("Library Changes…") { showingCatalogChanges = true }
                            .disabled(model.currentCatalog == nil)
                        Button("Refresh All Accounts") { Task { await model.refreshAllAccounts() } }
                            .disabled(!model.canSwitchAccounts)
                        LibraryVisibleExportMenu(model: model, books: visibleBooks)
                        Divider()
                        LibraryFolderActions(model: model)
                        let selection = model.selectedAudiobooks
                        if !selection.isEmpty {
                            Divider()
                            LibraryBookActions(model: model, books: selection, editTags: editTags)
                        }
                        if model.activeAudibleClient != nil {
                            Divider()
                            Button("Audible Tools…", systemImage: "wrench.and.screwdriver") {
                                openWindow(id: "audible-tools")
                            }
                            .appHelp("Open the Wish List, catalogue search, and Audible account tools.")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .appHelp("Show file matching, saved audio, and other actions for this library.")
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
            importAccount: { showingImport = true },
            editTags: editTags,
            showChanges: { showingCatalogChanges = true },
            showAllAccounts: { showingAllAccounts = true },
            visibleBooks: visibleBooks
        ))
        .focusedSceneValue(\.libraryBrowseActions, model.signedIn ? browseActions : nil)
    }

    private var browseActions: LibraryBrowseActions {
        let account = model.activeAccountID
        return LibraryBrowseActions(
            field: $sort.field, direction: $sort.direction, filters: $filters,
            savedViews: account.map { model.libraryOrganization.savedViews(for: $0) } ?? [],
            tags: account.map { model.libraryOrganization.tags(for: $0) } ?? [],
            applyView: { view in
                search = view.search
                showingSearch = !view.search.isEmpty
                sort = view.sort
                filters = view.filters
            },
            saveView: { if let account { organizationSheet = .save(account) } },
            manageViews: { if let account { organizationSheet = .manage(account) } },
            editFilter: { editingFilter = $0 }
        )
    }

    private func editTags(_ books: [AudibleBook]) {
        if let account = model.activeAccountID, !books.isEmpty { organizationSheet = .tags(account, books) }
    }

    private func tags(for book: AudibleBook) -> [String] {
        guard let account = model.activeAccountID else { return [] }
        return model.libraryOrganization.tags(for: book.asin, account: account)
    }

    private var tableSortOrder: Binding<[KeyPathComparator<LibraryRow>]> {
        Binding {
            guard let column = sort.field.column else { return [] }
            return [KeyPathComparator(column, comparator: .localizedStandard, order: sort.direction.tableOrder)]
        } set: { order in
            guard let primary = order.first,
                  let field = LibrarySortField.allCases.first(where: { $0.column == primary.keyPath }) else { return }
            sort = LibrarySort(field: field, direction: primary.order == .forward ? .ascending : .descending)
        }
    }

    private var accountMenu: some View {
        Menu {
            Button("All Accounts…") { showingAllAccounts = true }
                .appHelp("Find audiobooks across your saved account libraries.")
            Divider()
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
                .appHelp("Show the library for \(account.name).")
            }
            Divider()
            Button("Add Account…") { openSignIn(adding: true) }
                .disabled(!model.canSwitchAccounts)
                .appHelp("Connect another Audible account.")
            Button("Import Account…") { showingImport = true }
                .disabled(!model.canSwitchAccounts)
                .appHelp("Connect another account using a saved Audible CLI or OpenAudible sign-in.")
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
                .appHelp("Open DownAudible settings.")
            if model.signedIn {
                Button("Sign Out", action: model.signOut)
                    .disabled(!model.canRemoveAccounts)
                    .appHelp("Clear the saved sign-in for the current Audible account.")
            }
        } label: {
            Label(model.activeAccount?.name ?? "Audible Accounts", systemImage: "person.crop.circle")
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel("Audible Accounts")
        .accessibilityValue(model.activeAccount?.name ?? "")
        .appHelp("Switch accounts or manage the current Audible sign-in.")
    }

    private func library(rows: [LibraryRow]) -> some View {
        VStack(spacing: 0) {
            if model.currentCatalog != nil || model.currentCatalogFailure != nil || model.currentCatalogRetry != nil {
                LibraryCatalogStatusView(catalog: model.currentCatalog, failure: model.currentCatalogFailure,
                                         retry: model.currentCatalogRetry)
                Divider()
            }
            if !filters.isEmpty {
                activeFilters
                Divider()
            }
            Table(
                rows, selection: $model.selectedBooks, sortOrder: tableSortOrder,
                columnCustomization: $columnCustomization
            ) {
                TableColumn("Title", value: \.title, comparator: .localizedStandard) { row in
                    Text(row.title)
                        .appHelp(row.title)
                }
                .width(min: 128, ideal: 280)
                .customizationID("title")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("Author", value: \.authors, comparator: .localizedStandard) { row in
                    Text(row.authors).appHelp(row.authors)
                }
                .width(min: 80, ideal: 144)
                .customizationID("author")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("Narrator", value: \.narrators, comparator: .localizedStandard) { row in
                    Text(row.narrators).appHelp(row.narrators)
                }
                .width(min: 80, ideal: 144)
                .customizationID("narrator")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("Download Status", value: \.statusLabel, comparator: .localizedStandard) { row in
                    Label(row.statusLabel, systemImage: row.statusSymbol)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .appHelp(row.statusDetails)
                        .accessibilityRepresentation {
                            Text(row.spokenStatus)
                        }
                }
                .width(min: 124, ideal: 144, max: 180)
                .customizationID("downloadStatus")
                .disabledCustomizationBehavior(.visibility)
            }
            .contextMenu(forSelectionType: AudibleBook.ID.self) { ids in
                let books = rows.filter { ids.contains($0.id) }.map(\.book)
                if !books.isEmpty {
                    if model.canAddToDownloadQueue {
                        Button("Add to Queue…") { model.reviewAddingToDownloadQueue(books) }
                            .disabled(model.downloadQueueAdditions(from: books).isEmpty)
                            .appHelp("Add these audiobooks using the running batch’s destination and options.")
                    } else {
                        Button("Download") { model.requestSelectedDownloads(books) }
                            .disabled(!model.canRequestDownloads)
                            .appHelp("Download these audiobooks using the saved settings.")
                        Button("Download As…") { model.requestDownloads(books, customizing: true) }
                            .disabled(!model.canRequestDownloads)
                            .appHelp("Review the options before downloading these audiobooks.")
                    }
                    LibraryRestartAction(model: model, books: books)
                    Divider()
                    LibraryBookActions(model: model, books: books, editTags: editTags)
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
                .appHelp(summary)
                .accessibilityLabel("Active filters. \(summary)")
            Spacer(minLength: 8)
            Button("Clear Filters") { filters = LibraryFilters() }
                .appHelp("Show all books that match the search text.")
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
                .appHelp("DownAudible is fetching audiobook information from Audible.")
        } else if model.books.isEmpty, let error = model.libraryLoadError {
            ContentUnavailableView {
                Label("Couldn’t load your library", systemImage: "exclamationmark.circle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry", action: refresh)
                    .appHelp("Try to fetch the Audible library again.")
            }
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
                .appHelp("See which books need audio or already have a local copy.")
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
                    .appHelp("DownAudible is updating library or file information.")
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
                .appHelp(folder.path(percentEncoded: false))
        }
    }

    private var visibleRows: [LibraryRow] {
        let rows = filters.rows(
            in: model.books, search: search, statusFor: model.downloadStatus, missingFiles: model.missingOutputFiles,
            tagsFor: tags
        )
        return sort.field.sorted(rows, direction: sort.direction)
    }

    private func suggestions(for field: LibraryFilters.Field) -> LibraryFilterSuggestions? {
        guard showsFilterSuggestions else { return nil }
        let rows = filters.rows(in: model.books, search: search, excluding: field,
                                statusFor: model.downloadStatus, tagsFor: tags)
        return LibraryFilterSuggestions(field: field, books: rows.map(\.book))
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    private func openSignIn(adding: Bool) {
        addingAccount = adding
        showingSignIn = true
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
                    .appHelp("Close this sheet without starting the batch.")
                Button(request.restartsIncomplete ? "Restart" : "Download", action: startDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!layout.isValid || !options.hasSelection || !model.canStartDownloads)
                    .appHelp("Start this batch using the displayed options.")
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
                    .appHelp("Include audiobook audio in this batch.")
                Toggle("Convert to \(model.conversionPreferences.format.displayName)", isOn: $options.convert)
                    .disabled(!options.downloadAudio)
                    .appHelp("Convert the audio after downloading it.")
                if options.downloadAudio && options.convert {
                    Toggle("Keep the original after conversion", isOn: $options.keepOriginal)
                        .padding(.leading, 20)
                        .appHelp("Keep the original audio alongside the converted files.")
                    Text(model.conversionPreferences.chapterMode.displayName)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.leading, 20)
                }
                Toggle("Download companion PDFs when available", isOn: $options.downloadPDF)
                    .appHelp("Save any companion PDFs Audible offers for these books.")
                Toggle("Save cover images as separate files", isOn: $options.downloadCover)
                    .appHelp("Save separate cover image files alongside the other downloads.")
                Toggle("Save chapters as JSON", isOn: $options.downloadChapters)
                    .appHelp("Save an Audible chapter list for each book as a JSON file.")
                Toggle("Save annotations as JSON", isOn: $options.downloadAnnotations)
                    .appHelp("Save Audible notes and bookmarks as JSON files.")
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
                        .appHelp("Use book details and format tokens to arrange the files from this batch into folders.")
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
                Text(path).appHelp(path)
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
                Text(path).appHelp(path)
            }
            if !options.downloadAudio && options.hasSelection,
               let path = previewPath(for: book, format: existingFormat ?? "extras", folderOnly: true) {
                Text(path).appHelp(path)
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
