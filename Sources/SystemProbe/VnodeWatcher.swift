import CoreServices
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Per-file and per-directory change notifications with one kqueue (`EVFILT_VNODE`).
/// Works where FSEvents can't register a client, and reacts in microseconds instead of a poll
/// interval. Changes are reported with FSEvents-style flags so consumers handle both alike:
/// write/extend → `ItemModified`, delete → `ItemRemoved`, rename → `ItemRenamed`, and
/// `ItemIsDir` for directories (a directory "write" means an entry was added or removed).
/// A deleted or renamed file is unwatched automatically; watch the new file when it appears.
public final class VnodeWatcher: Sendable {
    public let changes: AsyncStream<[FileChange]>
    private let continuation: AsyncStream<[FileChange]>.Continuation
    private let queue = DispatchQueue(label: "mothership.vnode-watcher")
    private let state: Mutex<State>

    private struct Watch {
        var fd: Int32
        var isDirectory: Bool
    }

    private struct State {
        var kqueue: Int32
        var source: (any DispatchSourceRead)?
        var byPath: [String: Watch] = [:]
        var byFD: [Int32: String] = [:]
    }

    static let fileEvents = UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)

    public init() {
        let (stream, continuation) = AsyncStream<[FileChange]>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.changes = stream
        self.continuation = continuation
        let kq = kqueue()
        self.state = Mutex(State(kqueue: kq))
        guard kq >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        state.withLock { $0.source = source }
    }

    deinit { close() }

    /// Whether the kqueue was created.
    public var isHealthy: Bool { state.withLock { $0.kqueue >= 0 } }

    public var watchedPaths: Set<String> { state.withLock { Set($0.byPath.keys) } }

    public var watchedCount: Int { state.withLock { $0.byPath.count } }

    /// Start watching a file or directory. Returns false if it can't be opened.
    @discardableResult
    public func watch(_ path: String) -> Bool {
        if state.withLock({ $0.byPath[path] != nil }) { return true }
        // O_EVTONLY: no read access needed and doesn't keep the volume busy.
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var info = stat()
        let isDirectory = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        let registered = state.withLock { state -> Bool in
            guard state.kqueue >= 0, state.byPath[path] == nil else { return false }
            var event = kevent()
            event.ident = UInt(fd)
            event.filter = Int16(EVFILT_VNODE)
            event.flags = UInt16(EV_ADD | EV_CLEAR)
            event.fflags = Self.fileEvents
            guard kevent(state.kqueue, &event, 1, nil, 0, nil) == 0 else { return false }
            state.byPath[path] = Watch(fd: fd, isDirectory: isDirectory)
            state.byFD[fd] = path
            return true
        }
        if !registered { Darwin.close(fd) }
        return registered || state.withLock { $0.byPath[path] != nil }
    }

    public func unwatch(_ path: String) {
        let fd = state.withLock { state -> Int32? in
            guard let watch = state.byPath.removeValue(forKey: path) else { return nil }
            state.byFD[watch.fd] = nil
            return watch.fd
        }
        // Closing the descriptor removes its kevent.
        if let fd { Darwin.close(fd) }
    }

    public func close() {
        let (kq, source, fds) = state.withLock { state -> (Int32, (any DispatchSourceRead)?, [Int32]) in
            let result = (state.kqueue, state.source, Array(state.byFD.keys))
            state.kqueue = -1
            state.source = nil
            state.byPath.removeAll()
            state.byFD.removeAll()
            return result
        }
        source?.cancel()
        for fd in fds { Darwin.close(fd) }
        if kq >= 0 { Darwin.close(kq) }
        continuation.finish()
    }

    private func drain() {
        let kq = state.withLock { $0.kqueue }
        guard kq >= 0 else { return }
        var events: [kevent] = Array(repeating: kevent(), count: 64)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(kq, nil, 0, &events, Int32(events.count), &timeout)
        guard count > 0 else { return }
        var flagsByPath: [String: UInt32] = [:]
        var order: [String] = []
        var gone: [String] = []
        state.withLock { state in
            for event in events.prefix(Int(count)) where event.filter == Int16(EVFILT_VNODE) {
                let fd = Int32(truncatingIfNeeded: event.ident)
                guard let path = state.byFD[fd], let watch = state.byPath[path] else { continue }
                var flags: UInt32 = 0
                if event.fflags & UInt32(NOTE_WRITE | NOTE_EXTEND) != 0 { flags |= UInt32(kFSEventStreamEventFlagItemModified) }
                if event.fflags & UInt32(NOTE_DELETE | NOTE_REVOKE) != 0 { flags |= UInt32(kFSEventStreamEventFlagItemRemoved) }
                if event.fflags & UInt32(NOTE_RENAME) != 0 { flags |= UInt32(kFSEventStreamEventFlagItemRenamed) }
                if watch.isDirectory { flags |= UInt32(kFSEventStreamEventFlagItemIsDir) }
                if flagsByPath[path] == nil { order.append(path) }
                flagsByPath[path, default: 0] |= flags
                if event.fflags & UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE) != 0 { gone.append(path) }
            }
        }
        // The descriptor now refers to a deleted/moved inode; a new file at the path needs a new watch.
        for path in gone { unwatch(path) }
        let batch = order.compactMap { path in flagsByPath[path].map { FileChange(path: path, flags: $0) } }
        if !batch.isEmpty { continuation.yield(batch) }
    }
}
