import SwiftUI

struct DownAudibleHelpView: View {
    @State private var selection: HelpChapter.ID? = HelpChapter.all.first?.id
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(resultChapters, selection: $selection) { chapter in
                Text(chapter.title).tag(chapter.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
            .accessibilityLabel("Help chapters")
        } detail: {
            if let chapter = resultChapters.first(where: { $0.id == selection }) ?? resultChapters.first {
                HelpArticleView(chapter: chapter)
                    .id(chapter.id)
            } else if HelpChapter.all.isEmpty {
                ContentUnavailableView("Help Unavailable", systemImage: "book.closed",
                                       description: Text("Rebuild DownAudible to restore the help chapters."))
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
        .frame(minWidth: 616, minHeight: 360)
    }

    private var resultChapters: [HelpChapter] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return HelpChapter.all }
        return HelpChapter.all.filter { $0.matches(query) }
    }
}

private struct HelpArticleView: View {
    let chapter: HelpChapter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(chapter.title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                ForEach(chapter.paragraphs.indices, id: \.self) { index in
                    paragraph(chapter.paragraphs[index])
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func paragraph(_ paragraph: HelpChapter.Paragraph) -> some View {
        switch paragraph {
        case .heading(let title):
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
        case .body(let text):
            Text(text)
                .lineSpacing(3)
        }
    }
}

private struct HelpChapter: Identifiable {
    enum Paragraph {
        case heading(String)
        case body(AttributedString)
    }

    let id: String
    let title: String
    let paragraphs: [Paragraph]
    private let searchableText: String

    static let all: [HelpChapter] = {
        let folders: [String?] = [nil, "Manual", "Help/Manual"]
        let urls = Set(folders.flatMap { Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: $0) ?? [] })
        return urls.filter { $0.lastPathComponent.hasPrefix("help-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return HelpChapter(markdown: markdown, id: url.deletingPathExtension().lastPathComponent)
            }
    }()

    init?(markdown: String, id: String) {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let heading = blocks.first, heading.hasPrefix("# ") else { return nil }
        self.id = id
        title = String(heading.dropFirst(2))
        searchableText = normalized
        paragraphs = blocks.dropFirst().map { block in
            if block.hasPrefix("## ") { return .heading(String(block.dropFirst(3))) }
            let styled = try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return .body(styled ?? AttributedString(block))
        }
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchableText.localizedStandardContains(String($0))
        }
    }
}
