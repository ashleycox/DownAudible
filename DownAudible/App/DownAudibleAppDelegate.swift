import AppKit
import Sparkle

@MainActor
final class DownAudibleAppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    weak var model: WorkspaceModel?
    private(set) lazy var softwareUpdater = SoftwareUpdater(delegate: self)
    private var awaitingTransfers = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        softwareUpdater.start()
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
            await model.waitForTransfersBeforeUpdating()
            installHandler()
        }
        return true
    }

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
            await model.cancelAndWaitForTransfers()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
