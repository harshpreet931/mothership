import Darwin
import Dispatch
import Foundation
import Synchronization

/// Watches pids for exit with one kqueue (`EVFILT_PROC` / `NOTE_EXIT`) and reports them on
/// an `AsyncStream`. Costs nothing while processes are alive.
public final class ProcessExitWatcher: Sendable {
    public let exits: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private let queue = DispatchQueue(label: "mothership.exit-watcher")
    private let state: Mutex<State>

    private struct State {
        var kqueue: Int32
        var source: (any DispatchSourceRead)?
        var watched: Set<Int32> = []
    }

    public init() {
        let (stream, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .unbounded)
        self.exits = stream
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

    public var watchedPIDs: Set<Int32> { state.withLock { $0.watched } }

    /// Start watching. If the process already exited, the exit is reported immediately.
    public func watch(_ pid: Int32) {
        let (kq, isNew) = state.withLock { state -> (Int32, Bool) in
            (state.kqueue, state.watched.insert(pid).inserted)
        }
        guard isNew, kq >= 0 else { return }
        var event = kevent()
        event.ident = UInt(pid)
        event.filter = Int16(EVFILT_PROC)
        event.flags = UInt16(EV_ADD | EV_ONESHOT)
        event.fflags = NOTE_EXIT
        let result = kevent(kq, &event, 1, nil, 0, nil)
        if result < 0 {
            // ESRCH: the process is already gone.
            state.withLock { _ = $0.watched.remove(pid) }
            continuation.yield(pid)
        }
    }

    public func unwatch(_ pid: Int32) {
        let (kq, wasWatched) = state.withLock { state -> (Int32, Bool) in
            (state.kqueue, state.watched.remove(pid) != nil)
        }
        guard wasWatched, kq >= 0 else { return }
        var event = kevent()
        event.ident = UInt(pid)
        event.filter = Int16(EVFILT_PROC)
        event.flags = UInt16(EV_DELETE)
        _ = kevent(kq, &event, 1, nil, 0, nil)
    }

    public func close() {
        let (kq, source) = state.withLock { state -> (Int32, (any DispatchSourceRead)?) in
            let result = (state.kqueue, state.source)
            state.kqueue = -1
            state.source = nil
            state.watched.removeAll()
            return result
        }
        source?.cancel()
        if kq >= 0 { Darwin.close(kq) }
        continuation.finish()
    }

    private func drain() {
        let kq = state.withLock { $0.kqueue }
        guard kq >= 0 else { return }
        var events: [kevent] = Array(repeating: kevent(), count: 32)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(kq, nil, 0, &events, Int32(events.count), &timeout)
        guard count > 0 else { return }
        for event in events.prefix(Int(count)) where event.filter == Int16(EVFILT_PROC) {
            let pid = Int32(truncatingIfNeeded: event.ident)
            let removed = state.withLock { $0.watched.remove(pid) != nil }
            if removed { continuation.yield(pid) }
        }
    }
}
