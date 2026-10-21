import Darwin
import Dispatch
import Foundation
import os
import ShipModel
import ShipProtocol

// Transport choice: POSIX sockets + Dispatch sources rather than Network.framework.
// NWListener/NWConnection don't expose the underlying descriptor, so there is no supported way
// to read peer credentials (`getpeereid`, `LOCAL_PEERPID`), which this server needs to reject
// other users and attribute requests to a process. Owning the fd also gives exact control
// over the socket file (0600, stale-file detection by probing, unlinking only our own inode)
// and costs ~300 lines of well-understood code.

public enum ControlServerError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    /// Unix socket paths must be shorter than 104 bytes on Darwin.
    case socketPathTooLong(String)
    /// Another live process is accepting connections on this path.
    case addressInUse(String)
    /// Something other than a socket exists at the path; it is never deleted.
    case pathOccupied(String)
    case system(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .alreadyRunning: "The control server is already running"
        case .socketPathTooLong(let path): "Socket path is too long (max \(UnixSocket.maxPathBytes - 1) bytes): \(path)"
        case .addressInUse(let path): "Another Mothership instance is already listening on \(path)"
        case .pathOccupied(let path): "A non-socket file is in the way at \(path)"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The control socket: newline-delimited JSON-RPC 2.0 over a Unix domain socket.
///
/// ```swift
/// let router = ControlRouter()
/// router.on(.hook) { (hook: HookEnvelope, context) in await engine.handleHook(hook) }
/// let server = ControlServer(handler: router)       // ShipPaths.socket by default
/// try await server.start()
/// ...
/// await server.stop()
/// ```
public actor ControlServer {
    public static let defaultMaxLineBytes = 8 * 1024 * 1024

    public nonisolated let socketPath: String
    public nonisolated let maxLineBytes: Int
    public nonisolated let maxConnections: Int
    private let handler: any ControlHandling
    private var listener: SocketListener?

    public init(
        socketPath: String = ShipPaths.socket.path, handler: any ControlHandling,
        maxLineBytes: Int = ControlServer.defaultMaxLineBytes, maxConnections: Int = 256
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.maxLineBytes = maxLineBytes
        self.maxConnections = maxConnections
    }

    public var isRunning: Bool { listener != nil }

    /// Live client connections (diagnostics and tests).
    public var connectionCount: Int { listener?.connectionCount ?? 0 }

    /// Creates the parent directory (0700) if needed, replaces a stale socket file only after a
    /// connect attempt proves nothing listens on it, binds (0600) and starts accepting.
    public func start() throws(ControlServerError) {
        guard listener == nil else { throw .alreadyRunning }
        let processor = RequestProcessor(handler: handler, maxLineBytes: maxLineBytes)
        let listener = try SocketListener.bind(path: socketPath, processor: processor, maxConnections: maxConnections)
        listener.start()
        self.listener = listener
    }

    /// Stops accepting, closes every connection (cancelling in-flight requests) and removes the
    /// socket file if it is still ours.
    public func stop() {
        listener?.stop()
        listener = nil
    }
}

/// Accepts connections. All mutable state is confined to `queue`.
final class SocketListener: @unchecked Sendable {
    // @unchecked: `connections`, `source` and `stopped` are only touched on `queue`; the rest is immutable.

    let path: String
    private let fd: Int32
    private let identity: (device: Int32, inode: UInt64)
    private let processor: RequestProcessor
    private let maxConnections: Int
    private let queue = DispatchQueue(label: "mothership.control.listener")
    private var source: (any DispatchSourceRead)?
    private var connections: [ObjectIdentifier: SocketConnection] = [:]
    private var stopped = false

    private static let log = Logger(subsystem: ShipInfo.bundleIdentifier, category: "control")

    private init(path: String, fd: Int32, identity: (Int32, UInt64), processor: RequestProcessor, maxConnections: Int) {
        self.path = path
        self.fd = fd
        self.identity = identity
        self.processor = processor
        self.maxConnections = maxConnections
    }

    var connectionCount: Int { queue.sync { connections.count } }

    static func bind(path: String, processor: RequestProcessor, maxConnections: Int) throws(ControlServerError) -> SocketListener {
        guard let address = UnixSocket.address(for: path) else { throw .socketPathTooLong(path) }
        try ensureParentDirectory(of: path)
        try clearStaleSocket(at: path, address: address)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system(operation: "socket", code: errno) }
        UnixSocket.configure(fd, nonBlocking: true)

        var bindAddress = address
        let bound = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw code == EADDRINUSE ? .addressInUse(path) : .system(operation: "bind", code: code)
        }
        // The parent directory is 0700 as well, so the brief window before chmod isn't exposed;
        // the peer-uid check on accept is the real gate.
        guard chmod(path, 0o600) == 0, listen(fd, 128) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw .system(operation: "listen", code: code)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw .system(operation: "stat", code: code)
        }
        return SocketListener(
            path: path, fd: fd, identity: (info.st_dev, info.st_ino), processor: processor,
            maxConnections: maxConnections
        )
    }

    func start() {
        queue.sync {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        let open: [SocketConnection] = queue.sync {
            guard !stopped else { return [] }
            stopped = true
            source?.cancel()
            source = nil
            // Only remove the socket file if it is still the one we bound (a newer instance may
            // have replaced it after declaring ours stale).
            var info = stat()
            if lstat(path, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode {
                unlink(path)
            }
            let open = Array(connections.values)
            connections.removeAll()
            return open
        }
        for connection in open { connection.shutdownNow() }
    }

    private func acceptPending() {
        while !stopped {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if code != EAGAIN {
                    Self.log.error("accept failed: \(String(cString: strerror(code)), privacy: .public)")
                }
                return
            }
            UnixSocket.configure(client, nonBlocking: true)
            let peer = Self.credentials(of: client)
            guard peer.uid == geteuid() else {
                Self.log.warning("rejected control connection from uid \(peer.uid.map(String.init) ?? "?", privacy: .public)")
                Darwin.close(client)
                continue
            }
            guard connections.count < maxConnections else {
                Self.log.warning("rejected control connection: \(self.maxConnections) already open")
                Darwin.close(client)
                continue
            }
            let connection = SocketConnection(fd: client, peer: peer, processor: processor) { [weak self] id in
                guard let self else { return }
                queue.async { self.connections[id] = nil }
            }
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }

    static func credentials(of fd: Int32) -> ControlPeer {
        var uid = uid_t()
        var gid = gid_t()
        let haveUID = getpeereid(fd, &uid, &gid) == 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let havePID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
        return ControlPeer(pid: havePID ? pid : nil, uid: haveUID ? uid : nil)
    }

    private static func ensureParentDirectory(of path: String) throws(ControlServerError) {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .system(operation: "mkdir \(parent)", code: (error as NSError).code == 0 ? EIO : Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// A socket file left by a crashed instance is removed; a live one is never stolen.
    private static func clearStaleSocket(at path: String, address: sockaddr_un) throws(ControlServerError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw .pathOccupied(path) }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw .system(operation: "socket", code: errno) }
        defer { Darwin.close(probe) }
        UnixSocket.configure(probe, nonBlocking: true)
        if UnixSocket.connect(probe, address) == 0 { throw .addressInUse(path) }
        switch errno {
        case ECONNREFUSED, ENOENT:
            if unlink(path) != 0 && errno != ENOENT { throw .system(operation: "unlink", code: errno) }
        case EAGAIN, EINPROGRESS:
            // Backlog full or connect pending: someone is listening.
            throw .addressInUse(path)
        default:
            throw .system(operation: "connect", code: errno)
        }
    }
}
