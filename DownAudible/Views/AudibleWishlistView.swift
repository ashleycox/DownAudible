import AppKit
import SwiftUI

struct AudibleWishlistView: View {
    let client: AudibleClient

    @FocusState private var filterFocused: Bool
    @State private var books: [AudibleBook] = []
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var work: Task<Void, Never>?
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var issue: String?
    @State private var showingCatalog = false
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Filter Wish List", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .appHelp("Show wish list titles that match a title, author, series or ASIN.")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    run { try await load() }
                }
                .keyboardShortcut("r", modifiers: [.control, .shift])
                .disabled(isBusy)
                .appHelp("Fetch this account’s latest wish list from Audible.")
                if isBusy && hasLoaded {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working on the wish list")
                        .appHelp("The Wish List is being updated.")
                }
            }
            AudibleCatalogTable(books: visibleBooks, selection: $selection)
                .overlay {
                    if loading && !hasLoaded {
                        ProgressView("Loading Wish List")
                            .appHelp("DownAudible is fetching your Wish List from Audible.")
                    } else if hasLoaded && visibleBooks.isEmpty && issue == nil {
                        if search.isEmpty {
                            ContentUnavailableView("Your Wish List Is Empty", systemImage: "bookmark")
                        } else {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Add Titles…", systemImage: "plus") { showingCatalog = true }
                    .keyboardShortcut("a", modifiers: [.control, .shift])
                    .disabled(isBusy)
                    .appHelp("Search the Audible catalogue for titles to add to the wish list.")
                Button("Remove", systemImage: "minus") { confirmingRemoval = true }
                    .keyboardShortcut(.delete, modifiers: [.control, .shift])
                    .disabled(selection.isEmpty || isBusy)
                    .appHelp("Review removing the selected titles from this account’s wish list.")
                Spacer()
                Menu("Export", systemImage: "square.and.arrow.up") {
                    WishlistExportActions(state: exportState)
                }
                .disabled(!exportState.canExport)
                .appHelp("Choose a file format for exporting the complete wish list.")
            }
        }
        .focusedSceneValue(\.wishListCommands, exportState)
        .padding(12)
        .task {
            do {
                try await load()
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
        .onDisappear { work?.cancel() }
        .onChange(of: search) {
            selection.formIntersection(visibleBooks.map(\.asin))
        }
        .sheet(isPresented: $showingCatalog) {
            AudibleCatalogSearchView(client: client, existing: Set(books.map(\.asin))) { added in
                update(added, removing: false)
            }
        }
        .confirmationDialog("Remove selected titles from your wish list?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { update(selection, removing: true) }
                .appHelp("Remove the selected titles from this account’s Audible wish list.")
        }
    }

    private var visibleBooks: [AudibleBook] {
        guard !search.isEmpty else { return books }
        return books.filter {
            $0.title.localizedStandardContains(search)
                || $0.asin.localizedStandardContains(search)
                || $0.authors.contains { $0.localizedStandardContains(search) }
                || ($0.series?.localizedStandardContains(search) ?? false)
        }
    }

    private var isBusy: Bool { loading || work != nil }

    private var exportState: WishlistExportState {
        WishlistExportState(canExport: !books.isEmpty && !isBusy, export: export, find: { filterFocused = true })
    }

    private func load() async throws {
        loading = true
        issue = nil
        defer { loading = false }
        let loaded = try await client.wishlist()
        try Task.checkCancellation()
        books = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        selection.formIntersection(visibleBooks.map(\.asin))
        hasLoaded = true
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        issue = nil
        work = Task {
            defer { work = nil }
            do {
                try await action()
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private func update(_ asins: Set<String>, removing: Bool) {
        guard !asins.isEmpty else { return }
        run {
            let failed = try await (removing
                ? client.removeFromWishlist(asins.sorted())
                : client.addToWishlist(asins.sorted()))
            var problems: [String] = []
            if !failed.isEmpty {
                let action = removing ? "remove" : "add"
                let titles = failed.count == 1 ? "the selected title" : "\(failed.count) selected titles"
                problems.append("Couldn’t \(action) \(titles).")
                problems += Set(failed.values.map(\.localizedDescription)).sorted()
            }
            do {
                try await load()
            } catch {
                try Task.checkCancellation()
                problems.append("Couldn’t refresh the Wish List. \(error.localizedDescription)")
            }
            issue = problems.isEmpty ? nil : problems.joined(separator: " ")
        }
    }

    private func export(as format: LibraryExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "wishlist.\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let items = books
        run { try await format.write(items, to: destination, wishlist: true) }
    }
}

extension FocusedValues {
    @Entry fileprivate var wishListCommands: WishlistExportState?
}

struct WishlistExportCommands: View {
    @FocusedValue(\.wishListCommands) private var state

    var body: some View {
        if let state {
            Button("Find in Wish List", action: state.find)
                .keyboardShortcut("f")
                .appHelp("Move keyboard focus to the Wish List filter.")
            Menu("Export Wish List") {
                WishlistExportActions(state: state, inMenuBar: true)
            }
            .disabled(!state.canExport)
            .appHelp("Choose a file format for exporting the complete wish list.")
        }
    }
}

private struct WishlistExportState {
    let canExport: Bool
    let export: (LibraryExportFormat) -> Void
    let find: () -> Void
}

private struct WishlistExportActions: View {
    let state: WishlistExportState
    var inMenuBar = false

    var body: some View {
        ForEach(LibraryExportFormat.allCases) { format in
            Button(format.rawValue.uppercased()) { state.export(format) }
                .keyboardShortcut(inMenuBar ? KeyboardShortcut(shortcut(for: format), modifiers: [.control, .shift]) : nil)
                .disabled(!state.canExport)
                .appHelp("Save the complete wish list as \(format.rawValue.uppercased()).")
        }
    }

    private func shortcut(for format: LibraryExportFormat) -> KeyEquivalent {
        switch format {
        case .json: "j"
        case .csv: "g"
        case .tsv: "t"
        }
    }
}

private struct AudibleCatalogSearchView: View {
    let client: AudibleClient
    let existing: Set<String>
    let add: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var books: [AudibleBook] = []
    @State private var selection: Set<String> = []
    @State private var issue: String?
    @State private var hasSearched = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Title or ASIN", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                    .appHelp("Enter a book title or its Audible identifier to search the catalogue.")
                Button("Search", systemImage: "magnifyingglass", action: search)
                    .keyboardShortcut("f", modifiers: [.control, .shift])
                    .disabled(!canSearch)
                    .appHelp("Find matching Audible titles that you haven’t already added to the wish list.")
            }
            AudibleCatalogTable(books: books, selection: $selection)
                .overlay {
                    if work != nil {
                        ProgressView("Searching Audible")
                            .appHelp("Audible is searching its catalogue.")
                    } else if books.isEmpty && hasSearched && issue == nil {
                        ContentUnavailableView(
                            "No New Titles Found", systemImage: "magnifyingglass",
                            description: Text("Try a different title or ASIN.")
                        )
                    }
                }
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appHelp("Close the catalogue search without adding titles.")
                Button("Add to Wish List") {
                    add(selection)
                    dismiss()
                }
                .keyboardShortcut("a", modifiers: [.control, .shift])
                .disabled(selection.isEmpty || work != nil)
                .appHelp("Add the selected search results to this account’s wish list.")
            }
        }
        .padding(16)
        .frame(minWidth: 512, idealWidth: 600, minHeight: 320, idealHeight: 400)
        .onDisappear { work?.cancel() }
    }

    private var canSearch: Bool {
        work == nil && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func search() {
        guard canSearch else { return }
        issue = nil
        books = []
        selection = []
        let requested = query
        work = Task {
            defer { work = nil }
            do {
                let found = try await client.searchCatalog(requested)
                try Task.checkCancellation()
                books = found.filter { !existing.contains($0.asin) }
                hasSearched = true
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}

private struct AudibleCatalogTable: View {
    let books: [AudibleBook]
    @Binding var selection: Set<String>

    var body: some View {
        Table(books, selection: $selection) {
            TableColumn("Title") { book in
                Text(book.title).appHelp(book.title)
            }
            .width(min: 140, ideal: 148)
            TableColumn("Author") { book in
                let authors = book.authors.formatted(.list(type: .and))
                Text(authors).appHelp(authors)
            }
            .width(min: 84, ideal: 92)
            TableColumn("Series") { book in
                Text(book.series ?? "").appHelp(book.series ?? "")
            }
            .width(min: 60, ideal: 64)
            TableColumn("ASIN") { book in
                Text(book.asin).appHelp("Audible identifies this edition as \(book.asin).")
            }
            .width(min: 78, ideal: 82)
        }
    }
}
