import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TransferFeedbackSettingsView: View {
    private enum SoundChoice: Hashable {
        case chime(QueueCompletionSound.Chime)
        case system(String)
        case custom

        init?(sound: QueueCompletionSound) {
            switch sound.source {
            case .off: return nil
            case .builtIn: self = .chime(sound.chime)
            case .system: self = .system(sound.systemName)
            case .custom:
                guard sound.customFile != nil else { return nil }
                self = .custom
            }
        }
    }

    @Bindable var model: WorkspaceModel
    @State private var event = TransferFeedbackEvent.downloadCompleted
    @State private var choosingFile = false
    @State private var choosingFileFor: TransferFeedbackEvent?
    @State private var importingFile = false
    @State private var notificationStatus: TransferNotificationStatus?
    @State private var statusRefresh = 0
    @State private var notificationActionRunning = false
    @State private var sentTest = false
    @State private var showingProblem = false
    @State private var problem = ""

    var body: some View {
        let selection = settings
        Form {
            notificationPermissions

            Section("Transfer Events") {
                eventList
            }

            Section(event.displayName) {
                Picker("Delivery", selection: Binding {
                    selection.wrappedValue.delivery
                } set: { delivery in
                    model.setTransferDelivery(delivery, for: event)
                }) {
                    ForEach(TransferFeedbackPreferences.Delivery.allCases) { delivery in
                        if event != .queueFinished || !delivery.postsNotification {
                            Text(delivery.displayName).tag(delivery)
                        }
                    }
                }
                .appHelp(event == .queueFinished
                    ? "Play a sound when the whole queue finishes, or keep it silent."
                    : "Choose a sound, a silent macOS notification, both, or neither for this event.")
            }
            .disabled(importingFile)

            if selection.wrappedValue.delivery.playsSound {
                Section("Sound") {
                    soundControls(selection.sound)
                }
                .disabled(importingFile)
            }
        }
        .formStyle(.grouped)
        .task(id: statusRefresh) {
            let status = await TransferNotifications.shared.notificationStatus()
            if !Task.isCancelled { notificationStatus = status }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            statusRefresh += 1
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            importSound(result)
        } onCancellation: {
            choosingFileFor = nil
        }
        .alert("Transfer Alert", isPresented: $showingProblem) {
            Button("OK", role: .cancel) {}
                .appHelp("Close this transfer alert message.")
        } message: {
            Text(problem)
        }
    }

    private var eventList: some View {
        List(selection: Binding<TransferFeedbackEvent?> {
            event
        } set: { selection in
            if let selection { event = selection }
        }) {
            ForEach(TransferFeedbackEvent.allCases) { event in
                let delivery = model.transferFeedback[event].delivery.displayName
                HStack {
                    Text(event.displayName)
                    Spacer()
                    Text(delivery)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(event.displayName), \(delivery)")
                .tag(event)
            }
        }
        .listStyle(.inset)
        .frame(height: 140)
        .accessibilityLabel("Transfer Events")
        .appHelp("Select a transfer event to change its delivery or sound.")
    }

    private var notificationPermissions: some View {
        Section("macOS Notifications") {
            permissionRow("Permission", value: permissionDescription,
                          help: "Shows whether macOS lets DownAudible send notifications.")
            permissionRow("Notification Center", value: settingDescription(notificationStatus?.appearsInNotificationCenter),
                          help: "Shows whether DownAudible notifications can appear in Notification Center.")
            permissionRow("Banners and Alerts", value: settingDescription(notificationStatus?.showsBanners),
                          help: "Shows whether macOS can show DownAudible banners or alerts on screen.")

            HStack {
                if notificationStatus?.authorization == .notRequested {
                    Button("Enable Notifications", action: enableNotifications)
                        .appHelp("Ask macOS to allow notifications from DownAudible.")
                }
                Button("Open Notification Settings", action: openNotificationSettings)
                    .appHelp("Manage DownAudible’s notification permission in System Settings.")
                Button("Send Test Notification", action: sendTestNotification)
                    .disabled(notificationStatus?.canSendTest != true)
                    .appHelp("Send a silent test to confirm notifications appear in Notification Center.")
            }
            .disabled(notificationActionRunning)

            if sentTest {
                Text("Test notification sent. Check Notification Center.")
                    .foregroundStyle(.secondary)
                    .appHelp("Click the clock in the menu bar to open Notification Center and find the test.")
            }
        }
    }

    private func permissionRow(_ label: String, value: String, help: String) -> some View {
        LabeledContent(label, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .appHelp(help)
    }

    private var permissionDescription: String {
        switch notificationStatus?.authorization {
        case .notRequested: "Permission not requested"
        case .blocked: "Blocked by macOS"
        case .allowed: "Allowed"
        case nil: "Checking…"
        }
    }

    private func settingDescription(_ enabled: Bool?) -> String {
        enabled.map { $0 ? "On" : "Off" } ?? "Checking…"
    }

    @ViewBuilder
    private func soundControls(_ sound: Binding<QueueCompletionSound>) -> some View {
        let selected = sound.wrappedValue
        let event = event
        let selectedChoice = SoundChoice(sound: selected)
        let systemSounds = Set(QueueCompletionSoundPlayer.systemSounds.map(QueueCompletionSoundPlayer.systemName(for:)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ScrollViewReader { proxy in
            List(selection: soundSelection(sound, for: event)) {
                Section("Built-in Chimes") {
                    ForEach(QueueCompletionSound.Chime.allCases) { chime in
                        soundRow(chime.displayName, choice: .chime(chime))
                    }
                }
                if !systemSounds.isEmpty {
                    Section("macOS Sounds") {
                        ForEach(systemSounds, id: \.self) { name in
                            soundRow(name, choice: .system(name))
                        }
                    }
                }
                if let file = selected.customFile {
                    Section("Custom Sound") {
                        soundRow(file.name, choice: .custom)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 184)
            .accessibilityLabel("Sound")
            .appHelp("Use the Up and Down Arrow keys to select and preview sounds.")
            .onChange(of: selectedChoice, initial: true) { _, choice in
                if let choice { proxy.scrollTo(choice) }
            }
        }

        if selected.source == .system && !systemSounds.contains(selected.systemName) {
            Text("Saved sound unavailable: \(selected.systemName)")
                .foregroundStyle(.secondary)
                .appHelp("Select another sound from the list.")
        }
        HStack {
            Button("Choose Sound File…") { chooseSoundFile(for: event) }
                .appHelp("Open and preview an audio file. DownAudible keeps a copy so it stays available if the original moves.")
            Button("Play Sound", systemImage: "play") { preview(event) }
                .disabled(selectedChoice == nil || (selected.source == .system && !systemSounds.contains(selected.systemName)))
                .appHelp("Listen again to the sound for this event.")
        }
    }

    private func soundRow(_ title: String, choice: SoundChoice) -> some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.middle)
            .tag(choice)
            .id(choice)
    }

    private func soundSelection(_ sound: Binding<QueueCompletionSound>,
                                for event: TransferFeedbackEvent) -> Binding<SoundChoice?> {
        Binding {
            SoundChoice(sound: sound.wrappedValue)
        } set: { choice in
            var updated = sound.wrappedValue
            guard let choice, choice != SoundChoice(sound: updated) else { return }
            switch choice {
            case .chime(let chime):
                updated.source = .builtIn
                updated.chime = chime
            case .system(let name):
                updated.source = .system
                updated.systemName = name
            case .custom:
                guard updated.customFile != nil else { return }
                updated.source = .custom
            }
            sound.wrappedValue = updated
            preview(event)
        }
    }

    private var settings: Binding<TransferFeedbackPreferences.Settings> {
        let event = event
        return Binding {
            model.transferFeedback[event]
        } set: { settings in
            model.transferFeedback[event] = settings
        }
    }

    private func preview(_ event: TransferFeedbackEvent) {
        let settings = model.transferFeedback[event]
        guard settings.delivery.playsSound,
              settings.sound.source != .custom || settings.sound.customFile != nil else { return }
        do {
            try model.previewTransferSound(for: event)
        } catch {
            show(error)
        }
    }

    private func chooseSoundFile(for event: TransferFeedbackEvent) {
        choosingFileFor = event
        choosingFile = true
    }

    private func importSound(_ result: Result<[URL], Error>) {
        guard let event = choosingFileFor else { return }
        choosingFileFor = nil
        importingFile = true
        Task {
            defer { importingFile = false }
            do {
                guard let file = try result.get().first else { return }
                try await model.installTransferSound(from: file, for: event)
                preview(event)
            } catch is CancellationError {
            } catch {
                show(error)
            }
        }
    }

    private func enableNotifications() {
        notificationActionRunning = true
        Task {
            defer {
                notificationActionRunning = false
                statusRefresh += 1
            }
            do {
                try await TransferNotifications.shared.askPermission()
            } catch {
                show(error)
            }
        }
    }

    private func openNotificationSettings() {
        guard let url = TransferNotifications.systemSettingsURL,
              NSWorkspace.shared.open(url) else {
            show("Open System Settings and choose Notifications to manage DownAudible’s permissions.")
            return
        }
    }

    private func sendTestNotification() {
        notificationActionRunning = true
        sentTest = false
        Task {
            defer {
                notificationActionRunning = false
                statusRefresh += 1
            }
            do {
                try await TransferNotifications.shared.sendTestNotification()
                sentTest = true
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: any Error) {
        show(error.localizedDescription)
    }

    private func show(_ message: String) {
        problem = message
        showingProblem = true
    }
}
