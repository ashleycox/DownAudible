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

    var helpTag: String {
        switch self {
        case .general: "Change update and interface preferences."
        case .accounts: "Manage the Audible accounts connected to DownAudible."
        case .library: "Choose which books to load and how library filters behave."
        case .downloads: "Choose audio quality, original files, and what to save with a download."
        case .conversion: "Choose the format, chapters, and audio settings for converted files."
        case .files: "Choose where and how DownAudible names saved files."
        case .jobs: "Set transfer speed, completion sounds, progress, and logging."
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
                        .appHelp(pane.helpTag)
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
                .appHelp("Hide podcasts or include podcast series or individual episodes when loading the library.")
                NumberPreference("Books per request", value: $model.apiOptions.pageSize, range: 10...1_000,
                                 help: "Set the number of library entries Audible returns in one request.")
            }

            Section("Purchase date") {
                PurchaseDateOption(title: "Purchased on or after", date: $model.apiOptions.purchaseStart,
                                   help: "Include purchases starting on this date.")
                PurchaseDateOption(title: "Purchased on or before", date: $model.apiOptions.purchaseEnd,
                                   help: "Include purchases through the end of this date.")
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
                    .appHelp("Reload your Audible library using the options above.")
            }

            Section("Browsing") {
                Toggle("Suggest filter values as you type", isOn: $showsFilterSuggestions)
                    .appHelp("Offer matching titles, authors, and other values from the current library in filter fields.")
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
    let help: String

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
            .appHelp(help)
    }

    @ViewBuilder private var datePicker: some View {
        if date != nil {
            DatePicker(title, selection: selectedDate, displayedComponents: .date)
                .labelsHidden()
                .appHelp(help)
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
                    .appHelp("Save audiobook audio. Turn this off to download only the additional files you select.")
                Picker("Download format", selection: $model.apiOptions.format) {
                    ForEach(AudibleDownloadFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .disabled(!model.downloadOptions.downloadAudio)
                .appHelp("Choose whether to request AAX, AAXC, or AAX with fallback.")
                Picker("Download quality", selection: $model.apiOptions.quality) {
                    ForEach(AudibleQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .disabled(!model.downloadOptions.downloadAudio)
                .appHelp("Choose the audio quality DownAudible requests from Audible.")
                Toggle("Convert to \(model.conversionPreferences.format.displayName)", isOn: $model.downloadOptions.convert)
                    .disabled(!model.downloadOptions.downloadAudio)
                    .appHelp("Convert downloaded audio using the current Conversion settings.")
                Toggle("Keep the original after conversion", isOn: $model.downloadOptions.keepOriginal)
                    .disabled(!model.downloadOptions.downloadAudio || !model.downloadOptions.convert)
                    .appHelp("Save the original Audible audio alongside the converted copy.")
            }

            Section("Additional files") {
                Toggle("Download companion PDFs", isOn: $model.downloadOptions.downloadPDF)
                    .appHelp("Save any PDF that Audible supplies with the book.")
                Toggle("Save cover images", isOn: $model.downloadOptions.downloadCover)
                    .appHelp("Save cover art as a separate image file.")
                Toggle("Save chapters as JSON", isOn: $model.downloadOptions.downloadChapters)
                    .appHelp("Save Audible’s chapter list as a separate JSON file.")
                Picker("Chapter file layout", selection: $model.apiOptions.chapterStyle) {
                    ForEach(AudibleChapterStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .disabled(!model.downloadOptions.downloadChapters)
                .appHelp("Choose whether the chapter JSON has a flat list or nested chapter groups.")
                Toggle("Save annotations as JSON", isOn: $model.downloadOptions.downloadAnnotations)
                    .appHelp("Save the account’s notes and bookmarks for the book as JSON.")
            }

            Section("Cover sizes") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), alignment: .leading)], spacing: 8) {
                    ForEach(AudibleAPIOptions.availableCoverSizes, id: \.self) { size in
                        Toggle(isOn: selectedCoverSize(size)) {
                            Text("\(size, format: .number.grouping(.never)) px")
                        }
                        .toggleStyle(.checkbox)
                        .appHelp("Request a cover image at this size.")
                    }
                }
                Text("Leave the sizes unchecked to use the largest cover Audible provides.")
                    .foregroundStyle(.secondary)
                Button("Use Largest Available") { model.apiOptions.coverSizes = [] }
                    .keyboardShortcut("l", modifiers: [.control, .shift])
                    .disabled(model.apiOptions.coverSizes.isEmpty)
                    .appHelp("Clear specific cover sizes so Audible supplies its largest available image.")
            }

            Section("Apple Books") {
                Picker("Add after saving", selection: $model.appleBooksDestination) {
                    ForEach(AppleBooksDestination.allCases) { destination in
                        Text(destination.displayName).tag(destination)
                    }
                }
                .appHelp("Choose which newly saved audio to send to Apple Books.")
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
                    .appHelp("Arrange exported files into folders using the tokens shown in the template preview.")
                Text("Separate folders with /.")
                    .foregroundStyle(.secondary)
                Button("Restore Default Template") {
                    model.folderTemplate = ArchiveLayout.defaultTemplate
                }
                .keyboardShortcut("d", modifiers: [.control, .shift])
                .disabled(model.folderTemplate == ArchiveLayout.defaultTemplate)
                .appHelp("Reset the folder template to DownAudible’s default.")
            }

            Section("Filenames") {
                Toggle("Keep Audible’s AAX filename", isOn: $model.outputNaming.keepOriginalAAXFilename)
                    .appHelp("Keep the original filename supplied by Audible for a new AAX download.")
                Text("Use the filename supplied by Audible when saving a new AAX download.")
                    .foregroundStyle(.secondary)
                TextField("Filename template", text: $model.outputNaming.filenameTemplate,
                          prompt: Text("Use the filename style"))
                    .font(.body.monospaced())
                    .appHelp("Use book details and other template tokens in saved filenames.")
                TextField("Chapter filename template", text: $model.outputNaming.chapterFilenameTemplate)
                    .font(.body.monospaced())
                    .appHelp("Name each exported chapter file using tokens such as chapter number and chapter title.")
                Picker("Name files by", selection: $model.filenameStyle) {
                    ForEach(FilenameStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .appHelp("Choose what appears in a filename when a filename template is empty.")
                NumberPreference("Maximum filename length", value: $model.filenameLength, range: 40...230, unit: "bytes",
                                 help: "Limit the number of bytes used for each saved filename.")
                Picker("Spaces", selection: $model.outputNaming.whitespace) {
                    ForEach(NamingWhitespace.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                .appHelp("Keep spaces in filenames or replace them with the selected separator.")
                Picker("Letter case", selection: $model.outputNaming.letterCase) {
                    ForEach(NamingLetterCase.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                .appHelp("Keep the original letter case or change it for saved filenames.")
                Toggle("Use ASCII characters", isOn: $model.outputNaming.transliterate)
                    .appHelp("Use basic Latin characters in saved names for compatibility with more devices.")
                Picker("If a file is already saved", selection: $model.transferPreferences.existingFiles) {
                    ForEach(ExistingFiles.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .appHelp("Reuse a saved file when possible or create a new copy with a distinct name.")
            }

            Section("Template preview") {
                if let path = examplePath {
                    Text(path)
                        .monospaced()
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .appHelp("This is an example path built from the current folder and filename options.")
                } else {
                    Label("Check the folder and filename templates.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(ArchiveLayout.tokens.map { "{\($0)}" }.joined(separator: "  "))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .appHelp("Copy tokens from this list into your folder or filename templates.")
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
                NumberPreference("Simultaneous downloads", value: $model.transferPreferences.jobLimit, range: 1...12,
                                 help: "Limit how many download jobs can run at once.")
                NumberPreference("Simultaneous conversions", value: $model.transferPreferences.conversionJobLimit, range: 1...12,
                                 help: "Limit how many audio conversions can run at once.")
            }

            Section("Network") {
                NumberPreference("Request timeout", value: $model.apiOptions.timeout, range: 0...600, step: 5, unit: "seconds",
                                 help: "Set how long to wait for a network request. Set 0 to turn off the timeout.")
                DownloadBandwidthPicker(bytesPerSecond: $model.apiOptions.bytesPerSecond)
                Text("Enter 0 seconds to turn off the request timeout.")
                    .foregroundStyle(.secondary)
            }

            Section("Batch behavior") {
                Toggle("Continue after a job fails", isOn: $model.transferPreferences.continueAfterError)
                    .appHelp("Start the jobs still waiting in the batch after one job fails.")
                Toggle("Show detailed transfer progress", isOn: $model.transferPreferences.showProgress)
                    .appHelp("Show progress bars for each running job and for the batch.")
            }

            TransferFeedbackSettingsView(model: model)

            Section("Transfer log") {
                Picker("Log", selection: $model.transferPreferences.logLevel) {
                    ForEach(TransferLogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .appHelp("Choose whether the text log records failures, all results, or nothing.")
                if model.transferPreferences.logLevel != .off {
                    LabeledContent("Log file") {
                        HStack(spacing: 8) {
                            Text(logFile.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .appHelp(logFile.path(percentEncoded: false))
                            Button("Choose…", action: model.chooseLogFile)
                                .keyboardShortcut("g", modifiers: [.control, .shift])
                                .accessibilityLabel("Choose transfer log file")
                                .appHelp("Choose a file for logging transfer results.")
                        }
                    }
                    if model.transferPreferences.logFile != nil {
                        Button("Use Default Location") { model.transferPreferences.logFile = nil }
                            .keyboardShortcut("k", modifiers: [.control, .shift])
                            .appHelp("Save the transfer log in DownAudible’s Application Support folder.")
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
    let help: String

    init(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1,
         unit: LocalizedStringKey? = nil, help: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.help = help
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, value: boundedValue, format: .number)
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .appHelp(help)
                Stepper(title, value: boundedValue, in: range, step: step)
                    .labelsHidden()
                    .appHelp(help)
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
