import SwiftUI

struct PreferencesView: View {
    let model: WorkspaceModel

    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountPreferencesView(model: model)
            }
            Tab("Library", systemImage: "books.vertical") {
                LibraryPreferencesView(model: model)
            }
            Tab("Downloads", systemImage: "arrow.down.to.line") {
                DownloadPreferencesView(model: model)
            }
            Tab("Files", systemImage: "folder") {
                FilePreferencesView(model: model)
            }
            Tab("Jobs", systemImage: "clock") {
                JobPreferencesView(model: model)
            }
        }
        .frame(width: 640, height: 550)
    }
}

private struct LibraryPreferencesView: View {
    @Bindable var model: WorkspaceModel

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
                    .disabled(!model.signedIn || !model.canSwitchAccounts || reversedDateRange)
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
        HStack {
            Toggle(title, isOn: enabled)
                .toggleStyle(.checkbox)
            Spacer()
            if date != nil {
                DatePicker(title, selection: selectedDate, displayedComponents: .date)
                    .labelsHidden()
            }
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
                Toggle("Convert to M4B", isOn: $model.downloadOptions.convert)
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 8) {
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
                    .disabled(model.apiOptions.coverSizes.isEmpty)
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
                if model.layout.isValid {
                    Text("Use {format}, {author}, {title}, or {asin}. Separate folders with /.")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Enter a valid folder template.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Button("Restore Default Template") {
                    model.folderTemplate = ArchiveLayout.defaultTemplate
                }
                .disabled(model.folderTemplate == ArchiveLayout.defaultTemplate)
            }

            Section("Filenames") {
                Picker("Name files by", selection: $model.filenameStyle) {
                    ForEach(FilenameStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                NumberPreference("Maximum filename length", value: $model.filenameLength, range: 40...230, unit: "bytes")
                Picker("If a file is already saved", selection: $model.transferPreferences.existingFiles) {
                    ForEach(ExistingFiles.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
                TextField("Bandwidth per download (bytes/s)", value: $model.apiOptions.bytesPerSecond, format: .number)
                    .onChange(of: model.apiOptions.bytesPerSecond) {
                        if model.apiOptions.bytesPerSecond < 0 { model.apiOptions.bytesPerSecond = 0 }
                    }
                Text("Enter 0 to turn off the timeout or bandwidth limit.")
                    .foregroundStyle(.secondary)
            }

            Section("Batch behavior") {
                Toggle("Continue after a job fails", isOn: $model.transferPreferences.continueAfterError)
                Toggle("Show detailed transfer progress", isOn: $model.transferPreferences.showProgress)
                Toggle("Start downloads with the saved options", isOn: $model.transferPreferences.skipConfirmation)
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
                                .accessibilityLabel("Choose transfer log file")
                        }
                    }
                    if model.transferPreferences.logFile != nil {
                        Button("Use Default Location") { model.transferPreferences.logFile = nil }
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
