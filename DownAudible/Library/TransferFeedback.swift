import Foundation
import UserNotifications

nonisolated enum TransferFeedbackEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case downloadCompleted, conversionCompleted, downloadFailed, conversionFailed, queueFinished

    var id: Self { self }

    var displayName: String {
        switch self {
        case .downloadCompleted: "Download Completed"
        case .conversionCompleted: "Conversion Completed"
        case .downloadFailed: "Download Failed"
        case .conversionFailed: "Conversion Failed"
        case .queueFinished: "Queue Finished"
        }
    }
}

nonisolated struct TransferFeedbackPreferences: Codable, Sendable {
    enum Delivery: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, notificationOnly, soundOnly, both

        var id: Self { self }
        var playsSound: Bool { self == .soundOnly || self == .both }
        var postsNotification: Bool { self == .notificationOnly || self == .both }

        var displayName: String {
            switch self {
            case .off: "Off"
            case .notificationOnly: "Notification Only"
            case .soundOnly: "Sound Only"
            case .both: "Both"
            }
        }
    }

    struct Settings: Codable, Sendable {
        var sound = QueueCompletionSound()
        var delivery = Delivery.off

        private enum CodingKeys: CodingKey {
            case sound, delivery
        }

        private enum PreviousKeys: CodingKey {
            case notification
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sound = try values.decodeIfPresent(QueueCompletionSound.self, forKey: .sound) ?? QueueCompletionSound()
            if let saved = try values.decodeIfPresent(Delivery.self, forKey: .delivery) {
                delivery = saved
            } else {
                let previous = try decoder.container(keyedBy: PreviousKeys.self)
                let notified = try previous.decodeIfPresent(Bool.self, forKey: .notification) ?? false
                switch (sound.source != .off, notified) {
                case (true, true): delivery = .both
                case (true, false): delivery = .soundOnly
                case (false, true): delivery = .notificationOnly
                case (false, false): delivery = .off
                }
            }
            setDelivery(delivery)
        }

        mutating func setDelivery(_ value: Delivery) {
            delivery = value
            if delivery.playsSound && (sound.source == .off || (sound.source == .custom && sound.customFile == nil)) {
                sound.source = .builtIn
            }
        }
    }

    private var settings: [TransferFeedbackEvent: Settings] = [:]

    subscript(event: TransferFeedbackEvent) -> Settings {
        get { settings[event] ?? Settings() }
        set { settings[event] = newValue }
    }
}

nonisolated struct TransferFeedbackProgress {
    private enum Stage {
        case download, conversion
    }

    private var stage: Stage
    private var downloaded = false
    private var converted = false

    init(isDownload: Bool) {
        stage = isDownload ? .download : .conversion
    }

    mutating func record(_ milestone: ArchiveWorker.FeedbackMilestone) {
        switch milestone {
        case .downloading: stage = .download
        case .downloaded: downloaded = true
        case .preparingConversion: stage = .conversion
        case .converted: converted = true
        }
    }

    func outcomes(for status: Transfer.Status) -> [TransferFeedbackEvent] {
        var completed: [TransferFeedbackEvent] = []
        if downloaded { completed.append(.downloadCompleted) }
        if converted { completed.append(.conversionCompleted) }
        switch status {
        case .done:
            return completed
        case .failed:
            switch stage {
            case .download: return completed.filter { $0 != .downloadCompleted } + [.downloadFailed]
            case .conversion: return completed.filter { $0 != .conversionCompleted } + [.conversionFailed]
            }
        default:
            return []
        }
    }
}

nonisolated struct TransferNotificationStatus: Equatable, Sendable {
    enum Authorization: Equatable, Sendable {
        case notRequested, blocked, allowed
    }

    let authorization: Authorization
    let appearsInNotificationCenter: Bool
    let showsBanners: Bool

    var canSendTest: Bool { authorization == .allowed && appearsInNotificationCenter }

    init(authorization: UNAuthorizationStatus, notificationCenter: UNNotificationSetting, alerts: UNNotificationSetting, style: UNAlertStyle) {
        self.authorization = switch authorization {
        case .notDetermined: .notRequested
        case .denied: .blocked
        case .authorized, .provisional: .allowed
        @unknown default: .blocked
        }
        appearsInNotificationCenter = self.authorization == .allowed && notificationCenter == .enabled
        showsBanners = self.authorization == .allowed && alerts == .enabled && style != .none
    }
}

nonisolated struct TransferNotificationJob: Sendable {
    let id: UUID
    let title: String
}

nonisolated enum TransferNotificationContent {
    private static let transferIDsKey = "transferIDs"

    static func batch(_ event: TransferFeedbackEvent, jobs: [TransferNotificationJob]) -> UNMutableNotificationContent? {
        guard let firstJob = jobs.first, event != .queueFinished else { return nil }
        return make(
            title: event.displayName,
            body: jobs.count == 1 ? firstJob.title : "\(jobs.count.formatted()) jobs. Open Downloads for details.",
            transferIDs: jobs.map(\.id)
        )
    }

    static func test() -> UNMutableNotificationContent {
        make(
            title: "DownAudible Test Notification",
            body: "DownAudible can deliver alerts to Notification Center.",
            transferIDs: []
        )
    }

    static func transferIDs(in userInfo: [AnyHashable: Any]) -> [UUID] {
        let ids = userInfo[transferIDsKey] as? [String] ?? []
        return ids.compactMap(UUID.init(uuidString:))
    }

    private static func make(title: String, body: String, transferIDs: [UUID]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.userInfo = [transferIDsKey: transferIDs.map(\.uuidString)]
        return content
    }
}

@MainActor
final class TransferNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TransferNotifications()
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")

    let openRequests: AsyncStream<[UUID]>
    private nonisolated let openRequestContinuation: AsyncStream<[UUID]>.Continuation
    private let center = UNUserNotificationCenter.current()

    private override init() {
        (openRequests, openRequestContinuation) = AsyncStream.makeStream()
        super.init()
        center.delegate = self
    }

    func notificationStatus() async -> TransferNotificationStatus {
        let settings = await center.notificationSettings()
        return TransferNotificationStatus(
            authorization: settings.authorizationStatus,
            notificationCenter: settings.notificationCenterSetting,
            alerts: settings.alertSetting,
            style: settings.alertStyle
        )
    }

    func askPermission() async throws {
        guard try await center.requestAuthorization(options: [.alert]) else {
            throw TransferNotificationError.blocked
        }
    }

    func sendTestNotification() async throws {
        let status = await notificationStatus()
        switch status.authorization {
        case .notRequested: throw TransferNotificationError.notRequested
        case .blocked: throw TransferNotificationError.blocked
        case .allowed: break
        }
        guard status.canSendTest else { throw TransferNotificationError.hiddenFromNotificationCenter }
        do {
            try await deliver(TransferNotificationContent.test())
        } catch {
            throw TransferNotificationError.testDeliveryFailed
        }
    }

    func post(_ event: TransferFeedbackEvent, jobs: [TransferNotificationJob]) async {
        guard let content = TransferNotificationContent.batch(event, jobs: jobs),
              await notificationStatus().authorization == .allowed else { return }
        try? await deliver(content)
    }

    private func deliver(_ content: UNNotificationContent) async throws {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        openRequestContinuation.yield(TransferNotificationContent.transferIDs(in: response.notification.request.content.userInfo))
    }
}

nonisolated private enum TransferNotificationError: LocalizedError {
    case notRequested, blocked, hiddenFromNotificationCenter, testDeliveryFailed

    var errorDescription: String? {
        switch self {
        case .notRequested:
            "Choose Enable Notifications in DownAudible Settings before sending a test."
        case .blocked:
            "Allow notifications for DownAudible in System Settings > Notifications, then try again."
        case .hiddenFromNotificationCenter:
            "Turn on Show in Notification Center for DownAudible in System Settings > Notifications, then try again."
        case .testDeliveryFailed:
            "macOS could not schedule the test notification. Check that notifications are allowed for DownAudible in System Settings > Notifications and try again."
        }
    }
}
