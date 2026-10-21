import Darwin
import Foundation
import Testing
@testable import ControlPlane
import ShipModel
import ShipProtocol

/// The `mship` binary built alongside the tests (`swift test` builds every product), or
/// `$MSHIP_BINARY` (e.g. a release build when measuring latency).
let mshipBinary: URL? = {
    let fileManager = FileManager.default
    if let override = ProcessInfo.processInfo.environment["MSHIP_BINARY"], fileManager.isExecutableFile(atPath: override) {
        return URL(fileURLWithPath: override)
    }
    var candidates: [URL] = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appending(path: "mship") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(root.appending(path: ".build/debug/mship"))
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
}()

struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var elapsed: Duration
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs `mship` with a clean MOTHERSHIP_* environment plus `environment`.
func runMship(_ arguments: [String], environment: [String: String], stdin: Data? = nil, timeout: Double = 20) async throws -> ProcessOutput {
    let binary = try #require(mshipBinary, "mship isn't built; run `swift build --product mship`")
    return try await offPool { try runMshipBlocking(binary, arguments, environment: environment, stdin: stdin, timeout: timeout) }
}

private func runMshipBlocking(_ binary: URL, _ arguments: [String], environment: [String: String], stdin: Data?, timeout: Double) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MOTHERSHIP_") }
    env.merge(environment) { _, new in new }
    process.environment = env
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    let collected = Collected()
    let group = DispatchGroup()
    for (pipe, isError) in [(output, false), (errors, true)] {
        group.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            collected.set(data, isError: isError)
            group.leave()
        }
    }
    let start = ContinuousClock.now
    try process.run()
    if let stdin { input.fileHandleForWriting.write(stdin) }
    try input.fileHandleForWriting.close()
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    process.waitUntilExit()
    let elapsed = ContinuousClock.now - start
    killer.cancel()
    group.wait()
    return ProcessOutput(status: process.terminationStatus, stdout: collected.stdout, stderr: collected.stderr, elapsed: elapsed)
}

private final class Collected: @unchecked Sendable {
    // @unchecked: guarded by `lock`.
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func set(_ data: Data, isError: Bool) { lock.withLock { if isError { err = data } else { out = data } } }
    var stdout: Data { lock.withLock { out } }
    var stderr: Data { lock.withLock { err } }
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@Suite("mship CLI", .serialized)
struct CLITests {
    @Test func hookExitsSilentlyAndQuicklyWhenAppIsNotRunning() async throws {
        let environment = ["MOTHERSHIP_SOCKET": "/tmp/mship-gone-\(UUID().uuidString.prefix(6)).sock"]
        var timings: [Double] = []
        for _ in 0..<5 {
            let result = try await runMship(["hook", "claude", "Stop"], environment: environment, stdin: Data(#"{"session_id":"s1"}"#.utf8))
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.isEmpty)
            timings.append(milliseconds(result.elapsed))
        }
        let best = timings.min() ?? 0
        print("mship hook, app not running: best \(String(format: "%.1f", best)) ms of \(timings.map { String(format: "%.1f", $0) })")
        #expect(best < 250)
    }

    @Test func hookRoundTripForwardsEnvelopeAndRelaysReply() async throws {
        let router = ControlRouter()
        let received = Box<HookEnvelope>()
        let decision = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        router.on(.hook) { (hook: HookEnvelope, _) in
            await received.set(hook)
            return HookReply(stdout: decision, exitCode: 0)
        }
        try await withServer(router) { _, path in
            let surface = SurfaceID()
            let workspace = WorkspaceID()
            let payload = Data(#"{"session_id":"abc","tool_name":"Bash","tool_input":{"command":"npm run migrate"}}"#.utf8)
            let result = try await runMship(
                ["hook", "claude", "PermissionRequest"],
                environment: [
                    "MOTHERSHIP_SOCKET": path, "MOTHERSHIP_SURFACE_ID": surface.description,
                    "MOTHERSHIP_WORKSPACE_ID": workspace.description,
                ],
                stdin: payload
            )
            #expect(result.status == 0)
            #expect(result.stdoutText == decision)
            let hook = try #require(await received.value)
            #expect(hook.agent == .claude)
            #expect(hook.event == "PermissionRequest")
            #expect(hook.payload == payload)
            #expect(hook.surface == surface)
            #expect(hook.workspace == workspace)
            #expect(hook.agentPID == getpid())  // the hook's parent is whoever ran it: us
            #expect(hook.cwd == FileManager.default.currentDirectoryPath)
        }
    }

    @Test func hookTakesCodexNotifyJSONFromArgvAndRelaysExitCode() async throws {
        let router = ControlRouter()
        let received = Box<HookEnvelope>()
        router.on(.hook) { (hook: HookEnvelope, _) in
            await received.set(hook)
            return HookReply(stdout: nil, exitCode: 2)
        }
        try await withServer(router) { _, path in
            let json = #"{"type":"agent-turn-complete","turn-id":"t1"}"#
            let result = try await runMship(["hook", "codex", "notify", json], environment: ["MOTHERSHIP_SOCKET": path], stdin: Data("ignored".utf8))
            #expect(result.status == 2)
            #expect(result.stdout.isEmpty)
            #expect(await received.value?.payload == Data(json.utf8))
            #expect(await received.value?.surface == nil)
        }
    }

    @Test func nonPermissionHookGivesUpAfterTwoSeconds() async throws {
        let router = ControlRouter()
        router.on(.hook) { (_: HookEnvelope, _) async -> HookReply in
            try? await Task.sleep(for: .seconds(10))
            return HookReply(stdout: "too late", exitCode: 1)
        }
        try await withServer(router) { _, path in
            let result = try await runMship(["hook", "claude", "Stop"], environment: ["MOTHERSHIP_SOCKET": path], stdin: Data("{}".utf8))
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.elapsed < .milliseconds(3500))
            #expect(result.elapsed >= .milliseconds(1900))
        }
    }

    @Test func permissionHookWaitsForTheDecision() async throws {
        let router = ControlRouter()
        router.on(.hook) { (_: HookEnvelope, _) async -> HookReply in
            try? await Task.sleep(for: .milliseconds(2600))
            return HookReply(stdout: "decided", exitCode: 0)
        }
        try await withServer(router) { _, path in
            let result = try await runMship(["hook", "codex", "PermissionRequest"], environment: ["MOTHERSHIP_SOCKET": path], stdin: Data("{}".utf8))
            #expect(result.status == 0)
            #expect(result.stdoutText == "decided")
        }
    }

    @Test func hookRoundTripLatency() async throws {
        let router = ControlRouter()
        router.on(.hook) { (_: HookEnvelope, _) in HookReply.passthrough }
        try await withServer(router) { _, path in
            var timings: [Double] = []
            for _ in 0..<15 {
                let result = try await runMship(["hook", "claude", "PostToolUse"], environment: ["MOTHERSHIP_SOCKET": path], stdin: Data(#"{"session_id":"s"}"#.utf8))
                #expect(result.status == 0)
                timings.append(milliseconds(result.elapsed))
            }
            timings.sort()
            print("mship hook round trip: median \(String(format: "%.1f", timings[timings.count / 2])) ms, best \(String(format: "%.1f", timings[0])) ms (process spawn included)")
            #expect(timings[timings.count / 2] < 250)
        }
    }

    @Test func splitSendsParamsAndPrintsSurface() async throws {
        let router = ControlRouter()
        let received = Box<SplitParams>()
        let created = SurfaceResult(surface: SurfaceID(), workspace: WorkspaceID())
        router.on(.surfaceSplit) { (params: SplitParams, _) in
            await received.set(params)
            return created
        }
        try await withServer(router) { _, path in
            let own = SurfaceID()
            let result = try await runMship(
                ["split", "--down", "--cwd", "/tmp", "--", "claude", "fix the tests"],
                environment: ["MOTHERSHIP_SOCKET": path, "MOTHERSHIP_SURFACE_ID": own.description]
            )
            #expect(result.status == 0)
            #expect(result.stdoutText == created.surface.description + "\n")
            let params = try #require(await received.value)
            #expect(params.direction == .down)
            #expect(params.surface == own)
            #expect(params.cwd == "/tmp")
            #expect(params.command == "claude 'fix the tests'")
            #expect(params.kind == .terminal)
        }
    }

    @Test func statusTableAndJSON() async throws {
        let workspace = WorkspaceID()
        let pane = SurfaceID()
        let permission = PermissionRequest(
            session: AgentSessionKey(kind: .claude, sessionID: "a"), surface: pane, toolName: "Bash",
            summary: "npm run migrate", expiresAt: Date().addingTimeInterval(600)
        )
        let status = StatusResult(
            workspaces: [WorkspaceSummary(id: workspace, name: "api-server", rootDirectory: "/src/api", surfaces: [pane])],
            sessions: [
                AgentSession(id: AgentSessionKey(kind: .codex, sessionID: "b"), hostApp: "Visual Studio Code", cwd: "/src/web", state: .working(tool: "Edit"), summary: "Add dark mode"),
                AgentSession(id: AgentSessionKey(kind: .claude, sessionID: "a"), surface: pane, cwd: "/src/api", state: .needsInput(.permission), pendingPermission: permission, title: "Refactor auth middleware"),
            ]
        )
        let router = ControlRouter()
        router.on(.status) { (_: StatusParams, _) in status }
        try await withServer(router) { _, path in
            let table = try await runMship(["status"], environment: ["MOTHERSHIP_SOCKET": path])
            #expect(table.status == 0)
            let lines = table.stdoutText.split(separator: "\n").map(String.init)
            print(table.stdoutText)
            #expect(lines.first?.hasPrefix("WORKSPACE") == true)
            #expect(lines[1].contains("api-server"))  // needs-you sorts first
            #expect(lines[1].contains("needs permission: Bash npm run migrate"))
            #expect(lines[2].contains("(Visual Studio Code)"))
            #expect(!table.stdoutText.contains("\u{1B}["))  // no colors when not a TTY
            #expect(table.stdoutText.contains("1 needs you"))

            let json = try await runMship(["status", "--json"], environment: ["MOTHERSHIP_SOCKET": path])
            // Compare through the wire format: ISO-8601 dates drop sub-second precision.
            let expected = try JSONValue(encoding: status).decode(StatusResult.self)
            #expect(try JSONDecoder.ship.decode(StatusResult.self, from: json.stdout) == expected)
        }
    }

    @Test func commandsReportAppNotRunning() async throws {
        let result = try await runMship(["notify", "hi"], environment: ["MOTHERSHIP_SOCKET": "/tmp/mship-gone.sock"])
        #expect(result.status == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("isn't running"))
        let usage = try await runMship(["split", "--sideways"], environment: [:])
        #expect(usage.status == 2)
    }

    @Test func mcpOverStdio() async throws {
        let router = ControlRouter()
        router.on(.browserSnapshot) { (_: BrowserTarget, _) in
            BrowserSnapshotResult(url: "http://localhost:3000/", title: "Acme", outline: "- link \"Docs\" [ref=e2]")
        }
        try await withServer(router) { _, path in
            let messages: [JSONValue] = [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]],
                ["jsonrpc": "2.0", "method": "notifications/initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "browser_snapshot", "arguments": [:]]],
                ["jsonrpc": "2.0", "id": 4, "method": "server/discover", "params": ["_meta": modernMeta()]],
            ]
            let input = messages.compactMap(\.compactText).joined(separator: "\n") + "\n"
            let result = try await runMship(["mcp"], environment: ["MOTHERSHIP_SOCKET": path], stdin: Data(input.utf8))
            #expect(result.status == 0)
            let lines = result.stdoutText.split(separator: "\n")
            #expect(lines.count == 4)
            var byID: [Int: JSONValue] = [:]
            for line in lines {
                let value = try JSONDecoder.ship.decode(JSONValue.self, from: Data(line.utf8))
                byID[value["id"]?.intValue ?? -1] = value
            }
            #expect(byID[1]?["result"]?["protocolVersion"] == "2025-11-25")
            #expect((byID[2]?["result"]?["tools"]?.arrayValue?.count ?? 0) >= 13)
            #expect(byID[3]?["result"]?.firstText?.contains("[ref=e2]") == true)
            #expect(byID[4]?["result"]?["resultType"] == "complete")
        }
    }
}
