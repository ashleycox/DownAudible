import SwiftUI

struct AccountPreferencesView: View {
    @Bindable var model: WorkspaceModel
    @State private var selectedAccount: SavedAudibleAccount.ID?
    @State private var sheet: Sheet?
    @State private var showingRemove = false
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
                        TableColumn("Account", value: \.name)
                        TableColumn("Marketplace") { account in Text(account.marketplace.displayName) }
                        TableColumn("Status") { account in
                            if model.activeAccount?.id == account.id {
                                Text(model.signedIn ? "Active" : "Signed out")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 80, ideal: 92, max: 100)
                    }
                    .frame(minHeight: 160)
                }

                HStack(spacing: 8) {
                    Button("Add Account…") { sheet = .add }
                    Button("Import from Audible CLI…") { sheet = .importCLI }
                    if model.accountBusy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Updating Audible accounts")
                    }
                }
                .disabled(!model.canSwitchAccounts)
            }

            if let account {
                Section("Selected account") {
                    if model.activeAccount?.id == account.id && !model.signedIn {
                        Button("Sign In…") { sheet = .reconnect }
                            .disabled(!model.canSwitchAccounts)
                    } else {
                        Button("Switch to This Account") { switchAccount(to: account) }
                            .disabled(!model.canSwitchAccounts || model.activeAccount?.id == account.id)
                    }

                    Button("Rename…") { sheet = .rename(account) }
                        .disabled(!model.canSwitchAccounts)
                    Button("Remove Account…", role: .destructive) { showingRemove = true }
                        .disabled(!model.canRemoveAccounts)
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
        .alert("Remove Account?", isPresented: $showingRemove, presenting: account) { account in
            Button("Cancel", role: .cancel) {}
            Button("Remove Account", role: .destructive) { removeAccount(account) }
        } message: { account in
            Text("This removes \(account.name) from DownAudible and clears its saved sign-in.")
        }
    }

    private var account: SavedAudibleAccount? {
        model.accounts.first { $0.id == selectedAccount }
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.renameAccount(account, to: trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == account.name)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
