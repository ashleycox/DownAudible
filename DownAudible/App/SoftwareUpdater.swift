import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class SoftwareUpdater {
    private struct State: Equatable {
        var canCheckForUpdates = false
        var automaticallyChecksForUpdates = false
        var automaticallyDownloadsUpdates = false
        var allowsAutomaticUpdates = false
    }

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private var state = State()

    init(delegate: any SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        let keys: [KeyPath<SPUUpdater, Bool>] = [
            \.canCheckForUpdates,
            \.automaticallyChecksForUpdates,
            \.automaticallyDownloadsUpdates,
            \.allowsAutomaticUpdates
        ]
        observations = keys.map { key in
            controller.updater.observe(key) { @Sendable [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshState()
                }
            }
        }
        refreshState()
    }

    #if HELP_SCREENSHOTS
    convenience init(helpScreenshotDelegate delegate: any SPUUpdaterDelegate) {
        self.init(delegate: delegate)
        state = State(canCheckForUpdates: true, automaticallyChecksForUpdates: true,
                      automaticallyDownloadsUpdates: false, allowsAutomaticUpdates: true)
    }
    #endif

    var canCheckForUpdates: Bool { state.canCheckForUpdates }
    var allowsAutomaticUpdates: Bool { state.allowsAutomaticUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { state.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            refreshState()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { state.automaticallyDownloadsUpdates }
        set {
            controller.updater.automaticallyDownloadsUpdates = newValue
            refreshState()
        }
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        let updater = controller.updater
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    private func refreshState() {
        let updater = controller.updater
        state = State(
            canCheckForUpdates: updater.canCheckForUpdates,
            automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
            automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
            allowsAutomaticUpdates: updater.allowsAutomaticUpdates
        )
    }
}
