import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GoodreadsExportView: View {
    let export: GoodreadsExport
    @Environment(\.dismiss) private var dismiss
    @State private var issue: String?
    @State private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export to Goodreads").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Review the titles, then save a CSV to import in Goodreads.")
                .foregroundStyle(.secondary)
            Table(export.entries) {
                TableColumn("Title") { Text($0.book.title) }.width(min: 140, ideal: 200)
                TableColumn("Edition") { Text($0.identifier?.displayName ?? "—") }.width(min: 150, ideal: 170)
                TableColumn("Listening", value: \.listening.rawValue).width(min: 94, ideal: 110)
                TableColumn("Status", value: \.status).width(min: 100, ideal: 115)
            }
            .accessibilityLabel("Titles to export to Goodreads")
            if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            HStack {
                Text("\(export.readyCount.formatted()) ready · \((export.entries.count - export.readyCount).formatted()) skipped")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export CSV…", action: write)
                    .keyboardShortcut(.defaultAction)
                    .disabled(export.readyCount == 0 || writing)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 390)
    }

    private func write() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Goodreads Library.csv"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let path = panel.url else { return }
        issue = nil
        writing = true
        Task {
            defer { writing = false }
            do {
                try await export.write(to: path)
                dismiss()
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}
