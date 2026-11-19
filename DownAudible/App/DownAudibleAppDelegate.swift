import AppKit

@MainActor
final class DownAudibleAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    private var awaitingTransfers = false

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
