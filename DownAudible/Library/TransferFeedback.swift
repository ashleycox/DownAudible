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
        }

        mutating func setDelivery(_ value: Delivery) {
            delivery = value
            if delivery.playsSound && sound.source == .off { sound.source = .builtIn }
        }
    }

    private var settings: [TransferFeedbackEvent: Settings] = [:]

    subscript(event: TransferFeedbackEvent) -> Settings {
        get { settings[event] ?? Settings() }
        set { settings[event] = newValue }
    }
}

nonisolated struct TransferFeedbackProgress {
    var downloaded = false
    var converting = false

    func outcomes(isDownload: Bool, requestsConversion: Bool, status: Transfer.Status) -> [TransferFeedbackEvent] {
        switch status {
        case .done:
            guard isDownload else { return [.conversionCompleted] }
            var events: [TransferFeedbackEvent] = downloaded || !requestsConversion ? [.downloadCompleted] : []
            if requestsConversion { events.append(.conversionCompleted) }
            return events
        case .failed:
            guard isDownload else { return [.conversionFailed] }
            guard converting else { return [.downloadFailed] }
            return downloaded ? [.downloadCompleted, .conversionFailed] : [.conversionFailed]
        default:
            return []
        }
    }
}

@MainActor
final class TransferNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TransferNotifications()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func askPermission() async throws {
        guard try await center.requestAuthorization(options: [.alert]) else {
            throw NotificationPermissionError.denied
        }
    }

    func post(_ event: TransferFeedbackEvent, jobs: [String]) async {
        guard !jobs.isEmpty, event != .queueFinished else { return }
        let content = UNMutableNotificationContent()
        content.title = event.displayName
        content.body = jobs.count == 1 ? jobs[0] : "\(jobs.count.formatted()) jobs. Open Downloads for details."
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

private enum NotificationPermissionError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Allow notifications for DownAudible in System Settings > Notifications, then try again."
    }
}
