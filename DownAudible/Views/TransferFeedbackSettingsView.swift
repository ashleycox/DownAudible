import SwiftUI
import UniformTypeIdentifiers

struct TransferFeedbackSettingsView: View {
    @Bindable var model: WorkspaceModel
    @State private var event = TransferFeedbackEvent.queueFinished
    @State private var choosingFile = false
    @State private var importingFile = false
    @State private var requestingPermission = false
    @State private var showingProblem = false
    @State private var problem = ""

    var body: some View {
        let selection = settings
        Section("Transfer alerts") {
            Picker("Event", selection: $event) {
                ForEach(TransferFeedbackEvent.allCases) { event in
                    Text(event.displayName).tag(event)
                }
            }
            .appHelp("Choose the transfer outcome you want to configure.")

            Picker("Delivery", selection: Binding {
                selection.wrappedValue.delivery
            } set: { delivery in
                setDelivery(delivery)
            }) {
                ForEach(TransferFeedbackPreferences.Delivery.allCases) { delivery in
                    if event != .queueFinished || !delivery.postsNotification {
                        Text(delivery.displayName).tag(delivery)
                    }
                }
            }
            .appHelp(event == .queueFinished
                ? "Play a sound when the whole queue finishes, or keep it silent."
                : "Choose a sound, a silent Notification Center alert, both, or neither for this event.")

            if selection.wrappedValue.delivery.playsSound {
                soundControls(selection.sound)
            }
        }
        .disabled(importingFile || requestingPermission)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio], onCompletion: importSound)
        .alert("Transfer Alert", isPresented: $showingProblem) {
            Button("OK", role: .cancel) {}
                .appHelp("Close this transfer alert message.")
        } message: {
            Text(problem)
        }
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

    private func setDelivery(_ delivery: TransferFeedbackPreferences.Delivery) {
        let event = event
        requestingPermission = delivery.postsNotification && !model.transferFeedback[event].delivery.postsNotification
        Task {
            defer { requestingPermission = false }
            do {
                try await model.setTransferDelivery(delivery, for: event)
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: any Error) {
        problem = error.localizedDescription
        showingProblem = true
    }
}
