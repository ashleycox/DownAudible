import AppKit
import SwiftUI

struct AudibleWishlistView: View {
    let client: AudibleClient

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
                Button("Refresh", systemImage: "arrow.clockwise") {
                    run { try await load() }
                }
                .disabled(isBusy)
                if isBusy && hasLoaded {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working on the wish list")
                }
            }
            AudibleCatalogTable(books: visibleBooks, selection: $selection)
                .overlay {
                    if loading && !hasLoaded {
                        ProgressView("Loading Wish List")
                    } else if hasLoaded && visibleBooks.isEmpty && issue == nil {
                        if search.isEmpty {
                            ContentUnavailableView("Your Wish List Is Empty", systemImage: "bookmark")
                        } else {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
            if let issue {
                Text(issue)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Add Titles…", systemImage: "plus") { showingCatalog = true }
                    .disabled(isBusy)
                Button("Remove", systemImage: "minus") { confirmingRemoval = true }
                    .disabled(selection.isEmpty || isBusy)
                Spacer()
                Menu("Export", systemImage: "square.and.arrow.up") {
                    ForEach(LibraryExportFormat.allCases) { format in
                        Button(format.rawValue.uppercased()) { export(as: format) }
                    }
                }
                .disabled(books.isEmpty || isBusy)
            }
        }
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
            try await load()
            if !failed.isEmpty {
                let ids = failed.formatted(.list(type: .and))
                issue = removing ? "Couldn’t remove \(ids)." : "Couldn’t add \(ids)."
            }
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
                Button("Search", systemImage: "magnifyingglass", action: search)
                    .disabled(!canSearch)
            }
            AudibleCatalogTable(books: books, selection: $selection)
                .overlay {
                    if work != nil {
                        ProgressView("Searching Audible")
                    } else if books.isEmpty && hasSearched && issue == nil {
                        ContentUnavailableView(
                            "No New Titles Found", systemImage: "magnifyingglass",
                            description: Text("Try a different title or ASIN.")
                        )
                    }
                }
            if let issue {
                Text(issue)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Wish List") {
                    add(selection)
                    dismiss()
                }
                .disabled(selection.isEmpty || work != nil)
            }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 360)
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
            TableColumn("Title", value: \.title)
                .width(min: 170, ideal: 255)
            TableColumn("Author") { Text($0.authors.formatted(.list(type: .and))) }
                .width(min: 100, ideal: 160)
            TableColumn("Series") { Text($0.series ?? "") }
                .width(min: 65, ideal: 100)
            TableColumn("ASIN", value: \.asin)
                .width(min: 78, ideal: 90)
        }
    }
}
