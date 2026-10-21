import Darwin
import Foundation
import ShipProtocol

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A short unique socket path (sun_path is limited to 104 bytes, so no $TMPDIR).
func tempSocketPath(_ tag: String = "t") -> String {
    "/tmp/mship-\(tag)-\(UUID().uuidString.prefix(8)).sock"
}

/// Runs blocking work (poll, waitUntilExit) on a GCD thread. Blocking the cooperative pool
/// from many parallel tests starves the server's handler tasks and deadlocks until timeouts.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
}

/// A bare line-oriented socket client, so tests can pipeline several requests on one
/// connection and send malformed bytes the real client never would.
final class RawConnection: @unchecked Sendable {
    // @unchecked: each test uses its connection from one task at a time.

    func next(timeout: Double = 3) async -> JSONValue? {
        (try? await offPool { self.readJSON(timeout: timeout) }) ?? nil
    }

    func nextLine(timeout: Double = 3) async -> String? {
        (try? await offPool { self.readLine(timeout: timeout) }) ?? nil
    }

    let fd: Int32
    private var buffer: [UInt8] = []

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, let address = UnixSocket.address(for: path) else { throw TestFailure("socket") }
        guard UnixSocket.connect(fd, address) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw TestFailure("connect: \(String(cString: strerror(code)))")
        }
        UnixSocket.configure(fd, nonBlocking: false)
    }

    deinit { Darwin.close(fd) }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { return }
            offset += written
        }
    }

    func sendLine(_ text: String) { send(text + "\n") }

    /// The next line, or nil on timeout / EOF.
    func readLine(timeout: Double = 3) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1000) + 1) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    func readJSON(timeout: Double = 3) -> JSONValue? {
        guard let line = readLine(timeout: timeout) else { return nil }
        return try? JSONDecoder.ship.decode(JSONValue.self, from: Data(line.utf8))
    }

    func closeWrite() { shutdown(fd, SHUT_WR) }
}

/// A one-shot latch async code can wait on.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor Box<Value: Sendable> {
    private(set) var value: Value?
    func set(_ value: Value) { self.value = value }
}

/// Polls `condition` until true or the timeout passes.
func eventually(timeout: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func line(_ object: [String: JSONValue]) -> String {
    let data = (try? JSONEncoder.ship.encode(JSONValue.object(object))) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

func request(_ id: Int, _ method: String, _ params: JSONValue? = nil) -> String {
    var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
    if let params { object["params"] = params }
    return line(object)
}

extension JSONValue {
    var errorCode: Int? { self["error"]?["code"]?.intValue }
    var idInt: Int? { self["id"]?.intValue }
}
