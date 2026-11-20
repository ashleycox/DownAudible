import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class WorkspaceModel {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum AccountError: LocalizedError {
        case busy

        var errorDescription: String? { "Wait for the current account operation to finish, then try again." }
    }

    var page: WorkspacePage? = .library
    var marketplace: AudibleMarketplace
    var signIn: AudibleSignIn?
    var signInBusy = false
    var accountBusy = false
    var signedIn = false
    var isRefreshing = false
    var isScanning = false
    var isPreparingFiles = false
    private(set) var isCheckingFiles = false
    var books: [AudibleBook] = []
    var transfers: [Transfer] = []
    var selectedBooks: Set<AudibleBook.ID> = []
    var selectedFiles: Set<LocalAudioFile.ID> = []
    var localFiles: [LocalAudioFile] = []
    var activationBytes = ""
    var downloadRequest: DownloadRequest?
    var notice: Notice?

    var outputDirectory: URL {
        didSet {
            defaults.set(outputDirectory.path, forKey: "OutputDirectory")
            if oldValue != outputDirectory { watchFiles() }
        }
    }

    var folderTemplate: String {
        didSet { defaults.set(folderTemplate, forKey: "FolderTemplate") }
    }

    var filenameStyle: FilenameStyle {
        didSet { defaults.set(filenameStyle.rawValue, forKey: "FilenameStyle") }
    }

    var filenameLength: Int {
        didSet { defaults.set(filenameLength, forKey: "FilenameLength") }
    }

    var outputNaming: OutputNaming {
        didSet { save(outputNaming, as: "OutputNaming") }
    }

    var conversionPreferences: ConversionPreferences {
        didSet { save(conversionPreferences, as: "ConversionPreferences") }
    }

    var appleBooksDestination: AppleBooksDestination {
        didSet { defaults.set(appleBooksDestination.rawValue, forKey: "AppleBooksDestination") }
    }

    var downloadOptions: DownloadOptions {
        didSet { save(downloadOptions, as: "DownloadOptions") }
    }

    var apiOptions: AudibleAPIOptions {
        didSet { save(apiOptions, as: "AudibleAPIOptions") }
    }

    var transferPreferences: TransferPreferences {
        didSet { save(transferPreferences, as: "TransferPreferences") }
    }

    private(set) var accounts: [SavedAudibleAccount] {
        didSet { save(accounts, as: "Accounts") }
    }

    private(set) var activeAccountID: UUID? {
        didSet { defaults.set(activeAccountID?.uuidString, forKey: "ActiveAccountID") }
    }

    private(set) var localMatches: LocalMatches
    private(set) var exportedFiles: [String: [URL]] = [:]
    private var inventory: [String: ArchiveInventoryItem] = [:]
    private var validLocalMatches: [String: [URL]] = [:]
    private(set) var isTransferring = false
    private(set) var didRestoreTransfers = false

    private static let legacyBooksImportError = "The files were saved. Books couldn’t open them."

    private let defaults = UserDefaults.standard
    private let audible = AudibleClient()
    private let media = MediaTools()
    private let archive: ArchiveWorker
    private let transferLog = TransferLog()
    private let queue = TransferQueueStore()
    @ObservationIgnored private var queueSaveTask: Task<Void, Never>?
    @ObservationIgnored private var queueRevision = 0
    @ObservationIgnored private var pendingQueueWrites = 0
    @ObservationIgnored private var activeJobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var batchEncounteredError = false
    @ObservationIgnored private var outputWatcher: ArchiveWatcher?
    @ObservationIgnored private var matchWatcher: ArchiveWatcher?
    @ObservationIgnored private var fileCheckTask: Task<Void, Never>?
    @ObservationIgnored private var fileCheckRevision = 0
    @ObservationIgnored private var fallbackFileCheck: Task<Void, Never>?
    @ObservationIgnored private var activeTransfer: Task<Void, Never>?
    @ObservationIgnored private var initialLoad = false
    @ObservationIgnored private var lastBatch: TransferBatch?
    @ObservationIgnored private var pendingAccount: SavedAudibleAccount?
    @ObservationIgnored private var matchesByAccount: [UUID: LocalMatches]

    init() {
        archive = ArchiveWorker(media: media)
        marketplace = defaults.string(forKey: "Marketplace")
            .flatMap(AudibleMarketplace.init(rawValue:)) ?? .unitedKingdom
        if let path = defaults.string(forKey: "OutputDirectory") {
            outputDirectory = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            outputDirectory = URL.documentsDirectory.appending(component: "Audiobooks", directoryHint: .isDirectory)
        }
        folderTemplate = defaults.string(forKey: "FolderTemplate") ?? ArchiveLayout.defaultTemplate
        filenameStyle = defaults.string(forKey: "FilenameStyle").flatMap(FilenameStyle.init(rawValue:)) ?? .unicode
        filenameLength = (defaults.object(forKey: "FilenameLength") as? Int) ?? 230
        outputNaming = Self.load("OutputNaming", from: defaults) ?? OutputNaming()
        conversionPreferences = Self.load("ConversionPreferences", from: defaults) ?? ConversionPreferences()
        appleBooksDestination = defaults.string(forKey: "AppleBooksDestination").flatMap(AppleBooksDestination.init(rawValue:)) ?? .off
        downloadOptions = Self.load("DownloadOptions", from: defaults) ?? DownloadOptions()
        apiOptions = Self.load("AudibleAPIOptions", from: defaults) ?? AudibleAPIOptions()
        transferPreferences = Self.load("TransferPreferences", from: defaults) ?? TransferPreferences()
        accounts = Self.load("Accounts", from: defaults) ?? []
        activeAccountID = defaults.string(forKey: "ActiveAccountID").flatMap(UUID.init(uuidString:))
        matchesByAccount = Self.load("AccountMatches", from: defaults) ?? [:]
        localMatches = Self.load("LocalMatches", from: defaults) ?? LocalMatches()
    }

    var layout: ArchiveLayout {
        ArchiveLayout(
            root: outputDirectory, template: folderTemplate, filenameStyle: filenameStyle,
            filenameLength: filenameLength, naming: outputNaming
        )
    }

    var activeAccount: SavedAudibleAccount? { accounts.first { $0.id == activeAccountID } }
    var canSwitchAccounts: Bool { didRestoreTransfers && !accountBusy && !signInBusy && !isRefreshing && !isScanning }
    var canRemoveAccounts: Bool { canSwitchAccounts && !isTransferring }
    var activeAudibleClient: AudibleClient? { signedIn ? client(for: activeAccount) : nil }
    var hasPendingQueueWrite: Bool { queueSaveTask != nil || pendingQueueWrites > 0 }
    var canRetry: Bool { canRetryTransfers && transfers.contains(where: \.canRetry) }
    var canRestart: Bool { canRetryTransfers && transfers.contains(where: \.canRestart) }
    var canClearCompleted: Bool {
        !isTransferring && transfers.contains { if case .done(_, nil) = $0.status { true } else { false } }
    }
    private var canRetryTransfers: Bool {
        guard !isTransferring, let batch = lastBatch else { return false }
        if batch.work.contains(where: \.isDownload) {
            guard let id = batch.account?.id else { return false }
            return accounts.contains { $0.id == id }
        }
        return true
    }

    var missingBooks: [AudibleBook] {
        books.filter { book in
            LibraryAudioCategory(status: downloadStatus(for: book), isDownloadable: book.isDownloadable) == .toDownload
        }
    }

    var activeLibraryAudioTransfers: [AudibleBook.ID: Transfer.Status] {
        guard isTransferring, let batch = lastBatch, let accountID = activeAccountID,
              batch.account?.id == accountID, batch.options.downloadAudio else { return [:] }
        return zip(batch.work, transfers).reduce(into: [:]) { result, pair in
            let (work, transfer) = pair
            if case .library(let book, _) = work, !transfer.isFinished {
                result[book.id] = transfer.status
            }
        }
    }

    var canDownloadMissing: Bool {
        canRequestDownloads && !isRefreshing && !isScanning && !isCheckingFiles && !missingBooks.isEmpty
    }

    var canStartDownloads: Bool { didRestoreTransfers && signedIn && !accountBusy && !signInBusy && !isTransferring }
    var canRequestDownloads: Bool { canStartDownloads && downloadRequest == nil }
    var selectedAudiobooks: [AudibleBook] { books.filter { selectedBooks.contains($0.id) } }

    var finishedCount: Int { transfers.count(where: \.isFinished) }

    private var enteredActivationBytes: String? {
        let value = activationBytes.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var hasValidActivationBytes: Bool {
        guard let value = enteredActivationBytes else { return true }
        return MediaCredentials(activationBytes: value).hasActivationBytes
    }

    func load() async {
        guard !initialLoad else { return }
        initialLoad = true
        watchFiles()
        startFallbackFileCheck()
        await restoreTransfers()
        didRestoreTransfers = true
        do {
            if accounts.isEmpty, try audible.hasSession() {
                let account = SavedAudibleAccount(id: UUID(), name: marketplace.displayName, marketplace: marketplace, usesLegacySession: true)
                accounts = [account]
                activeAccountID = account.id
            }
            migrateLibrarySort()
            if let account = activeAccount ?? accounts.first {
                try await activate(account)
            }
        } catch {
            show("Couldn’t open the saved session", error: error)
        }
    }

    func beginSignIn(
        marketplace: AudibleMarketplace,
        name: String = "",
        legacyUsername: Bool = false,
        addingAccount: Bool = false
    ) async {
        guard canSwitchAccounts else { return }
        signInBusy = true
        defer { signInBusy = false }
        let account = if !addingAccount, let activeAccount, activeAccount.marketplace == marketplace {
            activeAccount
        } else {
            SavedAudibleAccount(id: UUID(), name: Self.accountName(name, marketplace), marketplace: marketplace)
        }
        do {
            signIn = try await client(for: account).beginSignIn(marketplace: marketplace, legacyUsername: legacyUsername)
            pendingAccount = account
        } catch {
            show("Couldn’t start sign-in", error: error)
        }
    }

    @discardableResult
    func finishSignIn(_ attempt: AudibleSignIn, redirect: String) async -> Bool {
        guard !signInBusy, let account = pendingAccount else { return false }
        guard let url = URL(string: redirect.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host() != nil else {
            notice = Notice(title: "Check the address", message: "Paste the full address from your browser after signing in.")
            return false
        }
        signInBusy = true
        defer { signInBusy = false }
        do {
            try await client(for: account).completeSignIn(attempt, redirectURL: url)
            store(account)
            pendingAccount = nil
            signIn = nil
            try await activate(account)
            return true
        } catch {
            show("Couldn’t sign in", error: error)
            return false
        }
    }

    func switchAccount(to account: SavedAudibleAccount) async {
        guard canSwitchAccounts, account.id != activeAccountID else { return }
        accountBusy = true
        defer { accountBusy = false }
        do {
            try await activate(account)
        } catch {
            show("Couldn’t open this account", error: error)
        }
    }

    func signOut() {
        guard canRemoveAccounts, let account = activeAccount else { return }
        do {
            try client(for: account).signOut()
            clearLibrary()
        } catch {
            show("Couldn’t sign out", error: error)
        }
    }

    func renameAccount(_ account: SavedAudibleAccount, to name: String) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].name = Self.accountName(name, account.marketplace)
        }
    }

    func librarySort(for accountID: UUID) -> LibrarySort {
        accounts.first { $0.id == accountID }?.librarySort ?? LibrarySort()
    }

    func setLibrarySort(_ sort: LibrarySort, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].librarySort != sort else { return }
        accounts[index].librarySort = sort
    }

    private func migrateLibrarySort() {
        let field = defaults.string(forKey: "LibrarySortField")
        let direction = defaults.string(forKey: "LibrarySortDirection")
        guard field != nil || direction != nil else { return }
        let previous = LibrarySort(
            field: field.flatMap(LibrarySortField.init(rawValue:)) ?? .title,
            direction: direction.flatMap(LibrarySortDirection.init(rawValue:)) ?? .ascending
        )
        let migrated = accounts.map { account in
            var account = account
            if account.librarySort == nil { account.librarySort = previous }
            return account
        }
        if migrated != accounts { accounts = migrated }
        defaults.removeObject(forKey: "LibrarySortField")
        defaults.removeObject(forKey: "LibrarySortDirection")
    }

    func removeAccount(_ account: SavedAudibleAccount) async {
        guard canRemoveAccounts else { return }
        accountBusy = true
        defer { accountBusy = false }
        do {
            try client(for: account).signOut()
            accounts.removeAll { $0.id == account.id }
            matchesByAccount.removeValue(forKey: account.id)
            save(matchesByAccount, as: "AccountMatches")
            if activeAccountID == account.id {
                clearLibrary()
                activeAccountID = nil
                if let next = accounts.first { try await activate(next) }
            }
        } catch {
            show("Couldn’t remove the account", error: error)
        }
    }

    func cliProfiles(config: URL) async throws -> [AudibleCLIProfile] {
        try await audible.cliProfiles(config: config)
    }

    func inspectAuthFile(_ url: URL) async throws -> Bool {
        try await audible.inspectAuthFile(url)
    }

    func importAccount(from url: URL, name: String, password: String?, marketplace: AudibleMarketplace?) async throws {
        guard canSwitchAccounts else { throw AccountError.busy }
        accountBusy = true
        defer { accountBusy = false }
        let id = UUID()
        let accepted = try await audible.scoped(to: id, options: apiOptions).importAuthFile(url, password: password, marketplace: marketplace)
        let account = SavedAudibleAccount(id: id, name: Self.accountName(name, accepted), marketplace: accepted)
        store(account)
        try await activate(account)
    }

    private func activate(_ account: SavedAudibleAccount) async throws {
        let hasSession = try client(for: account).hasSession()
        clearLibrary()
        activeAccountID = account.id
        if let matches = matchesByAccount[account.id] {
            localMatches = matches
        } else if account.usesLegacySession {
            localMatches = Self.load("LocalMatches", from: defaults) ?? LocalMatches()
        } else {
            localMatches = LocalMatches()
        }
        marketplace = account.marketplace
        defaults.set(marketplace.rawValue, forKey: "Marketplace")
        signedIn = hasSession
        watchFiles()
        if signedIn { await refresh() }
    }

    private func clearLibrary() {
        signedIn = false
        books = []
        selectedBooks = []
        downloadRequest = nil
        exportedFiles = [:]
        inventory = [:]
        validLocalMatches = [:]
    }

    private func store(_ account: SavedAudibleAccount) {
        if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
    }

    private static func accountName(_ name: String, _ marketplace: AudibleMarketplace) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? marketplace.displayName : trimmed
    }

    private func client(for account: SavedAudibleAccount?, with settings: AudibleAPIOptions? = nil) -> AudibleClient {
        var options = settings ?? apiOptions
        let calendar = Calendar.current
        options.purchaseStart = options.purchaseStart.map { calendar.startOfDay(for: $0) }
        options.purchaseEnd = options.purchaseEnd.flatMap { calendar.dateInterval(of: .day, for: $0) }?
            .end.addingTimeInterval(-0.000_001)
        let profileID = account?.usesLegacySession == false ? account?.id : nil
        return audible.scoped(to: profileID, options: options)
    }

    private func archiveID(for account: SavedAudibleAccount) -> String {
        account.usesLegacySession ? account.marketplace.rawValue : account.id.uuidString
    }

    func refresh() async {
        guard signedIn, !isRefreshing, !isScanning else { return }
        if let start = apiOptions.purchaseStart, let end = apiOptions.purchaseEnd,
           Calendar.current.compare(start, to: end, toGranularity: .day) == .orderedDescending {
            notice = Notice(title: "Check the purchase dates", message: "Choose an end date on or after the start date in Settings.")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            books = try await client(for: activeAccount).library()
            selectedBooks.formIntersection(books.map(\.id))
            await refreshExportStatus()
            if let directory = localMatches.directory { await scanMatches(in: directory) }
        } catch is CancellationError {
            return
        } catch {
            show("Couldn’t load your library", error: error)
        }
    }

    func refreshExportStatus() async {
        await recheckFiles()
    }

    func recheckFiles() async {
        guard signedIn, let account = activeAccount else { return }
        fileCheckRevision += 1
        let revision = fileCheckRevision
        isCheckingFiles = true
        defer { if fileCheckRevision == revision { isCheckingFiles = false } }
        let layout = layout
        let ids = books.map(\.id)
        let matches = Dictionary(uniqueKeysWithValues: ids.map { ($0, localMatches.files(for: $0)) })
        let current = await archive.inventory(for: ids, account: archiveID(for: account), layout: layout)
        let valid = await archive.validMatches(matches)
        guard signedIn, activeAccountID == account.id, self.layout == layout,
              fileCheckRevision == revision, !Task.isCancelled else { return }
        inventory = current
        validLocalMatches = valid
        exportedFiles = current.mapValues(\.files).filter { !$0.value.isEmpty }
    }

    func downloadStatus(for book: AudibleBook) -> LibraryDownloadStatus {
        let item = inventory[book.id]
        if !(item?.files.isEmpty ?? true) { return .downloaded }
        if !(validLocalMatches[book.id]?.isEmpty ?? true) { return .matched }
        if item?.hasPartial == true { return .partial }
        if item?.hadAudio == true || !localMatches.files(for: book.id).isEmpty { return .missing }
        return book.isDownloadable ? .notDownloaded : .unavailable
    }

    func originalFiles(for book: AudibleBook) -> [URL] {
        let matchedOriginals = (validLocalMatches[book.id] ?? []).filter {
            ["aax", "aaxc", "aa"].contains($0.pathExtension.lowercased())
        }
        return (inventory[book.id]?.originals ?? []) + matchedOriginals
    }

    func missingOutputFiles(for book: AudibleBook) -> [URL] {
        guard let paths = inventory[book.id]?.missingFiles else { return [] }
        return Array(Set(paths)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func watchFiles() {
        guard initialLoad else { return }
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleFileCheck() }
        }
        outputWatcher = ArchiveWatcher(root: outputDirectory, changed: changed)
        if let matchDirectory = localMatches.directory, matchDirectory != outputDirectory {
            matchWatcher = ArchiveWatcher(root: matchDirectory, changed: changed)
        } else {
            matchWatcher = nil
        }
        scheduleFileCheck()
    }

    private func scheduleFileCheck() {
        // File events already arrive in batches. Keep one additional check pending.
        guard fileCheckTask == nil else { return }
        fileCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.fileCheckTask = nil
            if !Task.isCancelled { await self.recheckFiles() }
        }
    }

    private func startFallbackFileCheck() {
        fallbackFileCheck = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard let self else { return }
                if NSApplication.shared.isActive, self.signedIn, !self.isCheckingFiles, !self.isRefreshing,
                   !self.isTransferring, !self.inventory.isEmpty || !self.localMatches.manual.isEmpty || self.localMatches.directory != nil {
                    await self.recheckFiles()
                }
            }
        }
    }

    func scanMatches(in directory: URL) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let files = try await media.scan(directory)
            let matches = try await Self.matchBooks(books, with: files)
            try Task.checkCancellation()
            localMatches.directory = directory
            localMatches.automatic = matches
            persistMatches()
            watchFiles()
            await recheckFiles()
        } catch is CancellationError {
            return
        } catch {
            show("Couldn’t scan the folder", error: error)
        }
    }

    @concurrent private nonisolated static func matchBooks(_ books: [AudibleBook], with files: [LocalAudioFile]) async throws -> [String: [URL]] {
        try LocalAudioIndex(files: files).matches(for: books)
    }

    func match(_ book: AudibleBook, to urls: [URL]) {
        localMatches.manual[book.id] = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        localMatches.excluded.remove(book.id)
        persistMatches()
    }

    func removeMatch(_ book: AudibleBook) {
        localMatches.manual.removeValue(forKey: book.id)
        localMatches.excluded.insert(book.id)
        persistMatches()
    }

    func unlinkFolder() {
        localMatches.directory = nil
        localMatches.automatic.removeAll()
        persistMatches()
        watchFiles()
    }

    private func persistMatches() {
        guard let id = activeAccountID else { return }
        matchesByAccount[id] = localMatches
        save(matchesByAccount, as: "AccountMatches")
        scheduleFileCheck()
    }

    func localAudio(for book: AudibleBook) -> [URL] { localMatches.files(for: book.id) }

    func addFiles(at urls: [URL]) async {
        guard !isPreparingFiles else { return }
        isPreparingFiles = true
        defer { isPreparingFiles = false }
        do {
            var new: [LocalAudioFile] = []
            var failed: [(url: URL, error: any Error)] = []
            for url in urls {
                do {
                    new.append(contentsOf: try await media.scan(url))
                } catch is CancellationError {
                    return
                } catch MediaError.toolsMissing {
                    throw MediaError.toolsMissing
                } catch {
                    failed.append((url, error))
                }
            }
            try Task.checkCancellation()
            guard !new.isEmpty else { throw failed.first?.error ?? ArchiveError.noAudio }
            let existing = Set(localFiles.map(\.id))
            var added = Set<LocalAudioFile.ID>()
            localFiles += new.filter { !existing.contains($0.id) && added.insert($0.id).inserted }
            if let first = failed.first {
                let title = failed.count == 1 ? "Couldn’t open \(first.url.lastPathComponent)" : "Couldn’t open some items"
                show(title, error: first.error)
            }
        } catch is CancellationError {
            return
        } catch {
            show("Couldn’t open the audio files", error: error)
        }
    }

    func removeSelectedFiles() {
        localFiles.removeAll { selectedFiles.contains($0.id) }
        selectedFiles.removeAll()
    }

    func requestMissingDownloads(customizing: Bool = false) {
        guard canDownloadMissing, let accountID = activeAccountID else { return }
        Task {
            guard canDownloadMissing, activeAccountID == accountID else { return }
            await recheckFiles()
            guard canRequestDownloads, activeAccountID == accountID,
                  !isRefreshing, !isScanning, !isCheckingFiles else { return }
            let missing = missingBooks
            guard !missing.isEmpty else {
                notice = Notice(title: "Library is up to date", message: "Every downloadable title has a saved or matched audio file.")
                return
            }
            requestDownloads(missing, customizing: customizing, ensureAudio: true)
        }
    }

    func hasIncompleteDownload(for book: AudibleBook) -> Bool {
        inventory[book.id]?.hasPartial == true
    }

    func restartDownloads(_ books: [AudibleBook]) {
        let resumable = books.filter { hasIncompleteDownload(for: $0) }
        guard canRequestDownloads, !resumable.isEmpty else { return }
        downloadRequest = DownloadRequest(books: resumable, restartsIncomplete: true, requestsAudio: true)
    }

    func requestDownloads(_ books: [AudibleBook], customizing: Bool = false, ensureAudio: Bool = false) {
        guard canRequestDownloads, !books.isEmpty else { return }
        if customizing {
            downloadRequest = DownloadRequest(books: books, requestsAudio: ensureAudio)
            return
        }
        var options = downloadOptions
        if ensureAudio { options.downloadAudio = true }
        guard options.hasSelection else {
            notice = Notice(title: "Choose What to Download", message: "Use a Download As command or choose what to save in Downloads settings.")
            return
        }
        startDownloads(for: books, options: options)
    }

    func startDownloads(for books: [AudibleBook], options: DownloadOptions, restartsIncomplete: Bool = false) {
        guard canStartDownloads, options.hasSelection, !restartsIncomplete || options.downloadAudio,
              let account = activeAccount else { return }
        let work = books.map { book in
            TransferWork.library(book, matches: restartsIncomplete ? [] : sourceFiles(for: book))
        }
        let jobLimit = options.makesConversion
            ? min(transferPreferences.jobLimit, transferPreferences.conversionJobLimit)
            : transferPreferences.jobLimit
        run(
            TransferBatch(
                work: work, account: account, apiOptions: apiOptions, layout: layout, options: options,
                conversion: conversionPreferences, appleBooks: appleBooksDestination,
                preferences: transferPreferences, jobLimit: jobLimit
            ), restartIncomplete: restartsIncomplete
        )
    }

    func previewSourceFormat(for book: AudibleBook, downloadingAudio: Bool) -> String? {
        let matched = validLocalMatches[book.id]?.first
        let usesOriginal = !downloadingAudio || transferPreferences.existingFiles == .reuse
        let original = usesOriginal ? inventory[book.id]?.originals.first : nil
        return (original ?? matched)?.pathExtension.lowercased()
    }

    private func sourceFiles(for book: AudibleBook) -> [URL] {
        if let paths = validLocalMatches[book.id], !paths.isEmpty { return paths }
        if transferPreferences.existingFiles == .reuse { return inventory[book.id]?.originals ?? [] }
        return []
    }

    func startConversion(_ files: [LocalAudioFile]) {
        let needsActivationBytes = files.contains { $0.format == "aax" }
        guard !needsActivationBytes || hasValidActivationBytes else {
            show("Check the activation bytes", error: ArchiveError.invalidActivation)
            return
        }
        var batch = TransferBatch(
            work: files.map(TransferWork.local), account: activeAccount, apiOptions: apiOptions,
            layout: layout, options: DownloadOptions(), conversion: conversionPreferences,
            appleBooks: appleBooksDestination, preferences: transferPreferences, jobLimit: transferPreferences.conversionJobLimit
        )
        batch.activation = needsActivationBytes ? enteredActivationBytes : nil
        run(batch)
    }

    func cancelBatch() { activeTransfer?.cancel() }

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        activeJobs[id]?.cancel()
        if case .waiting = transfers[index].status {
            transfers[index].status = .cancelled
            scheduleQueueSave()
        }
    }

    func cancelAndWaitForTransfers() async {
        activeTransfer?.cancel()
        await activeTransfer?.value
        queueSaveTask?.cancel()
        queueSaveTask = nil
        await persistQueue()
    }

    func waitForTransfersBeforeUpdating() async {
        while let activeTransfer {
            await activeTransfer.value
        }
        await queueSaveTask?.value
        if hasPendingQueueWrite {
            await persistQueue()
        }
    }

    func addToAppleBooks(_ files: [URL]) async {
        do {
            try await AppleBooks.open(files, activate: true)
        } catch {
            show("Couldn’t open files in Books", error: error)
        }
    }

    func retryBatch() { retryTransfers(transfers.map(\.id), restartIncomplete: false) }

    func retryTransfers(_ ids: [UUID], restartIncomplete: Bool = false) {
        guard canRetryTransfers, var batch = lastBatch else { return }
        let ids = Set(ids)
        let selected = transfers.indices.filter {
            let transfer = transfers[$0]
            return ids.contains(transfer.id) && transfer.canRetry && (!restartIncomplete || transfer.canRestart)
        }
        for index in selected {
            if case .library(let book, _) = batch.work[index], activeAccountID == batch.account?.id {
                batch.work[index] = .library(book, matches: restartIncomplete ? [] : sourceFiles(for: book))
            }
        }
        if selected.contains(where: { index in
            if case .local(let file) = batch.work[index] { return file.format == "aax" }
            return false
        }) {
            guard hasValidActivationBytes else {
                show("Check the activation bytes", error: ArchiveError.invalidActivation)
                return
            }
            batch.activation = enteredActivationBytes
        }
        run(batch, indices: selected, restartIncomplete: restartIncomplete)
    }

    func clearCompletedTransfers() {
        let ids = transfers.compactMap { transfer in
            if case .done(_, nil) = transfer.status { return transfer.id }
            return nil
        }
        removeTransfers(ids)
    }

    func removeTransfers(_ ids: [UUID]) {
        guard !isTransferring, var batch = lastBatch else { return }
        let ids = Set(ids)
        let kept = transfers.indices.filter { !ids.contains(transfers[$0].id) }
        transfers = kept.map { transfers[$0] }
        batch.work = kept.map { batch.work[$0] }
        lastBatch = batch.work.isEmpty ? nil : batch
        scheduleQueueSave()
    }

    private func run(_ batch: TransferBatch, indices: [Int]? = nil, restartIncomplete: Bool = false) {
        let selected = indices ?? Array(batch.work.indices)
        guard didRestoreTransfers, !isTransferring, !selected.isEmpty else { return }
        guard batch.layout.isValid else {
            show("Check the folder and filename templates", error: ArchiveError.invalidTemplate)
            return
        }
        isTransferring = true
        batchEncounteredError = false
        lastBatch = batch
        if indices == nil {
            transfers = batch.work.map { work in
                Transfer(title: work.title, restartPending: restartIncomplete)
            }
        } else {
            for index in selected {
                transfers[index].status = .waiting
                if restartIncomplete { transfers[index].restartPending = true }
            }
        }
        page = .transfers

        activeTransfer = Task { [self] in
            let partialFolders = await partialFolders(for: batch)
            for index in selected {
                transfers[index].partialFolder = batch.work[index].bookID.flatMap { partialFolders[$0] }
            }
            await persistQueue()
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                var stopped = false
                let limit = min(selected.count, max(1, min(12, batch.jobLimit)))
                for _ in 0..<limit {
                    let index = selected[next]
                    group.addTask { await self.execute(batch, at: index) }
                    next += 1
                }
                while await group.next() != nil {
                    stopped = batchEncounteredError && !batch.preferences.continueAfterError
                    guard !stopped, !Task.isCancelled, next < selected.count else { continue }
                    let index = selected[next]
                    group.addTask { await self.execute(batch, at: index) }
                    next += 1
                }
                for index in selected.dropFirst(next) where !transfers[index].isFinished {
                    transfers[index].status = stopped ? .stopped : .cancelled
                }
            }
            await recheckFiles()
            await persistQueue()
            isTransferring = false
            activeTransfer = nil
        }
    }

    private func execute(_ batch: TransferBatch, at index: Int) async {
        guard !transfers[index].isFinished else { return }
        guard !Task.isCancelled else {
            transfers[index].status = .cancelled
            return
        }
        let id = transfers[index].id
        let job = Task { await process(batch, at: index) }
        activeJobs[id] = job
        defer { activeJobs.removeValue(forKey: id) }
        await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func process(_ batch: TransferBatch, at index: Int) async {
        if Task.isCancelled {
            transfers[index].status = .cancelled
            return
        }
        transfers[index].status = .active("Preparing", nil)
        let id = transfers[index].id
        let progress: ArchiveWorker.Progress = { [weak self] name, fraction in
            await self?.updateProgress(at: index, id: id, description: name, fraction: fraction)
        }
        let client = client(for: batch.account, with: batch.apiOptions)
        do {
            let receipt: ExportReceipt
            switch batch.work[index] {
            case .library(let book, let matches):
                guard let account = batch.account else { throw AudibleError.notSignedIn }
                let restart = transfers[index].restartPending == true
                receipt = try await archive.download(
                    book, account: archiveID(for: account), audible: client,
                    matches: restart ? [] : matches, layout: batch.layout, options: batch.options,
                    existingFiles: batch.preferences.existingFiles, conversion: batch.conversion,
                    requestID: id, restartIncomplete: restart, didRestart: { [weak self] in
                        await self?.acknowledgeRestart(at: index, id: id)
                    }, progress: progress
                )
                transfers[index].restartPending = false
                if batch.options.downloadAudio, activeAccountID == account.id, layout == batch.layout {
                    scheduleFileCheck()
                }
            case .local(let file):
                receipt = try await archive.convert(
                    file, audible: client, layout: batch.layout, activationBytes: batch.activation,
                    existingFiles: batch.preferences.existingFiles, conversion: batch.conversion,
                    requestID: id, progress: progress
                )
            }

            transfers[index].files = receipt.audioFiles.isEmpty ? [receipt.url] : receipt.audioFiles
            let note = await sendToAppleBooks(receipt, destination: batch.appleBooks, at: index)
            transfers[index].status = .done(receipt.url, note: note)
        } catch {
            if Task.isCancelled {
                transfers[index].status = .cancelled
            } else {
                batchEncounteredError = true
                transfers[index].status = .failed(error.localizedDescription)
            }
        }

        if case .library(let book, _) = batch.work[index], let account = batch.account, batch.options.downloadAudio {
            let accountID = archiveID(for: account)
            transfers[index].partialFolder = IncompleteDownloads.containsAudio(for: book.id, account: accountID, root: batch.layout.root)
                ? IncompleteDownloads.folder(for: book.id, account: accountID, root: batch.layout.root)
                : nil
            if activeAccountID == account.id { scheduleFileCheck() }
        }
        scheduleQueueSave()
        do {
            try await transferLog.record(transfers[index], preferences: batch.preferences)
        } catch {
            show("Couldn’t write the transfer log", error: error)
        }
    }

    private func acknowledgeRestart(at index: Int, id: UUID) async {
        guard transfers.indices.contains(index), transfers[index].id == id else { return }
        transfers[index].restartPending = false
        await persistQueue()
    }

    private func sendToAppleBooks(
        _ receipt: ExportReceipt, destination: AppleBooksDestination, at index: Int
    ) async -> String? {
        let retry = transfers[index].booksImportPending == true
        let candidates: [URL] = switch destination {
        case .off: []
        case .original: (retry ? receipt.original : receipt.addedOriginal).filter { AppleBooks.supports($0) }
        case .m4b: (retry ? receipt.converted : receipt.addedConverted).filter { $0.pathExtension.lowercased() == "m4b" }
        }
        guard !candidates.isEmpty else { return receipt.note }
        transfers[index].booksImportPending = true
        await persistQueue()
        do {
            try Task.checkCancellation()
            try await AppleBooks.open(candidates, activate: false)
            transfers[index].booksImportPending = nil
            return receipt.note
        } catch {
            let detail = Task.isCancelled ? "Books import was cancelled." : error.localizedDescription
            let message = "The files were saved. \(detail)"
            return [receipt.note, message].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func restoreTransfers() async {
        do {
            guard let snapshot = try await queue.load(),
                  let batch = snapshot.batch, batch.work.count == snapshot.transfers.count else { return }
            let partialFolders = await partialFolders(for: batch)
            lastBatch = batch
            transfers = zip(snapshot.transfers, batch.work).map { saved, work in
                var transfer = saved
                if !saved.isFinished { transfer.status = .interrupted }
                transfer.partialFolder = work.bookID.flatMap { partialFolders[$0] }
                if case .done(_, let note) = saved.status, note?.hasSuffix(Self.legacyBooksImportError) == true {
                    transfer.booksImportPending = true
                }
                return transfer
            }
        } catch {
            show("Couldn’t restore the transfer queue", error: error)
        }
    }

    private func partialFolders(for batch: TransferBatch) async -> [String: URL] {
        guard batch.options.downloadAudio, let account = batch.account else { return [:] }
        let ids = Set(batch.work.compactMap(\.bookID))
        guard !ids.isEmpty else { return [:] }
        return await archive.partialFolders(for: ids, account: archiveID(for: account), root: batch.layout.root)
    }

    private func scheduleQueueSave() {
        guard queueSaveTask == nil else { return }
        queueSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.queueSaveTask = nil
            if !Task.isCancelled { await self.persistQueue() }
        }
    }

    private func persistQueue() async {
        queueRevision += 1
        pendingQueueWrites += 1
        defer { pendingQueueWrites -= 1 }
        let snapshot = TransferQueueSnapshot(batch: lastBatch, transfers: transfers)
        do {
            try await queue.save(snapshot, revision: queueRevision)
        } catch {
            show("Couldn’t save the transfer queue", error: error)
        }
    }

    private func updateProgress(at index: Int, id: UUID, description: String, fraction: Double?) {
        guard transfers.indices.contains(index), transfers[index].id == id,
              case .active = transfers[index].status else { return }
        transfers[index].status = .active(description, fraction)
    }

    func chooseLogFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "DownAudible Transfers.txt"
        panel.prompt = "Choose"
        if panel.runModal() == .OK { transferPreferences.logFile = panel.url }
    }

    func exportLibrary(_ format: LibraryExportFormat) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Audible Library.\(format.rawValue)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let path = panel.url else { return }
        do {
            try await format.write(books, to: path)
        } catch {
            show("Couldn’t export the library", error: error)
        }
    }

    private func show(_ title: String, error: any Error) {
        notice = Notice(title: title, message: error.localizedDescription)
    }

    private func save<Value: Encodable>(_ value: Value, as key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ key: String, from defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }
}
