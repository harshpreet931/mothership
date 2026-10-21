import Darwin
import Dispatch
import Foundation
import Synchronization

/// What a session's handler hears, on the client's private queue (not the main thread):
/// output goes straight to the terminal parser without a hop.
public enum SessionEvent: Sendable {
    case output(offset: UInt64, data: Data)
    /// Replay finished; `suffix` restores terminal modes. Live output follows.
    case replayEnd(suffix: Data)
    case exited(ExitedMessage)
    /// The host went away (crashed or was killed); the session is gone with it.
    case disconnected
}

public enum SessionHostClientError: Error, Equatable, CustomStringConvertible {
    case notRunning
    case timedOut
    case disconnected
    case protocolError(String)
    case host(ErrorMessage)

    public var description: String {
        switch self {
        case .notRunning: "mshipd isn't running"
        case .timedOut: "mshipd didn't answer"
        case .disconnected: "mshipd closed the connection"
        case .protocolError(let detail): "protocol error: \(detail)"
        case .host(let error): "mshipd: \(error.message)"
        }
    }
}

/// One connection from the app to `mshipd`, shared by every pane.
public final class SessionHostClient: Sendable {
    public let socketPath: String
    public let welcome: WelcomeMessage
    private let fd: Int32
    private let queue = DispatchQueue(label: "mothership.sessions.client", qos: .userInteractive)
    private let state: Mutex<State>
    private let writeLock = Mutex<Void>(())
    private let scratch = ReadBuffer(byteCount: 256 * 1024)

    private struct State {
        var handlers: [UUID: @Sendable (SessionEvent) -> Void] = [:]
        var pendingOpens: [UInt32: CheckedContinuation<OpenedMessage, any Error>] = [:]
        var pendingLists: [UInt32: CheckedContinuation<[SessionInfo], any Error>] = [:]
        var nextRequestID: UInt32 = 1
        var closed = false
        var decoder = FrameDecoder()
        var source: (any DispatchSourceRead)?
        var onDisconnect: (@Sendable () -> Void)?
    }

    /// Connects and exchanges hello/welcome. Fails fast (`notRunning`) when nothing listens.
    public static func connect(socketPath: String, client: String = "Mothership", timeout: Duration = .seconds(2)) throws(SessionHostClientError) -> SessionHostClient {
        var address = sockaddr_un()
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw .notRunning }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .notRunning }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard SessionHostServer.connect(fd, &address) == 0 else {
            Darwin.close(fd)
            throw .notRunning
        }
        // Synchronous hello so the caller knows the host's version before anything else.
        let hello = SessionMessage.hello(HelloMessage(client: client)).frame.encoded
        guard writeFully(fd, hello) else {
            Darwin.close(fd)
            throw .disconnected
        }
        var decoder = FrameDecoder()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var welcome: WelcomeMessage?
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while welcome == nil {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                Darwin.close(fd)
                throw .timedOut
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let millis = Int32(clamping: remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000 + 1)
            guard poll(&descriptor, 1, millis) > 0 else { continue }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else {
                Darwin.close(fd)
                throw .disconnected
            }
            chunk.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            do {
                if let frame = try decoder.next(), case .welcome(let message)? = try? SessionMessage(frame: frame) {
                    welcome = message
                }
            } catch {
                Darwin.close(fd)
                throw .protocolError("\(error)")
            }
        }
        guard let welcome else { throw .timedOut }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let client = SessionHostClient(socketPath: socketPath, fd: fd, welcome: welcome, decoder: decoder)
        client.startReading()
        return client
    }

    private init(socketPath: String, fd: Int32, welcome: WelcomeMessage, decoder: FrameDecoder) {
        self.socketPath = socketPath
        self.fd = fd
        self.welcome = welcome
        var state = State()
        state.decoder = decoder
        self.state = Mutex(state)
    }

    deinit { close() }

    public var isConnected: Bool { !state.withLock { $0.closed } }

    /// Called once, on the client queue, when the connection drops.
    public func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onDisconnect = handler }
    }

    // MARK: Sessions

    /// Routes a session's events to `handler` (on the client queue). Register before `open`.
    public func setHandler(for session: UUID, _ handler: @escaping @Sendable (SessionEvent) -> Void) {
        state.withLock { $0.handlers[session] = handler }
    }

    public func removeHandler(for session: UUID) {
        _ = state.withLock { $0.handlers.removeValue(forKey: session) }
    }

    /// Attaches to a live session or starts it. Replay (then live output) arrives on the
    /// session's handler.
    public func open(
        session: UUID, attachIfExists: Bool, spawn: SpawnSpec?, columns: UInt16, rows: UInt16, fromOffset: UInt64 = 0
    ) async throws -> OpenedMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OpenedMessage, any Error>) in
            let id: UInt32? = state.withLock { state in
                guard !state.closed else { return nil }
                let id = state.nextRequestID
                state.nextRequestID &+= 1
                state.pendingOpens[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(throwing: SessionHostClientError.disconnected)
                return
            }
            let request = OpenRequest(
                requestID: id, session: session, attachIfExists: attachIfExists, spawn: spawn, columns: columns, rows: rows,
                fromOffset: fromOffset
            )
            if !send(.open(request)), let pending = state.withLock({ $0.pendingOpens.removeValue(forKey: id) }) {
                pending.resume(throwing: SessionHostClientError.disconnected)
            }
        }
    }

    public func list() async throws -> [SessionInfo] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SessionInfo], any Error>) in
            let id: UInt32? = state.withLock { state in
                guard !state.closed else { return nil }
                let id = state.nextRequestID
                state.nextRequestID &+= 1
                state.pendingLists[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(throwing: SessionHostClientError.disconnected)
                return
            }
            if !send(.list(ListRequest(requestID: id))), let pending = state.withLock({ $0.pendingLists.removeValue(forKey: id) }) {
                pending.resume(throwing: SessionHostClientError.disconnected)
            }
        }
    }

    public func input(_ data: Data, to session: UUID) { send(.input(session: session, data: data)) }

    public func resize(_ session: UUID, columns: UInt16, rows: UInt16, widthPixels: UInt32 = 0, heightPixels: UInt32 = 0) {
        send(.resize(session: session, columns: columns, rows: rows, widthPixels: widthPixels, heightPixels: heightPixels))
    }

    public func setPaused(_ paused: Bool, session: UUID) { send(.flow(session: session, paused: paused)) }

    /// Stops streaming this session to us; it keeps running in the host.
    public func detach(_ session: UUID) {
        removeHandler(for: session)
        send(.detach(session: session))
    }

    /// Ends the session (hangs up its process group).
    public func closeSession(_ session: UUID) {
        removeHandler(for: session)
        send(.close(session: session))
    }

    public func signal(_ session: UUID, _ signal: Int32) { send(.signal(session: session, signal: signal)) }

    /// Ends every session and stops the host.
    public func shutdownHost() { send(.shutdown) }

    // MARK: I/O

    /// Thread-safe; frames from different threads never interleave. False once disconnected.
    @discardableResult
    public func send(_ message: SessionMessage) -> Bool {
        guard isConnected else { return false }
        let data = message.frame.encoded
        return writeLock.withLock { _ in Self.writeFully(fd, data, nonBlocking: true) }
    }

    /// Writes everything; with a non-blocking fd it waits for writability on EAGAIN.
    static func writeFully(_ fd: Int32, _ data: Data, nonBlocking: Bool = false) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base + offset, raw.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 5_000) <= 0 { return false }
            } else {
                return false
            }
        }
        return true
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        state.withLock { $0.source = source }
        source.resume()
        // Bytes that arrived with the welcome.
        queue.async { [weak self] in self?.drainFrames() }
    }

    private func readAvailable() {
        let buffer = scratch.bytes
        while true {
            let count = read(fd, buffer.baseAddress, buffer.count)
            if count > 0 {
                state.withLock { $0.decoder.append(UnsafeRawBufferPointer(rebasing: buffer[0..<count])) }
                drainFrames()
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return
            } else {
                close()
                return
            }
        }
    }

    private func drainFrames() {
        while true {
            let frame: Frame?
            do {
                frame = try state.withLock { (state) throws(FrameError) -> Frame? in try state.decoder.next() }
            } catch {
                close()
                return
            }
            guard let frame else { return }
            guard let message = try? SessionMessage(frame: frame) else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: SessionMessage) {
        switch message {
        case .output(let session, let offset, let data):
            handler(for: session)?(.output(offset: offset, data: data))
        case .replayEnd(let session, let suffix):
            handler(for: session)?(.replayEnd(suffix: suffix))
        case .exited(let exited):
            let handler = state.withLock { $0.handlers.removeValue(forKey: exited.session) }
            handler?(.exited(exited))
        case .opened(let opened):
            state.withLock { $0.pendingOpens.removeValue(forKey: opened.requestID) }?.resume(returning: opened)
        case .sessions(let list):
            state.withLock { $0.pendingLists.removeValue(forKey: list.requestID) }?.resume(returning: list.sessions)
        case .error(let error):
            guard let id = error.requestID else { return }
            let pending = state.withLock { state -> (CheckedContinuation<OpenedMessage, any Error>?, CheckedContinuation<[SessionInfo], any Error>?) in
                (state.pendingOpens.removeValue(forKey: id), state.pendingLists.removeValue(forKey: id))
            }
            pending.0?.resume(throwing: SessionHostClientError.host(error))
            pending.1?.resume(throwing: SessionHostClientError.host(error))
        default:
            break
        }
    }

    private func handler(for session: UUID) -> (@Sendable (SessionEvent) -> Void)? {
        state.withLock { $0.handlers[session] }
    }

    public func close() {
        let snapshot = state.withLock { state -> (handlers: [@Sendable (SessionEvent) -> Void], opens: [CheckedContinuation<OpenedMessage, any Error>], lists: [CheckedContinuation<[SessionInfo], any Error>], source: (any DispatchSourceRead)?, disconnect: (@Sendable () -> Void)?)? in
            guard !state.closed else { return nil }
            state.closed = true
            defer {
                state.handlers.removeAll()
                state.pendingOpens.removeAll()
                state.pendingLists.removeAll()
                state.onDisconnect = nil
            }
            return (Array(state.handlers.values), Array(state.pendingOpens.values), Array(state.pendingLists.values), state.source, state.onDisconnect)
        }
        guard let snapshot else { return }
        if let source = snapshot.source {
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            source.cancel()
        } else {
            Darwin.close(fd)
        }
        for pending in snapshot.opens { pending.resume(throwing: SessionHostClientError.disconnected) }
        for pending in snapshot.lists { pending.resume(throwing: SessionHostClientError.disconnected) }
        for handler in snapshot.handlers { handler(.disconnected) }
        snapshot.disconnect?()
    }
}


/// The client's read buffer, allocated once.
private final class ReadBuffer: @unchecked Sendable {
    // @unchecked: only the client's serial read queue touches the bytes.
    let bytes: UnsafeMutableRawBufferPointer
    init(byteCount: Int) { bytes = .allocate(byteCount: byteCount, alignment: 16) }
    deinit { bytes.deallocate() }
}
