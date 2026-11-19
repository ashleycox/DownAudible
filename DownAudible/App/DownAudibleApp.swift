import AppKit
import SwiftUI

@main
struct DownAudibleApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var model = WorkspaceModel()

    var body: some Scene {
        Window("DownAudible", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1_080, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DownAudible") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Audio Files…") {
                    let files = Panels.openAudio(allowFolders: false)
                    guard !files.isEmpty else { return }
                    model.page = .convert
                    openWindow(id: "workspace")
                    Task { await model.addFiles(at: files) }
                }
                .keyboardShortcut("o")
                .disabled(model.isPreparingFiles)
            }
            CommandMenu("Audiobooks") {
                Button("Refresh Library") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(!model.signedIn || model.isRefreshing || model.isScanning)
                Button("Download Entire Library…") {
                    openWindow(id: "workspace")
                    model.requestDownloads(model.books)
                }
                .disabled(model.books.isEmpty || model.isTransferring)
                Menu("Export Library") {
                    Button("JSON…") { Task { await model.exportLibrary(.json) } }
                    Button("CSV…") { Task { await model.exportLibrary(.csv) } }
                    Button("TSV…") { Task { await model.exportLibrary(.tsv) } }
                }
                .disabled(!model.signedIn || model.isRefreshing)
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
        .sheet(item: $model.downloadRequest) { request in
            DownloadOptionsView(model: model, request: request)
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
    }
}
