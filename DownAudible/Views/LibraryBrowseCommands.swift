import SwiftUI

struct LibraryBrowseActions {
    let field: Binding<LibrarySortField>
    let direction: Binding<LibrarySortDirection>
    let filters: Binding<LibraryFilters>
    let editFilter: (LibraryFilters.Field) -> Void
}

extension FocusedValues {
    @Entry var libraryBrowseActions: LibraryBrowseActions?
}

struct LibraryBrowseCommands: View {
    @FocusedValue(\.libraryBrowseActions) private var actions

    var body: some View {
        if let actions {
            Divider()
            Menu("Sort Library") { LibrarySortItems(actions: actions) }
            Menu("Filter Library") { LibraryFilterItems(actions: actions) }
        }
    }
}

struct LibrarySortItems: View {
    let actions: LibraryBrowseActions

    var body: some View {
        Picker("Sort by", selection: actions.field) {
            ForEach(LibrarySortField.allCases) { field in
                Text(field.displayName).tag(field)
            }
        }
        .pickerStyle(.inline)

        Divider()

        let field = actions.field.wrappedValue
        Picker("Order", selection: actions.direction) {
            ForEach(LibrarySortDirection.allCases) { direction in
                Text(field.orderName(direction)).tag(direction)
            }
        }
        .pickerStyle(.inline)
    }
}

struct LibraryFilterItems: View {
    let actions: LibraryBrowseActions

    var body: some View {
        ForEach(LibraryFilters.Field.allCases) { field in
            Button {
                actions.editFilter(field)
            } label: {
                if let text = actions.filters.wrappedValue[field] {
                    Label("\(field.displayName)…", systemImage: "checkmark")
                        .accessibilityValue(text)
                } else {
                    Text("\(field.displayName)…")
                }
            }
        }

        Menu("Download Status") {
            Picker("Download Status", selection: actions.filters.status) {
                Text("Any Status").tag(nil as LibraryDownloadStatus?)
                ForEach(LibraryDownloadStatus.allCases) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
            .pickerStyle(.inline)
        }

        Divider()

        Button("Clear Filters") { actions.filters.wrappedValue = LibraryFilters() }
            .disabled(actions.filters.wrappedValue.isEmpty)
    }
}

struct LibraryTextFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text: String
    let field: LibraryFilters.Field
    let apply: (String) -> Void
    private let hasFilter: Bool

    init(field: LibraryFilters.Field, value: String?, apply: @escaping (String) -> Void) {
        self.field = field
        self.apply = apply
        hasFilter = value != nil
        _text = State(initialValue: value ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filter by \(field.displayName)")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            TextField(field.displayName, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)

            HStack {
                if hasFilter {
                    Button("Remove Filter") { finish(with: "") }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Filter") { finish(with: text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private var canApply: Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return field == .releaseYear ? (Int(value).map { (1...9999).contains($0) } ?? false) : !value.isEmpty
    }

    private func finish(with value: String) {
        apply(value)
        dismiss()
    }
}
