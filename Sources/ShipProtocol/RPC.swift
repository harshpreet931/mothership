import Foundation

/// JSON-RPC 2.0 over a Unix domain socket. Framing: one JSON object per line (`\n`).
/// A connection may carry many requests; responses may arrive out of order (match by `id`).

public enum RPCID: Sendable, Codable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct RPCRequest: Sendable, Codable, Equatable {
    public var jsonrpc: String = "2.0"
    /// Absent for notifications (fire-and-forget).
    public var id: RPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCError: Error, Sendable, Codable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ message: String = "Parse error") -> RPCError { RPCError(code: -32700, message: message) }
    public static func invalidRequest(_ message: String = "Invalid request") -> RPCError { RPCError(code: -32600, message: message) }
    public static func methodNotFound(_ method: String) -> RPCError { RPCError(code: -32601, message: "Method not found: \(method)") }
    public static func invalidParams(_ message: String) -> RPCError { RPCError(code: -32602, message: message) }
    public static func internalError(_ message: String) -> RPCError { RPCError(code: -32603, message: message) }
    /// The target surface/workspace doesn't exist.
    public static func notFound(_ message: String) -> RPCError { RPCError(code: -32004, message: message) }
    /// Refused by policy (e.g. reading another workspace's pane without opt-in).
    public static func forbidden(_ message: String) -> RPCError { RPCError(code: -32003, message: message) }
}

public struct RPCResponse: Sendable, Codable, Equatable {
    public var jsonrpc: String = "2.0"
    public var id: RPCID?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: RPCID?, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RPCID?, error: RPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// Who is on the other end of a socket connection (filled from `getpeereid` / `LOCAL_PEERPID`).
public struct ControlPeer: Sendable, Equatable {
    public var pid: Int32?
    public var uid: UInt32?

    public init(pid: Int32?, uid: UInt32?) {
        self.pid = pid
        self.uid = uid
    }
}

/// Implemented by the app; the socket server decodes requests and calls this.
public protocol ControlHandling: Sendable {
    func handle(method: String, params: JSONValue?, peer: ControlPeer) async throws(RPCError) -> JSONValue
}
