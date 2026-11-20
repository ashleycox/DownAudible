import SwiftUI

struct AccountPreferencesView: View {
    @Bindable var model: WorkspaceModel
    @State private var selectedAccount: SavedAudibleAccount.ID?
    @State private var sheet: Sheet?
    @State private var showingRemove = false
    @State private var accountToRemove: SavedAudibleAccount?
    @State private var issue: WorkspaceModel.Notice?

    private enum Sheet: Identifiable {
        case add
        case reconnect
        case importCLI
        case rename(SavedAudibleAccount)

        var id: String {
            switch self {
            case .add: "add"
            case .reconnect: "reconnect"
            case .importCLI: "import"
            case .rename(let account): account.id.uuidString
            }
        }
    }

    var body: some View {
        Form {
            Section("Audible Accounts") {
                if model.accounts.isEmpty {
                    Text("Add an account or import one from Audible CLI.")
                        .foregroundStyle(.secondary)
                } else {
                    Table(model.accounts, selection: $selectedAccount) {
                        TableColumn("Account") { account in
                            Text(account.name).appHelp(account.name)
                        }
                        TableColumn("Marketplace") { account in
                            Text(account.marketplace.displayName)
                                .appHelp("This account uses the Audible marketplace in \(account.marketplace.displayName).")
                        }
                        TableColumn("Status") { account in
                            if model.activeAccount?.id == account.id {
                                Label(model.signedIn ? "Active" : "Signed out",
                                      systemImage: model.signedIn ? "checkmark.circle" : "person.crop.circle.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                                    .appHelp(model.signedIn
                                        ? "The Library is showing books from this account."
                                        : "Sign in to this account to refresh the library or download its books.")
                            }
                        }
                        .width(min: 96, ideal: 112, max: 132)
                    }
                    .frame(minHeight: 160)
                    .appHelp("Select an account to see sign-in and account management actions.")
                    .contextMenu(forSelectionType: SavedAudibleAccount.ID.self) { ids in
                        if let selected = model.accounts.first(where: { ids.contains($0.id) }) {
                            accountActions(selected)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Add Account…", systemImage: "person.badge.plus") { sheet = .add }
                        .keyboardShortcut("a", modifiers: [.control, .shift])
                        .appHelp("Connect another Audible account through your browser.")
                    Button("Import from Audible CLI…", systemImage: "square.and.arrow.down") { sheet = .importCLI }
                        .keyboardShortcut("i", modifiers: [.control, .shift])
                        .appHelp("Connect an account using an Audible CLI profile or auth file.")
                    if model.accountBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Updating Audible accounts")
                            .appHelp("DownAudible is updating the Audible account.")
                    }
                }
                .disabled(!model.canSwitchAccounts)
            }

            if let account {
                Section("Selected account") {
                    accountActions(account)
                }
            }

            if let issue {
                Section {
                    Label(issue.message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(issue.title). \(issue.message)")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { selectedAccount = model.activeAccount?.id }
        .onChange(of: model.activeAccount?.id) { _, accountID in selectedAccount = accountID }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                AudibleSignInView(model: model, addingAccount: true)
            case .reconnect:
                AudibleSignInView(model: model)
            case .importCLI:
                AudibleCLIImportView(model: model)
            case .rename(let account):
                RenameAccountView(model: model, account: account)
            }
        }
        .alert("Remove Account?", isPresented: $showingRemove, presenting: accountToRemove) { account in
            Button("Cancel", role: .cancel) { accountToRemove = nil }
                .appHelp("Close this message and keep the account in DownAudible.")
            Button("Remove Account", role: .destructive) { removeAccount(account) }
                .appHelp("Remove this account, its saved sign-in and its file matches from DownAudible.")
        } message: { account in
            Text("This removes \(account.name) from DownAudible and clears its saved sign-in.")
        }
    }

    private var account: SavedAudibleAccount? {
        model.accounts.first { $0.id == selectedAccount }
    }

    @ViewBuilder
    private func accountActions(_ account: SavedAudibleAccount) -> some View {
        if model.activeAccount?.id == account.id {
            if !model.signedIn {
                Button("Sign In…") { sheet = .reconnect }
                    .keyboardShortcut("s", modifiers: [.control, .shift])
                    .disabled(!model.canSwitchAccounts)
                    .appHelp("Open the browser sign-in steps for this account.")
            } else {
                Button("Sign Out", action: model.signOut)
                    .keyboardShortcut("q", modifiers: [.control, .shift])
                    .disabled(!model.canRemoveAccounts)
                    .appHelp("Clear this account’s saved sign-in. You can sign in to the same profile later.")
            }
        } else {
            Button("Switch to This Account") { switchAccount(to: account) }
                .keyboardShortcut("s", modifiers: [.control, .shift])
                .disabled(!model.canSwitchAccounts)
                .appHelp("Make this account active and load its library.")
        }
        Button("Rename…", systemImage: "pencil") { sheet = .rename(account) }
            .keyboardShortcut("n", modifiers: [.control, .shift])
            .disabled(!model.canSwitchAccounts)
            .appHelp("Change the name shown for this account in DownAudible.")
        Button("Remove Account…", role: .destructive) {
            accountToRemove = account
            showingRemove = true
        }
        .keyboardShortcut(.delete, modifiers: [.control, .shift])
        .disabled(!model.canRemoveAccounts)
        .appHelp("Review removal of this account and its saved sign-in from DownAudible.")
    }

    private func switchAccount(to account: SavedAudibleAccount) {
        issue = nil
        Task {
            await model.switchAccount(to: account)
            issue = model.notice
            model.notice = nil
        }
    }

    private func removeAccount(_ account: SavedAudibleAccount) {
        issue = nil
        accountToRemove = nil
        Task {
            await model.removeAccount(account)
            issue = model.notice
            model.notice = nil
        }
    }
}

private struct RenameAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    let account: SavedAudibleAccount
    @State private var name: String

    init(model: WorkspaceModel, account: SavedAudibleAccount) {
        self.model = model
        self.account = account
        _name = State(initialValue: account.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Account")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            TextField("Account name", text: $name)
                .textFieldStyle(.roundedBorder)
                .appHelp("Enter the name you want to see in the account switcher.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appHelp("Close this sheet and keep the current account name.")
                Button("Save") {
                    model.renameAccount(account, to: trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == account.name)
                .appHelp("Use this name for the account in DownAudible.")
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
