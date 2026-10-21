import Foundation
import Testing
import ShipModel
@testable import ShipProtocol

@Suite("Wire fast paths")
struct WireFastPathTests {
    @Test func handBuiltHookJSONMatchesCodable() throws {
        let envelope = HookEnvelope(
            agent: .claude, event: "PermissionRequest", payload: Data(#"{"tool_name":"Bash","x":"é"}"#.utf8),
            surface: SurfaceID(), workspace: WorkspaceID(), agentPID: 4242, cwd: "/Users/me/src/api",
            sentAt: Date(timeIntervalSince1970: 1_792_000_123)
        )
        #expect(envelope.wireJSON == (try JSONValue(encoding: envelope)))
        #expect(try envelope.wireJSON.decode(HookEnvelope.self) == envelope)

        let minimal = HookEnvelope(agent: .codex, event: "notify", payload: Data(), sentAt: Date(timeIntervalSince1970: 0))
        #expect(minimal.wireJSON == (try JSONValue(encoding: minimal)))
    }

    @Test func iso8601MatchesFoundation() throws {
        for interval in [0.0, 951_782_400, 1_792_000_123.75, 4_102_444_799] {
            let date = Date(timeIntervalSince1970: interval)
            let foundation = try JSONEncoder.ship.encode([date])
            #expect(String(decoding: foundation, as: UTF8.self) == "[\"\(HookEnvelope.iso8601(date))\"]".replacingOccurrences(of: "\\/", with: "/"))
        }
    }

    @Test func fastSocketPathAgreesWithShipPaths() {
        #expect(ControlSocketLocation.resolve() == ShipPaths.socket.path)
    }

    @Test func responseLinesAlwaysCarryAnID() throws {
        let line = try RPCResponse(id: nil, error: .parseError()).encodedLine()
        let value = try JSONDecoder.ship.decode(JSONValue.self, from: line)
        #expect(value["id"] == .null)
        #expect(value["jsonrpc"] == "2.0")
        let ok = try JSONDecoder.ship.decode(JSONValue.self, from: try RPCResponse(id: .string("a"), result: .null).encodedLine())
        #expect(ok["result"] == .null)
        #expect(ok["id"] == "a")
    }

    @Test func callerContextRoundTrip() {
        let caller = CallerContext(surface: SurfaceID(), workspace: WorkspaceID())
        let params = JSONValue.object(["url": "x"]).attachingCaller(caller)
        #expect(params.callerContext == caller)
        #expect(params.removingCaller == ["url": "x"])
        #expect(JSONValue.object([:]).attachingCaller(CallerContext()) == [:])
    }
}
