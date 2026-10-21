import Foundation
import Testing
@testable import ControlPlane
import ShipModel
import ShipProtocol

/// A fake app: a real ControlServer on a temp socket whose router returns canned results.
func withFakeApp(
    caller: CallerContext = CallerContext(surface: SurfaceID(), workspace: WorkspaceID()),
    configure: (ControlRouter) -> Void, _ body: (MCPServer, String) async throws -> Void
) async throws {
    let router = ControlRouter()
    configure(router)
    try await withServer(router) { _, path in
        let mcp = MCPServer(
            caller: caller, cwd: "/work/project",
            transport: SocketControlTransport(socketPath: path, caller: caller), socketPath: path
        )
        try await body(mcp, path)
    }
}

func mcpRequest(_ id: Int, _ method: String, _ params: JSONValue? = nil) -> RPCRequest {
    RPCRequest(id: .number(id), method: method, params: params)
}

func modernMeta(_ version: String = "2026-07-28", capabilities: Bool = true) -> JSONValue {
    var meta: [String: JSONValue] = [
        "io.modelcontextprotocol/protocolVersion": .string(version),
        "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
    ]
    if capabilities { meta["io.modelcontextprotocol/clientCapabilities"] = [:] }
    return .object(meta)
}

extension MCPServer {
    func call(_ tool: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let response = await handle(mcpRequest(1, "tools/call", ["name": .string(tool), "arguments": arguments]))
        if let error = response?.error { throw TestFailure("RPC error \(error.code): \(error.message)") }
        return try #require(response?.result)
    }
}

extension JSONValue {
    var firstText: String? { self["content"]?.arrayValue?.first { $0["type"] == "text" }?["text"]?.stringValue }
    var isToolError: Bool { self["isError"]?.boolValue == true }
}

@Suite("MCP")
struct MCPTests {
    let offline = MCPServer(
        caller: CallerContext(), cwd: "/tmp",
        transport: SocketControlTransport(socketPath: "/tmp/mship-absent-\(UUID().uuidString.prefix(6)).sock", caller: CallerContext())
    )

    // MARK: Lifecycle

    @Test func legacyInitializeNegotiatesVersion() async throws {
        let echoed = try #require(await offline.handle(mcpRequest(1, "initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2"],
        ]))?.result)
        #expect(echoed["protocolVersion"] == "2025-06-18")
        #expect(echoed["capabilities"]?["tools"] != nil)
        #expect(echoed["serverInfo"]?["name"] == "mothership")
        #expect(echoed["instructions"]?.stringValue?.isEmpty == false)
        #expect(echoed["resultType"] == nil)  // legacy results stay legacy-shaped

        let fallback = try #require(await offline.handle(mcpRequest(2, "initialize", ["protocolVersion": "1999-01-01", "capabilities": [:]]))?.result)
        #expect(fallback["protocolVersion"] == "2025-11-25")
    }

    @Test func notificationsGetNoResponse() async {
        #expect(await offline.handle(RPCRequest(id: nil, method: "notifications/initialized")) == nil)
        #expect(await offline.handle(RPCRequest(id: nil, method: "notifications/cancelled", params: ["requestId": 3])) == nil)
    }

    @Test func pingAndUnknownMethods() async throws {
        #expect(await offline.handle(mcpRequest(1, "ping"))?.result == [:])
        #expect(await offline.handle(mcpRequest(2, "resources/list"))?.error?.code == -32601)
    }

    @Test func modernDiscover() async throws {
        let result = try #require(await offline.handle(mcpRequest(1, "server/discover", ["_meta": modernMeta()]))?.result)
        #expect(result["resultType"] == "complete")
        #expect(result["supportedVersions"]?.arrayValue?.contains("2026-07-28") == true)
        #expect(result["supportedVersions"]?.arrayValue?.contains("2025-11-25") == true)
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "mothership")
        #expect(result["ttlMs"]?.intValue ?? 0 > 0)
    }

    @Test func modernRequestsAreValidated() async throws {
        let unsupported = try #require(await offline.handle(mcpRequest(1, "tools/list", ["_meta": modernMeta("2099-01-01")]))?.error)
        #expect(unsupported.code == -32022)
        #expect(unsupported.data?["requested"] == "2099-01-01")
        #expect(unsupported.data?["supported"]?.arrayValue?.contains("2026-07-28") == true)

        let missingCapabilities = try #require(await offline.handle(mcpRequest(2, "tools/list", ["_meta": modernMeta(capabilities: false)]))?.error)
        #expect(missingCapabilities.code == -32602)
    }

    // MARK: Tools

    @Test func toolsListIsCompleteAndWellFormed() async throws {
        let legacy = try #require(await offline.handle(mcpRequest(1, "tools/list"))?.result)
        let tools = try #require(legacy["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        let required = [
            "browser_open", "browser_snapshot", "browser_click", "browser_fill", "browser_eval", "browser_console",
            "browser_screenshot", "terminal_split", "terminal_read_screen", "terminal_send_text", "notify_user",
            "agents_status", "workspace_new",
        ]
        #expect(Set(required).isSubset(of: Set(names)))
        #expect(Set(names).count == names.count)
        let validName = /^[A-Za-z0-9_.-]{1,128}$/
        for tool in tools {
            let name = tool["name"]?.stringValue ?? ""
            #expect(name.wholeMatch(of: validName) != nil)
            #expect((tool["description"]?.stringValue?.count ?? 0) > 80, "\(name) needs a real description")
            #expect(tool["inputSchema"]?["type"] == "object")
            for key in tool["inputSchema"]?["required"]?.arrayValue ?? [] {
                #expect(tool["inputSchema"]?["properties"]?[key.stringValue ?? ""] != nil, "\(name) requires undeclared \(key)")
            }
            #expect(tool["annotations"]?["readOnlyHint"]?.boolValue != nil)
        }
        #expect(legacy["ttlMs"] == nil)

        let modern = try #require(await offline.handle(mcpRequest(2, "tools/list", ["_meta": modernMeta()]))?.result)
        #expect(modern["resultType"] == "complete")
        #expect(modern["cacheScope"] == "private")
        #expect(modern["tools"] == legacy["tools"])  // deterministic order
    }

    @Test func unknownToolIsAProtocolError() async throws {
        let response = await offline.handle(mcpRequest(1, "tools/call", ["name": "rm_rf", "arguments": [:]]))
        #expect(response?.error?.code == -32602)
        #expect(response?.error?.message.contains("rm_rf") == true)
    }

    @Test func appNotRunningIsAHelpfulToolError() async throws {
        let result = try await offline.call("browser_snapshot")
        #expect(result.isToolError)
        #expect(result.firstText?.contains("isn't running") == true)
    }

    @Test func badArgumentsAreToolErrors() async throws {
        let missing = try await offline.call("browser_click", [:])
        #expect(missing.isToolError)
        #expect(missing.firstText?.contains("ref") == true)
        let wrongType = try await offline.call("terminal_split", ["focus": "maybe"])
        #expect(wrongType.isToolError)
        let badSurface = try await offline.call("terminal_read_screen", ["surface": "not-a-uuid"])
        #expect(badSurface.isToolError)
        #expect(badSurface.firstText?.contains("surface id") == true)
    }

    @Test func snapshotThroughTheSocket() async throws {
        let seen = Box<ControlContext>()
        let caller = CallerContext(surface: SurfaceID(), workspace: WorkspaceID())
        try await withFakeApp(caller: caller, configure: { router in
            router.on(.browserSnapshot) { (target: BrowserTarget, context) in
                await seen.set(context)
                #expect(target.browser == nil)
                return BrowserSnapshotResult(url: "http://localhost:3000/", title: "Acme", outline: "- button \"Sign in\" [ref=e1]")
            }
        }) { mcp, _ in
            let result = try await mcp.call("browser_snapshot")
            #expect(!result.isToolError)
            let text = try #require(result.firstText)
            #expect(text.contains("Page: Acme"))
            #expect(text.contains("[ref=e1]"))
            #expect(await seen.value?.caller == caller)
            #expect(await seen.value?.peer.pid == getpid())
        }
    }

    @Test func screenshotReturnsImageContent() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        let path = FileManager.default.temporaryDirectory.appending(path: "mship-shot-\(UUID().uuidString).png")
        try png.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        try await withFakeApp(configure: { router in
            router.on(.browserScreenshot) { (_: BrowserTarget, _) in BrowserScreenshotResult(path: path.path) }
        }) { mcp, _ in
            let result = try await mcp.call("browser_screenshot")
            let image = try #require(result["content"]?.arrayValue?.first)
            #expect(image["type"] == "image")
            #expect(image["mimeType"] == "image/png")
            #expect(image["data"]?.stringValue == png.base64EncodedString())
            #expect(result.firstText?.contains(path.path) == true)
        }
    }

    @Test func serverErrorsBecomeToolErrors() async throws {
        try await withFakeApp(configure: { router in
            router.on(.browserClick) { (params: BrowserElementParams, _) throws(RPCError) -> OKResult in
                throw .notFound("No element matches \(params.ref). Take a new browser_snapshot.")
            }
        }) { mcp, _ in
            let result = try await mcp.call("browser_click", ["ref": "e99"])
            #expect(result.isToolError)
            #expect(result.firstText?.contains("e99") == true)
        }
    }

    @Test func splitDefaultsToCallerPaneAndCwd() async throws {
        let received = Box<SplitParams>()
        let caller = CallerContext(surface: SurfaceID(), workspace: WorkspaceID())
        let created = SurfaceResult(surface: SurfaceID(), workspace: caller.workspace ?? WorkspaceID())
        try await withFakeApp(caller: caller, configure: { router in
            router.on(.surfaceSplit) { (params: SplitParams, _) in
                await received.set(params)
                return created
            }
        }) { mcp, _ in
            let result = try await mcp.call("terminal_split", ["command": "npm run dev", "direction": "down"])
            #expect(!result.isToolError)
            #expect(result.firstText?.contains(created.surface.description) == true)
            #expect(result["structuredContent"]?["surface"]?.stringValue == created.surface.description)
            let params = try #require(await received.value)
            #expect(params.surface == caller.surface)
            #expect(params.cwd == "/work/project")
            #expect(params.command == "npm run dev")
            #expect(params.direction == .down)
            #expect(params.focus == false)
        }
    }

    @Test func evalAndConsoleFormatting() async throws {
        try await withFakeApp(configure: { router in
            router.on(.browserEval) { (params: BrowserEvalParams, _) -> JSONValue in
                params.script == "document.title" ? "Acme" : ["items": [1, 2]]
            }
            router.on(.browserConsole) { (_: BrowserTarget, _) in
                BrowserConsoleResult(entries: [
                    BrowserConsoleEntry(level: "log", message: "ready", date: Date()),
                    BrowserConsoleEntry(level: "error", message: "TypeError: x is undefined", date: Date()),
                    BrowserConsoleEntry(level: "network", message: "GET /api/me → 500", date: Date()),
                ])
            }
        }) { mcp, _ in
            #expect(try await mcp.call("browser_eval", ["script": "document.title"]).firstText == "Acme")
            #expect(try await mcp.call("browser_eval", ["script": "x"]).firstText?.contains("\"items\"") == true)
            let all = try #require(try await mcp.call("browser_console").firstText)
            #expect(all.contains("[log] ready"))
            let errors = try #require(try await mcp.call("browser_console", ["level": "errors"]).firstText)
            #expect(!errors.contains("ready"))
            #expect(errors.contains("TypeError"))
            #expect(errors.contains("→ 500"))
        }
    }

    @Test func agentsStatusIsScopedToOwnWorkspace() async throws {
        let mine = WorkspaceID()
        let other = WorkspaceID()
        let myPane = SurfaceID()
        let otherPane = SurfaceID()
        let status = StatusResult(
            workspaces: [
                WorkspaceSummary(id: mine, name: "api", rootDirectory: "/src/api", surfaces: [myPane]),
                WorkspaceSummary(id: other, name: "web", rootDirectory: "/src/web", surfaces: [otherPane]),
            ],
            sessions: [
                AgentSession(id: AgentSessionKey(kind: .claude, sessionID: "a"), surface: myPane, cwd: "/src/api", state: .working(tool: "Bash")),
                AgentSession(id: AgentSessionKey(kind: .codex, sessionID: "b"), surface: otherPane, cwd: "/src/web", state: .idle),
                AgentSession(id: AgentSessionKey(kind: .gemini, sessionID: "c"), hostApp: "iTerm2", cwd: "/x", state: .needsInput(.question)),
            ]
        )
        try await withFakeApp(caller: CallerContext(surface: myPane, workspace: mine), configure: { router in
            router.on(.status) { (_: StatusParams, _) in status }
        }) { mcp, _ in
            let scoped = try #require(try await mcp.call("agents_status").firstText)
            #expect(scoped.contains("Claude Code: working (Bash)"))
            #expect(!scoped.contains("Codex"))
            let everything = try #require(try await mcp.call("agents_status", ["all_workspaces": true]).firstText)
            #expect(everything.contains("Codex"))
            #expect(everything.contains("outside Mothership (iTerm2)"))
        }
    }

    @Test func batchesAreSupported() async throws {
        let line = Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#.utf8)
        let reply = try #require(await offline.handle(line: line))
        let items = try #require(try JSONDecoder.ship.decode(JSONValue.self, from: reply).arrayValue)
        #expect(items.map { $0["id"]?.intValue } == [1, 2])
        #expect(reply.last == 0x0A)
    }

    @Test func modernToolCallsAreStamped() async throws {
        let result = try #require(await offline.handle(mcpRequest(1, "tools/call", [
            "name": "notify_user", "arguments": ["title": "hi"], "_meta": modernMeta(),
        ]))?.result)
        #expect(result["resultType"] == "complete")
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "mothership")
        #expect(result.isToolError)  // the app isn't running in this test
    }

    @Test func lineLevelErrors() async throws {
        let parse = try #require(await offline.handle(line: Data("{nope".utf8)))
        let decoded = try JSONDecoder.ship.decode(JSONValue.self, from: parse)
        #expect(decoded["error"]?["code"] == -32700)
        #expect(decoded["id"] == .null)
        #expect(parse.last == 0x0A)
        #expect(!parse.dropLast().contains(0x0A))
        // Responses from the client are ignored.
        #expect(await offline.handle(line: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == nil)
    }
}
