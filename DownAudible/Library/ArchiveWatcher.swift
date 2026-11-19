import CoreServices
import Darwin
import Foundation

final class ArchiveWatcher {
    private final class Context {
        let root: String
        let changed: @Sendable () -> Void

        init(root: String, changed: @escaping @Sendable () -> Void) {
            self.root = root
            self.changed = changed
        }
    }

    private let stream: FSEventStreamRef

    init?(root: URL, changed: @escaping @Sendable () -> Void) {
        var existing = root.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            suffix.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        // FSEvents reports physical paths, including the /private prefix on system aliases.
        let path = existing.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? existing.path
        let physicalRoot = suffix.reversed().reduce(URL(filePath: path, directoryHint: .isDirectory)) {
            $0.appending(component: $1, directoryHint: .isDirectory)
        }
        let owner = Context(root: physicalRoot.path, changed: changed)
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(owner).toOpaque()
        context.retain = { pointer in
            guard let pointer else { return nil }
            _ = Unmanaged<Context>.fromOpaque(pointer).retain()
            return pointer
        }
        context.release = { pointer in
            if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, pointer, _, paths, _, _ in
                guard let pointer else { return }
                let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
                let matches = list.compactMap { $0 as? String }.contains { path in
                    context.root == "/" || path == context.root
                        || path.hasPrefix(context.root + "/") || context.root.hasPrefix(path + "/")
                }
                if matches { context.changed() }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.6,
            flags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
