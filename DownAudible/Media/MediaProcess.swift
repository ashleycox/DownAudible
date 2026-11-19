import Foundation
import Synchronization

struct MediaProcess {
    typealias Progress = @Sendable (Double?) async -> Void

    private struct Child {
        var process: Process?
        var cancelled = false
    }

    @concurrent static func run(
        _ executable: URL,
        arguments: [String],
        workingDirectory: URL,
        progress: Progress? = nil,
        durationSeconds: Double? = nil
    ) async throws -> (Int32, Data, Data) {
        try Task.checkCancellation()
        let (stdout, stderr) = try captureFiles(in: workingDirectory)
        defer {
            try? FileManager.default.removeItem(at: stdout)
            try? FileManager.default.removeItem(at: stderr)
        }

        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer {
            try? output.close()
            try? errors.close()
        }

        let status = try await withThrowingTaskGroup(of: Int32.self, returning: Int32.self) { group in
            group.addTask {
                try await launch(executable, arguments: arguments, directory: workingDirectory, output: output, errors: errors)
            }
            if let progress {
                group.addTask {
                    try await readProgress(from: stdout, durationSeconds: durationSeconds, progress: progress)
                }
            }
            defer { group.cancelAll() }
            guard let status = try await group.next() else { throw MediaError.conversionFailed }
            return status
        }

        try Task.checkCancellation()
        let log = try FileHandle(forReadingFrom: stderr)
        defer { try? log.close() }
        // One corrupt input can generate many lines. Only the initial error is needed.
        let diagnostic = try log.read(upToCount: 16_384) ?? Data()
        let data = progress == nil ? try Data(contentsOf: stdout) : Data()
        return (status, data, diagnostic)
    }

    private static func launch(
        _ executable: URL, arguments: [String], directory: URL, output: FileHandle, errors: FileHandle
    ) async throws -> Int32 {
        let child = Mutex(Child())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = errors
                var environment = ProcessInfo.processInfo.environment
                environment["FFREPORT"] = nil
                process.environment = environment
                process.terminationHandler = { process in
                    child.withLock { state in state.process = nil }
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try child.withLock { state in
                        guard !state.cancelled else { throw CancellationError() }
                        try process.run()
                        state.process = process
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            child.withLock { state in
                state.cancelled = true
                if state.process?.isRunning == true { state.process?.terminate() }
            }
        }
    }

    private static func captureFiles(in directory: URL) throws -> (URL, URL) {
        let unique = UUID().uuidString
        let output = directory.appending(path: "\(unique).out")
        let errors = directory.appending(path: "\(unique).err")
        try Data().write(to: output)
        do {
            try Data().write(to: errors)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return (output, errors)
    }

    private static func readProgress(
        from url: URL, durationSeconds: Double?, progress: Progress
    ) async throws -> Never {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var incomplete = Data()
        var lastReported = 0.0
        while true {
            try await Task.sleep(for: .milliseconds(250))
            guard let data = try handle.readToEnd(), !data.isEmpty else { continue }
            incomplete.append(data)
            guard let lineBreak = incomplete.lastIndex(of: 0x0A) else { continue }
            let lines = String(decoding: incomplete[...lineBreak], as: UTF8.self).split(separator: "\n")
            incomplete.removeSubrange(...lineBreak)
            guard let durationSeconds, durationSeconds > 0,
                  let time = lines.last(where: { $0.hasPrefix("out_time_us=") }),
                  let microseconds = Double(time.dropFirst("out_time_us=".count)) else { continue }
            let fraction = min(0.99, microseconds / 1_000_000 / durationSeconds)
            if fraction > lastReported {
                lastReported = fraction
                await progress(fraction)
            }
        }
    }
}
