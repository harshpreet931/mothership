import Foundation
import ShipModel

/// Where a control-socket request comes from, as reported by the client: the
/// `MOTHERSHIP_SURFACE_ID` / `MOTHERSHIP_WORKSPACE_ID` of the shell it runs in.
///
/// Travels inside the request's params object under `_caller`, so every params struct keeps
/// its shape (decoders ignore the extra key) and the server can scope "nil = mine" defaults
/// (e.g. `BrowserTarget.browser == nil` → the browser pane in the caller's workspace).
/// Advisory only: any same-uid process can claim any workspace, so this scopes behavior for
/// well-behaved agents; it is not an authorization boundary.
public struct CallerContext: Sendable, Codable, Equatable {
    public var surface: SurfaceID?
    public var workspace: WorkspaceID?

    public init(surface: SurfaceID? = nil, workspace: WorkspaceID? = nil) {
        self.surface = surface
        self.workspace = workspace
    }

    /// The params key the context travels under.
    public static let paramsKey = "_caller"

    public var isEmpty: Bool { surface == nil && workspace == nil }

    /// Reads the caller from this process's environment (cheap: two `getenv` calls).
    public static func fromEnvironment() -> CallerContext {
        CallerContext(
            surface: SurfaceID(string: environmentValue(ShipEnvironment.surfaceID)),
            workspace: WorkspaceID(string: environmentValue(ShipEnvironment.workspaceID))
        )
    }

    static func environmentValue(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

extension JSONValue {
    /// These params with `_caller` attached. Non-object params and empty callers are returned unchanged.
    public func attachingCaller(_ caller: CallerContext) -> JSONValue {
        guard !caller.isEmpty, case .object(var object) = self else { return self }
        var context: [String: JSONValue] = [:]
        if let surface = caller.surface { context["surface"] = .string(surface.description) }
        if let workspace = caller.workspace { context["workspace"] = .string(workspace.description) }
        object[CallerContext.paramsKey] = .object(context)
        return .object(object)
    }

    /// The `_caller` attached to these params, if any. Malformed contexts are ignored.
    public var callerContext: CallerContext {
        guard let context = self[CallerContext.paramsKey] else { return CallerContext() }
        return CallerContext(
            surface: SurfaceID(string: context["surface"]?.stringValue),
            workspace: WorkspaceID(string: context["workspace"]?.stringValue)
        )
    }

    /// These params without the `_caller` key.
    public var removingCaller: JSONValue {
        guard case .object(var object) = self, object[CallerContext.paramsKey] != nil else { return self }
        object.removeValue(forKey: CallerContext.paramsKey)
        return .object(object)
    }
}

/// Result of the built-in `ping` method. Also decodes as `OKResult`.
public struct PingResult: Sendable, Codable, Equatable {
    public var ok: Bool
    public var version: String
    /// The app's process id.
    public var pid: Int32

    public init(ok: Bool = true, version: String = ShipInfo.version, pid: Int32) {
        self.ok = ok
        self.version = version
        self.pid = pid
    }
}

extension RPCError {
    /// The request was cancelled (client disconnected or sent a cancellation). Same code as LSP.
    public static func cancelled(_ message: String = "Request cancelled") -> RPCError {
        RPCError(code: -32800, message: message)
    }
}

extension RPCResponse {
    /// One wire line (newline-terminated). Unlike the synthesized encoding, an absent id is
    /// written as `"id":null`, which JSON-RPC 2.0 requires for errors on unparseable requests.
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder.ship.encode(WireResponse(response: self))
        data.append(0x0A)
        return data
    }
}

private struct WireResponse: Encodable {
    let response: RPCResponse

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(response.jsonrpc, forKey: .jsonrpc)
        if let id = response.id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        if let error = response.error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(response.result ?? .null, forKey: .result)
        }
    }
}
