import Foundation

struct LosslessChapter {
    let sourceIndex: Int
    let sampleRate: Int
    let sampleCount: Int64
    private let seekMicroseconds: Int64
    private let offsetMicroseconds: Int64
    private let lengthMicroseconds: Int64

    var seekArguments: [String] {
        guard offsetMicroseconds > 0 else { return [] }
        return ["-ss", "\(seekMicroseconds)us", "-itsoffset", "-\(offsetMicroseconds)us"]
    }

    var outputArguments: [String] {
        [
            "-c:a", "copy", "-t", "\(lengthMicroseconds)us",
            // Keep the final frame's compressed data and limit its playback duration to the chapter.
            "-bsf:a", "setts=duration='max(1,min(DURATION,\(sampleCount)-PTS))'",
            "-avoid_negative_ts", "disabled", "-use_editlist", "1", "-movie_timescale", String(sampleRate)
        ]
    }

    func matches(_ probe: AudioProbe) -> Bool {
        probe.audio?.codecName == "aac" && probe.audio?.timeBase == "1/\(sampleRate)"
            && probe.audio?.startTicks == 0 && probe.audio?.durationTicks == sampleCount
    }

    static func plan(
        _ ranges: [Range<Int64>?], sources: [AudioProbe.Stream?], enabled: Bool
    ) -> [LosslessChapter?] {
        func encodeEveryChapter() -> [LosslessChapter?] {
            Array(repeating: nil, count: ranges.count)
        }
        guard enabled, let first = sources.first.flatMap({ $0 }),
              first.codecName == "aac", first.profile == "LC",
              let rate = first.sampleRate.flatMap(Int.init), (7_350...96_000).contains(rate) else {
            return encodeEveryChapter()
        }
        let ticksPerSecond = Int64(rate)
        var sourceRanges: [Range<Int64>] = []
        var end: Int64 = 0
        for stream in sources {
            guard let stream, stream.concatParameters == first.concatParameters,
                  stream.timeBase == "1/\(rate)", stream.startTicks == 0,
                  let length = stream.durationTicks, length > 0, length <= Int64.max - end else {
                return encodeEveryChapter()
            }
            sourceRanges.append(end..<(end + length))
            end += length
        }
        return ranges.enumerated().map { index, range in
            guard let range,
                  let start = rescale(range.lowerBound, by: ticksPerSecond, over: 1_000),
                  let finish = rescale(range.upperBound, by: ticksPerSecond, over: 1_000) else { return nil }
            // Chapter starts are measured in milliseconds. The last chapter ends at the actual last sample.
            let chapterEnd = index + 1 == ranges.count ? end : finish
            guard start < chapterEnd,
                  let sourceIndex = sourceRanges.firstIndex(where: { $0.contains(start) && chapterEnd <= $0.upperBound })
            else { return nil }
            let localStart = start - sourceRanges[sourceIndex].lowerBound
            let count = chapterEnd - start
            // Include decoder preroll before the edit point for nonzero starts.
            let seek = max(0, localStart - ticksPerSecond / 4)
            guard let seekTime = rescale(seek, by: 1_000_000, over: ticksPerSecond),
                  let startTime = rescale(localStart, by: 1_000_000, over: ticksPerSecond),
                  let length = rescale(count, by: 1_000_000, over: ticksPerSecond) else { return nil }
            return LosslessChapter(
                sourceIndex: sourceIndex, sampleRate: rate, sampleCount: count,
                seekMicroseconds: seekTime, offsetMicroseconds: startTime - seekTime, lengthMicroseconds: length
            )
        }
    }

    private static func rescale(_ value: Int64, by multiplier: Int64, over divisor: Int64) -> Int64? {
        let (scaled, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow, scaled >= 0 else { return nil }
        let (quotient, remainder) = scaled.quotientAndRemainder(dividingBy: divisor)
        return quotient + (remainder * 2 >= divisor ? 1 : 0)
    }
}
