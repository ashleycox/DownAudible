import Foundation

struct AudioProbe: Decodable, Sendable {
    struct Stream: Decodable, Sendable {
        struct Disposition: Decodable, Sendable {
            let attachedPicture: Int?

            private enum CodingKeys: String, CodingKey {
                case attachedPicture = "attached_pic"
            }
        }

        let index: Int
        let codecName: String?
        let codecType: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let duration: String?
        let durationTicks: Int64?
        let startTicks: Int64?
        let timeBase: String?
        let sampleRate: String?
        let channels: Int?
        let bitRate: String?
        let extradataHash: String?
        let disposition: Disposition?
        let tags: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case index, profile, width, height, duration, channels, disposition, tags
            case codecName = "codec_name"
            case codecType = "codec_type"
            case durationTicks = "duration_ts"
            case startTicks = "start_pts"
            case timeBase = "time_base"
            case sampleRate = "sample_rate"
            case bitRate = "bit_rate"
            case extradataHash = "extradata_hash"
        }

        var concatParameters: [String?] {
            [codecName, profile, sampleRate, channels.map(String.init), extradataHash]
        }
    }

    struct Format: Decodable, Sendable {
        let duration: String?
        let tags: [String: String]?
    }

    struct Chapter: Decodable, Sendable {
        let startTime: String?
        let endTime: String?
        let tags: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case tags
            case startTime = "start_time"
            case endTime = "end_time"
        }
    }

    let streams: [Stream]
    let chapters: [Chapter]
    let format: Format

    var formatTags: [String: String] {
        var tags: [String: String] = [:]
        for entry in (format.tags ?? [:]).sorted(by: { $0.key < $1.key }) {
            tags[entry.key.lowercased()] = entry.value
        }
        return tags
    }

    var audio: Stream? {
        streams.first { $0.codecType == "audio" }
    }

    var artwork: Stream? {
        streams.first {
            $0.codecType == "video" && $0.disposition?.attachedPicture == 1
                && ["mjpeg", "png"].contains($0.codecName ?? "")
                && (1...8_192).contains($0.width ?? 0) && (1...8_192).contains($0.height ?? 0)
        }
    }

    var durationSeconds: Double? {
        [audio?.duration, format.duration].lazy.compactMap { $0.flatMap(Double.init) }
            .first { $0.isFinite && $0 > 0 }
    }

    var durationMilliseconds: Int64? {
        durationSeconds.flatMap { Int64(exactly: ($0 * 1_000).rounded()) }
    }

    func chapterMarkers(numberingFrom: Int) -> [MediaChapter] {
        chapters.enumerated().compactMap { index, chapter in
            guard let start = Self.milliseconds(chapter.startTime),
                  let end = Self.milliseconds(chapter.endTime), end > start else { return nil }
            let title = chapter.tags?["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MediaChapter(
                startMilliseconds: start,
                durationMilliseconds: end - start,
                title: (title?.isEmpty == false ? title : nil) ?? "Chapter \(numberingFrom + index)"
            )
        }
    }

    static func milliseconds(_ time: String?) -> Int64? {
        guard let seconds = time.flatMap(Double.init), seconds.isFinite, seconds >= 0 else { return nil }
        return Int64(exactly: (seconds * 1_000).rounded())
    }
}
