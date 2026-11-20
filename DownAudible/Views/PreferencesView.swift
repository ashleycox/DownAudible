import SwiftUI

// The order and content here apply to both Settings and the setup assistant.
enum SettingsPane: CaseIterable, Identifiable {
    case general, accounts, library, downloads, conversion, files, jobs

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .library: "Library"
        case .downloads: "Downloads"
        case .conversion: "Conversion"
        case .files: "Files"
        case .jobs: "Jobs"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .library: "books.vertical"
        case .downloads: "arrow.down.to.line"
        case .conversion: "waveform"
        case .files: "folder"
        case .jobs: "list.bullet.rectangle"
        }
    }

    @MainActor @ViewBuilder
    func content(for model: WorkspaceModel, softwareUpdater: SoftwareUpdater) -> some View {
        @Bindable var model = model
        switch self {
        case .general:
            GeneralPreferencesView(softwareUpdater: softwareUpdater)
        case .accounts:
            AccountPreferencesView(model: model)
        case .library:
            LibraryPreferencesView(model: model)
        case .downloads:
            DownloadPreferencesView(model: model)
        case .conversion:
            Form {
                ConversionPreferencesView(preferences: $model.conversionPreferences)
            }
            .formStyle(.grouped)
        case .files:
            FilePreferencesView(model: model)
        case .jobs:
            JobPreferencesView(model: model)
        }
    }
}

struct PreferencesView: View {
    let model: WorkspaceModel
    let softwareUpdater: SoftwareUpdater

    var body: some View {
        TabView {
            ForEach(SettingsPane.allCases) { pane in
                Tab {
                    pane.content(for: model, softwareUpdater: softwareUpdater)
                } label: {
                    Label(pane.title, systemImage: pane.systemImage)
                }
            }
        }
        .frame(width: 640, height: 550)
    }
}

private struct LibraryPreferencesView: View {
    @Bindable var model: WorkspaceModel
    @AppStorage(LibraryFilters.suggestionsPreferenceKey) private var showsFilterSuggestions = true

    var body: some View {
        Form {
            Section("Library") {
                Picker("Podcasts", selection: $model.apiOptions.podcasts) {
                    ForEach(AudiblePodcastMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                NumberPreference("Books per request", value: $model.apiOptions.pageSize, range: 10...1_000)
            }

            Section("Purchase date") {
                PurchaseDateOption(title: "Purchased on or after", date: $model.apiOptions.purchaseStart)
                PurchaseDateOption(title: "Purchased on or before", date: $model.apiOptions.purchaseEnd)
                if reversedDateRange {
                    Label("Choose an end date on or after the start date.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Refresh the library to apply these settings.")
                    .foregroundStyle(.secondary)
                Button("Refresh Library") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: [.control, .shift])
                    .disabled(!model.signedIn || !model.canSwitchAccounts || reversedDateRange)
            }

            Section("Browsing") {
                Toggle("Suggest filter values as you type", isOn: $showsFilterSuggestions)
            }
        }
        .formStyle(.grouped)
    }

    private var reversedDateRange: Bool {
        guard let start = model.apiOptions.purchaseStart, let end = model.apiOptions.purchaseEnd else { return false }
        return Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end)
    }
}

private struct PurchaseDateOption: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                dateToggle
                Spacer(minLength: 8)
                datePicker
            }
            VStack(alignment: .leading, spacing: 8) {
                dateToggle
                datePicker
            }
        }
    }

    private var dateToggle: some View {
        Toggle(title, isOn: enabled)
            .toggleStyle(.checkbox)
    }

    @ViewBuilder private var datePicker: some View {
        if date != nil {
            DatePicker(title, selection: selectedDate, displayedComponents: .date)
                .labelsHidden()
        }
    }

    private var enabled: Binding<Bool> {
        Binding {
            date != nil
        } set: { enabled in
            date = enabled ? (date ?? .now) : nil
        }
    }

    private var selectedDate: Binding<Date> {
        Binding { date ?? .now } set: { date = $0 }
    }
}

private struct DownloadPreferencesView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Form {
            Section("Audio") {
                Toggle("Download audio", isOn: $model.downloadOptions.downloadAudio)
                Picker("Download format", selection: $model.apiOptions.format) {
                    ForEach(AudibleDownloadFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .disabled(!model.downloadOptions.downloadAudio)
                Picker("Download quality", selection: $model.apiOptions.quality) {
                    ForEach(AudibleQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .disabled(!model.downloadOptions.downloadAudio)
                Toggle("Convert to \(model.conversionPreferences.format.displayName)", isOn: $model.downloadOptions.convert)
                    .disabled(!model.downloadOptions.downloadAudio)
                Toggle("Keep the original after conversion", isOn: $model.downloadOptions.keepOriginal)
                    .disabled(!model.downloadOptions.downloadAudio || !model.downloadOptions.convert)
            }

            Section("Additional files") {
                Toggle("Download companion PDFs", isOn: $model.downloadOptions.downloadPDF)
                Toggle("Save cover images", isOn: $model.downloadOptions.downloadCover)
                Toggle("Save chapters as JSON", isOn: $model.downloadOptions.downloadChapters)
                Picker("Chapter file layout", selection: $model.apiOptions.chapterStyle) {
                    ForEach(AudibleChapterStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .disabled(!model.downloadOptions.downloadChapters)
                Toggle("Save annotations as JSON", isOn: $model.downloadOptions.downloadAnnotations)
            }

            Section("Cover sizes") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), alignment: .leading)], spacing: 8) {
                    ForEach(AudibleAPIOptions.availableCoverSizes, id: \.self) { size in
                        Toggle(isOn: selectedCoverSize(size)) {
                            Text("\(size, format: .number.grouping(.never)) px")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Text("Leave the sizes unchecked to use the largest cover Audible provides.")
                    .foregroundStyle(.secondary)
                Button("Use Largest Available") { model.apiOptions.coverSizes = [] }
                    .keyboardShortcut("l", modifiers: [.control, .shift])
                    .disabled(model.apiOptions.coverSizes.isEmpty)
            }

            Section("Apple Books") {
                Picker("Add after saving", selection: $model.appleBooksDestination) {
                    ForEach(AppleBooksDestination.allCases) { destination in
                        Text(destination.displayName).tag(destination)
                    }
                }
                if model.appleBooksDestination == .m4b && model.conversionPreferences.format != .m4b {
                    Text("Choose M4B in Conversion to send converted files to Apple Books.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func selectedCoverSize(_ size: Int) -> Binding<Bool> {
        Binding {
            model.apiOptions.coverSizes.contains(size)
        } set: { selected in
            var sizes = Set(model.apiOptions.coverSizes)
            if selected { sizes.insert(size) } else { sizes.remove(size) }
            model.apiOptions.coverSizes = sizes.sorted()
        }
    }
}

private struct FilePreferencesView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Form {
            Section("Destination") {
                DestinationPicker(directory: $model.outputDirectory)
                TextField("Folder template", text: $model.folderTemplate)
                    .font(.body.monospaced())
                Text("Separate folders with /.")
                    .foregroundStyle(.secondary)
                Button("Restore Default Template") {
                    model.folderTemplate = ArchiveLayout.defaultTemplate
                }
                .keyboardShortcut("d", modifiers: [.control, .shift])
                .disabled(model.folderTemplate == ArchiveLayout.defaultTemplate)
            }

            Section("Filenames") {
                Toggle("Keep Audible’s AAX filename", isOn: $model.outputNaming.keepOriginalAAXFilename)
                Text("Use the filename supplied by Audible when saving a new AAX download.")
                    .foregroundStyle(.secondary)
                TextField("Filename template", text: $model.outputNaming.filenameTemplate,
                          prompt: Text("Use the filename style"))
                    .font(.body.monospaced())
                TextField("Chapter filename template", text: $model.outputNaming.chapterFilenameTemplate)
                    .font(.body.monospaced())
                Picker("Name files by", selection: $model.filenameStyle) {
                    ForEach(FilenameStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                NumberPreference("Maximum filename length", value: $model.filenameLength, range: 40...230, unit: "bytes")
                Picker("Spaces", selection: $model.outputNaming.whitespace) {
                    ForEach(NamingWhitespace.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                Picker("Letter case", selection: $model.outputNaming.letterCase) {
                    ForEach(NamingLetterCase.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                Toggle("Use ASCII characters", isOn: $model.outputNaming.transliterate)
                Picker("If a file is already saved", selection: $model.transferPreferences.existingFiles) {
                    ForEach(ExistingFiles.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Template preview") {
                if let path = examplePath {
                    Text(path)
                        .monospaced()
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Label("Check the folder and filename templates.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(ArchiveLayout.tokens.map { "{\($0)}" }.joined(separator: "  "))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var examplePath: String? {
        let layout = model.layout
        let format = model.conversionPreferences.format.fileExtension
        let book = ArchiveTitle(title: "My Great Book", author: "Annie Reader", asin: "B001EXAMPLE", metadata: [
            "subtitle": "A Memoir", "authors": "Annie Reader", "narrator": "Ella Day", "narrators": "Ella Day",
            "series": "Village Stories", "seriesNumber": "2", "publisher": "Square Press", "year": "2026", "language": "English"
        ])
        let chapterNumber = model.conversionPreferences.chapterMode == .separate ? 1 : nil
        let chapterTitle = chapterNumber == nil ? nil : "The Beginning"
        return layout.previewPath(for: book, format: format, chapterNumber: chapterNumber, chapterTitle: chapterTitle)
    }
}

private struct JobPreferencesView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Form {
            Section("Concurrency") {
                NumberPreference("Simultaneous downloads", value: $model.transferPreferences.jobLimit, range: 1...12)
                NumberPreference("Simultaneous conversions", value: $model.transferPreferences.conversionJobLimit, range: 1...12)
            }

            Section("Network") {
                NumberPreference("Request timeout", value: $model.apiOptions.timeout, range: 0...600, step: 5, unit: "seconds")
                DownloadBandwidthPicker(bytesPerSecond: $model.apiOptions.bytesPerSecond)
                Text("Enter 0 seconds to turn off the request timeout.")
                    .foregroundStyle(.secondary)
            }

            Section("Batch behavior") {
                Toggle("Continue after a job fails", isOn: $model.transferPreferences.continueAfterError)
                Toggle("Show detailed transfer progress", isOn: $model.transferPreferences.showProgress)
            }

            Section("Transfer log") {
                Picker("Log", selection: $model.transferPreferences.logLevel) {
                    ForEach(TransferLogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                if model.transferPreferences.logLevel != .off {
                    LabeledContent("Log file") {
                        HStack(spacing: 8) {
                            Text(logFile.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(logFile.path(percentEncoded: false))
                            Button("Choose…", action: model.chooseLogFile)
                                .keyboardShortcut("g", modifiers: [.control, .shift])
                                .accessibilityLabel("Choose transfer log file")
                        }
                    }
                    if model.transferPreferences.logFile != nil {
                        Button("Use Default Location") { model.transferPreferences.logFile = nil }
                            .keyboardShortcut("k", modifiers: [.control, .shift])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var logFile: URL { model.transferPreferences.logFile ?? TransferLog.defaultURL }
}

private struct NumberPreference: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: LocalizedStringKey?

    init(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: LocalizedStringKey? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, value: boundedValue, format: .number)
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Stepper(title, value: boundedValue, in: range, step: step)
                    .labelsHidden()
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }

    private var boundedValue: Binding<Int> {
        Binding { value } set: { number in
            value = min(max(number, range.lowerBound), range.upperBound)
        }
    }
}
