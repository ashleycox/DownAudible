import AppKit
import SwiftUI

struct TitleCheckRequest: Identifiable {
    let id = UUID()
    let book: AudibleBook
    let marketplace: AudibleMarketplace
    let client: AudibleClient
}

struct TitleInsightsView: View {
    let request: TitleCheckRequest
    var initialReport: AudibleTitleCheck? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var report: AudibleTitleCheck?
    @State private var issue: String?
    @State private var copied = false
    @State private var attempt = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check This Title").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(request.book.title).font(.headline)
            LabeledContent("ASIN", value: request.book.asin)
            LabeledContent("Marketplace", value: request.marketplace.displayName)
            if let report {
                List(report.offers) { offer in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(offer.specification).fontWeight(.medium)
                        Text([offer.status.label, offer.explanation].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityLabel("Audible audio offers")
            } else if let issue {
                ContentUnavailableView("Couldn’t Check Title", systemImage: "exclamationmark.circle", description: Text(issue))
            } else {
                ProgressView("Checking Audible…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let report {
                    Button("Copy Redacted Report") { copyReport(report) }
                    if copied { Text("Copied").foregroundStyle(.secondary) }
                }
                Spacer()
                if issue != nil { Button("Retry") { attempt = UUID() } }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 510, minHeight: 325)
        .task(id: attempt) {
            issue = nil
            if let initialReport { report = initialReport; return }
            do { report = try await request.client.checkTitle(request.book.asin) }
            catch is CancellationError {}
            catch { issue = error.localizedDescription }
        }
    }

    private func copyReport(_ report: AudibleTitleCheck) {
        let rows = report.offers.map { offer in
            [offer.specification, offer.status.label, offer.explanation].compactMap { $0 }.joined(separator: " · ")
        }
        let header = ["DownAudible title check", "ASIN \(report.asin)", "Marketplace \(request.marketplace.displayName)"]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString((header + rows).joined(separator: "\n"), forType: .string)
    }
}

struct QualityAuditScope: Identifiable {
    struct Input: Sendable {
        let book: AudibleBook
        let files: [URL]
    }

    let id = UUID()
    let accountID: UUID
    let accountName: String
    let client: AudibleClient
    let layout: ArchiveLayout
    let inputs: [Input]
}

enum QualityAuditError: LocalizedError {
    case scopeChanged

    var errorDescription: String? {
        "The account, archive or available titles changed. Open the quality check again before queuing new copies."
    }
}

private nonisolated struct AudioQuality: Sendable {
    let codec: String
    let bitrate: Int?
    let channels: Int?

    var label: String {
        [codec, bitrate.map { "\($0) kbps" }, channels.map { "\($0) channels" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @concurrent static func inspect(_ files: [URL], media: MediaTools = MediaTools()) async throws -> Self? {
        let executable = try media.executable(named: "ffprobe")
        let folder = try MediaTools.workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        var best: Self?
        for file in files {
            try Task.checkCancellation()
            do {
                guard let stream = try await MediaTools.probe(file, options: [], ffprobe: executable,
                    directory: folder, metadataOnly: true).audio else { continue }
                let kbps = stream.bitRate.flatMap(Double.init).flatMap { rate in
                    rate >= 1_000 ? Int(exactly: (rate / 1_000).rounded()) : nil
                }
                let description = [stream.codecName?.uppercased(), stream.profile].compactMap { $0 }.joined(separator: " ")
                let current = Self(codec: description, bitrate: kbps, channels: stream.channels)
                if best == nil || (kbps ?? 0) > (best?.bitrate ?? 0) { best = current }
            } catch is MediaError {
                continue
            }
        }
        return best
    }
}

struct QualityAuditView: View {
    private struct Row: Identifiable {
        let book: AudibleBook
        let local: String
        let available: String
        let upgrade: Bool

        var id: AudibleBook.ID { book.id }
    }

    let scope: QualityAuditScope
    let queue: (Set<AudibleBook.ID>) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var selection: Set<AudibleBook.ID> = []
    @State private var upgradesOnly = false
    @State private var work: Task<Void, Never>?
    @State private var issue: String?

    #if HELP_SCREENSHOTS
    init(scope: QualityAuditScope, demoResults: Bool = false, queue: @escaping (Set<AudibleBook.ID>) throws -> Void) {
        self.scope = scope
        self.queue = queue
        if demoResults {
            _rows = State(initialValue: scope.inputs.prefix(3).enumerated().map { index, input in
                Row(book: input.book, local: "AAC LC · 64 kbps · 2 channels",
                    available: index == 1 ? "AAX · AAC-LC · 64 kbps" : "Widevine stereo · AAC-LC · 128 kbps",
                    upgrade: index != 1)
            })
            if let first = scope.inputs.first { _selection = State(initialValue: [first.book.id]) }
        }
    }
    #endif

    private var visible: [Row] { upgradesOnly ? rows.filter(\.upgrade) : rows }
    private var eligible: Set<AudibleBook.ID> { Set(rows.filter(\.upgrade).map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check for Better-Quality Audio").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("\(scope.accountName) · Best quality · \(scope.client.options.format.displayName)")
                .foregroundStyle(.secondary)
            if work != nil {
                ProgressView(value: Double(rows.count), total: Double(scope.inputs.count)) {
                    Text("Checked \(rows.count) of \(scope.inputs.count) books")
                }
            }
            if let issue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
            if rows.isEmpty {
                ContentUnavailableView("Compare Saved Audio with Audible", systemImage: "waveform",
                    description: Text("Check the \(scope.inputs.count) saved titles. Queue any higher-bitrate copies you want to keep."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Toggle("Show higher-bitrate offers only", isOn: $upgradesOnly)
                Table(visible, selection: $selection) {
                    TableColumn("Title", value: \.book.title).width(min: 125, ideal: 165)
                    TableColumn("Saved audio", value: \.local).width(min: 170, ideal: 195)
                    TableColumn("Audible offer", value: \.available).width(min: 235, ideal: 245)
                    TableColumn("Result") { Text($0.upgrade ? "Higher bitrate" : "Review") }
                        .width(min: 105, ideal: 110)
                }
                .accessibilityLabel("Saved audio and Audible offers")
            }
            HStack {
                if work != nil { Button("Stop Check") { work?.cancel() } }
                else { Button(rows.isEmpty ? "Check Audio" : "Check Again", action: scan).disabled(scope.inputs.isEmpty) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Queue Selected as New Copies") {
                    do { try queue(selection.intersection(eligible)); dismiss() }
                    catch { issue = error.localizedDescription }
                }
                .disabled(work != nil || selection.isDisjoint(with: eligible))
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 430)
        .onDisappear { work?.cancel() }
    }

    private func scan() {
        rows = []
        issue = nil
        selection = []
        work = Task {
            defer { work = nil }
            for input in scope.inputs {
                do {
                    try Task.checkCancellation()
                    let local = try await AudioQuality.inspect(input.files)
                    let report = try await scope.client.checkTitle(input.book.asin, preferredAudioOnly: true)
                    try Task.checkCancellation()
                    let offer = report.preferredOffer(for: scope.client.options)
                    let upgrade: Bool
                    if let current = local?.bitrate, let proposed = offer?.bitrateKbps {
                        let comparable = offer?.channels == nil || local?.channels == nil || offer?.channels == local?.channels
                        upgrade = comparable && proposed - current > (offer?.bitrateEstimated == true ? 2 : 0)
                    } else {
                        upgrade = false
                    }
                    let refusal = report.offers.first { $0.status == .denied || $0.status == .error }
                    let available = offer?.specification ?? refusal?.explanation
                        ?? report.offers.first(where: { $0.explanation != nil })?.explanation
                    rows.append(Row(book: input.book, local: local?.label ?? "Unknown",
                                    available: available ?? "No comparable offer", upgrade: upgrade))
                    if let interruption = report.interruption { issue = interruption.errorDescription; return }
                } catch is CancellationError {
                    return
                } catch {
                    rows.append(Row(book: input.book, local: "Unknown", available: error.localizedDescription, upgrade: false))
                    if let failure = error as? AudibleError, failure.interruptsQualityAudit {
                        issue = failure.errorDescription
                        return
                    }
                }
            }
        }
    }
}
