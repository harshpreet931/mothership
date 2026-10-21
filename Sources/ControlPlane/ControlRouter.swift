import Darwin
import Foundation
import ShipModel
import ShipProtocol
import Synchronization

/// Everything a handler knows about who is calling.
public struct ControlContext: Sendable, Equatable {
    /// Kernel-verified peer credentials (pid via `LOCAL_PEERPID`, uid via `getpeereid`).
    public var peer: ControlPeer
    /// Self-reported by the client from its environment (`_caller` in params). Use it to
    /// resolve "nil = mine" defaults; don't treat it as authentication.
    public var caller: CallerContext
    public var method: String

    public init(peer: ControlPeer, caller: CallerContext = CallerContext(), method: String) {
        self.peer = peer
        self.caller = caller
        self.method = method
    }
}

/// Routes JSON-RPC methods to typed handlers.
///
/// ```swift
/// let router = ControlRouter()
/// router.on(.hook) { (hook: HookEnvelope, context) in
///     await engine.handleHook(hook)
/// }
/// router.on(.browserSnapshot) { (target: BrowserTarget, context) throws(RPCError) -> BrowserSnapshotResult in
///     guard let browser = app.browser(target.browser, workspace: context.caller.workspace) else {
///         throw .notFound("No browser pane in this workspace")
///     }
///     return try await browser.snapshot()   // any Encodable with the same JSON shape works
/// }
/// ```
///
/// Params are decoded into the handler's parameter type (missing/mistyped fields become
/// `invalidParams` with a readable message), results are encoded with `JSONEncoder.ship`.
/// Handlers may throw `RPCError` to choose the code; any other error becomes `internalError`
/// carrying its `localizedDescription`, and cancellation becomes code -32800.
/// Unknown methods get `methodNotFound`. `ping` is built in (returns `PingResult`).
/// Registration is thread-safe and may happen after the server started.
public final class ControlRouter: ControlHandling {
    public typealias RawHandler = @Sendable (JSONValue?, ControlContext) async throws -> JSONValue

    private let routes = Mutex<[String: RawHandler]>([:])

    public init() {
        on(.ping) { (_: ControlContext) in PingResult(pid: getpid()) }
    }

    /// Registers a handler whose params decode as `P`. Replaces any previous handler.
    public func on<P: Decodable & SendableMetatype, R: Encodable & SendableMetatype>(
        _ method: ControlMethod, _ handler: @escaping @Sendable (P, ControlContext) async throws -> R
    ) {
        on(method.rawValue, handler)
    }

    public func on<P: Decodable & SendableMetatype, R: Encodable & SendableMetatype>(
        _ method: String, _ handler: @escaping @Sendable (P, ControlContext) async throws -> R
    ) {
        onRaw(method) { params, context in
            let decoded: P = try Self.decodeParams(params)
            return try Self.encodeResult(try await handler(decoded, context))
        }
    }

    /// Registers a handler that takes no params.
    public func on<R: Encodable & SendableMetatype>(_ method: ControlMethod, _ handler: @escaping @Sendable (ControlContext) async throws -> R) {
        on(method.rawValue, handler)
    }

    public func on<R: Encodable & SendableMetatype>(_ method: String, _ handler: @escaping @Sendable (ControlContext) async throws -> R) {
        onRaw(method) { _, context in try Self.encodeResult(try await handler(context)) }
    }

    /// Registers an untyped handler; params arrive without the `_caller` key.
    public func onRaw(_ method: String, _ handler: @escaping RawHandler) {
        routes.withLock { $0[method] = handler }
    }

    public func remove(_ method: ControlMethod) {
        _ = routes.withLock { $0.removeValue(forKey: method.rawValue) }
    }

    public var registeredMethods: [String] { routes.withLock { Array($0.keys).sorted() } }

    public func handle(method: String, params: JSONValue?, peer: ControlPeer) async throws(RPCError) -> JSONValue {
        guard let handler = routes.withLock({ $0[method] }) else { throw .methodNotFound(method) }
        let context = ControlContext(peer: peer, caller: params?.callerContext ?? CallerContext(), method: method)
        do {
            return try await handler(params?.removingCaller, context)
        } catch let error as RPCError {
            throw error
        } catch is CancellationError {
            throw .cancelled()
        } catch {
            throw .internalError(Self.describe(error))
        }
    }

    // MARK: Coding

    static func decodeParams<P: Decodable>(_ params: JSONValue?) throws(RPCError) -> P {
        if let value = params as? P { return value }
        do {
            return try (params ?? .object([:])).decode(P.self)
        } catch let error as DecodingError {
            throw .invalidParams(describe(error))
        } catch {
            throw .invalidParams(String(describing: error))
        }
    }

    static func encodeResult<R: Encodable>(_ result: R) throws(RPCError) -> JSONValue {
        if let value = result as? JSONValue { return value }
        do {
            return try JSONValue(encoding: result)
        } catch {
            throw .internalError("Couldn't encode the result: \(error)")
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey], appending key: (any CodingKey)? = nil) -> String {
            let keys = (codingPath + (key.map { [$0] } ?? [])).map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "params" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing parameter '\(path(context.codingPath, appending: key))'"
        case .typeMismatch(let type, let context):
            return "Parameter '\(path(context.codingPath))' has the wrong type (expected \(type))"
        case .valueNotFound(let type, let context):
            return "Parameter '\(path(context.codingPath))' is null (expected \(type))"
        case .dataCorrupted(let context):
            return "Invalid value for '\(path(context.codingPath))': \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
