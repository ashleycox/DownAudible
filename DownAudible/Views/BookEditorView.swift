import AVFoundation
import SwiftUI

struct BookEditorView: View {
    private enum PreviewRow: Equatable {
        case part(Int)
        case section(Int)
    }

    private struct PreviewRequest: Identifiable {
        let id = UUID()
        let row: PreviewRow
        let section: BookEditSection
        let position: BookPreviewPosition
    }

    let model: WorkspaceModel
    let request: BookEditRequest

    @Environment(\.dismiss) private var dismiss
    @State private var prepared: PreparedBookEdit?
    @State private var excluded: Set<Int> = []
    @State private var isReading = true
    @State private var readError: String?
    @State private var readingAttempt = 0
    @State private var downloadID: UUID?
    @State private var preview: PreviewRequest?
    @State private var previewIsPlaying = false
    @State private var previewError: String?

    #if HELP_SCREENSHOTS
    init(model: WorkspaceModel, request: BookEditRequest, excludedSections: Set<Int> = []) {
        self.model = model
        self.request = request
        _excluded = State(initialValue: excludedSections)
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Edit Book").font(.headline)
                Text(request.origin.title).font(.title3)
                Text("DownAudible keeps the original AAX and other source files intact. Your edits apply only to the converted M4B.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let previewError {
                    Label(previewError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    if let prepared {
                        let count = prepared.layout.sections.count - excluded.count
                        Text(count == 0 ? "Include at least one section." : "\(count) of \(prepared.layout.sections.count) included")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Convert to M4B") {
                        guard let prepared else { return }
                        preview = nil
                        model.convertEditedBook(request, prepared: prepared, excludedSections: excluded)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConvert)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 520)
        .task(id: readingAttempt) { await readAudio() }
        .task(id: preview?.id) { await playPreview() }
        .onChange(of: didDownload) { _, done in
            if done { readingAttempt += 1 }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let prepared {
            sectionList(prepared)
        } else if isReading {
            ProgressView("Reading audio…")
        } else if let readError {
            ContentUnavailableView {
                Label("Couldn’t Read the Audio", systemImage: "waveform.badge.exclamationmark")
            } description: {
                Text(readError)
            } actions: {
                Button("Try Again") { readingAttempt += 1 }
            }
        } else if case .active(let name, let fraction) = downloadStatus {
            if let fraction {
                ProgressView(name, value: fraction)
                    .frame(maxWidth: 280)
            } else {
                ProgressView(name)
            }
        } else if case .waiting = downloadStatus {
            ProgressView("Preparing download…")
        } else {
            ContentUnavailableView {
                Label("Audio Needed", systemImage: "waveform")
            } description: {
                Text(downloadMessage)
            } actions: {
                if request.origin.book?.isDownloadable == true {
                    Button(downloadID == nil ? "Download Original" : "Retry Download") {
                        downloadID = model.downloadOriginalForBookEdit(request)
                    }
                    .disabled(!model.canStartDownloads || !request.destination.isValid)
                }
            }
        }
    }

    private var downloadStatus: Transfer.Status? {
        model.transfers.first { $0.id == downloadID }?.status
    }

    private var didDownload: Bool {
        if case .done = downloadStatus { return true }
        return false
    }

    private var downloadMessage: String {
        if case .failed(let message) = downloadStatus { return message }
        return if request.origin.book?.isDownloadable == true {
            "Download the original audio to preview and edit this book."
        } else {
            "Match this book to an audio file in Library to open it in the editor."
        }
    }

    private var canConvert: Bool {
        guard let prepared else { return false }
        return !model.isTransferring && request.destination.isValid && excluded.count < prepared.layout.sections.count
    }

    private func sectionList(_ prepared: PreparedBookEdit) -> some View {
        let groups = Dictionary(grouping: prepared.layout.sections, by: \.sourceIndex)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(prepared.sources.indices, id: \.self) { sourceIndex in
                    let sections = groups[sourceIndex, default: []]
                    if prepared.sources.count > 1, sections.count > 1, let part = BookEditSection.partPreview(sections) {
                        partRow(part, sections: sections)
                            .appHelp(prepared.sources[sourceIndex].audio.url.lastPathComponent)
                        ForEach(sections) { sectionRow($0).padding(.leading, 20) }
                    } else {
                        ForEach(sections) { section in
                            let partName = "Part \(sourceIndex + 1)"
                            let label = prepared.sources.count > 1 && section.title != partName
                                ? "\(partName) · \(section.title)" : section.title
                            sectionRow(section, label: label)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Book sections")
    }

    private func partRow(_ part: BookEditSection, sections: [BookEditSection]) -> some View {
        let ids = Set(sections.map(\.id))
        let count = ids.subtracting(excluded).count
        return HStack(spacing: 12) {
            Toggle(part.title, isOn: included(ids))
                .toggleStyle(.checkbox)
                .font(.headline)
                .accessibilityLabel("Include \(part.title)")
                .accessibilityValue("\(count) of \(ids.count) sections included")
            if count > 0 && count < ids.count {
                Text("\(count) of \(ids.count) included").foregroundStyle(.secondary)
            }
            Spacer()
            previewButtons(.part(part.sourceIndex), section: part, label: part.title)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func sectionRow(_ section: BookEditSection, label: String? = nil) -> some View {
        let title = label ?? section.title
        return HStack(spacing: 12) {
            Toggle(title, isOn: included([section.id]))
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(title)")
            Spacer(minLength: 8)
            let duration = Duration.milliseconds(section.durationMilliseconds)
            Text(duration, format: .time(pattern: section.durationMilliseconds >= 3_600_000 ? .hourMinuteSecond : .minuteSecond))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            previewButtons(.section(section.id), section: section, label: title)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func included(_ ids: Set<Int>) -> Binding<Bool> {
        Binding {
            !ids.isSubset(of: excluded)
        } set: { keep in
            if keep {
                excluded.subtract(ids)
            } else {
                excluded.formUnion(ids)
            }
        }
    }

    private func previewButtons(_ row: PreviewRow, section: BookEditSection, label: String) -> some View {
        HStack(spacing: 8) {
            previewButton(row, section: section, label: label, position: .start)
            previewButton(row, section: section, label: label, position: .end)
        }
    }

    private func previewButton(
        _ row: PreviewRow, section: BookEditSection, label: String, position: BookPreviewPosition
    ) -> some View {
        let active = preview?.row == row && preview?.position == position
        let title = position == .start ? "Preview Start" : "Preview End"
        let target = position == .start ? "start of \(label)" : "end of \(label)"
        let help = position == .start
            ? "Play up to ten seconds from the start of this section."
            : "Play up to ten seconds from the end of this section."
        return Button(active ? "Stop Preview" : title, systemImage: active ? "stop.fill" : "play.fill") {
            previewIsPlaying = false
            previewError = nil
            preview = active ? nil : PreviewRequest(row: row, section: section, position: position)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(active ? "Stop preview of the \(target)" : "Preview \(target)")
        .accessibilityValue(active && !previewIsPlaying ? "Preparing audio" : "")
        .appHelp(active ? "Stop this preview." : help)
        .frame(minWidth: 104, alignment: .trailing)
    }

    private func readAudio() async {
        isReading = true
        readError = nil
        defer { isReading = false }
        do {
            let result = try await model.prepareBookEdit(request)
            try Task.checkCancellation()
            prepared = result
        } catch {
            if !Task.isCancelled { readError = error.localizedDescription }
        }
    }

    private func playPreview() async {
        guard let preview, let prepared, prepared.sources.indices.contains(preview.section.sourceIndex) else { return }
        defer {
            if self.preview?.id == preview.id {
                self.preview = nil
                previewIsPlaying = false
            }
        }
        do {
            let directory = try MediaTools.workspace()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "Preview.m4a")
            try await model.previewBookSection(
                preview.section, at: preview.position, source: prepared.sources[preview.section.sourceIndex],
                request: request, to: url
            )
            try Task.checkCancellation()
            guard self.preview?.id == preview.id else { return }
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.play() else { throw MediaError.unreadableAudio }
            previewIsPlaying = true
            defer { player.stop() }
            try await Task.sleep(for: .seconds(player.duration))
        } catch {
            if !Task.isCancelled, self.preview?.id == preview.id { previewError = error.localizedDescription }
        }
    }
}
