import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationsRequest: Identifiable {
    let id = UUID()
    let book: AudibleBook
    let account: String
    let client: AudibleClient
}

struct AudibleAnnotationsView: View {
    private struct Row: Identifiable {
        let id: Int
        let annotation: AudibleAnnotation

        var timestamp: String { annotation.timestamp.isEmpty ? "Unknown" : annotation.timestamp }
        var kind: String { annotation.kind.label }
        var summary: String {
            annotation.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    let request: AnnotationsRequest
    private let initialEntries: [AudibleAnnotation]?
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AudibleAnnotation]?
    @State private var selection: Int?
    @State private var search = ""
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var loadError: String?
    @State private var exportError: String?
    @FocusState private var searchFocused: Bool

    init(request: AnnotationsRequest, initialEntries: [AudibleAnnotation]? = nil) {
        self.request = request
        self.initialEntries = initialEntries
        _entries = State(initialValue: initialEntries)
        _selection = State(initialValue: initialEntries?.firstIndex { $0.kind == .note })
    }

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = (entries ?? []).enumerated().compactMap { index, entry in
            entry.matches(query) ? Row(id: index, annotation: entry) : nil
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmarks and Notes").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("\(request.book.title) · \(request.account)")
                .foregroundStyle(.secondary)
            TextField("Search Annotations", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .disabled(entries?.isEmpty != false)

            if entries == nil {
                if let loadError {
                    ContentUnavailableView("Couldn’t Load Annotations", systemImage: "exclamationmark.circle",
                                           description: Text(loadError))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Loading annotations…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No Bookmarks or Notes" : "No Matching Annotations",
                                       systemImage: "bookmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Position", value: \.timestamp).width(min: 80, ideal: 100, max: 115)
                    TableColumn("Type", value: \.kind).width(min: 90, ideal: 100, max: 115)
                    TableColumn("Text", value: \.summary)
                }
                .accessibilityLabel("Bookmarks and notes")
                let selected = rows.first { $0.id == selection }
                GroupBox("Annotation text") {
                    ScrollView {
                        Text(selected.map { row in
                            row.annotation.text.isEmpty ? "\(row.kind) · \(row.timestamp)" : row.annotation.text
                        } ?? "Select a bookmark or note to read it here.")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 76)
                    .accessibilityLabel("Selected annotation text")
                }
            }

            if let loadError, entries != nil { Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            if let exportError { Label(exportError, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            HStack {
                if entries != nil {
                    Text(rows.count == 1 ? "1 annotation" : "\(rows.count.formatted()) annotations")
                        .foregroundStyle(.secondary)
                }
                if loading && entries != nil { ProgressView("Reloading…").controlSize(.small) }
                Spacer()
                Button("Reload") { requestID = UUID() }.disabled(loading)
                Menu("Export…") {
                    ForEach(AudibleAnnotation.ExportFormat.allCases, id: \.rawValue) { format in
                        Button("\(format.label)…") { export(rows.map(\.annotation), format: format) }
                    }
                }
                .disabled(rows.isEmpty || loading)
                .appHelp("Save the bookmarks and notes shown in the table.")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 670, minHeight: 420)
        .onKeyPress(keys: ["f"]) { key in
            guard key.modifiers == .command, entries?.isEmpty == false else { return .ignored }
            searchFocused = true
            return .handled
        }
        .task(id: requestID) {
            if initialEntries != nil { return }
            loadError = nil
            loading = true
            defer { loading = false }
            do {
                let annotations = try await request.client.annotations(for: request.book)
                try Task.checkCancellation()
                entries = annotations
                selection = nil
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onChange(of: query) {
            if !rows.contains(where: { $0.id == selection }) { selection = nil }
        }
    }

    private func export(_ entries: [AudibleAnnotation], format: AudibleAnnotation.ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(request.book.asin)-annotations.\(format.fileExtension)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let path = panel.url else { return }
        exportError = nil
        Task {
            do { try await AudibleAnnotation.export(entries, book: request.book, as: format, to: path) }
            catch { exportError = error.localizedDescription }
        }
    }
}
