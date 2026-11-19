import AppKit
import SwiftUI
import WebKit

enum DownAudibleHelp {
    static let shortcuts = "help-10-keyboard-shortcuts"

    static var pages: URL? {
        Bundle.main.resourceURL?.appending(path: "DownAudible.help/Contents/Resources/en.lproj", directoryHint: .isDirectory)
    }

    @MainActor
    static func openSystemHelp(anchor: String? = nil) -> Bool {
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().pathComponents
        let applications = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        // macOS Help cannot always read a third-party book outside an Applications directory.
        guard applications.contains(where: { appPath.starts(with: $0.resolvingSymlinksInPath().pathComponents) }),
              let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String,
              NSHelpManager.shared.registerBooks(in: Bundle.main) else { return false }
        if let anchor {
            NSHelpManager.shared.openHelpAnchor(.init(anchor), inBook: .init(book))
        } else {
            NSApplication.shared.showHelp(nil)
        }
        return true
    }
}

struct DownAudibleHelpView: View {
    @Environment(\.openWindow) private var openWindow
    var keyboardShortcuts = false
    @Binding var requestedChapter: String?
    @State private var selection: HelpChapter.ID? = HelpChapter.all.first?.id
    @State private var search = ""

    var body: some View {
        Group {
            if keyboardShortcuts {
                if let chapter = HelpChapter.all.first(where: { $0.id == DownAudibleHelp.shortcuts }) {
                    article(chapter) { chapterID in
                        requestedChapter = chapterID
                        openWindow(id: "help")
                    }
                } else {
                    unavailable
                }
            } else {
                manual
            }
        }
        .frame(minWidth: 616, minHeight: 360)
    }

    private var manual: some View {
        NavigationSplitView {
            List(resultChapters, selection: $selection) { chapter in
                Text(chapter.title).tag(chapter.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
            .accessibilityLabel("Help chapters")
        } detail: {
            if let chapter = resultChapters.first(where: { $0.id == selection }) ?? resultChapters.first {
                article(chapter, openChapter: showChapter)
                    .id(chapter.id)
            } else if HelpChapter.all.isEmpty {
                unavailable
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Search Help")
        .onChange(of: search) {
            if !resultChapters.contains(where: { $0.id == selection }) {
                selection = resultChapters.first?.id
            }
        }
        .onChange(of: requestedChapter, initial: true) { _, chapterID in
            if let chapterID {
                showChapter(chapterID)
                requestedChapter = nil
            }
        }
    }

    private func showChapter(_ chapterID: HelpChapter.ID) {
        if !resultChapters.contains(where: { $0.id == chapterID }) { search = "" }
        selection = chapterID
    }

    @ViewBuilder
    private func article(_ chapter: HelpChapter, openChapter: @escaping (HelpChapter.ID) -> Void) -> some View {
        if let pages = DownAudibleHelp.pages {
            let url = pages.appending(path: chapter.id + ".html", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                HelpWebPage(url: url, openChapter: openChapter)
            } else {
                unavailable
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Help Unavailable", systemImage: "book.closed",
                               description: Text("Rebuild DownAudible to restore the help chapters."))
    }

    private var resultChapters: [HelpChapter] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return HelpChapter.all }
        return HelpChapter.all.filter { $0.matches(query) }
    }
}

private struct HelpWebPage: NSViewRepresentable {
    let url: URL
    let openChapter: (HelpChapter.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openChapter: openChapter)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.openChapter = openChapter
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var openChapter: (HelpChapter.ID) -> Void

        init(openChapter: @escaping (HelpChapter.ID) -> Void) {
            self.openChapter = openChapter
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.isFileURL {
                let id = url.deletingPathExtension().lastPathComponent
                if id == "index", let firstChapter = HelpChapter.all.first {
                    openChapter(firstChapter.id)
                    return .cancel
                }
                if HelpChapter.all.contains(where: { $0.id == id }) {
                    openChapter(id)
                    return .cancel
                }
                return .allow
            }
            if url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

private struct HelpChapter: Identifiable {
    let id: String
    let title: String
    private let searchableText: String

    static let all: [HelpChapter] = {
        let folders: [String?] = [nil, "Manual", "Help/Manual"]
        let urls = Set(folders.flatMap { Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: $0) ?? [] })
        return urls.filter { $0.lastPathComponent.hasPrefix("help-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let heading = text.split(separator: "\n").first, heading.hasPrefix("# ") else { return nil }
                let footerStart = text.range(of: "\n## Support DownAudible\n")?.lowerBound ?? text.endIndex
                return HelpChapter(id: url.deletingPathExtension().lastPathComponent,
                                   title: String(heading.dropFirst(2)), searchableText: String(text[..<footerStart]))
            }
    }()

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchableText.localizedStandardContains(String($0))
        }
    }
}
