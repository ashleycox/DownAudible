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

    private enum Work: Sendable {
        case library(AudibleBook, matches: [URL])
        case local(LocalAudioFile)

        var title: String {
            switch self {
            case .library(let book, _): book.title
            case .local(let file): file.title
            }
        }
    }

    private struct Batch: Sendable {
        var work: [Work]
        let account: SavedAudibleAccount?
        let client: AudibleClient
        let layout: ArchiveLayout
        let options: DownloadOptions
        let preferences: TransferPreferences
        let activation: String?
        let jobLimit: Int
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
    var books: [AudibleBook] = []
    var transfers: [Transfer] = []
    var selectedBooks: Set<AudibleBook.ID> = []
    var selectedFiles: Set<LocalAudioFile.ID> = []
    var localFiles: [LocalAudioFile] = []
    var activationBytes = ""
    var downloadRequest: DownloadRequest?
    var notice: Notice?

    var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path, forKey: "OutputDirectory") }
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
    private(set) var isTransferring = false

    private let defaults = UserDefaults.standard
    private let audible = AudibleClient()
    private let media = MediaTools()
    private let archive: ArchiveWorker
    private let transferLog = TransferLog()
    @ObservationIgnored private var activeTransfer: Task<Void, Never>?
    @ObservationIgnored private var initialLoad = false
    @ObservationIgnored private var lastBatch: Batch?
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
        downloadOptions = Self.load("DownloadOptions", from: defaults) ?? DownloadOptions()
        apiOptions = Self.load("AudibleAPIOptions", from: defaults) ?? AudibleAPIOptions()
        transferPreferences = Self.load("TransferPreferences", from: defaults) ?? TransferPreferences()
        accounts = Self.load("Accounts", from: defaults) ?? []
        activeAccountID = defaults.string(forKey: "ActiveAccountID").flatMap(UUID.init(uuidString:))
        matchesByAccount = Self.load("AccountMatches", from: defaults) ?? [:]
        localMatches = Self.load("LocalMatches", from: defaults) ?? LocalMatches()
    }

    var layout: ArchiveLayout {
        ArchiveLayout(root: outputDirectory, template: folderTemplate, filenameStyle: filenameStyle, filenameLength: filenameLength)
    }

    var activeAccount: SavedAudibleAccount? { accounts.first { $0.id == activeAccountID } }
    var canSwitchAccounts: Bool { !accountBusy && !signInBusy && !isRefreshing && !isScanning }
    var canRemoveAccounts: Bool { canSwitchAccounts && !isTransferring }
    var canRetry: Bool { !isTransferring && transfers.contains(where: \.canRetry) }
    var finishedCount: Int { transfers.count(where: \.isFinished) }

    var hasValidActivationBytes: Bool {
        let value = activationBytes.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || (value.utf8.count == 8 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })
    }

    func load() async {
        guard !initialLoad else { return }
        initialLoad = true
        do {
            if accounts.isEmpty, try audible.hasSession() {
                let account = SavedAudibleAccount(id: UUID(), name: marketplace.displayName, marketplace: marketplace, usesLegacySession: true)
                accounts = [account]
                activeAccountID = account.id
            }
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
        } else if !account.usesLegacySession {
            localMatches = LocalMatches()
        }
        marketplace = account.marketplace
        defaults.set(marketplace.rawValue, forKey: "Marketplace")
        signedIn = hasSession
        if signedIn { await refresh() }
    }

    private func clearLibrary() {
        signedIn = false
        books = []
        selectedBooks = []
        downloadRequest = nil
        exportedFiles = [:]
    }

    private func store(_ account: SavedAudibleAccount) {
        if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
    }

    private static func accountName(_ name: String, _ marketplace: AudibleMarketplace) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? marketplace.displayName : trimmed
    }

    private func client(for account: SavedAudibleAccount?) -> AudibleClient {
        var options = apiOptions
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
        guard signedIn, let account = activeAccount else { return }
        let layout = layout
        let ids = books.map(\.id)
        let exports = await archive.existingExports(for: ids, account: archiveID(for: account), layout: layout)
        guard signedIn, activeAccountID == account.id, self.layout == layout else { return }
        exportedFiles = exports
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
        } catch is CancellationError {
            return
        } catch {
            show("Couldn’t scan the folder", error: error)
        }
    }

    @concurrent private nonisolated static func matchBooks(_ books: [AudibleBook], with files: [LocalAudioFile]) async throws -> [String: [URL]] {
        let index = LocalAudioIndex(files: files)
        var matches: [String: [URL]] = [:]
        for book in books {
            try Task.checkCancellation()
            if let file = index.match(title: book.title, author: book.authors.first, asin: book.asin) {
                matches[book.id] = [file.url]
            }
        }
        let counts = Dictionary(grouping: matches.values.compactMap(\.first), by: { $0 }).mapValues(\.count)
        return matches.filter { entry in entry.value.first.flatMap { counts[$0] } == 1 }
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
    }

    private func persistMatches() {
        guard let id = activeAccountID else { return }
        matchesByAccount[id] = localMatches
        save(matchesByAccount, as: "AccountMatches")
    }

    func localAudio(for book: AudibleBook) -> [URL] { localMatches.files(for: book.id) }

    func addFiles(at urls: [URL]) async {
        guard !isPreparingFiles else { return }
        isPreparingFiles = true
        defer { isPreparingFiles = false }
        do {
            var new: [LocalAudioFile] = []
            for url in urls {
                new.append(contentsOf: try await media.scan(url))
            }
            guard !new.isEmpty else { throw ArchiveError.noAudio }
            let existing = Set(localFiles.map(\.id))
            var added = Set<LocalAudioFile.ID>()
            localFiles += new.filter { !existing.contains($0.id) && added.insert($0.id).inserted }
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

    func requestDownloads(_ books: [AudibleBook]) {
        guard !isTransferring && !books.isEmpty else { return }
        if transferPreferences.skipConfirmation && downloadOptions.hasSelection {
            startDownloads(for: books, options: downloadOptions)
        } else {
            downloadRequest = DownloadRequest(books: books)
        }
    }

    func startDownloads(for books: [AudibleBook], options: DownloadOptions) {
        guard signedIn, options.hasSelection, let account = activeAccount else { return }
        downloadOptions = options
        let work = books.map { Work.library($0, matches: localMatches.files(for: $0.id)) }
        let jobLimit = options.makesM4B
            ? min(transferPreferences.jobLimit, transferPreferences.conversionJobLimit)
            : transferPreferences.jobLimit
        run(Batch(
            work: work, account: account, client: client(for: account),
            layout: layout, options: options, preferences: transferPreferences, activation: nil, jobLimit: jobLimit
        ))
    }

    func startConversion(_ files: [LocalAudioFile]) {
        guard hasValidActivationBytes else {
            show("Check the activation bytes", error: ArchiveError.invalidActivation)
            return
        }
        let value = activationBytes.trimmingCharacters(in: .whitespacesAndNewlines)
        run(Batch(
            work: files.map(Work.local), account: activeAccount, client: client(for: activeAccount),
            layout: layout, options: DownloadOptions(), preferences: transferPreferences,
            activation: value.isEmpty ? nil : value, jobLimit: transferPreferences.conversionJobLimit
        ))
    }

    func cancelBatch() { activeTransfer?.cancel() }

    func retryBatch() {
        guard canRetry, var batch = lastBatch else { return }
        batch.work = transfers.indices.filter { transfers[$0].canRetry }.map { index in
            switch batch.work[index] {
            case .library(let book, _) where activeAccountID == batch.account?.id:
                .library(book, matches: localMatches.files(for: book.id))
            case let work:
                work
            }
        }
        run(batch)
    }

    private func run(_ batch: Batch) {
        guard !isTransferring && !batch.work.isEmpty else { return }
        guard batch.layout.isValid else {
            show("Check the folder template", error: ArchiveError.invalidTemplate)
            return
        }
        isTransferring = true
        lastBatch = batch
        transfers = batch.work.map { Transfer(title: $0.title) }
        page = .transfers

        activeTransfer = Task { [self] in
            defer {
                isTransferring = false
                activeTransfer = nil
            }
            await withTaskGroup(of: Int.self) { group in
                var next = 0
                var stopped = false
                let limit = min(batch.work.count, max(1, min(12, batch.jobLimit)))
                for _ in 0..<limit {
                    let index = next
                    group.addTask { await self.process(batch, at: index); return index }
                    next += 1
                }
                while let index = await group.next() {
                    if case .failed = transfers[index].status, !batch.preferences.continueAfterError { stopped = true }
                    guard !stopped, !Task.isCancelled, next < batch.work.count else { continue }
                    let index = next
                    group.addTask { await self.process(batch, at: index); return index }
                    next += 1
                }
                for index in next..<batch.work.count {
                    transfers[index].status = stopped ? .stopped : .cancelled
                }
            }
        }
    }

    private func process(_ batch: Batch, at index: Int) async {
        guard !Task.isCancelled else {
            transfers[index].status = .cancelled
            return
        }
        transfers[index].status = .active("Preparing", nil)
        let id = transfers[index].id
        let progress: ArchiveWorker.Progress = { [weak self] name, fraction in
            await self?.updateProgress(at: index, id: id, description: name, fraction: fraction)
        }
        do {
            let receipt: ExportReceipt
            switch batch.work[index] {
            case .library(let book, let matches):
                guard let account = batch.account else { throw AudibleError.notSignedIn }
                receipt = try await archive.download(
                    book, account: archiveID(for: account), audible: batch.client, matches: matches,
                    layout: batch.layout, options: batch.options, existingFiles: batch.preferences.existingFiles,
                    progress: progress
                )
                if batch.options.downloadAudio, activeAccountID == account.id, layout == batch.layout {
                    exportedFiles[book.id] = receipt.original.isEmpty ? [receipt.url] : receipt.original
                }
            case .local(let file):
                receipt = try await archive.convert(
                    file, audible: batch.client, layout: batch.layout, activationBytes: batch.activation,
                    existingFiles: batch.preferences.existingFiles, progress: progress
                )
            }
            transfers[index].status = .done(receipt.url, note: receipt.note)
        } catch {
            transfers[index].status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
        do {
            try await transferLog.record(transfers[index], preferences: batch.preferences)
        } catch {
            show("Couldn’t write the transfer log", error: error)
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
