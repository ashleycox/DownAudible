import AppKit
import Sparkle
import SwiftUI

@main
@MainActor
struct CaptureHelp {
    static func main() throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.dropFirst().first == "--capture-menu" {
            try captureFixtureMenu(arguments: Array(arguments.dropFirst(2)))
            return
        }
        let output = URL(filePath: arguments[1], directoryHint: .isDirectory)
        let fixture = URL(filePath: arguments[2], directoryHint: .isDirectory)
        let requested = Set(arguments.dropFirst(3))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        if let url = Bundle.main.url(forResource: "DownAudible", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            app.applicationIconImage = icon
        }
        app.finishLaunching()
        let capturer = HelpCapture(output: output, fixture: fixture, requested: requested)
        defer { capturer.removeFixturePreferences() }
        try capturer.run()
    }
}

@MainActor
private final class CaptureUpdaterDelegate: NSObject, SPUUpdaterDelegate {}

@MainActor
final class HelpCapture {
    let output: URL
    let fixture: URL
    let requested: Set<String>
    let defaults: UserDefaults
    private let preferencesName = "org.downaudible.help-capture." + UUID().uuidString
    private let delegate = CaptureUpdaterDelegate()
    lazy var updater = SoftwareUpdater(helpScreenshotDelegate: delegate)
    let archive: URL
    private let shelfQueueFile: URL
    let model: WorkspaceModel
    let signedOut: WorkspaceModel

    init(output: URL, fixture: URL, requested: Set<String>) {
        self.output = output
        self.fixture = fixture
        self.requested = requested
        archive = fixture.appending(path: "Demo Audiobooks", directoryHint: .isDirectory)
        shelfQueueFile = fixture.appending(path: "AudiobookshelfUploads.json")
        defaults = UserDefaults(suiteName: preferencesName)!
        defaults.set(true, forKey: "HasFinishedOnboarding")
        defaults.set(archive.path, forKey: "OutputDirectory")
        let client = AudibleClient(helperURL: fixture.appending(path: "audible-demo-helper"))
        let shelfQueue = ShelfUploadQueue(file: shelfQueueFile)
        model = WorkspaceModel(defaultsSuite: preferencesName, audible: client, shelfQueue: shelfQueue)
        signedOut = WorkspaceModel(defaultsSuite: preferencesName, audible: client, shelfQueue: shelfQueue)
    }

    func removeFixturePreferences() {
        defaults.removePersistentDomain(forName: preferencesName)
    }

    func run() throws {
        let books = (1...6).map { makeBook($0) }
        let account = SavedAudibleAccount(id: UUID(), name: "Demo Account", marketplace: .unitedKingdom)
        let second = SavedAudibleAccount(id: UUID(), name: "Demo Account 2", marketplace: .unitedStates)
        let existing = fixture.appending(path: "Demo Audio", directoryHint: .isDirectory)
        let sourceFile = existing.appending(path: "Demo Book 3.m4b")
        let importedFile = existing.appending(path: "Demo Book 2.m4b")
        let completedFile = archive.appending(path: "m4b/Demo Author 1/Demo Book 1/Demo Book 1.m4b")
        let missingFile = archive.appending(path: "m4b/Demo Author 2/Demo Book 5/Demo Book 5.m4b")
        model.seedHelpScreenshotArchive([books[0].id: completedFile, books[4].id: missingFile])
        let inventory = [
            books[0].id: ArchiveInventoryItem(files: [completedFile], hadAudio: true),
            books[3].id: ArchiveInventoryItem(hadAudio: false, hasPartial: true),
            books[4].id: ArchiveInventoryItem(missingFiles: [missingFile], hadAudio: true)
        ]
        let matches = [books[1].id: [importedFile]]
        model.books = books
        let partial = try IncompleteDownloads.audioFolder(for: books[3].id, account: account.id.uuidString, root: archive, restart: false)
        try Data("Demo partial audio".utf8).write(to: partial.appending(path: "Demo Book 4.partial"))
        let batch = makeBatch(books: books, account: account)
        let date = Date(timeIntervalSince1970: 1_786_714_800)
        let history = [
            TransferHistoryBatch(date: date, batch: makeBatch(books: [books[0]], account: account),
                                 transfers: [Transfer(title: books[0].title, status: .done(completedFile, note: nil),
                                                      files: [completedFile])])
        ]
        let transfers = [
            Transfer(title: books[0].title, status: .done(completedFile, note: nil), files: [completedFile]),
            Transfer(title: books[1].title, status: .done(importedFile, note: nil), files: [importedFile]),
            Transfer(title: books[2].title, status: .stopped),
            Transfer(title: books[3].title, status: .failed("The download arrived incomplete."), partialFolder: partial.deletingLastPathComponent()),
            Transfer(title: books[4].title, status: .interrupted)
        ]
        model.seedHelpScreenshots(accounts: [account, second], inventory: inventory, matchedFiles: matches,
                                  matchDirectory: existing, currentBatch: batch, history: history)
        signedOut.seedHelpScreenshots(accounts: [], inventory: [:], matchedFiles: [:],
                                      matchDirectory: existing, currentBatch: nil, history: [])
        model.transfers = transfers
        model.selectedBooks = [books[2].id]
        model.localFiles = [
            LocalAudioFile(url: importedFile, format: "m4b", title: "Demo Book 2",
                           author: "Demo Author 1", asin: nil, durationSeconds: 34),
            LocalAudioFile(url: sourceFile, format: "m4b", title: "Demo Book 3",
                           author: "Demo Author 2", asin: nil, durationSeconds: 48),
            LocalAudioFile(url: existing.appending(path: "Demo Book 4.aax"), format: "aax", title: "Demo Book 4",
                           author: "Demo Author 2", asin: nil, durationSeconds: 42)
        ]
        model.selectedFiles = [sourceFile]

        let query = LibraryCatalog.Query(model.apiOptions)
        let catalog = LibraryCatalog(books: books, query: query, previous: LibraryCatalog(
            books: Array(books.prefix(5)) + [makeBook(7)], query: query, previous: nil, refreshed: date
        ), refreshed: date.addingTimeInterval(7_200))
        model.seedHelpScreenshotCatalogs([
            account.id: catalog,
            second.id: LibraryCatalog(books: [books[2], makeBook(8)], query: query, previous: nil, refreshed: date),
        ])
        model.libraryOrganization.changeTags(["To Listen"], for: [books[2].asin], account: account.id, adding: true)
        try capture("library-saved-view", size: (420, 190)) {
            LibrarySaveViewSheet(saved: []) { _ in }
        }
        try capture("library-tags", size: (440, 268)) {
            LibraryTagsSheet(model: model, account: account.id, books: [books[2]])
        }
        try capture("library-changes", size: (520, 360)) { LibraryChangesView(snapshot: catalog) }
        try capture("library-all-accounts", size: (740, 440)) { AllAccountsLibraryView(model: model) }

        try capture("setup-welcome", size: (640, 380)) {
            OnboardingView(model: signedOut, softwareUpdater: updater) { _ in }
        }
        try capture("setup-accounts", size: (640, 430)) {
            OnboardingView(model: signedOut, softwareUpdater: updater, pane: .accounts) { _ in }
        }
        try capture("setup-finish", size: (640, 380)) {
            OnboardingView(model: signedOut, softwareUpdater: updater, finished: true) { _ in }
        }
        try capture("sign-in-methods", size: (486, 230)) { AudibleSignInView(model: signedOut, addingAccount: true) }
        try capture("sign-in-android", size: (486, 280)) { AudibleSignInView(model: signedOut, demoCredentials: false, demoAndroid: true) }
        try capture("sign-in-credentials", size: (486, 284)) { AudibleSignInView(model: signedOut, demoCredentials: true) }
        try capture("sign-in-browser", size: (486, 254)) {
            AudibleSignInView(model: signedOut, demoCredentials: false, attempt: .helpScreenshot)
        }
        try capture("sign-in-cli", size: (500, 360), settle: 0.7) { AudibleAccountImportView(model: signedOut) }
        try capture("sign-in-cli-auth", size: (500, 310), settle: 0.7) {
            AudibleAccountImportView(model: signedOut, demoAuthFile: fixture.appending(path: "cli/demo-account.json"))
        }
        try capture("import-openaudible", size: (500, 330), settle: 0.7) {
            AudibleAccountImportView(model: signedOut, demoOpenAudibleFile: fixture.appending(path: "cli/credentials.json"))
        }

        try capture("library", title: "Library", size: (1_080, 405)) { workspace(.library) }
        model.helpScreenshotSearch = "Demo Book 3"
        try capture("library-search", title: "Library", size: (1_080, 405)) { workspace(.library) }
        model.helpScreenshotSearch = nil
        try capture("library-signed-out", title: "Library", size: (800, 380)) { workspace(.library, with: signedOut) }
        try capture("library-status", title: "Library Status", size: (900, 565)) { LibraryStatusView(model: model) }
        try capture("library-unavailable", title: "Library Status", size: (900, 400)) {
            LibraryStatusView(model: model, unavailableOnly: true)
        }
        try capture("library-filter", size: (440, 260)) {
            LibraryTextFilterView(field: .author, value: "Demo Au",
                                  suggestions: LibraryFilterSuggestions(field: .author, books: books)) { _ in }
        }
        try capture("download-options", size: (560, 475)) {
            DownloadOptionsView(model: model, request: DownloadRequest(books: [books[2]]))
        }
        try capture("download-restart", size: (560, 475)) {
            DownloadOptionsView(model: model, request: DownloadRequest(books: [books[3]], restartsIncomplete: true))
        }
        model.downloadOptions.convert = true
        try capture("download-conversion", size: (560, 520)) {
            DownloadOptionsView(model: model, request: DownloadRequest(books: [books[2]]))
        }
        model.downloadOptions.convert = false

        try capture("converter", title: "Convert Files", size: (900, 380)) { workspace(.convert) }
        try capture("converter-options", title: "Convert Files", size: (900, 550), sheet: true) {
            workspace(.convert, conversionOptions: true)
        }
        try capture("book-editor", size: (750, 455), settle: 1) {
            BookEditorView(model: model, request: BookEditRequest(
                origin: .local(ArchiveTitle(books[2])), localAudio: [StoredAudio(url: sourceFile, asin: nil)],
                account: nil, apiOptions: model.apiOptions, destination: model.layout
            ), excludedSections: [0])
        }
        try capture("book-chapter-repair", size: (750, 455), settle: 1.5) {
            let chapters = [
                MediaChapter(startMilliseconds: 0, durationMilliseconds: 22_000, title: "Chapter 1"),
                MediaChapter(startMilliseconds: 22_000, durationMilliseconds: 26_000, title: "Chapter 2"),
            ]
            let separated = [
                MediaChapter(startMilliseconds: 0, durationMilliseconds: 4_000, title: "Audible Intro"),
                MediaChapter(startMilliseconds: 4_000, durationMilliseconds: 18_000, title: "Chapter 1"),
                MediaChapter(startMilliseconds: 22_000, durationMilliseconds: 22_000, title: "Chapter 2"),
                MediaChapter(startMilliseconds: 44_000, durationMilliseconds: 4_000, title: "Audible Outro"),
            ]
            BookEditorView(model: model, request: BookEditRequest(
                origin: .local(ArchiveTitle(books[2])), localAudio: [StoredAudio(url: sourceFile, asin: nil)],
                account: nil, apiOptions: model.apiOptions, destination: model.layout
            ), chapterRepair: ChapterRepair(asin: nil, runtimeMilliseconds: 48_000,
                                            chapters: chapters, separatedChapters: separated))
        }
        try capture("archive-verification", size: (690, 380), settle: 1) {
            ArchiveVerificationView(model: model)
        }

        try capture("transfers", title: "Downloads", size: (870, 396)) { workspace(.transfers) }
        model.selectTransferHistory(history[0].id)
        try capture("transfer-history", title: "Downloads", size: (870, 300)) { workspace(.transfers) }
        model.selectTransferHistory(nil)
        let activeBatch = makeBatch(books: Array(books.prefix(3)), account: account)
        model.seedHelpScreenshots(accounts: [account, second], inventory: inventory, matchedFiles: matches,
                                  matchDirectory: existing, currentBatch: activeBatch, history: history, active: true)
        model.transfers = [
            transfers[0],
            Transfer(title: books[1].title, status: .active("Downloading audio", 0.64)),
            Transfer(title: books[2].title, status: .waiting)
        ]
        try capture("transfers-active", title: "Downloads", size: (870, 340)) { workspace(.transfers) }
        var deferred = Transfer(title: books[1].title, status: .waiting)
        deferred.audibleRetry = AudibleRetryDelay(error: AudibleError.rateLimited, now: date)
        model.transfers = [transfers[0], deferred, Transfer(title: books[2].title, status: .waiting)]
        try capture("transfers-audible-retry", title: "Downloads", size: (870, 340)) { workspace(.transfers) }
        model.selectedBooks = [books[3].id]
        try capture("download-queue", title: "Library", size: (1_080, 405), menu: .toolbar("Download")) {
            workspace(.library)
        }
        model.selectedBooks = [books[2].id]
        model.seedHelpScreenshots(accounts: [account, second], inventory: inventory, matchedFiles: matches,
                                  matchDirectory: existing, currentBatch: batch, history: history)
        model.transfers = transfers

        if let client = model.activeAudibleClient {
            try capture("audible-wishlist", title: "Audible Tools", size: (740, 430), settle: 0.8) {
                AudibleToolsView(client: client, accountName: account.name)
            }
            try capture("audible-catalogue", size: (590, 330)) {
                demoAudibleCatalogue(client: client, books: (10...13).map { makeBook($0) })
            }
            try capture("audible-activation", title: "Audible Tools", size: (700, 430)) {
                AudibleToolsView(client: client, accountName: account.name, showAccount: true)
            }
            try capture("audible-export", size: (460, 250)) { demoAudibleAuthExport(client: client) }
            let statistics: [AudibleListeningMonth] = [
                .init(month: "2025-11", durationMilliseconds: 49_500_000),
                .init(month: "2026-08", durationMilliseconds: 98_400_000),
                .init(month: "2026-09", durationMilliseconds: 0),
                .init(month: "2026-10", durationMilliseconds: 183_600_000),
            ]
            try capture("listening-statistics", title: "Listening Statistics", size: (760, 450)) {
                ListeningStatisticsWindow(model: model, initialMonths: statistics)
            }
            let check = try JSONDecoder().decode(AudibleTitleCheck.self, from: Data("""
                {"asin":"DEMOBOOK01","offers":[
                 {"format":"aax","status":"available","codec":"AAC-LC","bitrateKbps":64},
                 {"format":"aaxc","status":"available","codec":"AAC-LC","bitrateKbps":96},
                 {"format":"widevine","status":"available","codec":"AAC-LC","bitrateKbps":128}]}
                """.utf8))
            try capture("title-diagnostics", size: (600, 350)) {
                TitleInsightsView(request: TitleCheckRequest(book: books[0], marketplace: account.marketplace, client: client),
                                  initialReport: check)
            }
            try capture("audible-annotations", size: (720, 460)) {
                AudibleAnnotationsView(request: AnnotationsRequest(book: books[0], account: account.name, client: client),
                    initialEntries: [
                        .init(kind: .bookmark, positionMilliseconds: 115_000, text: ""),
                        .init(kind: .note, positionMilliseconds: 506_000, text: "Return to the description of the old station.\nIt sets up the next chapter."),
                        .init(kind: .bookmark, positionMilliseconds: 3_733_000, text: ""),
                    ])
            }
            var finished = makeBook(1, finished: true, progress: 100)
            finished.isbn = "9780000000002"
            let started = makeBook(2, progress: 35)
            try capture("library-goodreads-export", size: (760, 435)) {
                GoodreadsExportView(export: GoodreadsExport([finished, started, finished]))
            }
            let audit = QualityAuditScope(accountID: account.id, accountName: account.name, client: client, layout: model.layout,
                                          inputs: books.prefix(3).map { .init(book: $0, files: []) })
            try capture("audio-quality-audit", size: (860, 460)) {
                QualityAuditView(scope: audit, demoResults: true) { _ in }
            }
            try capture("audible-device-registration", size: (510, 260)) {
                AudibleDeviceView(model: model, account: account, initialRegistration: .init(
                    kind: "android", name: "Audible for Android", marketplace: "uk", serialSuffix: "1234"
                ))
            }
        }
        try capture("about", title: "About DownAudible", size: (480, 380)) { AboutView() }
        let settings: [(SettingsPane, String)] = [
            (.general, "general"), (.downloads, "downloads"),
            (.conversion, "conversion"), (.files, "files"), (.notifications, "notifications")
        ]
        for (pane, name) in settings {
            try capture("settings-" + name, title: "DownAudible Settings", size: (720, 600)) {
                PreferencesView(model: model, softwareUpdater: updater, selection: pane)
            }
        }
        try capture("settings-library", size: (680, 570)) {
            SettingsPane.library.content(for: model, softwareUpdater: updater)
        }
        try capture("settings-accounts", size: (680, 650)) { AccountPreferencesView(model: model) }
        try capture("settings-jobs", size: (680, 670)) {
            SettingsPane.jobs.content(for: model, softwareUpdater: updater)
        }
        model.shelfSettings = ShelfSettings(
            server: "https://audiobookshelf.example.com", libraryID: "demo-library", libraryName: "Audiobooks",
            folderID: "demo-folder", folderName: "/audiobooks", autoUpload: true, includePDFs: true
        )
        try capture("settings-audiobookshelf", size: (680, 520)) {
            AudiobookshelfPreferencesView(model: model)
        }
        if requested.isEmpty || requested.contains("audiobookshelf-uploads"),
           let destination = model.shelfSettings.destination {
            let examples: [(AudibleBook, URL, ShelfUpload.State, String?)] = [
                (books[0], completedFile, .sent, nil),
                (books[1], importedFile, .failed, "The server couldn’t be reached."),
                (books[2], sourceFile, .waiting, nil),
            ]
            let uploads = examples.map { book, audio, state, detail in
                let item = ShelfBook(asin: book.asin, title: book.title, authors: book.authors,
                                     series: book.series, audio: [audio], cover: nil, pdf: nil)
                return ShelfUpload(book: item, destination: destination, state: state, detail: detail)
            }
            try JSONEncoder().encode(uploads).write(to: shelfQueueFile, options: .atomic)
            try capture("audiobookshelf-uploads", size: (620, 340)) { ShelfUploadsView(model: model) }
        }
        try capture("settings-downloads-extras", title: "DownAudible Settings", size: (720, 600), scrollToBottom: true) {
            PreferencesView(model: model, softwareUpdater: updater, selection: .downloads)
        }
        try capture("settings-accounts-switch", size: (680, 650)) {
            AccountPreferencesView(model: model, demoAccountID: second.id)
        }
        try capture("widevine-stereo", size: (540, 410)) {
            WidevineAccountView(model: model, account: account)
        }
        model.conversionPreferences.chapterMode = .separate
        model.conversionPreferences.copyChapterAudio = true
        try capture("conversion-chapters", title: "DownAudible Settings", size: (720, 600)) {
            PreferencesView(model: model, softwareUpdater: updater, selection: .conversion)
        }
        model.conversionPreferences.chapterMode = .single
        model.conversionPreferences.format = .mp3
        model.conversionPreferences.mp3BitrateMode = .variable
        model.conversionPreferences.moveAAXToTrash = true
        try capture("conversion-mp3", size: (680, 750)) {
            @Bindable var model = model
            Form { ConversionPreferencesView(preferences: $model.conversionPreferences) }
                .formStyle(.grouped)
        }
        model.conversionPreferences = ConversionPreferences()
        model.downloadPacing.scope = .all
        model.downloadPacing.limit = 25
        try capture("settings-jobs-pacing", size: (680, 610)) {
            SettingsPane.jobs.content(for: model, softwareUpdater: updater)
        }
        model.downloadPacing = DownloadPacing()
        model.transferPreferences.logLevel = .errors
        model.transferPreferences.logFile = fixture.appending(path: "Demo Transfers.txt")
        try capture("jobs-log", size: (680, 600), scrollToBottom: true) {
            SettingsPane.jobs.content(for: model, softwareUpdater: updater)
        }
        model.setTransferDelivery(.soundOnly, for: .downloadCompleted)
        try capture("notifications-sound", title: "DownAudible Settings", size: (720, 600), scrollToBottom: true) {
            PreferencesView(model: model, softwareUpdater: updater, selection: .notifications)
        }
        try capture("settings-files-naming", title: "DownAudible Settings", size: (720, 600), scrollToBottom: true) {
            PreferencesView(model: model, softwareUpdater: updater, selection: .files)
        }
        try captureAlerts()
        try captureMenus()
    }

    func workspace(_ page: WorkspacePage, with model: WorkspaceModel? = nil,
                           conversionOptions: Bool = false) -> some View {
        let model = model ?? self.model
        model.page = page
        return WorkspaceView(model: model, softwareUpdater: updater, showsStatusBar: true,
                             showingOnboarding: .constant(false), showingConversionOptions: .constant(conversionOptions),
                             requestingBatchRestart: .constant(false), sidebarVisibility: .constant(.all), openManual: {})
    }

    private func makeBatch(books: [AudibleBook], account: SavedAudibleAccount) -> TransferBatch {
        TransferBatch(work: books.map { .library($0, matches: []) }, account: account, apiOptions: model.apiOptions,
                      layout: model.layout, options: model.downloadOptions, conversion: model.conversionPreferences,
                      appleBooks: .off, preferences: model.transferPreferences, jobLimit: 3)
    }

    private func makeBook(_ index: Int, finished: Bool = false, progress: Double = 0) -> AudibleBook {
        AudibleBook(
            asin: "DEMOBOOK\(index < 10 ? "0" : "")\(index)", title: "Demo Book \(index)", subtitle: nil,
            authors: ["Demo Author \(index <= 2 ? 1 : 2)"], narrators: ["Demo Narrator \(index % 2 + 1)"],
            series: index <= 3 ? "Demo Series" : nil, seriesSequence: index <= 3 ? String(index) : nil,
            publisher: "Demo Publisher", description: nil, language: "English",
            genres: [index.isMultiple(of: 2) ? "Adventure" : "Mystery"], releaseDate: "2026-08-11",
            purchaseDate: "2026-08-12", dateAdded: "2026-08-12", rating: nil, ratingCount: nil,
            isFinished: finished, percentComplete: progress, durationSeconds: 18_000 + index * 800,
            coverURL: nil, coverImages: nil, hasPDF: index == 3, isDownloadable: index != 6,
            downloadUnavailableReason: index == 6 ? .offlineRestricted : nil
        )
    }

    func capture<Content: View>(
        _ name: String, title: String = "", size: (width: CGFloat, height: CGFloat), sheet: Bool = false,
        settle: TimeInterval = 0.25, menu: FixtureMenu? = nil, scrollToBottom: Bool = false,
        @ViewBuilder content: () -> Content
    ) throws {
        guard requested.isEmpty || requested.contains(name) else { return }
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: title.isEmpty ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingController(rootView: content()
            .defaultAppStorage(defaults)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .background(.background))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(frame.size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let hostWindow = host.view.window { hostWindow.displayIfNeeded() }
        defer {
            for attached in window.sheets { window.endSheet(attached) }
            window.orderOut(nil)
            window.close()
        }

        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        let subject = sheet ? (window.attachedSheet ?? window) : window
        if scrollToBottom, let content = subject.contentView, let scroll = scrollingArea(in: content),
           let document = scroll.documentView {
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.documentVisibleRect.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        let destination = output.appending(path: name + ".png")
        if let menu {
            try captureFixtureMenu(menu, window: window, destination: destination)
            print(name)
            return
        }
        let screenshot = Process()
        screenshot.executableURL = URL(filePath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-o", "-l", String(subject.windowNumber), destination.path]
        try screenshot.run()
        screenshot.waitUntilExit()
        guard screenshot.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t capture \(name). Run from a signed-in macOS desktop session with Screen Recording access."
            ])
        }
        print(name)
    }

    private func scrollingArea(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.bounds.height > scroll.documentVisibleRect.height + 1 {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.scrollingArea(in: $0) }.first
    }
}
