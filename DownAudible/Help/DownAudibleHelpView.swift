import AppKit
import SwiftUI
import WebKit

enum DownAudibleHelp {
    static let contents = "index"
    static let shortcuts = "help-10-keyboard-shortcuts"
    static let settings = "help-12-settings"
    static let widevine = "help-13-widevine"
    static let audiobookshelf = "help-14-audiobookshelf"

    private static var book: Bundle? {
        guard let folder = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookFolder") as? String,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String,
              let url = Bundle.main.resourceURL?.appending(path: folder, directoryHint: .isDirectory),
              let book = Bundle(url: url), book.bundleIdentifier == identifier else { return nil }
        return book
    }

    static var pages: URL? {
        book?.url(forResource: contents, withExtension: "html")?.deletingLastPathComponent()
    }

    @MainActor
    static func openSystemHelp(anchor: String? = nil) -> Bool {
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().pathComponents
        let applications = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let topic = anchor ?? contents
        // macOS Help cannot always read a third-party book outside an Applications directory.
        guard applications.contains(where: { appPath.starts(with: $0.resolvingSymlinksInPath().pathComponents) }),
              let book, let identifier = book.bundleIdentifier,
              book.url(forResource: topic, withExtension: "html") != nil,
              NSHelpManager.shared.registerBooks(in: Bundle.main) else { return false }
        NSHelpManager.shared.openHelpAnchor(.init(topic), inBook: .init(identifier))
        return true
    }
}

struct DownAudibleHelpView: View {
    @Environment(\.openWindow) private var openWindow
    var keyboardShortcuts = false
    @Binding var requestedChapter: String?
    @State private var selection: HelpChapter.ID? = HelpChapter.all.first?.id
    @State private var fragment: (chapter: HelpChapter.ID, anchor: String)?
    @State private var search = ""

    var body: some View {
        Group {
            if keyboardShortcuts {
                if let chapter = HelpChapter.all.first(where: { $0.id == DownAudibleHelp.shortcuts }) {
                    article(chapter) { chapterID, anchor in
                        requestedChapter = anchor.map { "\(chapterID)#\($0)" } ?? chapterID
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
            VStack(spacing: 8) {
                TextField("Search Help", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top], 8)
                    .appHelp("Find help chapters by their titles or text.")

                List(resultChapters, selection: $selection) { chapter in
                    Text(chapter.title)
                        .tag(chapter.id)
                        .appHelp("Open the \(chapter.title) help page.")
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Help chapters")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if let chapter = resultChapters.first(where: { $0.id == selection }) ?? resultChapters.first {
                article(chapter, anchor: fragment?.chapter == chapter.id ? fragment?.anchor : nil, openChapter: showChapter)
            } else if HelpChapter.all.isEmpty {
                unavailable
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
        .onChange(of: search) {
            if !resultChapters.contains(where: { $0.id == selection }) {
                selection = resultChapters.first?.id
            }
        }
        .onChange(of: requestedChapter, initial: true) { _, chapterID in
            if let chapterID {
                let parts = chapterID.split(separator: "#", maxSplits: 1)
                if let page = parts.first { showChapter(String(page), parts.dropFirst().first.map(String.init)) }
                requestedChapter = nil
            }
        }
    }

    private func showChapter(_ chapterID: HelpChapter.ID, _ anchor: String?) {
        if !resultChapters.contains(where: { $0.id == chapterID }) { search = "" }
        fragment = anchor.map { (chapterID, $0) }
        selection = chapterID
    }

    @ViewBuilder
    private func article(
        _ chapter: HelpChapter, anchor: String? = nil,
        openChapter: @escaping (HelpChapter.ID, String?) -> Void
    ) -> some View {
        if let pages = DownAudibleHelp.pages {
            let file = pages.appending(path: chapter.id + ".html", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: file.path) {
                let url = pageURL(file, anchor: anchor)
                HelpWebPage(url: url, openChapter: openChapter).id(url)
            } else {
                unavailable
            }
        } else {
            unavailable
        }
    }

    private func pageURL(_ file: URL, anchor: String?) -> URL {
        guard let anchor, var parts = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        parts.fragment = anchor
        return parts.url ?? file
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
    let openChapter: (HelpChapter.ID, String?) -> Void

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
        var openChapter: (HelpChapter.ID, String?) -> Void

        init(openChapter: @escaping (HelpChapter.ID, String?) -> Void) {
            self.openChapter = openChapter
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.isFileURL {
                let id = url.deletingPathExtension().lastPathComponent
                if webView.url?.path == url.path, url.fragment != nil { return .allow }
                if HelpChapter.all.contains(where: { $0.id == id }) {
                    openChapter(id, url.fragment)
                }
                return .cancel
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
        let chapters: [HelpChapter] = urls.filter { $0.lastPathComponent.hasPrefix("help-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let heading = text.split(separator: "\n").first, heading.hasPrefix("# ") else { return nil }
                let footerStart = text.range(of: "\n## Support DownAudible\n")?.lowerBound ?? text.endIndex
                return HelpChapter(id: url.deletingPathExtension().lastPathComponent,
                                   title: String(heading.dropFirst(2)), searchableText: String(text[..<footerStart]))
            }
        guard DownAudibleHelp.pages != nil else { return [] }
        return [HelpChapter(id: DownAudibleHelp.contents, title: "Contents", searchableText: "")] + chapters
    }()

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchableText.localizedStandardContains(String($0))
        }
    }
}
