import Accessibility
import AppKit
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
            Menu(LibraryBrowseMenu.sort.rawValue) { LibrarySortItems(actions: actions) }
                .appHelp("Choose the field and direction used to order the library.")
            Menu(LibraryBrowseMenu.filter.rawValue) { LibraryFilterItems(actions: actions) }
                .appHelp("Choose what to show in the library without changing its contents.")
            Button("Open Sort Menu", action: LibraryBrowseMenu.sort.open)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .appHelp("Open the menu for choosing a library sort field and direction.")
            Button("Open Filter Menu", action: LibraryBrowseMenu.filter.open)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .appHelp("Open the menu for setting or clearing library filters.")
        }
    }
}

enum LibraryBrowseMenu: String {
    case sort = "Sort Library"
    case filter = "Filter Library"

    @MainActor func open() {
        // Wait for the View menu to finish tracking before presenting its submenu.
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil,
                  let view = window.contentView,
                  let menu = NSApp.mainMenu?.items.lazy.compactMap({
                      $0.submenu?.item(withTitle: rawValue)?.submenu
                  }).first else { return }
            let top = view.isFlipped ? view.bounds.minY + 16 : view.bounds.maxY - 16
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX + 16, y: top), in: view)
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
        .appHelp("Choose which book detail determines the order.")

        Divider()

        let field = actions.field.wrappedValue
        Picker("Order", selection: actions.direction) {
            ForEach(LibrarySortDirection.allCases) { direction in
                Text(field.orderName(direction)).tag(direction)
            }
        }
        .pickerStyle(.inline)
        .appHelp("Choose the direction of the current sort.")

        Divider()

        Button("Reverse Sort Order") {
            actions.direction.wrappedValue = actions.direction.wrappedValue == .ascending ? .descending : .ascending
        }
        .keyboardShortcut("s", modifiers: [.command, .option, .shift])
        .appHelp("Change the current sort to the opposite direction.")
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
            .appHelp("Enter a filter value for this book detail.")
        }

        Menu("Download Status") {
            Picker("Download Status", selection: actions.filters.status) {
                Text("Any Status").tag(nil as LibraryDownloadStatus?)
                ForEach(LibraryDownloadStatus.allCases) { status in
                    Text(status.displayName).tag(Optional(status))
                }
            }
            .pickerStyle(.inline)
            .appHelp("Show books with a particular download status.")
        }
        .appHelp("Show books with a particular download status.")

        Divider()

        Button("Clear Filters") { actions.filters.wrappedValue = LibraryFilters() }
            .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            .disabled(actions.filters.wrappedValue.isEmpty)
            .appHelp("Remove all filters from the library table.")
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
                .appHelp("Enter part of a matching book detail or choose a suggestion.")

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
                        .appHelp("Remove this filter and keep the other active filters.")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appHelp("Close the sheet without changing this filter.")
                Button("Apply Filter", action: applyFilter)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply(highlighted ?? text))
                    .appHelp("Filter the library using the entered value or highlighted suggestion.")
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
        .appHelp(suggestion)
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
