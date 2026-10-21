import Foundation
import ShipProtocol

/// Turns one wire line into handler calls and a response line. Stateless; shared by all
/// connections of a server.
struct RequestProcessor: Sendable {
    let handler: any ControlHandling
    let maxLineBytes: Int

    enum Parsed: Sendable {
        /// A request with an id: run it, reply.
        case call(RPCRequest)
        /// No id: run it, never reply.
        case notification(RPCRequest)
        /// A JSON-RPC batch (non-empty array).
        case batch([JSONValue])
        /// Answer immediately without running anything (parse error, invalid request).
        case reply(RPCResponse)
        /// Blank line.
        case ignore
    }

    func parse(_ line: Data) -> Parsed {
        var line = line
        while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 { line.removeLast() }
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return .ignore }
        let decoder = JSONDecoder.ship
        // Fast path: a well-formed single request.
        if let request = try? decoder.decode(RPCRequest.self, from: line) {
            return classify(request)
        }
        guard let value = try? decoder.decode(JSONValue.self, from: line) else {
            return .reply(RPCResponse(id: nil, error: .parseError()))
        }
        if case .array(let items) = value {
            return items.isEmpty ? .reply(RPCResponse(id: nil, error: .invalidRequest("Empty batch"))) : .batch(items)
        }
        return .reply(RPCResponse(id: Self.id(in: value), error: .invalidRequest()))
    }

    private func classify(_ request: RPCRequest) -> Parsed {
        guard request.jsonrpc == "2.0" else {
            return .reply(RPCResponse(id: request.id, error: .invalidRequest("jsonrpc must be \"2.0\"")))
        }
        return request.id == nil ? .notification(request) : .call(request)
    }

    /// Runs a request and builds its response.
    func run(_ request: RPCRequest, peer: ControlPeer) async -> RPCResponse {
        do throws(RPCError) {
            let result = try await handler.handle(method: request.method, params: request.params, peer: peer)
            return RPCResponse(id: request.id, result: result)
        } catch {
            return RPCResponse(id: request.id, error: error)
        }
    }

    /// Runs a notification; errors have nowhere to go.
    func runNotification(_ request: RPCRequest, peer: ControlPeer) async {
        _ = try? await handler.handle(method: request.method, params: request.params, peer: peer)
    }

    /// Runs batch members concurrently. Returns nil when every member was a notification.
    func runBatch(_ items: [JSONValue], peer: ControlPeer) async -> Data? {
        let responses = await withTaskGroup(of: (Int, RPCResponse?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    guard let request = try? item.decode(RPCRequest.self) else {
                        return (index, RPCResponse(id: Self.id(in: item), error: .invalidRequest()))
                    }
                    switch classify(request) {
                    case .call(let call): return (index, await run(call, peer: peer))
                    case .notification(let note):
                        await runNotification(note, peer: peer)
                        return (index, nil)
                    case .reply(let reply): return (index, reply)
                    case .batch, .ignore: return (index, RPCResponse(id: nil, error: .invalidRequest()))
                    }
                }
            }
            var collected: [(Int, RPCResponse)] = []
            for await (index, response) in group {
                if let response { collected.append((index, response)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !responses.isEmpty else { return nil }
        var data = Data("[".utf8)
        for (offset, response) in responses.enumerated() {
            if offset > 0 { data.append(UInt8(ascii: ",")) }
            data.append(Self.encode(response).dropLast())
        }
        data.append(contentsOf: Array("]\n".utf8))
        return data
    }

    /// Encodes a response line, degrading to an internal error if the result can't be encoded
    /// (e.g. a NaN slipped into a JSONValue).
    static func encode(_ response: RPCResponse) -> Data {
        if let line = try? response.encodedLine() { return line }
        let fallback = RPCResponse(id: response.id, error: .internalError("Couldn't encode the result"))
        return (try? fallback.encodedLine()) ?? Data(#"{"error":{"code":-32603,"message":"Encoding failure"},"id":null,"jsonrpc":"2.0"}"#.utf8 + [0x0A])
    }

    static func oversizeResponse(limit: Int) -> Data {
        let megabytes = Double(limit) / 1_048_576
        let readable = megabytes >= 1 ? "\(Int(megabytes.rounded())) MB" : "\(limit) bytes"
        return encode(RPCResponse(id: nil, error: .invalidRequest("Request line exceeds the \(readable) limit")))
    }

    private static func id(in value: JSONValue) -> RPCID? {
        switch value["id"] {
        case .string(let string): return .string(string)
        case .number(let number) where number == number.rounded() && abs(number) < 9e15: return .number(Int(number))
        default: return nil
        }
    }
}
