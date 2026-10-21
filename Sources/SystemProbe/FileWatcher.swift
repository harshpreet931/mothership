import CoreServices
import Dispatch
import Foundation
import Synchronization

/// One file-level change reported by FSEvents.
public struct FileChange: Sendable, Equatable {
    public var path: String
    public var flags: UInt32

    public init(path: String, flags: UInt32) {
        self.path = path
        self.flags = flags
    }

    public var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
    public var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    public var isCreated: Bool { flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 }
    public var isModified: Bool { flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 }
    public var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
    /// FSEvents dropped events under this path; the consumer should rescan it.
    public var mustRescan: Bool { flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
}

/// FSEvents with file-level events, delivered as coalesced batches on an `AsyncStream`.
/// `latency` is FSEvents' own coalescing window.
public final class FileSystemWatcher: Sendable {
    public let changes: AsyncStream<[FileChange]>
    public let paths: [String]
    private let continuation: AsyncStream<[FileChange]>.Continuation
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "mothership.fsevents")
    private let stream = Mutex<FSEventStreamRef?>(nil)
    private let box: CallbackBox

    /// Lives as long as the watcher; the C callback reaches it through the context pointer.
    private final class CallbackBox: Sendable {
        let continuation: AsyncStream<[FileChange]>.Continuation
        init(_ continuation: AsyncStream<[FileChange]>.Continuation) { self.continuation = continuation }
    }

    public init(paths: [String], latency: TimeInterval = 0.3) {
        let (stream, continuation) = AsyncStream<[FileChange]>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.changes = stream
        self.continuation = continuation
        self.paths = paths
        self.latency = latency
        self.box = CallbackBox(continuation)
    }

    deinit { stop() }

    /// Returns false when no stream could be created (e.g. every path is missing).
    @discardableResult
    public func start() -> Bool {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }
        return stream.withLock { current -> Bool in
            if current != nil { return true }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil,
                copyDescription: nil
            )
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
            )
            guard
                let created = FSEventStreamCreate(
                    kCFAllocatorDefault, fileWatcherCallback, &context, existing as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
                )
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            current = created
            return true
        }
    }

    public func stop() {
        stream.withLock { current in
            guard let active = current else { return }
            FSEventStreamStop(active)
            FSEventStreamInvalidate(active)
            FSEventStreamRelease(active)
            current = nil
        }
    }

    /// Stop and end the `changes` stream.
    public func finish() {
        stop()
        continuation.finish()
    }

    fileprivate static func deliver(info: UnsafeMutableRawPointer?, count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var changes: [FileChange] = []
        changes.reserveCapacity(count)
        for index in 0..<min(count, array.count) {
            guard let path = array[index] as? String else { continue }
            changes.append(FileChange(path: path, flags: flags[index]))
        }
        if !changes.isEmpty { box.continuation.yield(changes) }
    }
}

private func fileWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    FileSystemWatcher.deliver(info: info, count: count, paths: paths, flags: flags)
}
