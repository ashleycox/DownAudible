import Foundation

nonisolated struct AudibleTitleCheck: Decodable, Sendable {
    let asin: String
    let offers: [AudibleAudioOffer]

    func preferredOffer(for options: AudibleAPIOptions) -> AudibleAudioOffer? {
        let formats: [String] = switch options.format {
        case .aaxOnly: ["aax"]
        case .aaxcOnly: ["aaxc"]
        case .preferAAX: options.preferWidevine == true ? ["widevine", "aax", "aaxc"] : ["aax", "aaxc"]
        }
        for format in formats {
            guard let offer = offers.first(where: { $0.format == format }) else { continue }
            if offer.status == .available { return offer }
            if offer.status == .denied || offer.status == .error { return nil }
        }
        return nil
    }

    var interruption: AudibleError? {
        offers.lazy.compactMap { $0.reason.flatMap(AudibleError.init(rawValue:)) }.first { $0.interruptsQualityAudit }
    }
}

extension AudibleError {
    nonisolated var interruptsQualityAudit: Bool {
        [.rateLimited, .licenseThrottled, .authorization, .serverUnavailable].contains(self)
    }
}

nonisolated struct AudibleAudioOffer: Decodable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable {
        case available, notOffered, notChecked, denied, error

        var label: String {
            switch self {
            case .available: "Available"
            case .notOffered: "Unavailable"
            case .notChecked: "Not checked"
            case .denied: "Refused by Audible"
            case .error: "Couldn’t check"
            }
        }
    }

    let format: String
    let status: Status
    let codec: String?
    let bitrateKbps: Int?
    let bitrateEstimated: Bool?
    let channels: Int?
    let reason: String?

    var id: String { format }
    var name: String { format == "widevine" ? "Widevine stereo" : format.uppercased() }
    var explanation: String? { reason.flatMap(AudibleError.init(rawValue:))?.errorDescription }
    var specification: String {
        ([name] + [codec, bitrateKbps.map { "\(bitrateEstimated == true ? "about " : "")\($0.formatted()) kbps" }, channels.map { "\($0) channels" }]
            .compactMap { $0 }).joined(separator: " · ")
    }
}

nonisolated struct AudibleDeviceRegistration: Decodable, Equatable, Sendable {
    let kind: String
    let name: String?
    let marketplace: String
    let serialSuffix: String?

    var typeName: String {
        switch kind {
        case "android": "Android"
        case "iphone": "iPhone"
        default: "Unknown registration"
        }
    }
}

nonisolated struct AudibleListeningStatistics: Decodable, Sendable {
    let months: [AudibleListeningMonth]
}

nonisolated struct AudibleListeningMonth: Codable, Identifiable, Sendable {
    let month: String
    let durationMilliseconds: Int64

    var id: String { month }
    var year: Int? { Int(month.prefix(4)) }
    var monthNumber: Int? { Int(month.suffix(2)) }
    var listeningTime: String { Self.description(milliseconds: durationMilliseconds) }

    static func description(milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private struct ExportedDuration: Encodable {
        let hours: Int64
        let minutes: Int64
        let seconds: Int64
        let durationMilliseconds: Int64

        init(_ milliseconds: Int64) {
            durationMilliseconds = milliseconds
            let wholeSeconds = milliseconds / 1_000
            hours = wholeSeconds / 3_600
            minutes = (wholeSeconds / 60) % 60
            seconds = wholeSeconds % 60
        }
    }

    @concurrent static func export(_ months: [Self], as format: LibraryExportFormat, to path: URL) async throws {
        let data: Data
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let intervals = months.reduce(into: [String: ExportedDuration]()) { result, month in
                result[month.month] = ExportedDuration(month.durationMilliseconds)
            }
            data = try encoder.encode(intervals)
        } else {
            let durationColumn = "Duration (Milliseconds)"
            let headers = ["Month", "Listening Time", durationColumn]
            let rows = months.map { [$0.month, $0.listeningTime, String($0.durationMilliseconds)] }
            data = try format == .xlsx
                ? SpreadsheetExport.data(headers: headers, rows: rows, title: "Listening Statistics", numericHeaders: [durationColumn])
                : format.delimitedData(headers: headers, rows: rows)
        }
        try Task.checkCancellation()
        try data.write(to: path, options: .atomic)
    }
}
