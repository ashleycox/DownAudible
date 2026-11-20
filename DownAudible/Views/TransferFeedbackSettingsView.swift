import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TransferFeedbackSettingsView: View {
    @Bindable var model: WorkspaceModel
    @State private var event = TransferFeedbackEvent.downloadCompleted
    @State private var choosingFile = false
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
                Picker("Event", selection: $event) {
                    ForEach(TransferFeedbackEvent.allCases) { event in
                        let delivery = model.transferFeedback[event].delivery.displayName
                        Text("\(event.displayName), \(delivery)").tag(event)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .appHelp("Select an event to change its delivery or sound.")
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

                if selection.wrappedValue.delivery.playsSound {
                    soundControls(selection.sound)
                }
            }
            .disabled(importingFile)
        }
        .formStyle(.grouped)
        .task(id: statusRefresh) {
            let status = await TransferNotifications.shared.notificationStatus()
            if !Task.isCancelled { notificationStatus = status }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            statusRefresh += 1
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio], onCompletion: importSound)
        .alert("Transfer Alert", isPresented: $showingProblem) {
            Button("OK", role: .cancel) {}
                .appHelp("Close this transfer alert message.")
        } message: {
            Text(problem)
        }
    }

    private var notificationPermissions: some View {
        Section("macOS Notifications") {
            LabeledContent("Permission", value: permissionDescription)
                .appHelp("Shows whether macOS lets DownAudible send notifications.")
            LabeledContent("Notification Center", value: settingDescription(notificationStatus?.appearsInNotificationCenter))
                .appHelp("Shows whether DownAudible notifications can appear in Notification Center.")
            LabeledContent("Banners and Alerts", value: settingDescription(notificationStatus?.showsBanners))
                .appHelp("Shows whether macOS can show DownAudible banners or alerts on screen.")

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
        Picker("Sound", selection: previewing(sound.source)) {
            ForEach(QueueCompletionSound.Source.allCases.filter { $0 != .off }) { source in
                Text(source.displayName).tag(source)
            }
        }
        .appHelp("Choose a macOS sound, a built-in chime, or an audio file. Each new sound plays as you select it.")

        switch selected.source {
        case .off:
            EmptyView()
        case .system:
            Picker("macOS sound", selection: previewing(sound.systemName)) {
                let sounds = QueueCompletionSoundPlayer.systemSounds.map(QueueCompletionSoundPlayer.systemName(for:))
                if !sounds.contains(selected.systemName) {
                    Text("Selected sound unavailable").tag(selected.systemName)
                }
                ForEach(sounds, id: \.self) { sound in Text(sound).tag(sound) }
            }
            .appHelp("Choose and hear one of the sounds installed with macOS.")
        case .builtIn:
            Picker("Chime", selection: previewing(sound.chime)) {
                ForEach(QueueCompletionSound.Chime.allCases) { chime in
                    Text(chime.displayName).tag(chime)
                }
            }
            .appHelp("Choose and hear one of the chimes included with DownAudible.")
        case .custom:
            LabeledContent("Sound file") {
                let name = selected.customFile?.name ?? "No file chosen"
                Text(name).lineLimit(1).truncationMode(.middle).appHelp(name)
            }
            Button("Choose Sound File…") { choosingFile = true }
                .appHelp("Open and preview an audio file. DownAudible keeps a copy so it stays available if the original moves.")
        }
        Button("Play Sound", systemImage: "play") { preview(event) }
            .disabled(selected.source == .custom && selected.customFile == nil)
            .appHelp("Listen again to the sound for this event.")
    }

    private var settings: Binding<TransferFeedbackPreferences.Settings> {
        let event = event
        return Binding {
            model.transferFeedback[event]
        } set: { settings in
            model.transferFeedback[event] = settings
        }
    }

    private func previewing<Value: Equatable>(_ value: Binding<Value>) -> Binding<Value> {
        let event = event
        return Binding {
            value.wrappedValue
        } set: { replacement in
            guard replacement != value.wrappedValue else { return }
            value.wrappedValue = replacement
            preview(event)
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

    private func importSound(_ result: Result<URL, Error>) {
        let event = event
        importingFile = true
        Task {
            defer { importingFile = false }
            do {
                try await model.installTransferSound(from: result.get(), for: event)
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
