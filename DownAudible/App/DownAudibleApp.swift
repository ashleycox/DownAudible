import AppKit
import SwiftUI

@main
struct DownAudibleApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(DownAudibleAppDelegate.self) private var appDelegate
    @AppStorage private var showsStatusBar: Bool
    @State private var model: WorkspaceModel
    @State private var showingOnboarding = false
    @State private var showingConversionOptions = false
    @State private var requestingBatchRestart = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    @State private var helpChapterRequest: String?

    init() {
        DownAudibleIdentity.migratePreferences()
        _showsStatusBar = AppStorage(wrappedValue: true, "ShowsLibraryStatusBar")
        _model = State(initialValue: WorkspaceModel())
    }

    var body: some Scene {
        scenes
            .onChange(of: scenePhase, initial: true) { [openWindow] in
                appDelegate.model = model
                appDelegate.observeTransferNotifications { openWindow(id: "workspace") }
            }
    }

    @SceneBuilder
    private var scenes: some Scene {
        Window("DownAudible", id: "workspace") {
            WorkspaceView(model: model, softwareUpdater: appDelegate.softwareUpdater, showsStatusBar: showsStatusBar,
                          showingOnboarding: $showingOnboarding, showingConversionOptions: $showingConversionOptions,
                          requestingBatchRestart: $requestingBatchRestart,
                          sidebarVisibility: $sidebarVisibility, openManual: { openHelp() })
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1_080, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DownAudible") { openWindow(id: "about") }
                    .keyboardShortcut("a", modifiers: [.command, .control, .shift])
                    .appHelp("Show app version, licence, and developer information.")
                Button("Check for Updates…", action: appDelegate.softwareUpdater.checkForUpdates)
                    .disabled(!appDelegate.softwareUpdater.canCheckForUpdates)
                    .appHelp("Check for a new version of DownAudible.")
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Audio Files…", action: openAudioFiles)
                    .keyboardShortcut("o")
                    .disabled(model.isPreparingFiles)
                    .appHelp("Add audio files to Convert Files.")
                Button("Open Audio Folder…", action: openAudioFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isPreparingFiles)
                    .appHelp("Scan a folder for audio files to add to Convert Files.")
            }
            CommandGroup(after: .toolbar) {
                Button(sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar", action: toggleSidebar)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .appHelp("Show or hide the sidebar that switches between workspaces.")
                Button(showsStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                    showsStatusBar.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .appHelp("Show or hide the library counts and status at the bottom of the window.")
                LibraryBrowseCommands()
                    .disabled(showingOnboarding || model.downloadRequest != nil)
                Divider()
                Button("Library") { show(.library) }
                    .keyboardShortcut("1")
                    .appHelp("Open the library or use its refresh, file matching, and export commands.")
                Button(WorkspacePage.transfers.rawValue) { show(.transfers) }
                    .keyboardShortcut("2")
                    .appHelp("Show the downloads and conversions queue.")
                Button("Convert Files") { show(.convert) }
                    .keyboardShortcut("3")
                    .appHelp("Open the workspace for converting local audio files.")
                Button("Library Status") { openWindow(id: "library-status") }
                    .keyboardShortcut("4")
                    .appHelp("Open the breakdown of downloaded, matched, and unavailable audiobooks.")
            }
            CommandMenu("Audiobooks") {
                LibraryDownloadCommands(model: model, activateLibrary: { show(.library) })
                    .disabled(showingOnboarding)

                Menu("Library") {
                    Button("Refresh Library") {
                        show(.library)
                        Task { await model.refresh() }
                    }
                    .keyboardShortcut("r")
                    .disabled(!model.signedIn || model.isRefreshing || model.isScanning)
                    .appHelp("Fetch the latest library information from Audible.")
                    Button("Recheck Saved Files") {
                        show(.library)
                        Task { await model.recheckFiles() }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.signedIn || model.isRefreshing || model.isScanning || model.isCheckingFiles)
                    .appHelp("Check that the saved or matched audio files are still present.")
                    ArchiveVerificationButton(model: model)

                    Divider()
                    LibraryContextCommands(model: model)
                        .disabled(showingOnboarding || model.downloadRequest != nil || model.bookEditRequest != nil)
                    Menu("Export Library") {
                        Button("JSON…") { Task { await model.exportLibrary(.json) } }
                            .keyboardShortcut("j", modifiers: [.command, .control])
                            .appHelp("Export book information to a JSON file.")
                        Button("CSV…") { Task { await model.exportLibrary(.csv) } }
                            .keyboardShortcut("c", modifiers: [.command, .control])
                            .appHelp("Export book information to a comma-separated file.")
                        Button("TSV…") { Task { await model.exportLibrary(.tsv) } }
                            .keyboardShortcut("t", modifiers: [.command, .control])
                            .appHelp("Export book information to a tab-separated file.")
                    }
                    .disabled(!model.signedIn || model.isRefreshing)
                    .appHelp("Save the loaded library as a structured list.")
                    LibraryVisibleExportCommands(model: model)
                }
                .appHelp("Open the library or use its refresh, file matching, and export commands.")

                Divider()
                Button("Audible Tools…") { openWindow(id: "audible-tools") }
                    .keyboardShortcut("5")
                    .disabled(model.activeAudibleClient == nil)
                    .appHelp("Open the Wish List, catalogue search, and account tools.")
                WishlistExportCommands()

                Divider()
                ConversionSelectionCommands {
                    show(.convert)
                    showingConversionOptions = true
                }
                .disabled(showingOnboarding || model.downloadRequest != nil || model.bookEditRequest != nil)
            }
            CommandMenu(WorkspacePage.transfers.rawValue) {
                Button("Cancel Batch") {
                    show(.transfers)
                    model.cancelBatch()
                }
                .keyboardShortcut(".", modifiers: [.command, .control])
                .disabled(!model.isTransferring)
                .appHelp("Stop the running download and conversion jobs.")
                Button("Retry Incomplete") {
                    show(.transfers)
                    model.retryBatch()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!model.canRetry)
                .appHelp("Retry unfinished jobs and reuse valid partial downloads.")
                Button("Restart Incomplete Downloads…") {
                    show(.transfers)
                    requestingBatchRestart = true
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(!model.canRestart)
                .appHelp("Review restarting unfinished downloads from the beginning.")
                Divider()
                Button("Clear Completed") {
                    show(.transfers)
                    model.clearCompletedTransfers()
                }
                .keyboardShortcut("k", modifiers: [.command, .control])
                .disabled(!model.canClearCompleted)
                .appHelp("Remove successful jobs from Downloads and keep their saved files.")
                TransferSelectionCommands()
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show DownAudible") { openWindow(id: "workspace") }
                    .keyboardShortcut("0", modifiers: [.command, .control])
                    .appHelp("Bring the main DownAudible window to the front.")
            }
            CommandGroup(replacing: .help) {
                Button("DownAudible Help") { openHelp() }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                    .appHelp("Open the DownAudible manual.")
                Button("Keyboard Shortcuts") { openHelp(anchor: DownAudibleHelp.shortcuts) }
                    .keyboardShortcut("/", modifiers: [.command, .option])
                    .appHelp("Open the keyboard shortcuts chapter of the manual.")
                Button("Settings Reference") { openHelp(anchor: DownAudibleHelp.settings) }
                    .appHelp("Open the manual chapter explaining every setting.")
                Button("Set Up DownAudible…") {
                    openWindow(id: "workspace")
                    showingOnboarding = true
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(showingOnboarding || model.downloadRequest != nil)
                .appHelp("Open the setup assistant to review accounts and settings.")
                Divider()
                Button("Donate…") { openURL(DownAudibleLinks.donation) }
                    .keyboardShortcut("y", modifiers: [.command, .control])
                    .appHelp("Open the DownAudible donation page in your browser.")
            }
        }

        Settings {
            PreferencesView(model: model, softwareUpdater: appDelegate.softwareUpdater)
        }

        Window("About DownAudible", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Audible Tools", id: "audible-tools") {
            if let client = model.activeAudibleClient {
                AudibleToolsView(client: client, accountName: model.activeAccount?.name ?? "Audible")
                    .id(model.activeAccount?.id)
            } else {
                ContentUnavailableView {
                    Label("Sign In to Audible", systemImage: "person.crop.circle")
                } actions: {
                    Button("Show Library") { show(.library) }
                        .appHelp("Return to the library to connect an Audible account.")
                }
            }
        }
        .defaultSize(width: 840, height: 560)
        .commandsRemoved()

        Window("DownAudible Help", id: "help") {
            DownAudibleHelpView(requestedChapter: $helpChapterRequest)
        }
        .defaultSize(width: 820, height: 580)
        .commandsRemoved()

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            DownAudibleHelpView(keyboardShortcuts: true, requestedChapter: $helpChapterRequest)
        }
        .defaultSize(width: 780, height: 620)
        .commandsRemoved()

        Window("Library Status", id: "library-status") {
            LibraryStatusView(model: model)
        }
        .defaultSize(width: 960, height: 560)
        .commandsRemoved()
    }

    private func openHelp(anchor: String? = nil) {
        if DownAudibleHelp.openSystemHelp(anchor: anchor) { return }
        if anchor == DownAudibleHelp.shortcuts {
            openWindow(id: "keyboard-shortcuts")
        } else {
            helpChapterRequest = anchor ?? DownAudibleHelp.contents
            openWindow(id: "help")
        }
    }

    private func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }

    private func show(_ page: WorkspacePage) {
        model.page = page
        openWindow(id: "workspace")
    }

    private func openAudioFiles() {
        addAudio(Panels.openAudio(allowFolders: false))
    }

    private func openAudioFolder() {
        if let folder = Panels.openFolder() { addAudio([folder]) }
    }

    private func addAudio(_ files: [URL]) {
        guard !files.isEmpty else { return }
        show(.convert)
        Task { await model.addFiles(at: files) }
    }
}

private struct WorkspaceView: View {
    @AppStorage("HasFinishedOnboarding") private var hasFinishedOnboarding = false
    @Bindable var model: WorkspaceModel
    let softwareUpdater: SoftwareUpdater
    let showsStatusBar: Bool
    @Binding var showingOnboarding: Bool
    @Binding var showingConversionOptions: Bool
    @Binding var requestingBatchRestart: Bool
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    let openManual: () -> Void
    @State private var libraryFilters = LibraryFilters()
    @State private var openManualAfterSetup = false

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(WorkspacePage.allCases, selection: $model.page) { page in
                SidebarPageRow(page: page, remaining: page == .transfers ? remainingJobs : 0)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            Group {
                switch model.page ?? .library {
                case .library:
                    LibraryView(model: model, showsStatusBar: showsStatusBar, sort: librarySort, filters: $libraryFilters)
                        .id(model.activeAccountID)
                case .transfers:
                    TransfersView(model: model, requestingBatchRestart: $requestingBatchRestart)
                case .convert:
                    ConverterView(model: model, showingOptions: $showingConversionOptions)
                }
            }
            .navigationTitle((model.page ?? .library).rawValue)
        }
        .task {
            if !hasFinishedOnboarding { showingOnboarding = true }
            await model.load()
        }
        .onChange(of: model.activeAccountID) { libraryFilters = LibraryFilters() }
        .onChange(of: model.signedIn) {
            if !model.signedIn { libraryFilters = LibraryFilters() }
        }
        .onChange(of: model.layout) {
            Task { await model.refreshExportStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard model.signedIn && model.canSwitchAccounts && !model.isCheckingFiles else { return }
            Task { await model.recheckFiles() }
        }
        .sheet(item: $model.downloadRequest) { request in
            DownloadOptionsView(model: model, request: request)
        }
        .sheet(item: $model.bookEditRequest) { request in
            BookEditorView(model: model, request: request)
        }
        .sheet(isPresented: $model.showingArchiveVerification) {
            ArchiveVerificationView(model: model)
        }
        .sheet(isPresented: $showingOnboarding, onDismiss: openSetupManualIfRequested) {
            OnboardingView(model: model, softwareUpdater: softwareUpdater) { destination in
                hasFinishedOnboarding = true
                openManualAfterSetup = destination == .manual
                showingOnboarding = false
            }
        }
        .alert(item: workspaceNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
    }

    private var remainingJobs: Int {
        model.isTransferring ? model.transfers.count - model.finishedCount : 0
    }

    private var librarySort: Binding<LibrarySort> {
        guard let accountID = model.activeAccountID else { return .constant(LibrarySort()) }
        return Binding {
            model.librarySort(for: accountID)
        } set: { sort in
            model.setLibrarySort(sort, for: accountID)
        }
    }

    private var workspaceNotice: Binding<WorkspaceModel.Notice?> {
        Binding {
            showingOnboarding ? nil : model.notice
        } set: { notice in
            if !showingOnboarding { model.notice = notice }
        }
    }

    private func openSetupManualIfRequested() {
        guard openManualAfterSetup else { return }
        openManualAfterSetup = false
        openManual()
    }
}

private struct SidebarPageRow: View {
    let page: WorkspacePage
    let remaining: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(page.rawValue, systemImage: page.icon)
                .accessibilityLabel(accessibleTitle)
                .accessibilityInputLabels([Text(page.rawValue)])
            if remaining > 0 {
                Spacer(minLength: 4)
                Text(remaining, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .appHelp(pageHelp)
    }

    private var pageHelp: String {
        switch page {
        case .library: "Browse and manage the active Audible library."
        case .transfers: "See the download and conversion queue and manage unfinished jobs."
        case .convert: "Add and convert audio files already on this Mac."
        }
    }

    private var accessibleTitle: String {
        switch remaining {
        case 0: page.rawValue
        case 1: "\(page.rawValue), 1 job remaining"
        default: "\(page.rawValue), \(remaining.formatted()) jobs remaining"
        }
    }
}
