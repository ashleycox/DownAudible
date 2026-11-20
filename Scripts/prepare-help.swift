import Foundation

struct Chapter {
    let name: String
    let title: String
    let markdown: AttributedString
    let support: Substring?

    init(source: URL) throws {
        name = source.deletingPathExtension().lastPathComponent
        let text = try String(contentsOf: source, encoding: .utf8)
        guard let firstLine = text.split(separator: "\n").first, firstLine.hasPrefix("# ") else {
            throw HelpBuildError.missingTitle(source.lastPathComponent)
        }
        title = String(firstLine.dropFirst(2))
        markdown = try AttributedString(markdown: text)
        support = text.range(of: "\n## Support DownAudible\n").map { text[$0.lowerBound...] }
    }
}

enum HelpBuildError: LocalizedError {
    case missingTitle(String)
    case missingChapters
    case indexFailed(Int32)
    case missingAnchors([String])

    var errorDescription: String? {
        switch self {
        case .missingTitle(let file): "Missing a top-level heading in \(file)."
        case .missingChapters: "No help chapters found."
        case .indexFailed(let status): "Help indexing failed with status \(status)."
        case .missingAnchors(let anchors): "The Help index is missing these anchors: \(anchors.joined(separator: ", "))."
        }
    }
}

struct HTMLTag {
    let start: String
    let end: String

    init(_ name: String, attributes: String = "") {
        start = "<\(name)\(attributes)>"
        end = "</\(name)>"
    }

    init(start: String, end: String = "") {
        self.start = start
        self.end = end
    }
}

func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func tag(for kind: PresentationIntent.Kind, parent: PresentationIntent.Kind?, section: String?) -> HTMLTag {
    switch kind {
    case .header(let level):
        HTMLTag("h\(level)", attributes: section.map { " id=\"\($0)\"" } ?? "")
    case .paragraph:
        HTMLTag("p")
    case .orderedList:
        HTMLTag("ol")
    case .unorderedList:
        HTMLTag("ul")
    case .listItem:
        HTMLTag("li")
    case .codeBlock:
        HTMLTag(start: "<pre><code>", end: "</code></pre>")
    case .blockQuote:
        HTMLTag("blockquote")
    case .thematicBreak:
        HTMLTag(start: "<hr>")
    case .table:
        HTMLTag(start: "<table" + (section.map { " aria-labelledby=\"\($0)\"" } ?? "") + ">", end: "</tbody></table>")
    case .tableHeaderRow:
        HTMLTag(start: "<thead><tr>", end: "</tr></thead><tbody>")
    case .tableRow:
        HTMLTag("tr")
    case .tableCell(let column):
        if parent == .tableHeaderRow {
            HTMLTag("th", attributes: " scope=\"col\"")
        } else if column == 0 {
            HTMLTag("th", attributes: " scope=\"row\"")
        } else {
            HTMLTag("td")
        }
    @unknown default:
        HTMLTag("div")
    }
}

func html(for markdown: AttributedString) -> String {
    var html = ""
    var open: [(identity: Int, tag: HTMLTag)] = []
    var section: String?
    var headings: [Int: String] = [:]
    for run in markdown.runs {
        if let heading = run.presentationIntent?.components.first(where: {
            if case .header = $0.kind { return true }
            return false
        }) {
            headings[heading.identity, default: ""] += String(markdown[run.range].characters)
        }
    }
    var usedSections: Set<String> = []
    for run in markdown.runs {
        let path = Array((run.presentationIntent?.components ?? []).reversed())
        let shared = zip(open, path).prefix { $0.identity == $1.identity }.count
        for entry in open[shared...].reversed() {
            html += entry.tag.end
        }
        open.removeLast(open.count - shared)
        for (index, node) in path.enumerated().dropFirst(shared) {
            if case .header = node.kind {
                let heading = headings[node.identity, default: ""].lowercased()
                let slug = heading.map {
                    if $0.isWhitespace { return "-" }
                    return $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : ""
                }.joined()
                let base = slug.isEmpty ? "section-\(node.identity)" : slug
                var candidate = base
                var suffix = 1
                while !usedSections.insert(candidate).inserted {
                    candidate = "\(base)-\(suffix)"
                    suffix += 1
                }
                section = candidate
            }
            let parent = index > 0 ? path[index - 1].kind : nil
            let tag = tag(for: node.kind, parent: parent, section: section)
            html += tag.start
            open.append((node.identity, tag))
        }
        if path.last?.kind == .thematicBreak { continue }
        var text = escaped(String(markdown[run.range].characters))
        if let style = run.inlinePresentationIntent {
            if style.contains(.code) { text = "<code>\(text)</code>" }
            if style.contains(.stronglyEmphasized) { text = "<strong>\(text)</strong>" }
            if style.contains(.emphasized) { text = "<em>\(text)</em>" }
            if style.contains(.strikethrough) { text = "<s>\(text)</s>" }
            if style.contains(.lineBreak) { text = "<br>" }
        }
        if let url = run.link {
            let destination: String
            if url.scheme == nil, url.pathExtension == "md",
               var relative = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let name = url.deletingPathExtension().lastPathComponent
                relative.path = name == "README" ? "index.html" : name + ".html"
                destination = relative.string ?? url.absoluteString
            } else {
                destination = url.absoluteString
            }
            text = "<a href=\"\(escaped(destination))\">\(text)</a>"
        }
        html += text
    }
    for entry in open.reversed() {
        html += entry.tag.end
    }
    return html
}

func page(title: String, content: String, bookIdentifier: String? = nil) -> String {
    let metadata = bookIdentifier.map { "<meta name=\"AppleTitle\" content=\"\(escaped($0))\">" } ?? ""
    let navigation = bookIdentifier != nil ? "" : """
        <nav aria-label="Help navigation"><a href="index.html">Contents</a></nav>
        """
    return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        \(metadata)
        <title>\(escaped(title))</title>
        <link rel="stylesheet" href="help.css">
        </head>
        <body>
        \(navigation)
        <main>\(content)</main>
        </body>
        </html>
        """
}

func buildHelp(in destination: URL, source: URL, bookID: String) throws {
    let manager = FileManager.default
    let files = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("help-") && $0.pathExtension == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let chapters = try files.map(Chapter.init(source:))
    guard !chapters.isEmpty else { throw HelpBuildError.missingChapters }

    let scratch = destination.deletingLastPathComponent()
        .appendingPathComponent(".help-build-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: scratch) }
    let contents = scratch.appendingPathComponent("Contents", isDirectory: true)
    let pages = contents.appendingPathComponent("Resources/en.lproj", isDirectory: true)
    try manager.createDirectory(at: pages, withIntermediateDirectories: true)
    let indexName = "DownAudible.cshelpindex"
    let properties = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleIdentifier": bookID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "DownAudible Help",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": ProcessInfo.processInfo.environment["MARKETING_VERSION"] ?? "1.0",
        "CFBundleSignature": "hbwr",
        "CFBundleVersion": ProcessInfo.processInfo.environment["CURRENT_PROJECT_VERSION"] ?? "1",
        "HPDBookAccessPath": "index.html",
        "HPDBookCSIndexPath": indexName,
        "HPDBookTitle": "DownAudible Help",
        "HPDBookType": "3",
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    let englishTitle = "\"HPDBookTitle\" = \"DownAudible Help\";\n"
    try englishTitle.write(to: pages.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
    let style = source.deletingLastPathComponent().appendingPathComponent("help.css")
    try manager.copyItem(at: style, to: pages.appendingPathComponent("help.css"))

    for chapter in chapters {
        let anchor = "<a name=\"\(escaped(chapter.name))\" id=\"\(escaped(chapter.name))\"></a>"
        try page(title: chapter.title, content: anchor + html(for: chapter.markdown))
            .write(to: pages.appendingPathComponent(chapter.name + ".html"), atomically: true, encoding: .utf8)
    }
    let links = chapters.map { chapter in
        "<li><a href=\"\(escaped(chapter.name)).html\">\(escaped(chapter.title))</a></li>"
    }.joined(separator: "\n")
    let support = try chapters.first?.support.map { "<hr>" + html(for: try AttributedString(markdown: String($0))) } ?? ""
    let contentsPage = """
        <a name="index" id="index"></a><h1>DownAudible Help</h1>
        <nav aria-label="Chapters"><ul>\(links)</ul></nav>\(support)
        """
    try page(title: "DownAudible Help", content: contentsPage, bookIdentifier: bookID)
        .write(to: pages.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

    let indexer = Process()
    indexer.executableURL = URL(fileURLWithPath: "/usr/bin/hiutil")
    indexer.arguments = ["-I", "corespotlight", "-C", "-a", "-s", "en", "-l", "en",
                         "-f", pages.appendingPathComponent(indexName).path, pages.path]
    try indexer.run()
    indexer.waitUntilExit()
    guard indexer.terminationStatus == 0 else { throw HelpBuildError.indexFailed(indexer.terminationStatus) }

    let anchors = Process()
    let output = Pipe()
    anchors.executableURL = indexer.executableURL
    anchors.arguments = ["-I", "corespotlight", "-A", "-f", pages.appendingPathComponent(indexName).path]
    anchors.standardOutput = output
    try anchors.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    anchors.waitUntilExit()
    guard anchors.terminationStatus == 0 else { throw HelpBuildError.indexFailed(anchors.terminationStatus) }
    let indexed = Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
    let missing = (["index"] + chapters.map(\.name)).filter { !indexed.contains($0) }
    guard missing.isEmpty else { throw HelpBuildError.missingAnchors(missing) }

    if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: scratch)
    } else {
        try manager.moveItem(at: scratch, to: destination)
    }
}

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("Usage: prepare-help.swift manual-directory destination book-identifier\n".utf8))
    exit(2)
}

do {
    try buildHelp(
        in: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
        source: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
        bookID: CommandLine.arguments[3]
    )
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
