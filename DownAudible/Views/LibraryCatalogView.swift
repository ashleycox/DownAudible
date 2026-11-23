import SwiftUI

struct LibraryCatalogStatusView: View {
    let catalog: LibraryCatalog?
    let failure: String?
    let retry: AudibleRetryDelay?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let catalog {
                Text("Last refreshed \(catalog.refreshed.formatted(date: .abbreviated, time: .shortened))")
            }
            if let failure = failure ?? retry?.reason {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let retry {
                Text("Try again after \(retry.until.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct LibraryChangesView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: LibraryCatalog?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library Changes").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let snapshot {
                Text("Last refreshed \(snapshot.refreshed.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let changes = snapshot?.changes, !changes.isEmpty {
                List {
                    section("Added", books: changes.added)
                    section("Removed", books: changes.removed)
                    section("Updated", books: changes.updated)
                }
            } else {
                ContentUnavailableView(
                    snapshot?.changes == nil ? "No Earlier Refresh to Compare" : "No Library Changes",
                    systemImage: "books.vertical"
                )
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 360)
    }

    @ViewBuilder
    private func section(_ name: String, books: [AudibleBook]) -> some View {
        if !books.isEmpty {
            Section("\(name) (\(books.count.formatted()))") {
                ForEach(books) { book in Text(book.title) }
            }
        }
    }
}

struct AllAccountsLibraryView: View {
    private struct Row: Identifiable {
        struct ID: Hashable { let account: UUID; let asin: String }
        let account: SavedAudibleAccount
        let book: AudibleBook

        var id: ID { ID(account: account.id, asin: book.asin) }
        var author: String { book.authors.formatted(.list(type: .and)) }
        var profile: String { "\(account.name) · \(account.marketplace.displayName)" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Row.ID?
    let model: WorkspaceModel

    private var rows: [Row] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.signedInCatalogAccounts.flatMap { account in
            (model.catalogSnapshots[account.id]?.books ?? []).map { Row(account: account, book: $0) }
        }
        .filter { row in
            search.isEmpty || [row.book.title, row.author, row.book.asin, row.profile].contains {
                $0.localizedStandardContains(search)
            }
        }
        .sorted { left, right in
            let order = left.book.title.localizedStandardCompare(right.book.title)
            if order == .orderedSame { return left.profile.localizedStandardCompare(right.profile) == .orderedAscending }
            return order == .orderedAscending
        }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 12) {
            Text("All Accounts").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            TextField("Search all accounts", text: $query).textFieldStyle(.roundedBorder)
            Table(rows, selection: $selection) {
                TableColumn("Title") { Text($0.book.title) }
                TableColumn("Author", value: \.author)
                TableColumn("Account and Marketplace", value: \.profile)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Matching Audiobooks", systemImage: "books.vertical")
                }
            }
            HStack {
                Button("Refresh All Accounts") { Task { await model.refreshAllAccounts() } }
                    .disabled(!model.canSwitchAccounts)
                if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing accounts") }
                Spacer()
                Button("Open Account") {
                    guard let row = rows.first(where: { $0.id == selection }) else { return }
                    dismiss()
                    Task {
                        await model.switchAccount(to: row.account)
                        if model.activeAccountID == row.account.id,
                           let book = model.books.first(where: { $0.asin == row.book.asin }) {
                            model.selectedBooks = [book.id]
                        }
                    }
                }
                .disabled(selection == nil || !model.canSwitchAccounts)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 740, height: 440)
        .onChange(of: Set(rows.map(\.id))) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }
}
