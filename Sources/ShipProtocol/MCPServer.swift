import Foundation
import ShipModel

/// How the MCP server reaches the app. The socket implementation is the real one; tests may
/// substitute their own.
public protocol ControlTransport: Sendable {
    func call(_ method: String, params: JSONValue, timeout: Duration) async throws(ControlClientError) -> JSONValue
}

/// One short-lived connection per call: tool calls are rare, and a fresh connection keeps a
/// slow call from delaying another.
public struct SocketControlTransport: ControlTransport {
    public let socketPath: String
    public let caller: CallerContext

    public init(socketPath: String = ControlSocketLocation.resolve(), caller: CallerContext = .fromEnvironment()) {
        self.socketPath = socketPath
        self.caller = caller
    }

    public func call(_ method: String, params: JSONValue, timeout: Duration) async throws(ControlClientError) -> JSONValue {
        let client = ControlClient(socketPath: socketPath, caller: caller)
        defer { client.close() }
        return try await client.requestAsync(method, params: params, timeout: timeout)
    }
}

/// The MCP server behind `mship mcp`, as a pure request → response function so it can be
/// tested without stdio. Transport framing (one JSON-RPC message per line) lives in the CLI.
///
/// Dual-era per the 2026-07-28 spec: requests carrying `_meta["io.modelcontextprotocol/protocolVersion"]`
/// are served statelessly (modern: `server/discover`, `resultType`, per-result `serverInfo`,
/// cacheable lists); `initialize` selects legacy semantics (2025-11-25 and earlier) for clients
/// that still handshake. Nothing depends on connection state either way.
public final class MCPServer: Sendable {
    public static let modernVersions = ["2026-07-28"]
    /// Newest first; `initialize` with an unknown version negotiates down to the first.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    /// MCP `UnsupportedProtocolVersionError`.
    static let unsupportedVersionCode = -32022

    public let caller: CallerContext
    public let cwd: String?
    public let tools: [MCPTool]
    private let transport: any ControlTransport
    private let socketPathForMessages: String?

    public init(
        caller: CallerContext = .fromEnvironment(), cwd: String? = FileManager.default.currentDirectoryPath,
        transport: any ControlTransport, tools: [MCPTool] = MCPToolCatalog.tools, socketPath: String? = nil
    ) {
        self.caller = caller
        self.cwd = cwd
        self.transport = transport
        self.tools = tools
        self.socketPathForMessages = socketPath
    }

    static let serverInfo: JSONValue = ["name": "mothership", "title": "Mothership", "version": .string(ShipInfo.version)]

    static var capabilities: JSONValue { ["tools": ["listChanged": false]] }

    /// Handles one wire line. Returns the response line (newline-terminated), or nil when the
    /// message was a notification or a response.
    public func handle(line: Data) async -> Data? {
        guard let message = try? JSONDecoder.ship.decode(JSONValue.self, from: line) else {
            return try? RPCResponse(id: nil, error: .parseError()).encodedLine()
        }
        // Batches were allowed in 2025-03-26.
        if case .array(let items) = message {
            guard !items.isEmpty else { return try? RPCResponse(id: nil, error: .invalidRequest("Empty batch")).encodedLine() }
            var parts: [Data] = []
            for item in items {
                guard let data = item.compactText.map({ Data($0.utf8) }), let reply = await handle(line: data) else { continue }
                parts.append(reply.dropLast())  // strip the newline
            }
            guard !parts.isEmpty else { return nil }
            var batch = Data("[".utf8)
            batch.append(Data(parts.joined(separator: Data(",".utf8))))
            batch.append(contentsOf: Array("]\n".utf8))
            return batch
        }
        // Clients don't send us responses (we never send requests), but ignore them if they do.
        if message["method"] == nil, message["result"] != nil || message["error"] != nil { return nil }
        guard let request = try? message.decode(RPCRequest.self), request.jsonrpc == "2.0" else {
            let id: RPCID? = switch message["id"] {
            case .string(let value)?: .string(value)
            case .number(let value)?: .number(Int(value))
            default: nil
            }
            return try? RPCResponse(id: id, error: .invalidRequest()).encodedLine()
        }
        guard let response = await handle(request) else { return nil }
        return (try? response.encodedLine())
            ?? (try? RPCResponse(id: request.id, error: .internalError("Couldn't encode the response")).encodedLine())
    }

    /// Handles one request; nil for notifications.
    public func handle(_ request: RPCRequest) async -> RPCResponse? {
        guard let id = request.id else { return nil }  // notifications/initialized, cancelled, …: no reply
        let meta = request.params?["_meta"]
        let modernVersion = meta?[Self.versionKey]?.stringValue
        if let modernVersion {
            guard Self.supportedVersions.contains(modernVersion) else {
                return RPCResponse(id: id, error: RPCError(
                    code: Self.unsupportedVersionCode, message: "Unsupported protocol version",
                    data: ["supported": .array(Self.supportedVersions.map(JSONValue.string)), "requested": .string(modernVersion)]
                ))
            }
            guard meta?[Self.capabilitiesKey] != nil || request.method == "server/discover" else {
                return RPCResponse(id: id, error: .invalidParams("Missing _meta[\"\(Self.capabilitiesKey)\"]"))
            }
        }
        let modern = modernVersion != nil

        let result: JSONValue
        do throws(RPCError) {
            result = try await dispatch(request, modern: modern)
        } catch {
            return RPCResponse(id: id, error: error)
        }
        guard modern, case .object(var object) = result else { return RPCResponse(id: id, result: result) }
        object["resultType"] = "complete"
        var resultMeta = object["_meta"]?.objectValue ?? [:]
        resultMeta[Self.serverInfoKey] = Self.serverInfo
        object["_meta"] = .object(resultMeta)
        return RPCResponse(id: id, result: .object(object))
    }

    private func dispatch(_ request: RPCRequest, modern: Bool) async throws(RPCError) -> JSONValue {
        switch request.method {
        case "initialize":
            let requested = request.params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
            return [
                "protocolVersion": .string(version), "capabilities": Self.capabilities,
                "serverInfo": Self.serverInfo, "instructions": .string(MCPToolCatalog.instructions),
            ]
        case "server/discover":
            return [
                "supportedVersions": .array(Self.supportedVersions.map(JSONValue.string)),
                "capabilities": Self.capabilities, "instructions": .string(MCPToolCatalog.instructions),
                "ttlMs": 3_600_000, "cacheScope": "private",
            ]
        case "ping":
            return [:]
        case "tools/list":
            var result: [String: JSONValue] = ["tools": .array(tools.map(\.definition))]
            if modern {
                result["ttlMs"] = 3_600_000
                result["cacheScope"] = "private"
            }
            return .object(result)
        case "tools/call":
            return try await callTool(request.params)
        default:
            throw .methodNotFound(request.method)
        }
    }

    private func callTool(_ params: JSONValue?) async throws(RPCError) -> JSONValue {
        guard let name = params?["name"]?.stringValue else { throw .invalidParams("tools/call needs a tool name") }
        guard let tool = tools.first(where: { $0.name == name }) else { throw .invalidParams("Unknown tool: \(name)") }
        let arguments: [String: JSONValue]
        switch params?["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default: throw .invalidParams("tools/call arguments must be an object")
        }
        let invocation = MCPToolInvocation(arguments: arguments, caller: caller, cwd: cwd)
        let output: MCPToolOutput
        do throws(MCPToolError) {
            let controlParams = try tool.makeParams(invocation)
            let result: JSONValue
            do throws(ControlClientError) {
                result = try await transport.call(tool.method.rawValue, params: controlParams, timeout: tool.timeout)
            } catch {
                throw MCPToolError(explain(error, tool: tool))
            }
            output = try tool.formatResult(result, invocation)
        } catch {
            return Self.toolResult(.text(error.message), isError: true)
        }
        return Self.toolResult(output, isError: false)
    }

    static func toolResult(_ output: MCPToolOutput, isError: Bool) -> JSONValue {
        var result: [String: JSONValue] = ["content": .array(output.content.map(\.json)), "isError": .bool(isError)]
        if let structured = output.structuredContent { result["structuredContent"] = structured }
        return .object(result)
    }

    /// Error text the model can act on.
    private func explain(_ error: ControlClientError, tool: MCPTool) -> String {
        switch error {
        case .appNotRunning(let path):
            return "Mothership isn't running (no control socket at \(socketPathForMessages ?? path)). Ask the user to open the Mothership app; \(tool.name) needs it."
        case .timedOut:
            return "Mothership didn't answer within \(tool.timeout.components.seconds) seconds."
        case .server(let rpc):
            var message = rpc.message
            if caller.isEmpty, rpc.code == RPCError.notFound("").code {
                message += " (This agent isn't running inside a Mothership terminal, so there's no \"own workspace\" to default to.)"
            }
            if rpc.code == RPCError.forbidden("").code {
                message += " (Blocked by Mothership's workspace scoping; the user can allow it in Settings.)"
            }
            return message
        default:
            return "Couldn't reach Mothership: \(error.description)"
        }
    }
}
