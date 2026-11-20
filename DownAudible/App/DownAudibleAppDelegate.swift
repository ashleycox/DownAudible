import AppKit
import Sparkle

@MainActor
final class DownAudibleAppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    weak var model: WorkspaceModel?
    private(set) lazy var softwareUpdater = SoftwareUpdater(delegate: self)
    private var awaitingTransfers = false
    private var rejectPostponedUpdate = false
    private var transferNotificationTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = TransferNotifications.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        softwareUpdater.start()
    }

    func observeTransferNotifications(openWorkspace: @escaping @MainActor () -> Void) {
        guard transferNotificationTask == nil else { return }
        let requests = TransferNotifications.shared.openRequests
        transferNotificationTask = Task { [weak self] in
            for await ids in requests {
                guard let self else { return }
                model?.showNotifiedTransfers(ids)
                openWorkspace()
            }
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        UserDefaults.standard.bool(forKey: "HasFinishedOnboarding")
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let model, model.isTransferring || model.hasPendingQueueWrite else { return false }
        Task {
            let canInstall = await saveQueueBeforeUpdating(model)
            // Sparkle rechecks permission to relaunch when this continuation runs.
            rejectPostponedUpdate = !canInstall
            installHandler()
            rejectPostponedUpdate = false
        }
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { !rejectPostponedUpdate }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingTransfers { return .terminateLater }
        guard let model, model.isTransferring || model.hasPendingQueueWrite else { return .terminateNow }

        if model.isTransferring {
            let alert = NSAlert()
            alert.messageText = "Quit DownAudible?"
            alert.informativeText = "Transfers are in progress. Quitting stops the batch and keeps any partial downloads for next time."
            alert.addButton(withTitle: "Keep DownAudible Open")
            alert.addButton(withTitle: "Quit and Save Progress")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }

        awaitingTransfers = true
        Task {
            let canQuit = await saveQueueBeforeQuit(model)
            if !canQuit { model.resumeAfterCancelledQuit() }
            awaitingTransfers = false
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }

    private func saveQueueBeforeQuit(_ model: WorkspaceModel) async -> Bool {
        while true {
            do {
                try await model.cancelAndSaveTransfersForQuit()
                return true
            } catch {
                switch queueSaveFailureAlert(error, quitting: true) {
                case .alertSecondButtonReturn: continue
                case .alertThirdButtonReturn: return true
                default: return false
                }
            }
        }
    }

    private func saveQueueBeforeUpdating(_ model: WorkspaceModel) async -> Bool {
        while true {
            do {
                try await model.waitForTransfersBeforeUpdating()
                return true
            } catch {
                guard queueSaveFailureAlert(error, quitting: false) == .alertSecondButtonReturn else { return false }
            }
        }
    }

    private func queueSaveFailureAlert(_ error: any Error, quitting: Bool) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t save the transfer queue"
        if quitting {
            alert.informativeText = "\(error.localizedDescription) If you quit now, DownAudible may lose changes to the queue. Partial download files are still on disk."
        } else {
            alert.informativeText = "\(error.localizedDescription) DownAudible needs to save the queue before installing the update."
        }
        alert.addButton(withTitle: "Keep DownAudible Open")
        alert.addButton(withTitle: "Try Saving Again")
        if quitting { alert.addButton(withTitle: "Quit Without Saving").hasDestructiveAction = true }
        return alert.runModal()
    }
}
