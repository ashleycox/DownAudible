import AppKit
import SwiftUI

struct AudibleCLIImportView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel

    @State private var source = Source.profile
    @State private var config = AudibleClient.defaultCLIConfig
    @State private var profiles: [AudibleCLIProfile] = []
    @State private var selectedProfileName: String?
    @State private var authFile: URL?
    @State private var inspectedAuthFile: URL?
    @State private var authFileRequiresPassword = false
    @State private var name = ""
    @State private var password = ""
    @State private var marketplace: AudibleMarketplace?
    @State private var isReading = false
    @State private var isImporting = false
    @State private var problem: String?

    private enum Source: String, Identifiable, CaseIterable {
        case profile = "CLI profile"
        case authFile = "Auth file"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Audible CLI")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Picker("Import source", selection: $source) {
                ForEach(Source.allCases) { source in Text(source.rawValue).tag(source) }
            }
            .pickerStyle(.segmented)
            .disabled(isImporting)
            .onChange(of: source) { resetFields() }

            Group {
                if source == .profile {
                    profileFields
                } else {
                    authFileFields
                }

                if importFile != nil {
                    LabeledContent("Account name") {
                        TextField("Account name", text: $name)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    if requiresPassword {
                        LabeledContent("Auth file password") {
                            SecureField("Auth file password", text: $password)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    Picker("Marketplace", selection: $marketplace) {
                        Text(selectedProfile?.marketplace?.displayName ?? "Read from Auth File")
                            .tag(nil as AudibleMarketplace?)
                        ForEach(AudibleMarketplace.allCases) { market in
                            Text(market.displayName).tag(Optional(market))
                        }
                    }
                }
            }
            .disabled(isImporting)

            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("DownAudible saves imported accounts in Keychain.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isReading || isImporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(isImporting ? "Importing account" : "Reading Audible CLI files")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button("Import", action: importAccount)
                    .keyboardShortcut(.defaultAction)
                    .disabled(importFile == nil || isReading || isImporting || !model.canSwitchAccounts
                        || (requiresPassword && password.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isImporting)
    }

    private var profileFields: some View {
        Group {
            filePicker("Configuration", url: config) { config = $0 }
            if !profiles.isEmpty {
                Picker("Profile", selection: $selectedProfileName) {
                    ForEach(profiles) { profile in
                        Text(profile.isDefault ? "\(profile.name) (Default)" : profile.name)
                            .tag(Optional(profile.name))
                    }
                }
                .onChange(of: selectedProfileName) {
                    name = selectedProfile?.name ?? ""
                    password = ""
                    marketplace = nil
                    problem = nil
                }
            }
        }
        .task(id: config) { await readProfiles() }
    }

    private var authFileFields: some View {
        filePicker("Auth file", url: authFile) { authFile = $0 }
            .task(id: authFile) { await readAuthFile() }
    }

    private func filePicker(_ title: String, url: URL?, select: @escaping (URL) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(url?.lastPathComponent ?? "Choose a file")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url?.path(percentEncoded: false) ?? "")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.prompt = "Choose"
                    if let url, FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                        panel.directoryURL = url.deletingLastPathComponent()
                    }
                    guard panel.runModal() == .OK, let selected = panel.url else { return }
                    select(selected)
                }
                .keyboardShortcut("o", modifiers: [.control, .shift])
                .accessibilityLabel("Choose \(title.lowercased()) file")
            }
        }
    }

    private var selectedProfile: AudibleCLIProfile? {
        profiles.first { $0.name == selectedProfileName }
    }

    private var importFile: URL? {
        source == .profile ? selectedProfile?.authFile : inspectedAuthFile
    }

    private var requiresPassword: Bool {
        source == .profile ? selectedProfile?.requiresPassword == true : authFileRequiresPassword
    }

    private func resetFields() {
        name = ""
        password = ""
        marketplace = nil
        problem = nil
    }

    private func readProfiles() async {
        let requested = config
        profiles = []
        selectedProfileName = nil
        isReading = false
        guard FileManager.default.fileExists(atPath: requested.path) else {
            problem = "Choose your Audible CLI config.toml."
            return
        }
        isReading = true
        defer { if config == requested && source == .profile { isReading = false } }
        do {
            let result = try await model.cliProfiles(config: requested)
            try Task.checkCancellation()
            guard config == requested && source == .profile else { return }
            profiles = result
            let first = result.first(where: \.isDefault) ?? result.first
            selectedProfileName = first?.name
            name = first?.name ?? ""
        } catch is CancellationError {
            return
        } catch {
            guard config == requested && source == .profile else { return }
            problem = error.localizedDescription
        }
    }

    private func readAuthFile() async {
        inspectedAuthFile = nil
        authFileRequiresPassword = false
        isReading = false
        guard let requested = authFile else { return }
        isReading = true
        defer { if authFile == requested && source == .authFile { isReading = false } }
        do {
            let protected = try await model.inspectAuthFile(requested)
            try Task.checkCancellation()
            guard authFile == requested && source == .authFile else { return }
            authFileRequiresPassword = protected
            inspectedAuthFile = requested
            name = requested.deletingPathExtension().lastPathComponent
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            guard authFile == requested && source == .authFile else { return }
            problem = error.localizedDescription
        }
    }

    private func importAccount() {
        guard let file = importFile else { return }
        let region = marketplace ?? (source == .profile ? selectedProfile?.marketplace : nil)
        let secret = requiresPassword ? password : nil
        let accountName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isImporting = true
        problem = nil
        Task {
            defer { isImporting = false }
            do {
                try await model.importAccount(from: file, name: accountName, password: secret, marketplace: region)
                password = ""
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
