import SwiftUI

enum LibraryOrganizationSheet: Identifiable {
    case save(UUID), manage(UUID), tags(UUID, [AudibleBook])

    var id: String {
        switch self {
        case .save: "save"
        case .manage: "manage"
        case .tags: "tags"
        }
    }
}

struct LibrarySaveViewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    let saved: [SavedLibraryView]
    let save: (String) -> Void

    private var title: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var alreadySaved: Bool { saved.contains { LibraryOrganization.sameName($0.name, title) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Current View").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Keep this search, filters and sort for this account.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("View name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            if alreadySaved {
                Text("This name updates the saved view.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(alreadySaved ? "Update View" : "Save View") {
                    save(title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }
}

struct LibraryManageViewsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var name = ""
    @State private var confirmingRemoval = false
    let model: WorkspaceModel
    let account: UUID

    private var saved: [SavedLibraryView] { model.libraryOrganization.savedViews(for: account) }
    private var title: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canRename: Bool {
        selection != nil && !title.isEmpty && !saved.contains {
            $0.id != selection && LibraryOrganization.sameName($0.name, title)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Saved Views").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            List(saved, selection: $selection) { view in
                Text(view.name)
            }
            .accessibilityLabel("Saved Views")
            .frame(minHeight: 120)
            TextField("View name", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(selection == nil)
            HStack {
                Button("Rename") {
                    if let selection { model.libraryOrganization.rename(selection, to: title, for: account) }
                }
                .disabled(!canRename)
                Button("Remove…", role: .destructive) { confirmingRemoval = true }
                    .disabled(selection == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: selection) { _, id in name = saved.first { $0.id == id }?.name ?? "" }
        .confirmationDialog("Remove this saved view?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                if let selection { model.libraryOrganization.remove(selection, for: account) }
                selection = nil
            }
        }
    }
}

struct LibraryTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var tagsFocused: Bool
    @State private var text = ""
    @State private var adding = true
    let model: WorkspaceModel
    let account: UUID
    let books: [AudibleBook]

    private var tags: [String] { LibraryOrganization.uniqueTags(text.components(separatedBy: ",")) }
    private var existing: [String] {
        LibraryOrganization.uniqueTags(books.flatMap { model.libraryOrganization.tags(for: $0.asin, account: account) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tags").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(books.count == 1 ? (books.first?.title ?? "") : "\(books.count.formatted()) selected audiobooks")
            if !existing.isEmpty {
                LabeledContent("Current tags", value: existing.formatted(.list(type: .and)))
            }
            Picker("Action", selection: $adding) {
                Text("Add Tags").tag(true)
                Text("Remove Tags").tag(false)
            }
            TextField("Tags separated by commas", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($tagsFocused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(adding ? "Add Tags" : "Remove Tags") {
                    model.libraryOrganization.changeTags(tags, for: books.map(\.asin), account: account, adding: adding)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tags.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { tagsFocused = true }
    }
}
