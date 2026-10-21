import Darwin
import Dispatch
import Foundation
import ShipModel
import Synchronization

public enum ControlClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No socket file, nothing listening on it, or it isn't a socket: Mothership isn't running.
    case appNotRunning(path: String)
    case timedOut
    /// The server closed the connection before replying.
    case disconnected
    case cancelled
    case socketPathTooLong(String)
    case io(operation: String, code: Int32)
    case malformedResponse(String)
    case encodingFailed(String)
    /// The server answered with a JSON-RPC error.
    case server(RPCError)

    public var isAppNotRunning: Bool {
        if case .appNotRunning = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .appNotRunning(let path): "Mothership isn't running (no control socket at \(path))"
        case .timedOut: "Timed out waiting for Mothership"
        case .disconnected: "Mothership closed the connection"
        case .cancelled: "Cancelled"
        case .socketPathTooLong(let path): "Socket path is too long for a Unix socket: \(path)"
        case .io(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .malformedResponse(let detail): "Malformed response from Mothership: \(detail)"
        case .encodingFailed(let detail): "Couldn't encode the request: \(detail)"
        case .server(let error): error.message
        }
    }
}

/// Unix-domain socket plumbing shared by the client and the server.
public enum UnixSocket {
    /// `sizeof(sockaddr_un.sun_path)` on Darwin, including the NUL terminator.
    public static let maxPathBytes = 104

    public static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < maxPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// `connect(2)` with the address cast `connect` wants.
    public static func connect(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Close-on-exec, no SIGPIPE, optionally non-blocking. Returns false if any fcntl failed.
    @discardableResult
    public static func configure(_ fd: Int32, nonBlocking: Bool) -> Bool {
        var ok = fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
        var one: Int32 = 1
        ok = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 && ok
        if nonBlocking {
            let flags = fcntl(fd, F_GETFL)
            ok = flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 && ok
        }
        return ok
    }
}

/// A small blocking client for the control socket, built for the `mship` CLI's latency budget:
/// no run loop, no async runtime, one `connect` + `write` + `poll`/`read`. A missing or stale
/// socket fails immediately (`ENOENT` / `ECONNREFUSED` come straight back from `connect`).
///
/// One request is in flight at a time per client (calls are serialized). `cancel()` may be
/// called from any thread and makes the in-flight call throw `.cancelled` promptly.
public final class ControlClient: Sendable {
    public let socketPath: String
    /// Attached as `_caller` to every request with object params.
    public let caller: CallerContext

    // The fd lives behind its own lock so `cancel()` can `shutdown` it without racing `close()`
    // (which could otherwise hit a reused descriptor number). I/O never holds this lock.
    private let descriptor = Mutex<Int32>(-1)
    private let cancelled = Atomic<Bool>(false)
    private let session = Mutex<Session>(Session())

    private struct Session {
        var buffer: [UInt8] = []
        var nextID = 1
    }

    public init(socketPath: String = ShipPaths.socket.path, caller: CallerContext = .fromEnvironment()) {
        self.socketPath = socketPath
        self.caller = caller
    }

    deinit {
        let fd = descriptor.withLock { $0 }
        if fd >= 0 { Darwin.close(fd) }
    }

    public var isConnected: Bool { descriptor.withLock { $0 >= 0 } }

    /// Connects if not already connected. Fails fast with `.appNotRunning` when nothing listens.
    public func connect(timeout: Duration? = .seconds(2)) throws(ControlClientError) {
        _ = try connectedDescriptor(deadline: Deadline(timeout))
    }

    /// Sends one request and waits for its response. A request without an id is sent as a
    /// notification and returns nil without waiting.
    public func send(_ request: RPCRequest, timeout: Duration? = .seconds(5)) throws(ControlClientError) -> RPCResponse? {
        let deadline = Deadline(timeout)
        return try session.withLock { (session) throws(ControlClientError) -> RPCResponse? in
            let fd = try connectedDescriptor(deadline: deadline)
            var line: Data
            do {
                line = try JSONEncoder.ship.encode(request)
            } catch {
                throw .encodingFailed(String(describing: error))
            }
            line.append(0x0A)
            try writeAll(line, to: fd, deadline: deadline)
            guard let id = request.id else { return nil }
            return try readResponse(id: id, from: fd, buffer: &session.buffer, deadline: deadline)
        }
    }

    /// Calls `method` and returns its result, throwing `.server` for JSON-RPC errors.
    public func request(_ method: String, params: JSONValue? = nil, timeout: Duration? = .seconds(5)) throws(ControlClientError) -> JSONValue {
        let id = session.withLock { session in
            defer { session.nextID += 1 }
            return session.nextID
        }
        let request = RPCRequest(id: .number(id), method: method, params: params?.attachingCaller(caller))
        guard let response = try send(request, timeout: timeout) else { return .null }
        if let error = response.error { throw .server(error) }
        return response.result ?? .null
    }

    /// Fire-and-forget: the server runs the method but sends no response.
    public func notify(_ method: String, params: JSONValue? = nil, timeout: Duration? = .seconds(2)) throws(ControlClientError) {
        _ = try send(RPCRequest(id: nil, method: method, params: params?.attachingCaller(caller)), timeout: timeout)
    }

    /// Typed convenience: encodes `params`, calls `method`, decodes the result as `R`.
    public func call<P: Encodable, R: Decodable>(
        _ method: ControlMethod, _ params: P, as type: R.Type = R.self, timeout: Duration? = .seconds(5)
    ) throws(ControlClientError) -> R {
        let encoded: JSONValue
        do {
            encoded = try JSONValue(encoding: params)
        } catch {
            throw .encodingFailed(String(describing: error))
        }
        let result = try request(method.rawValue, params: encoded, timeout: timeout)
        do {
            return try result.decode(R.self)
        } catch {
            throw .malformedResponse("couldn't decode \(R.self): \(error)")
        }
    }

    /// Makes the in-flight call (and any later one) throw `.cancelled`. Safe from any thread.
    public func cancel() {
        cancelled.store(true, ordering: .sequentiallyConsistent)
        descriptor.withLock { fd in
            if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    public func close() {
        descriptor.withLock { fd in
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    // MARK: - I/O

    private func connectedDescriptor(deadline: Deadline) throws(ControlClientError) -> Int32 {
        if isCancelled { throw .cancelled }
        let existing = descriptor.withLock { $0 }
        if existing >= 0 { return existing }
        let fd = try Self.open(path: socketPath, deadline: deadline)
        descriptor.withLock { $0 = fd }
        if isCancelled { cancel(); throw .cancelled }
        return fd
    }

    private var isCancelled: Bool { cancelled.load(ordering: .sequentiallyConsistent) }

    private static func open(path: String, deadline: Deadline) throws(ControlClientError) -> Int32 {
        guard let address = UnixSocket.address(for: path) else { throw .socketPathTooLong(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .io(operation: "socket", code: errno) }
        UnixSocket.configure(fd, nonBlocking: true)
        while true {
            if UnixSocket.connect(fd, address) == 0 { return fd }
            let code = errno
            switch code {
            case EINTR:
                continue
            case ENOENT, ECONNREFUSED, ENOTDIR, ENOTSOCK, EPROTOTYPE:
                Darwin.close(fd)
                throw .appNotRunning(path: path)
            case EINPROGRESS, EALREADY:
                do {
                    try waitFor(fd, events: Int16(POLLOUT), deadline: deadline) { false }
                } catch {
                    Darwin.close(fd)
                    throw error
                }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                if socketError == 0 { return fd }
                Darwin.close(fd)
                if socketError == ECONNREFUSED || socketError == ENOENT { throw .appNotRunning(path: path) }
                throw .io(operation: "connect", code: socketError)
            case EAGAIN:
                // The listen backlog is full; the app is alive but busy. Retry until the deadline.
                if deadline.hasExpired {
                    Darwin.close(fd)
                    throw .timedOut
                }
                usleep(500)
            default:
                Darwin.close(fd)
                throw .io(operation: "connect", code: code)
            }
        }
    }

    private func writeAll(_ data: Data, to fd: Int32, deadline: Deadline) throws(ControlClientError) {
        var offset = 0
        while offset < data.count {
            if isCancelled { throw .cancelled }
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + offset, raw.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            let code = errno
            if written < 0 && (code == EAGAIN || code == EINTR) {
                try Self.waitFor(fd, events: Int16(POLLOUT), deadline: deadline) { self.isCancelled }
                continue
            }
            if isCancelled { throw .cancelled }
            if code == EPIPE || code == ECONNRESET || code == ENOTCONN { throw .disconnected }
            throw .io(operation: "write", code: code)
        }
    }

    private func readResponse(id: RPCID, from fd: Int32, buffer: inout [UInt8], deadline: Deadline) throws(ControlClientError) -> RPCResponse {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var scanned = 0
        while true {
            // Drain complete lines already buffered.
            while let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                scanned = 0
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                let response: RPCResponse
                do {
                    response = try JSONDecoder.ship.decode(RPCResponse.self, from: line)
                } catch {
                    throw .malformedResponse(String(decoding: line.prefix(200), as: UTF8.self))
                }
                if response.id == id { return response }
                // A response to something else (e.g. an earlier timed-out call): skip it.
            }
            scanned = buffer.count
            try Self.waitFor(fd, events: Int16(POLLIN), deadline: deadline) { self.isCancelled }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw isCancelled ? .cancelled : .disconnected
            } else {
                let code = errno
                if code == EAGAIN || code == EINTR { continue }
                if isCancelled { throw .cancelled }
                if code == ECONNRESET { throw .disconnected }
                throw .io(operation: "read", code: code)
            }
        }
    }

    private static func waitFor(_ fd: Int32, events: Int16, deadline: Deadline, isCancelled: () -> Bool) throws(ControlClientError) {
        while true {
            let timeout = deadline.pollTimeout
            if timeout == 0 { throw .timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, timeout)
            if isCancelled() { throw .cancelled }
            if ready > 0 { return }
            if ready == 0 { throw .timedOut }
            let code = errno
            if code == EINTR { continue }
            throw .io(operation: "poll", code: code)
        }
    }
}

extension ControlClient {
    /// Runs a blocking `request` on a background thread so async callers never block the
    /// cooperative pool (a held permission hook can take minutes). Task cancellation
    /// cancels the call.
    public func requestAsync(_ method: String, params: JSONValue? = nil, timeout: Duration? = .seconds(5)) async throws(ControlClientError) -> JSONValue {
        let result: Result<JSONValue, ControlClientError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do throws(ControlClientError) {
                        continuation.resume(returning: .success(try self.request(method, params: params, timeout: timeout)))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
        return try result.get()
    }
}

/// A monotonic deadline; nil timeout = wait forever.
struct Deadline: Sendable {
    private let end: ContinuousClock.Instant?

    init(_ timeout: Duration?) {
        end = timeout.map { ContinuousClock.now.advanced(by: $0) }
    }

    var hasExpired: Bool {
        guard let end else { return false }
        return ContinuousClock.now >= end
    }

    /// Milliseconds for `poll(2)`: -1 = infinite, 0 = expired, rounded up so we never spin.
    var pollTimeout: Int32 {
        guard let end else { return -1 }
        let remaining = ContinuousClock.now.duration(to: end)
        if remaining <= .zero { return 0 }
        let (seconds, attoseconds) = remaining.components
        let millis = seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: max(1, millis))
    }
}
