import Foundation
import Testing
import ShipModel
import ShipProtocol

@Test func hookEnvelopeRoundTripsThroughJSONValue() throws {
    let envelope = HookEnvelope(
        agent: .claude, event: "Stop", payload: Data(#"{"session_id":"abc"}"#.utf8),
        surface: SurfaceID(), workspace: WorkspaceID(), agentPID: 42, cwd: "/tmp",
        sentAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let request = RPCRequest(id: .number(1), method: ControlMethod.hook.rawValue, params: try JSONValue(encoding: envelope))
    let line = try JSONEncoder.ship.encode(request)
    #expect(!line.contains(UInt8(ascii: "\n")))
    let decoded = try JSONDecoder.ship.decode(RPCRequest.self, from: line)
    #expect(try decoded.params?.decode(HookEnvelope.self) == envelope)
}

@Test func identifiersEncodeAsBareUUIDs() throws {
    let id = SurfaceID()
    let data = try JSONEncoder.ship.encode([id])
    #expect(String(decoding: data, as: UTF8.self) == "[\"\(id.description)\"]")
    #expect(SurfaceID(string: id.description) == id)
}

@Test func agentStateCodable() throws {
    let states: [AgentState] = [.starting, .idle, .working(tool: "Bash"), .needsInput(.permission), .error("x"), .ended]
    let data = try JSONEncoder.ship.encode(states)
    #expect(try JSONDecoder.ship.decode([AgentState].self, from: data) == states)
}

@Test func longSupportDirectoriesFallBackToAShortSocketPath() {
    let short = ShipPaths.socketPath(forSupportDirectory: "/Users/u/Library/Application Support/Mothership/")
    #expect(short == "/Users/u/Library/Application Support/Mothership/control.sock")
    let deep = "/private/tmp/" + String(repeating: "scratch-", count: 12) + "home"
    let fallback = ShipPaths.socketPath(forSupportDirectory: deep)
    #expect(fallback.utf8.count < 104)
    #expect(fallback.hasSuffix(".sock"))
    #expect(fallback == ShipPaths.socketPath(forSupportDirectory: deep))
    #expect(fallback != ShipPaths.socketPath(forSupportDirectory: deep + "2"))
}
