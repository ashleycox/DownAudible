import Accessibility
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
    @State private var highlighted: String?
    let field: LibraryFilters.Field
    let suggestions: LibraryFilterSuggestions?
    let apply: (String) -> Void
    private let hasFilter: Bool

    init(field: LibraryFilters.Field, value: String?, suggestions: LibraryFilterSuggestions?, apply: @escaping (String) -> Void) {
        self.field = field
        self.suggestions = suggestions
        self.apply = apply
        hasFilter = value != nil
        _text = State(initialValue: value ?? "")
    }

    var body: some View {
        let matches = suggestions?.matching(text) ?? []
        VStack(alignment: .leading, spacing: 16) {
            Text("Filter by \(field.displayName)")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            TextField(field.displayName, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard press.modifiers.isDisjoint(with: [.shift, .control, .option, .command]) else { return .ignored }
                    return moveSuggestion(matches, down: press.key == .downArrow)
                }
                .onKeyPress(.return) {
                    guard highlighted != nil else { return .ignored }
                    applyFilter()
                    return .handled
                }
                .onSubmit(applyFilter)
                .accessibilityHint(suggestions == nil ? "" : "Use the Up and Down Arrow keys to choose a suggestion.")

            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggestions")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(matches, id: \.self) { suggestion in
                        suggestionButton(suggestion)
                    }
                }
            }

            HStack {
                if hasFilter {
                    Button("Remove Filter") { finish(with: "") }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Filter", action: applyFilter)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply(highlighted ?? text))
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { focused = true }
        .onChange(of: text) { highlighted = nil }
    }

    private func suggestionButton(_ suggestion: String) -> some View {
        let selected = highlighted == suggestion
        return Button { finish(with: suggestion) } label: {
            Text(suggestion)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                .background {
                    if selected { RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .selectedContentBackgroundColor)) }
                }
        }
        .buttonStyle(.plain)
        .help(suggestion)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveSuggestion(_ matches: [String], down: Bool) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        let index: Int
        if let highlighted, let current = matches.firstIndex(of: highlighted) {
            index = min(max(current + (down ? 1 : -1), 0), matches.count - 1)
        } else {
            index = down ? 0 : matches.count - 1
        }
        let selection = matches[index]
        if highlighted != selection {
            highlighted = selection
            AccessibilityNotification.Announcement(selection).post()
        }
        return .handled
    }

    private func canApply(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return field == .releaseYear ? (Int(value).map { (1...9999).contains($0) } ?? false) : !value.isEmpty
    }

    private func applyFilter() {
        let value = highlighted.flatMap { suggestions?.matching(text).contains($0) == true ? $0 : nil } ?? text
        if canApply(value) { finish(with: value) }
    }

    private func finish(with value: String) {
        apply(value)
        dismiss()
    }
}
