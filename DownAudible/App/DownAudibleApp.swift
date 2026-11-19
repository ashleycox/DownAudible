import AppKit
import SwiftUI

@main
struct DownAudibleApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(DownAudibleAppDelegate.self) private var appDelegate
    @State private var model = WorkspaceModel()

    var body: some Scene {
        Window("DownAudible", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 720, minHeight: 440)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1_080, height: 640)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About DownAudible") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Audio Files…", action: openAudioFiles)
                    .keyboardShortcut("o")
                    .disabled(model.isPreparingFiles)
                Button("Open Audio Folder…", action: openAudioFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isPreparingFiles)
            }
            CommandGroup(after: .toolbar) {
                Button("Library") { show(.library) }
                    .keyboardShortcut("1")
                Button("Transfers") { show(.transfers) }
                    .keyboardShortcut("2")
                Button("Convert Files") { show(.convert) }
                    .keyboardShortcut("3")
            }
            CommandMenu("Audiobooks") {
                Button("Refresh Library") {
                    show(.library)
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(!model.signedIn || model.isRefreshing || model.isScanning)
                Button("Recheck Saved Files") {
                    show(.library)
                    Task { await model.recheckFiles() }
                }
                .disabled(!model.signedIn || model.isRefreshing || model.isScanning || model.isCheckingFiles)

                Divider()
                Button("Download Selected…") {
                    show(.library)
                    model.requestDownloads(model.books.filter { model.selectedBooks.contains($0.id) })
                }
                .keyboardShortcut("d")
                .disabled(model.selectedBooks.isEmpty || model.isTransferring)
                Button("Download Missing…") {
                    show(.library)
                    model.requestMissingDownloads()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canDownloadMissing)
                Button("Download Entire Library…") {
                    show(.library)
                    model.requestDownloads(model.books)
                }
                .disabled(model.books.isEmpty || model.isTransferring)

                Divider()
                Menu("Export Library") {
                    Button("JSON…") { Task { await model.exportLibrary(.json) } }
                    Button("CSV…") { Task { await model.exportLibrary(.csv) } }
                    Button("TSV…") { Task { await model.exportLibrary(.tsv) } }
                }
                .disabled(!model.signedIn || model.isRefreshing)
                Button("Audible Tools…") { openWindow(id: "audible-tools") }
                    .disabled(model.activeAudibleClient == nil)
            }
            CommandMenu("Transfers") {
                Button("Cancel Batch") {
                    show(.transfers)
                    model.cancelBatch()
                }
                .disabled(!model.isTransferring)
                Button("Retry Incomplete") {
                    show(.transfers)
                    model.retryBatch()
                }
                .disabled(!model.canRetry)
                Button("Restart Incomplete Downloads") {
                    show(.transfers)
                    model.restartBatch()
                }
                .disabled(!model.canRestart)
                Divider()
                Button("Clear Finished") {
                    show(.transfers)
                    model.clearCompletedTransfers()
                }
                .disabled(!model.canClearCompleted)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show DownAudible") { openWindow(id: "workspace") }
            }
            CommandGroup(replacing: .help) {
                Button("DownAudible Help") { openWindow(id: "help") }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView(model: model)
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
                }
            }
        }
        .defaultSize(width: 840, height: 560)
        .commandsRemoved()

        Window("DownAudible Help", id: "help") {
            DownAudibleHelpView()
        }
        .defaultSize(width: 820, height: 580)
        .commandsRemoved()
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
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            List(WorkspacePage.allCases, selection: $model.page) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .badge(page == .transfers && model.isTransferring ? model.transfers.count - model.finishedCount : 0)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            Group {
                switch model.page ?? .library {
                case .library:
                    LibraryView(model: model)
                case .transfers:
                    TransfersView(model: model)
                case .convert:
                    ConverterView(model: model)
                }
            }
            .navigationTitle((model.page ?? .library).rawValue)
        }
        .task { await model.load() }
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
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
    }
}
