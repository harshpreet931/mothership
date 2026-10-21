import Darwin
import Dispatch
import Foundation
import ShipModel
import ShipProtocol
import Synchronization

/// `mship mcp`: MCP over stdio (one JSON-RPC message per line), bridged to the control socket.
///
/// stdout carries protocol messages only; diagnostics go to stderr. Requests run concurrently;
/// `notifications/cancelled` cancels one and suppresses its response. EOF on stdin ends the
/// server once in-flight requests have answered.
enum MCPCommand {
    static func run(_ arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)  // a client that hangs up mid-write must not kill us with SIGPIPE
        let path = socketPath
        let server = MCPServer(
            caller: .fromEnvironment(), cwd: currentDirectory,
            transport: SocketControlTransport(socketPath: path, caller: .fromEnvironment()), socketPath: path
        )
        let session = StdioSession(server: server)
        let reader = Thread { session.readLoop() }
        reader.name = "mship.mcp.stdin"
        reader.start()
        dispatchMain()
    }
}

final class StdioSession: Sendable {
    let server: MCPServer
    private let inFlight = Mutex<[RPCID: Task<Void, Never>]>([:])
    private let pending = Atomic<Int>(0)
    private let writeLock = Mutex<Void>(())

    init(server: MCPServer) { self.server = server }

    func readLoop() {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var scanned = 0
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                scanned = 0
                receive(line)
            }
            scanned = buffer.count
        }
        if !buffer.isEmpty { receive(Data(buffer)) }  // a final message without a newline
        drainAndExit()
    }

    private func receive(_ line: Data) {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return }
        let message = try? JSONDecoder.ship.decode(JSONValue.self, from: line)
        if message?["method"]?.stringValue == "notifications/cancelled" {
            if let id = Self.rpcID(message?["params"]?["requestId"]) {
                inFlight.withLock { $0.removeValue(forKey: id) }?.cancel()
            }
            return
        }
        // Only requests (method + id) can be cancelled; responses and notifications can't.
        let id = message?["method"] != nil ? Self.rpcID(message?["id"]) : nil
        pending.add(1, ordering: .sequentiallyConsistent)
        let work: @Sendable () async -> Void = { [server] in
            let response = await server.handle(line: line)
            // A cancelled request was already removed; per spec its response must not be sent.
            let wanted: Bool = if let id { self.inFlight.withLock { $0.removeValue(forKey: id) } != nil } else { true }
            if let response, wanted { self.write(response) }
            self.pending.subtract(1, ordering: .sequentiallyConsistent)
        }
        if let id {
            // Register under the lock so the task can't finish (and look itself up) before it's recorded.
            inFlight.withLock { $0[id] = Task { await work() } }
        } else {
            Task { await work() }
        }
    }

    private func write(_ data: Data) {
        writeLock.withLock { _ in
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(STDOUT_FILENO, base + offset, raw.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    exit(0)  // the client closed our stdout: nobody is listening any more
                }
            }
        }
    }

    private func drainAndExit() -> Never {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while pending.load(ordering: .sequentiallyConsistent) > 0, ContinuousClock.now < deadline {
            usleep(2_000)
        }
        exit(0)
    }

    static func rpcID(_ value: JSONValue?) -> RPCID? {
        switch value {
        case .string(let string)?: .string(string)
        case .number(let number)? where number == number.rounded(): .number(Int(number))
        default: nil
        }
    }
}
