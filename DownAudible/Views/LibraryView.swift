import AppKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: WorkspaceModel
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AudibleBook.title, comparator: .localizedStandard)]
    @State private var showingSignIn = false
    @State private var addingAccount = false
    @State private var showingImport = false

    var body: some View {
        Group {
            if model.signedIn {
                library
                    .searchable(text: $search, prompt: "Title, author, narrator or ASIN")
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
        .toolbar {
            if model.signedIn {
                ToolbarItemGroup {
                    Button("Refresh Library", systemImage: "arrow.clockwise", action: refresh)
                        .disabled(model.isRefreshing || model.isScanning)
                        .help("Refresh Library")

                    Menu("Download", systemImage: "arrow.down.to.line") {
                        Button("Download Selected…", action: downloadSelection)
                            .disabled(model.selectedBooks.isEmpty)
                        Button("Download Entire Library…", action: downloadLibrary)
                    }
                    .disabled(model.books.isEmpty || model.isTransferring)
                    .help("Download audiobooks")

                    Menu("Library Actions", systemImage: "ellipsis.circle") {
                        matchingFolderActions
                    }
                    .help("Library Actions")
                }
            }
            if !model.accounts.isEmpty {
                ToolbarItem {
                    accountMenu
                }
            }
        }
        .onChange(of: model.activeAccount?.id) {
            search = ""
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
            SettingsLink { Text("Settings…") }
            if model.signedIn {
                Button("Sign Out", action: model.signOut)
                    .disabled(!model.canRemoveAccounts)
            }
        } label: {
            Label(model.activeAccount?.name ?? "Audible Accounts", systemImage: "person.crop.circle")
        }
        .accessibilityLabel("Audible Accounts")
        .help(model.activeAccount?.name ?? "Audible Accounts")
    }

    private var library: some View {
        let books = visibleBooks
        return VStack(spacing: 0) {
            Table(books, selection: $model.selectedBooks, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { book in
                    Text(book.title)
                        .help(book.title)
                }
                .width(min: 150, ideal: 280)
                TableColumn("Author", value: \.tableAuthors)
                    .width(min: 100, ideal: 144)
                TableColumn("Narrator", value: \.tableNarrators)
                    .width(min: 100, ideal: 144)
                TableColumn("Status") { book in
                    Text(status(for: book))
                        .foregroundStyle(.secondary)
                }
                .width(min: 84, ideal: 104, max: 140)
            }
            .contextMenu(forSelectionType: AudibleBook.ID.self) { ids in
                Button("Download…") { download(ids) }
                    .disabled(ids.isEmpty || model.isTransferring)
                if ids.count == 1, let book = books.first(where: { ids.contains($0.id) }) {
                    Divider()
                    bookActions(book)
                }
            }
            .overlay {
                if books.isEmpty { emptyLibrary }
            }
            .onChange(of: search) {
                model.selectedBooks.formIntersection(visibleBooks.map(\.id))
            }

            Divider()
            libraryStatus(visibleCount: books.count)
        }
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if model.isRefreshing && model.books.isEmpty {
            ProgressView("Loading your library…")
                .controlSize(.regular)
        } else if model.books.isEmpty {
            ContentUnavailableView("No Audiobooks", systemImage: "books.vertical", description: Text("Your library is empty."))
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private func libraryStatus(visibleCount: Int) -> some View {
        HStack(spacing: 8) {
            if model.isScanning {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Matching audio files…")
            } else if model.isRefreshing {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Refreshing library…")
            } else {
                if visibleCount == model.books.count {
                    Text(visibleCount == 1 ? "1 audiobook" : "\(visibleCount.formatted()) audiobooks")
                } else {
                    Text("\(visibleCount.formatted()) of \(model.books.count.formatted()) audiobooks")
                }
                if !model.selectedBooks.isEmpty {
                    Text("·").accessibilityHidden(true)
                    Text("\(model.selectedBooks.count.formatted()) selected")
                }
            }
            Spacer()
            if let folder = model.localMatches.directory {
                Label(folder.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Matched folder \(folder.lastPathComponent)")
                    .help(folder.path(percentEncoded: false))
            }
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var matchingFolderActions: some View {
        Button("Match Existing Folder…", action: chooseMatchFolder)
            .disabled(model.isScanning || model.isRefreshing)

        if let folder = model.localMatches.directory {
            Button("Rescan Matched Folder") { scan(folder) }
                .disabled(model.isScanning || model.isRefreshing)
            Button("Show Matched Folder in Finder") { NSWorkspace.shared.open(folder) }
            Button("Stop Matching This Folder", action: model.unlinkFolder)
                .disabled(model.isScanning || model.isRefreshing)
        }

        if model.selectedBooks.count == 1, let book = model.books.first(where: { model.selectedBooks.contains($0.id) }) {
            Divider()
            bookActions(book)
        }
    }

    @ViewBuilder
    private func bookActions(_ book: AudibleBook) -> some View {
        let matches = model.localAudio(for: book)
        let files = matches.isEmpty ? model.exportedFiles[book.id, default: []] : matches
        Button(matches.isEmpty ? "Match to Audio Files…" : "Change Matched Files…") {
            let urls = Panels.openAudio(allowFolders: false)
            if !urls.isEmpty { model.match(book, to: urls) }
        }
        .disabled(model.isScanning)

        if !files.isEmpty {
            Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
        }

        if !matches.isEmpty {
            Button("Remove File Match") { model.removeMatch(book) }
                .disabled(model.isScanning)
        }
    }

    private var visibleBooks: [AudibleBook] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let books = query.isEmpty ? model.books : model.books.filter { book in
            book.title.localizedStandardContains(query)
                || book.tableAuthors.localizedStandardContains(query)
                || book.tableNarrators.localizedStandardContains(query)
                || book.asin.localizedStandardContains(query)
        }
        return books.sorted(using: sortOrder)
    }

    private func status(for book: AudibleBook) -> String {
        if !model.exportedFiles[book.id, default: []].isEmpty { return "Saved" }
        if !model.localAudio(for: book).isEmpty { return "Matched" }
        return book.isDownloadable ? "Available" : "Unavailable"
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    private func openSignIn(adding: Bool) {
        addingAccount = adding
        showingSignIn = true
    }

    private func downloadSelection() { download(model.selectedBooks) }

    private func download(_ ids: Set<AudibleBook.ID>) {
        model.requestDownloads(visibleBooks.filter { ids.contains($0.id) })
    }

    private func downloadLibrary() {
        model.requestDownloads(model.books.sorted(using: sortOrder))
    }

    private func chooseMatchFolder() {
        if let folder = Panels.openFolder() { scan(folder) }
    }

    private func scan(_ folder: URL) {
        Task { await model.scanMatches(in: folder) }
    }
}

private extension AudibleBook {
    var tableAuthors: String { authors.isEmpty ? "—" : authors.joined(separator: ", ") }
    var tableNarrators: String { narrators.isEmpty ? "—" : narrators.joined(separator: ", ") }
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
        _options = State(initialValue: model.downloadOptions)
        _directory = State(initialValue: model.outputDirectory)
        _template = State(initialValue: model.folderTemplate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if request.books.count == 1, let book = request.books.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Audiobook")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(book.title).foregroundStyle(.secondary)
                }
            } else {
                Text("Download \(request.books.count.formatted()) Audiobooks")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Download audio", isOn: $options.downloadAudio)
                Toggle("Convert to M4B", isOn: $options.convert)
                    .disabled(!options.downloadAudio)
                if options.downloadAudio && options.convert {
                    Toggle("Keep the original after conversion", isOn: $options.keepOriginal)
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
                LabeledContent("Folder template") {
                    TextField("Folder template", text: $template)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                Text("Use {format}, {author}, {title}, or {asin}. Separate folders with /.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !layout.isValid {
                    Label("Enter a valid folder template.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else if let book = request.books.first {
                    destinationPreview(for: book)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: startDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!layout.isValid || !options.hasSelection || model.isTransferring)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var layout: ArchiveLayout { ArchiveLayout(root: directory, template: template) }

    private func destinationPreview(for book: AudibleBook) -> some View {
        let preferredFormat = model.apiOptions.format == .aaxcOnly ? "aaxc" : "aax"
        let knownAudio = model.localAudio(for: book) + model.exportedFiles[book.id, default: []]
        let existingFormat = knownAudio.map { $0.pathExtension.lowercased() }
            .first { ["aax", "aaxc", "aa", "mp3"].contains($0) }
        let sourceFormat = existingFormat ?? preferredFormat
        return VStack(alignment: .leading, spacing: 4) {
            Text("Example folders")
                .font(.callout.bold())
            if options.savesOriginal, let path = previewPath(for: book, format: sourceFormat) {
                Text(path)
            }
            if options.makesM4B, let path = previewPath(for: book, format: "m4b") {
                Text(path)
            }
            if !options.downloadAudio && options.hasSelection,
               let path = previewPath(for: book, format: existingFormat ?? "extras") {
                Text(path)
            }
        }
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.top, 4)
    }

    private func previewPath(for book: AudibleBook, format: String) -> String? {
        guard let result = try? layout.directory(for: ArchiveTitle(book), format: format) else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        return result.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/") + "/"
    }

    private func startDownload() {
        guard layout.isValid, options.hasSelection else { return }
        model.outputDirectory = directory
        model.folderTemplate = template
        dismiss()
        model.startDownloads(for: request.books, options: options)
    }
}
