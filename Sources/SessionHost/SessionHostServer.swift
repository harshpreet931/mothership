import Darwin
import Dispatch
import Foundation

/// The session host behind `mshipd`: owns each pane's PTY and process, keeps the last few MB
/// of output per session, and streams to whichever app instance attaches.
///
/// Everything runs on one serial queue driven by Dispatch sources (accept, client reads and
/// writes, PTY reads and writes, process exits), so an idle host uses no CPU and there's no
/// locking. Output is fanned out to attached clients; a client that can't keep up (or asks
/// via `flow`) pauses the PTY read, so a flood blocks the program instead of buffering
/// without bound.
public final class SessionHostServer: @unchecked Sendable {
    // @unchecked: every mutable property is only touched on `queue`.

    public struct Configuration: Sendable {
        public var socketPath: String
        /// This binary, run with `--exec-child` to start each session's program.
        public var trampoline: String
        public var bufferCapacity: Int
        /// Exit this long after the last session ended with no client attached; nil = never.
        public var idleExit: Duration?
        public var log: @Sendable (String) -> Void

        public init(
            socketPath: String, trampoline: String, bufferCapacity: Int = 6 * 1024 * 1024,
            idleExit: Duration? = .seconds(10), log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.socketPath = socketPath
            self.trampoline = trampoline
            self.bufferCapacity = bufferCapacity
            self.idleExit = idleExit
            self.log = log
        }
    }

    public enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case alreadyRunning(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path): "socket path too long: \(path)"
            case .alreadyRunning(let path): "another mshipd is listening on \(path)"
            case .system(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Called (on the host queue) when the host decides to exit: idle timeout or `shutdown`.
    public var onExit: (@Sendable () -> Void)?

    let configuration: Configuration
    let queue = DispatchQueue(label: "mshipd.host", qos: .userInteractive)
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private var clients: [Int: Client] = [:]
    private var sessions: [UUID: Session] = [:]
    private var nextClientID = 1
    private var idleTimer: (any DispatchSourceTimer)?
    private var shuttingDown = false

    /// Above this many queued bytes for one client, its sessions stop reading their PTYs.
    static let clientHighWater = 8 * 1024 * 1024
    static let clientLowWater = 2 * 1024 * 1024
    static let readChunk = 64 * 1024
    static let replayChunk = 256 * 1024

    /// One read buffer for the whole host: every read happens on `queue`, one at a time.
    fileprivate let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { scratch.deallocate() }

    fileprivate func log(_ message: String) { configuration.log(message) }

    // MARK: Lifecycle

    public func start() throws(StartError) {
        let path = configuration.socketPath
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw .pathTooLong(path) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // A socket file left by a crashed host is replaced; a live one is never stolen.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw .alreadyRunning(path) }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = Self.connect(probe, &address) == 0
            close(probe)
            if connected { throw .alreadyRunning(path) }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? .alreadyRunning(path) : .system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw .system("listen", code)
        }
        listenFD = fd
        queue.sync {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.resume()
            acceptSource = source
            scheduleIdleExitIfNeeded()
        }
        log("listening on \(path) (protocol \(SessionProtocol.version), pid \(getpid()))")
    }

    /// Stops listening and ends every session (tests; `shutdown` does this on request).
    public func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(configuration.socketPath)
        }
        for client in clients.values { client.close() }
        clients.removeAll()
        for session in sessions.values { session.terminate(force: true) }
    }

    public var sessionCount: Int { queue.sync { sessions.count } }
    public var clientCount: Int { queue.sync { clients.count } }

    static func connect(_ fd: Int32, _ address: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    // MARK: Clients

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid = uid_t()
            var gid = gid_t()
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let id = nextClientID
            nextClientID += 1
            let client = Client(id: id, fd: fd, server: self)
            clients[id] = client
            client.start()
            cancelIdleExit()
        }
    }

    fileprivate func clientClosed(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        for id in client.attached {
            guard let session = sessions[id] else { continue }
            session.clients.remove(client.id)
            updateReadState(session)
        }
        scheduleIdleExitIfNeeded()
    }

    fileprivate func clientCongestionChanged(_ client: Client) {
        for id in client.attached { sessions[id].map(updateReadState) }
    }

    fileprivate func handle(_ message: SessionMessage, from client: Client) {
        switch message {
        case .hello(let hello):
            if hello.version != SessionProtocol.version {
                log("client \(hello.client) pid \(hello.pid) speaks protocol \(hello.version), host speaks \(SessionProtocol.version)")
            }
            client.send(.welcome(WelcomeMessage(pid: getpid(), sessionCount: sessions.count)))
        case .open(let request):
            open(request, for: client)
        case .input(let id, let data):
            sessions[id]?.write(data)
        case .resize(let id, let columns, let rows, let width, let height):
            sessions[id]?.resize(columns: columns, rows: rows, width: width, height: height)
        case .flow(let id, let paused):
            if paused { client.paused.insert(id) } else { client.paused.remove(id) }
            sessions[id].map(updateReadState)
        case .detach(let id):
            client.attached.remove(id)
            client.paused.remove(id)
            if let session = sessions[id] {
                session.clients.remove(client.id)
                updateReadState(session)
            }
        case .close(let id):
            guard let session = sessions[id] else { return }
            for clientID in session.clients { clients[clientID]?.attached.remove(id) }
            session.clients.removeAll()
            session.terminate(force: false)
        case .signal(let id, let signal):
            sessions[id]?.signalForeground(signal)
        case .list(let request):
            let infos = sessions.values.sorted { $0.createdAt < $1.createdAt }.map(\.info)
            client.send(.sessions(SessionsMessage(requestID: request.requestID, sessions: infos)))
        case .shutdown:
            log("shutdown requested; ending \(sessions.count) session(s)")
            shuttingDown = true
            for session in sessions.values { session.terminate(force: false) }
            if sessions.isEmpty { exitNow() }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.exitNow() }
        default:
            break  // host → client messages, ignored if echoed back
        }
    }

    // MARK: Sessions

    private func open(_ request: OpenRequest, for client: Client) {
        if request.attachIfExists, let session = sessions[request.session], !session.closing {
            attach(client, to: session, request: request)
            return
        }
        guard sessions[request.session] == nil else {
            client.send(.error(ErrorMessage(requestID: request.requestID, session: request.session, code: .badRequest, message: "session exists")))
            return
        }
        guard let spec = request.spawn else {
            client.send(.error(ErrorMessage(requestID: request.requestID, session: request.session, code: .notFound, message: "no such session")))
            return
        }
        let spawned: PTYSpawner.Spawned
        do {
            spawned = try PTYSpawner.spawn(spec, columns: request.columns, rows: request.rows, trampoline: configuration.trampoline)
        } catch {
            log("spawn failed for \(request.session): \(error)")
            client.send(.error(ErrorMessage(requestID: request.requestID, session: request.session, code: .spawnFailed, message: error.description)))
            return
        }
        let session = Session(
            id: request.session, pid: spawned.pid, master: spawned.master, capacity: configuration.bufferCapacity,
            columns: request.columns, rows: request.rows, workingDirectory: spec.workingDirectory, server: self
        )
        sessions[session.id] = session
        session.clients.insert(client.id)
        client.attached.insert(session.id)
        session.start()
        cancelIdleExit()
        log("session \(session.id) started: pid \(spawned.pid) \(spec.executable)")
        client.send(.opened(OpenedMessage(requestID: request.requestID, session: session.id, created: true, pid: session.pid, outputOffset: 0)))
        client.send(.replayEnd(session: session.id, suffix: Data()))
    }

    private func attach(_ client: Client, to session: Session, request: OpenRequest) {
        session.clients.insert(client.id)
        client.attached.insert(session.id)
        let end = session.ring.endOffset
        client.send(.opened(OpenedMessage(requestID: request.requestID, session: session.id, created: false, pid: session.pid, outputOffset: end)))
        let fullReplay = request.fromOffset == 0 || request.fromOffset < session.ring.startOffset
        let replay = session.ring.replay(from: request.fromOffset)
        var offset = replay.startOffset
        var index = replay.data.startIndex
        while index < replay.data.endIndex {
            let upper = min(index + Self.replayChunk, replay.data.endIndex)
            let chunk = replay.data.subdata(in: index..<upper)
            client.send(.output(session: session.id, offset: offset, data: chunk))
            offset += UInt64(chunk.count)
            index = upper
        }
        let suffix = fullReplay ? session.modes.restoreSequence(replayStart: replay.startOffset) : Data()
        client.send(.replayEnd(session: session.id, suffix: suffix))
        session.resize(columns: request.columns, rows: request.rows, width: 0, height: 0)
        // A full-screen program whose screen was rebuilt from a partial replay redraws on SIGWINCH.
        if fullReplay, session.modes.isAlternateScreen { session.nudgeRedraw() }
        updateReadState(session)
        log("session \(session.id) attached by client \(client.id): replayed \(replay.data.count) bytes")
    }

    fileprivate func deliver(_ data: Data, offset: UInt64, from session: Session) {
        for clientID in session.clients {
            clients[clientID]?.send(.output(session: session.id, offset: offset, data: data))
        }
    }

    fileprivate func sessionExited(_ session: Session, status: Int32) {
        let exited: ExitedMessage
        if (status & 0x7F) == 0 {
            exited = ExitedMessage(session: session.id, exitCode: (status >> 8) & 0xFF, signal: nil)
        } else {
            exited = ExitedMessage(session: session.id, exitCode: 128 + (status & 0x7F), signal: status & 0x7F)
        }
        for clientID in session.clients {
            guard let client = clients[clientID] else { continue }
            client.send(.exited(exited))
            client.attached.remove(session.id)
            client.paused.remove(session.id)
        }
        sessions[session.id] = nil
        log("session \(session.id) ended: exit \(exited.exitCode)")
        if shuttingDown, sessions.isEmpty { exitNow() }
        scheduleIdleExitIfNeeded()
    }

    /// Paused while any attached client asked to pause or can't keep up.
    fileprivate func updateReadState(_ session: Session) {
        let blocked = session.clients.contains { id in
            guard let client = clients[id] else { return false }
            return client.paused.contains(session.id) || client.isCongested
        }
        session.setReadPaused(blocked)
    }

    // MARK: Idle exit

    private func scheduleIdleExitIfNeeded() {
        guard let delay = configuration.idleExit, sessions.isEmpty, clients.isEmpty, idleTimer == nil, listenFD >= 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let (seconds, attoseconds) = delay.components
        timer.schedule(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            idleTimer = nil
            if sessions.isEmpty, clients.isEmpty {
                log("idle: no sessions and no clients; exiting")
                exitNow()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func cancelIdleExit() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func exitNow() {
        stopLocked()
        onExit?()
    }

    // MARK: - Client

    // @unchecked: confined to the host queue, like the server.
    fileprivate final class Client: @unchecked Sendable {
        let id: Int
        let fd: Int32
        unowned let server: SessionHostServer
        var attached: Set<UUID> = []
        var paused: Set<UUID> = []
        private var decoder = FrameDecoder()
        private var readSource: (any DispatchSourceRead)?
        private var writeSource: (any DispatchSourceWrite)?
        private var writing = false
        private var outbox = Data()
        private var outboxOffset = 0
        private(set) var isCongested = false
        private var closed = false

        init(id: Int, fd: Int32, server: SessionHostServer) {
            self.id = id
            self.fd = fd
            self.server = server
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: server.queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.resume()
            readSource = source
        }

        private func readAvailable() {
            let buffer = server.scratch
            while !closed {
                let count = read(fd, buffer.baseAddress, buffer.count)
                if count > 0 {
                    decoder.append(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                    drainFrames()
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    close()
                    return
                } else if errno == EAGAIN {
                    return
                }
            }
        }

        private func drainFrames() {
            while !closed {
                let frame: Frame?
                do {
                    frame = try decoder.next()
                } catch {
                    server.log("client \(id): bad frame (\(error)); disconnecting")
                    close()
                    return
                }
                guard let frame else { return }
                guard let message = try? SessionMessage(frame: frame) else { continue }  // unknown types are skipped
                server.handle(message, from: self)
            }
        }

        func send(_ message: SessionMessage) {
            guard !closed else { return }
            outbox.append(message.frame.encoded)
            flush()
        }

        private func flush() {
            while outboxOffset < outbox.count {
                let written = outbox.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return write(fd, base + outboxOffset, raw.count - outboxOffset)
                }
                if written > 0 {
                    outboxOffset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN {
                    armWriter()
                    updateCongestion()
                    return
                }
                close()
                return
            }
            outbox.removeAll(keepingCapacity: outbox.count < 1024 * 1024)
            outboxOffset = 0
            if writing {
                writeSource?.suspend()
                writing = false
            }
            updateCongestion()
        }

        private func armWriter() {
            if writeSource == nil {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: server.queue)
                source.setEventHandler { [weak self] in self?.flush() }
                writeSource = source
            }
            if !writing {
                writeSource?.resume()
                writing = true
            }
        }

        private func updateCongestion() {
            let pending = outbox.count - outboxOffset
            let congested = isCongested ? pending > SessionHostServer.clientLowWater : pending > SessionHostServer.clientHighWater
            guard congested != isCongested else { return }
            isCongested = congested
            server.log("client \(id) \(congested ? "congested" : "caught up") (\(pending) bytes queued)")
            server.clientCongestionChanged(self)
        }

        func close() {
            guard !closed else { return }
            closed = true
            readSource?.cancel()
            if let writeSource {
                if !writing { writeSource.resume() }
                writeSource.cancel()
            }
            Darwin.close(fd)
            server.clientClosed(self)
        }
    }

    // MARK: - Session

    // @unchecked: confined to the host queue, like the server.
    fileprivate final class Session: @unchecked Sendable {
        let id: UUID
        let pid: pid_t
        let master: Int32
        let createdAt = Date()
        let workingDirectory: String?
        unowned let server: SessionHostServer
        var ring: OutputRingBuffer
        var modes = TerminalModeTracker()
        var clients: Set<Int> = []
        var columns: UInt16
        var rows: UInt16
        private(set) var closing = false
        private var readSource: (any DispatchSourceRead)?
        private var readPaused = false
        private var writeSource: (any DispatchSourceWrite)?
        private var writing = false
        private var input = Data()
        private var inputOffset = 0
        private var exitSource: (any DispatchSourceProcess)?
        private var finished = false
        private var killTimer: DispatchWorkItem?

        init(
            id: UUID, pid: pid_t, master: Int32, capacity: Int, columns: UInt16, rows: UInt16,
            workingDirectory: String?, server: SessionHostServer
        ) {
            self.id = id
            self.pid = pid
            self.master = master
            self.columns = columns
            self.rows = rows
            self.workingDirectory = workingDirectory
            self.server = server
            ring = OutputRingBuffer(capacity: capacity)
        }

        var info: SessionInfo {
            SessionInfo(
                session: id, pid: pid, workingDirectory: workingDirectory, columns: columns, rows: rows,
                outputOffset: ring.endOffset, bufferedBytes: ring.count, attachedClients: clients.count, createdAt: createdAt
            )
        }

        func start() {
            let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: server.queue)
            reader.setEventHandler { [weak self] in self?.readEvent() }
            reader.resume()
            readSource = reader
            let exits = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: server.queue)
            exits.setEventHandler { [weak self] in self?.processExited() }
            exits.resume()
            exitSource = exits
        }

        /// Drains the PTY, yielding the queue every MB so other sessions and clients get a
        /// turn. Readiness isn't re-signalled for data already pending (the producer is blocked
        /// on a full PTY, so no new edge comes), so a partial drain re-queues itself.
        private func readEvent() {
            guard !readPaused, !finished else { return }
            if !readAvailable(budget: 1024 * 1024) { return }
            server.queue.async { [weak self] in self?.readEvent() }
        }

        /// Reads what the PTY has (up to `budget` bytes), records it and fans it out. True when
        /// the budget ran out with data possibly left.
        @discardableResult
        func readAvailable(budget: Int) -> Bool {
            let buffer = UnsafeMutableRawBufferPointer(rebasing: server.scratch[0..<SessionHostServer.readChunk])
            var remaining = budget
            while remaining > 0 {
                let count = read(master, buffer.baseAddress, buffer.count)
                if count > 0 {
                    remaining -= count
                    let offset = ring.endOffset
                    let bytes = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
                    ring.append(bytes)
                    modes.feed(bytes)
                    server.deliver(Data(bytes), offset: offset, from: self)
                    continue
                }
                if count < 0, errno == EINTR { continue }
                // EAGAIN: drained. EIO/0: every slave fd is closed (the program exited).
                return false
            }
            return true
        }

        func setReadPaused(_ paused: Bool) {
            guard paused != readPaused, let readSource, !finished else { return }
            readPaused = paused
            server.log("session \(id) \(paused ? "paused" : "resumed")")
            if paused {
                readSource.suspend()
            } else {
                readSource.resume()
                // Output that piled up while paused raised no new readiness event.
                server.queue.async { [weak self] in self?.readEvent() }
            }
        }

        func write(_ data: Data) {
            guard !finished else { return }
            input.append(data)
            flushInput()
        }

        private func flushInput() {
            while inputOffset < input.count {
                let written = input.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(master, base + inputOffset, raw.count - inputOffset)
                }
                if written > 0 {
                    inputOffset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN {
                    if writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: server.queue)
                        source.setEventHandler { [weak self] in self?.flushInput() }
                        writeSource = source
                    }
                    if !writing {
                        writeSource?.resume()
                        writing = true
                    }
                    return
                }
                input.removeAll()
                inputOffset = 0
                return
            }
            input.removeAll(keepingCapacity: true)
            inputOffset = 0
            if writing {
                writeSource?.suspend()
                writing = false
            }
        }

        func resize(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) {
            guard columns > 0, rows > 0, !finished else { return }
            self.columns = columns
            self.rows = rows
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: UInt16(clamping: width), ws_ypixel: UInt16(clamping: height))
            _ = ioctl(master, UInt(TIOCSWINSZ), &size)
        }

        /// Two size changes so the foreground program gets SIGWINCH and repaints, ending at
        /// the real size.
        func nudgeRedraw() {
            guard rows > 1, !finished else { return }
            var smaller = winsize(ws_row: rows - 1, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, UInt(TIOCSWINSZ), &smaller)
            let (columns, rows) = (self.columns, self.rows)
            server.queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, !self.finished else { return }
                var real = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(self.master, UInt(TIOCSWINSZ), &real)
            }
        }

        func signalForeground(_ signal: Int32) {
            let group = tcgetpgrp(master)
            if group > 0 { kill(-group, signal) } else { kill(pid, signal) }
        }

        /// Hangs up the session (as closing a terminal window does); SIGKILL if it lingers.
        func terminate(force: Bool) {
            guard !finished else { return }
            closing = true
            let group = tcgetpgrp(master)
            if group > 0 { kill(-group, SIGHUP) }
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            if force {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                return
            }
            let pid = self.pid
            let item = DispatchWorkItem {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
            killTimer = item
            server.queue.asyncAfter(deadline: .now() + 3, execute: item)
        }

        private func processExited() {
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG)
            guard reaped == pid || reaped < 0 else { return }
            // Hand over what the program wrote last before reporting the exit.
            if !readPaused { readAvailable(budget: 4 * 1024 * 1024) }
            finish(status: reaped == pid ? status : 0)
        }

        private func finish(status: Int32) {
            guard !finished else { return }
            finished = true
            killTimer?.cancel()
            if let readSource {
                if readPaused { readSource.resume() }
                readSource.cancel()
            }
            if let writeSource {
                if !writing { writeSource.resume() }
                writeSource.cancel()
            }
            exitSource?.cancel()
            // Kill anything still holding the slave (background jobs) along with the master.
            kill(-pid, SIGHUP)
            close(master)
            server.sessionExited(self, status: status)
        }
    }
}
