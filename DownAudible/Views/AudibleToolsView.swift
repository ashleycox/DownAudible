import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AudibleToolsView: View {
    let client: AudibleClient
    let accountName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            TabView {
                Tab("Wish List", systemImage: "bookmark") {
                    AudibleWishlistView(client: client)
                }
                Tab("Account", systemImage: "person.crop.circle") {
                    AudibleAccountToolsView(client: client)
                }
            }
            HStack {
                Label(accountName, systemImage: "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(accountName)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 576, idealWidth: 720, minHeight: 400, idealHeight: 500)
    }
}

private struct AudibleAccountToolsView: View {
    let client: AudibleClient

    @State private var bytes: String?
    @State private var isCopied = false
    @State private var work: Task<Void, Never>?
    @State private var issue: String?
    @State private var showingExport = false
    @State private var didExport = false

    var body: some View {
        Form {
            Section("Activation Bytes") {
                LabeledContent("Activation bytes") {
                    if let bytes {
                        Text(bytes)
                            .monospaced()
                            .textSelection(.enabled)
                    } else {
                        Text("Hidden")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if bytes == nil {
                        Button("Show", systemImage: "eye") { load() }
                            .keyboardShortcut("h", modifiers: [.control, .shift])
                    } else {
                        Button("Hide", systemImage: "eye.slash") {
                            bytes = nil
                            isCopied = false
                        }
                        .keyboardShortcut("h", modifiers: [.control, .shift])
                        Button("Copy", systemImage: "doc.on.doc", action: copyBytes)
                            .keyboardShortcut("c", modifiers: [.control, .shift])
                    }
                    Button("Reload from Audible", systemImage: "arrow.clockwise") { load(refresh: true) }
                        .keyboardShortcut("l", modifiers: [.control, .shift])
                    if work != nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Getting activation bytes")
                    }
                }
                .disabled(work != nil)
                if isCopied {
                    Label("Copied", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Account File") {
                Button("Export Encrypted Account File…", systemImage: "lock.doc") {
                    showingExport = true
                    didExport = false
                }
                .keyboardShortcut("e", modifiers: [.control, .shift])
                if didExport {
                    Label("Account file saved.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Save a password-protected file for use with Audible CLI or another copy of DownAudible.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingExport) {
            AudibleAuthExportView(client: client) { didExport = true }
        }
        .onDisappear {
            work?.cancel()
            bytes = nil
            isCopied = false
        }
    }

    private func load(refresh: Bool = false) {
        guard work == nil else { return }
        issue = nil
        isCopied = false
        work = Task {
            defer { work = nil }
            do {
                let value = try await client.activationBytes(refresh: refresh)
                try Task.checkCancellation()
                bytes = value
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private func copyBytes() {
        guard let bytes else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        isCopied = clipboard.setString(bytes, forType: .string)
    }
}

private struct AudibleAuthExportView: View {
    let client: AudibleClient
    let didSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var work: Task<Void, Never>?
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Form {
                Section("Export Encrypted Account File") {
                    SecureField("Password", text: $password)
                    SecureField("Confirm password", text: $confirmation)
                    if !confirmation.isEmpty && password != confirmation {
                        Text("The passwords don’t match.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Keep this file and its password private. Together, they can give access to your Audible account.")
                        .foregroundStyle(.secondary)
                    if let issue {
                        Text(issue)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(work != nil)
            HStack {
                if work != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Encrypting account file")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Encrypted File…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || password != confirmation || work != nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 460)
        .onDisappear {
            work?.cancel()
            password = ""
            confirmation = ""
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "audible-auth.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let suppliedPassword = password
        password = ""
        confirmation = ""
        issue = nil
        work = Task {
            defer { work = nil }
            do {
                try await client.exportEncryptedAuthFile(to: destination, password: suppliedPassword)
                try Task.checkCancellation()
                didSave()
                dismiss()
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}
