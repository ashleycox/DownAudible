import SwiftUI

struct DownAudibleHelpView: View {
    var keyboardShortcuts = false
    @State private var selection: HelpChapter.ID? = HelpChapter.all.first?.id
    @State private var search = ""

    var body: some View {
        Group {
            if keyboardShortcuts {
                if let chapter = HelpChapter.all.first(where: { $0.id == "help-10-keyboard-shortcuts" }) {
                    HelpArticleView(chapter: chapter)
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
                HelpArticleView(chapter: chapter)
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
        case .table(let table):
            HelpTableView(table: table)
        }
    }
}

private struct HelpTableView: View {
    let table: HelpChapter.MarkdownTable

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    Text(table.header[column])
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 6)
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(table.rows[row][column])
                            .frame(maxWidth: column == 0 ? .infinity : nil, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

private struct HelpChapter: Identifiable {
    enum Paragraph {
        case heading(String)
        case body(AttributedString)
        case table(MarkdownTable)
    }

    struct MarkdownTable {
        let header: [AttributedString]
        let rows: [[AttributedString]]

        init?(_ block: String) {
            let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count >= 3, lines.allSatisfy({ $0.hasPrefix("|") && $0.hasSuffix("|") }) else { return nil }
            let cells = lines.map { line in
                line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let columns = cells[0].count
            guard columns > 1, cells.allSatisfy({ $0.count == columns }), cells[1].allSatisfy({ separator in
                let rule = separator.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return rule.count >= 3 && rule.allSatisfy { $0 == "-" }
            }) else { return nil }
            header = cells[0].map(HelpChapter.inlineMarkdown)
            rows = cells.dropFirst(2).map { $0.map(HelpChapter.inlineMarkdown) }
        }
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
            if let table = MarkdownTable(block) { return .table(table) }
            return .body(Self.inlineMarkdown(block))
        }
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchableText.localizedStandardContains(String($0))
        }
    }
}
