import Foundation
import ShipModel
import Testing

@testable import AgentKit

/// Collects engine updates on a background task so tests can wait for specific events.
actor UpdateRecorder {
    private(set) var updates: [AgentEngineUpdate] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<AgentEngineUpdate>) {
        task = Task { [weak self] in
            for await update in stream { await self?.append(update) }
        }
    }

    func append(_ update: AgentEngineUpdate) { updates.append(update) }

    var permissionRequests: [PermissionRequest] {
        updates.compactMap { if case .attention(let event) = $0, case .permission(let request) = event.kind { request } else { nil } }
    }

    var attentionKinds: [AttentionEvent.Kind] {
        updates.compactMap { if case .attention(let event) = $0 { event.kind } else { nil } }
    }

    var resolved: [PermissionRequestID] {
        updates.compactMap { if case .permissionResolved(let id) = $0 { id } else { nil } }
    }

    var sessionSnapshots: Int {
        updates.reduce(0) { count, update in if case .sessions = update { count + 1 } else { count } }
    }

    func stop() { task?.cancel() }
}

func waitUntil(timeout: Double = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("Agent engine", .serialized)
struct EngineTests {
    let surface = SurfaceID()
    let workspace = WorkspaceID()

    func makeEngine(home: TempHome, holdTimeout: TimeInterval = 5) -> AgentEngine {
        var configuration = AgentEngineConfiguration.isolated(home: home.root)
        configuration.permissionHoldTimeout = holdTimeout
        configuration.updateInterval = 0.05
        return AgentEngine(configuration: configuration)
    }

    func hook(_ agent: AgentKind, _ event: String, _ json: String, surface: SurfaceID? = nil, pid: Int32? = 4242) -> HookEnvelope {
        HookEnvelope(agent: agent, event: event, payload: Data(json.utf8), surface: surface, agentPID: pid, cwd: "/repo")
    }

    func hook(_ event: String, _ json: String, surface: SurfaceID? = nil, pid: Int32? = 4242) -> HookEnvelope {
        hook(.claude, event, json, surface: surface, pid: pid)
    }

    let permissionPayload = #"{"session_id":"s-1","cwd":"/repo","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Clean"}}"#

    @Test func nonBlockingHooksPassThroughImmediately() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let reply = await engine.handleHook(hook("PreToolUse", #"{"session_id":"s-1","tool_name":"Read","tool_input":{"file_path":"/repo/a.swift"}}"#, surface: surface))
        #expect(reply == .passthrough)
        let sessions = await engine.sessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].state == .working(tool: "Read"))
        #expect(sessions[0].surface == surface)
        #expect(sessions[0].pid == 4242)
        #expect(sessions[0].summary == "Reading a.swift")
    }

    @Test func watchedSurfaceGetsPassthroughWithoutHold() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        await engine.attentionContextChanged(AttentionContext(focusedSurface: surface, appIsActive: true, visibleSurfaces: [surface]))
        let reply = await engine.handleHook(hook("PermissionRequest", permissionPayload, surface: surface))
        #expect(reply == .passthrough)
        #expect(await engine.pendingPermissions().isEmpty)
        let session = try #require(await engine.sessions().first)
        #expect(session.state == .needsInput(.permission))
        #expect(session.unread == false)
    }

    @Test func holdThenAllowReturnsClaudeDecision() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        let envelope = hook("PermissionRequest", permissionPayload, surface: surface)
        let pending = Task { await engine.handleHook(envelope) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        let request = try #require(await engine.pendingPermissions().first)
        #expect(request.toolName == "Bash")
        #expect(request.summary == "rm -rf build")
        #expect(request.surface == surface)
        #expect(request.detail?.contains("rm -rf build") == true)
        let session = try #require(await engine.sessions().first)
        #expect(session.state == .needsInput(.permission))
        #expect(session.pendingPermission?.id == request.id)
        #expect(session.unread)
        #expect(await waitUntil { await recorder.permissionRequests.map(\.id) == [request.id] })

        await engine.resolvePermission(request.id, decision: .allow)
        let reply = await pending.value
        #expect(reply.exitCode == 0)
        #expect(reply.stdout == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        let after = try #require(await engine.sessions().first)
        #expect(after.state == .working(tool: "Bash"))
        #expect(after.pendingPermission == nil)
        #expect(await waitUntil { await recorder.resolved == [request.id] })
        await recorder.stop()
    }

    @Test func denyReturnsMessage() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let pending = Task { await engine.handleHook(hook(.codex, "PermissionRequest", permissionPayload)) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        let request = try #require(await engine.pendingPermissions().first)
        #expect(request.surface == nil)
        await engine.resolvePermission(request.id, decision: .deny(reason: "Not now"))
        let reply = await pending.value
        let stdout = try #require(reply.stdout)
        let json = try #require(JSONNode.parse(stdout))
        #expect(json["hookSpecificOutput"]["decision"]["behavior"].string == "deny")
        #expect(json["hookSpecificOutput"]["decision"]["message"].string == "Not now")
        #expect(try #require(await engine.sessions().first).state == .working(tool: nil))
    }

    @Test func timeoutReleasesWithPassthrough() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home, holdTimeout: 0.2)
        let started = Date()
        let reply = await engine.handleHook(hook("PermissionRequest", permissionPayload, surface: surface))
        #expect(reply == .passthrough)
        #expect(Date().timeIntervalSince(started) >= 0.15)
        #expect(await engine.pendingPermissions().isEmpty)
        let session = try #require(await engine.sessions().first)
        // The agent now shows its own prompt.
        #expect(session.state == .needsInput(.permission))
        #expect(session.pendingPermission == nil)
    }

    @Test func focusingTheSurfaceReleasesTheHold() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        let envelope = hook("PermissionRequest", permissionPayload, surface: surface)
        let pending = Task { await engine.handleHook(envelope) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        let id = try #require(await engine.pendingPermissions().first?.id)
        // Looking at another surface, or an inactive app, doesn't release it.
        await engine.attentionContextChanged(AttentionContext(focusedSurface: SurfaceID(), appIsActive: true))
        await engine.attentionContextChanged(AttentionContext(focusedSurface: surface, appIsActive: false))
        #expect(await engine.pendingPermissions().count == 1)
        await engine.attentionContextChanged(AttentionContext(focusedSurface: surface, appIsActive: true, visibleSurfaces: [surface]))
        #expect(await pending.value == .passthrough)
        #expect(await waitUntil { await recorder.resolved == [id] })
        let session = try #require(await engine.sessions().first)
        #expect(session.unread == false)
        await recorder.stop()
    }

    @Test func cancelledHookReleasesTheHold() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let envelope = hook("PermissionRequest", permissionPayload, surface: surface)
        let pending = Task { await engine.handleHook(envelope) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        pending.cancel()
        #expect(await pending.value == .passthrough)
        #expect(await waitUntil { await engine.pendingPermissions().isEmpty })
    }

    @Test func sessionEndReleasesTheHold() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let envelope = hook("PermissionRequest", permissionPayload, surface: surface)
        let pending = Task { await engine.handleHook(envelope) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        _ = await engine.handleHook(hook("SessionEnd", #"{"session_id":"s-1","reason":"other"}"#, surface: surface))
        #expect(await pending.value == .passthrough)
        #expect(try #require(await engine.sessions().first).state == .ended)
    }

    /// Claude Code shows its own prompt while our hook is held; answering there runs the tool
    /// (PostToolUse) and must release the hook right away, not at the hold timeout.
    @Test func claudeAnsweredInTUIReleasesHold() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home, holdTimeout: 60)
        let pending = Task { await engine.handleHook(hook("PermissionRequest", permissionPayload, surface: surface)) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        let ran = #"{"session_id":"s-1","cwd":"/repo","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"tool_response":{}}"#
        _ = await engine.handleHook(hook("PostToolUse", ran, surface: surface))
        let started = Date()
        #expect(await pending.value == .passthrough)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(await engine.pendingPermissions().isEmpty)
    }

    @Test func openCodeReplyInTUIReleasesHold() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let asked = #"{"type":"permission.asked","directory":"/repo","properties":{"id":"per_9","sessionID":"ses_9","permission":"edit","patterns":["/repo/a.ts"],"metadata":{}}}"#
        let pending = Task { await engine.handleHook(hook(.opencode, "permission.asked", asked, pid: nil)) }
        #expect(await waitUntil { await !engine.pendingPermissions().isEmpty })
        #expect(try #require(await engine.pendingPermissions().first).summary == "a.ts")
        let replied = #"{"type":"permission.replied","properties":{"sessionID":"ses_9","requestID":"per_9","reply":"once"}}"#
        _ = await engine.handleHook(hook(.opencode, "permission.replied", replied, pid: nil))
        #expect(await pending.value == .passthrough)
        #expect(try #require(await engine.sessions().first).state == .working(tool: nil))
    }

    @Test func externalHoldCanBeDisabled() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var configuration = AgentEngineConfiguration.isolated(home: home.root)
        configuration.holdPermissionsForExternalSessions = false
        let engine = AgentEngine(configuration: configuration)
        #expect(await engine.handleHook(hook("PermissionRequest", permissionPayload, surface: nil)) == .passthrough)
    }

    @Test func attentionEventsAndUnread() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        _ = await engine.handleHook(hook("UserPromptSubmit", #"{"session_id":"s-2","prompt":"Write the changelog"}"#, surface: surface))
        _ = await engine.handleHook(hook("Stop", #"{"session_id":"s-2","last_assistant_message":"Changelog written."}"#, surface: surface))
        #expect(await waitUntil { await recorder.attentionKinds.contains(.finished) })
        var session = try #require(await engine.sessions().first)
        #expect(session.unread)
        #expect(session.title == "Write the changelog")
        await engine.markRead(surface: surface)
        session = try #require(await engine.sessions().first)
        #expect(session.unread == false)
        _ = await engine.handleHook(hook("StopFailure", #"{"session_id":"s-2","error":"overloaded"}"#, surface: surface))
        #expect(await waitUntil { await recorder.attentionKinds.contains(.failed) })
        await recorder.stop()
    }

    @Test func updatesAreCoalesced() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var configuration = AgentEngineConfiguration.isolated(home: home.root)
        configuration.updateInterval = 0.1
        let engine = AgentEngine(configuration: configuration)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        let started = Date()
        for index in 0..<300 {
            _ = await engine.handleHook(hook("PreToolUse", #"{"session_id":"s-3","tool_name":"Read","tool_input":{"file_path":"/repo/\#(index).swift"}}"#, surface: surface))
        }
        try await Task.sleep(for: .milliseconds(250))
        let elapsed = Date().timeIntervalSince(started)
        let snapshots = await recorder.sessionSnapshots
        #expect(snapshots >= 1)
        #expect(Double(snapshots) <= elapsed / 0.1 + 3)
        await recorder.stop()
    }

    @Test func unchangedStateIsNotRepublished() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        _ = await engine.handleHook(hook("UserPromptSubmit", #"{"session_id":"s-9","prompt":"Tidy the README"}"#, surface: surface))
        #expect(await waitUntil { await engine.sessions().first?.state.isBusy == true })
        try await Task.sleep(for: .milliseconds(150))
        let settled = await recorder.sessionSnapshots
        // A scan re-seeing the same process, and flushes with nothing new, publish nothing.
        for _ in 0..<5 {
            await engine.applyRootForTesting(kind: .claude, pid: 4242, surface: surface, cwd: "/repo")
            await engine.markDirty()
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(await recorder.sessionSnapshots == settled)
        // A real change still goes out.
        _ = await engine.handleHook(hook("Stop", #"{"session_id":"s-9","last_assistant_message":"README tidied."}"#, surface: surface))
        #expect(await waitUntil { await recorder.sessionSnapshots > settled })
        await recorder.stop()
    }

    @Test func hiddenAppBacksOff() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        await engine.surfaceOpened(surface, workspace: workspace, cwd: "/repo")
        #expect(await engine.scanIntervals.next == 1)
        await engine.setAppActive(false)
        let hidden = await engine.scanIntervals
        #expect(hidden.next == 8)
        #expect(hidden.system == 8)
        await engine.setAppActive(true)
        #expect(await engine.scanIntervals.next == 1)
    }

    @Test func surfaceScanRunsOnlyWhenTheAppTreeChanges() async throws {
        let scanner = ProcessScanner(adapters: [], home: FileManager.default.temporaryDirectory)
        _ = await scanner.descendantsChanged(of: getpid())
        #expect(await scanner.descendantsChanged(of: getpid()) == false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        #expect(await scanner.descendantsChanged(of: getpid()))
        #expect(await scanner.descendantsChanged(of: getpid()) == false)
        process.terminate()
        process.waitUntilExit()
        #expect(await scanner.descendantsChanged(of: getpid()))
    }

    @Test func terminalSignalsMapToSessionOnSurface() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        await engine.surfaceOpened(surface, workspace: workspace, cwd: "/repo")
        _ = await engine.handleHook(hook("SessionStart", #"{"session_id":"s-4","source":"startup"}"#, surface: surface))
        // Inside the hook lease, terminal progress is deferred, not applied.
        await engine.surfaceSignal(surface, .progress(state: "indeterminate", percent: nil))
        #expect(try #require(await engine.sessions().first).state == .idle)
        await engine.surfaceSignal(surface, .processExited)
        #expect(try #require(await engine.sessions().first).state == .ended)
    }

    @Test func rawNotificationWithoutSession() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        await engine.surfaceSignal(surface, .desktopNotification(title: "Build", body: "Done"))
        #expect(await waitUntil { await recorder.attentionKinds.contains(.notification) })
        await recorder.stop()
    }

    @Test func liveTranscriptIngestion() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var configuration = AgentEngineConfiguration.isolated(home: home.root)
        configuration.transcriptWatching = true
        configuration.transcriptPollInterval = 0.1
        configuration.safetyPollInterval = 0.2
        configuration.updateInterval = 0.02
        let engine = AgentEngine(configuration: configuration)
        await engine.start()
        defer { Task { await engine.stop() } }
        let transcript = ".claude/projects/-work-app/sess-777.jsonl"
        try home.write(transcript, #"{"type":"user","message":{"role":"user","content":"Add retries"},"timestamp":"2030-01-01T00:00:00.000Z","cwd":"/work/app","sessionId":"sess-777"}"# + "\n")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try home.write(".claude/sessions/777.json", #"{"pid":777,"sessionId":"sess-777","cwd":"/work/app","status":"busy","updatedAt":\#(now),"statusUpdatedAt":\#(now)}"#)
        let key = AgentSessionKey(kind: .claude, sessionID: "sess-777")
        #expect(await waitUntil(timeout: 5) { await engine.record(for: key)?.session.lastUserPrompt == "Add retries" })
        let record = try #require(await engine.record(for: key))
        #expect(record.session.pid == 777)
        #expect(record.session.state == .working(tool: nil))
        let finish = #"{"type":"assistant","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Retries added."}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2030-01-01T00:00:05.000Z","sessionId":"sess-777"}"#
        let handle = try FileHandle(forWritingTo: home.root.appending(path: transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((finish + "\n").utf8))
        try handle.close()
        #expect(await waitUntil(timeout: 5) { await engine.record(for: key)?.session.state == .idle })
        #expect(await engine.record(for: key)?.session.lastAssistantMessage == "Retries added.")
        #expect(await engine.record(for: key)?.session.usage.outputTokens == 7)
    }

    @Test func commands() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        #expect(await engine.resumeCommand(for: AgentSessionKey(kind: .claude, sessionID: "abc")) == "claude --resume abc")
        #expect(await engine.resumeCommand(for: AgentSessionKey(kind: .codex, sessionID: "019f")) == "codex resume 019f")
        #expect(await engine.resumeCommand(for: AgentSessionKey(kind: .opencode, sessionID: "ses_1")) == "opencode --session ses_1")
        #expect(await engine.resumeCommand(for: .provisional(kind: .claude, pid: 1)) == nil)
        #expect(await engine.launchCommand(.claude, prompt: "fix the 'auth' tests") == #"claude 'fix the '\''auth'\'' tests'"#)
        #expect(await engine.launchCommand(.gemini, prompt: "hi") == "gemini -i hi")
        #expect(await engine.launchCommand(.opencode, prompt: nil) == "opencode")
        #expect(await engine.launchCommand(AgentKind(rawValue: "unknown-agent"), prompt: nil) == "unknown-agent")
    }

    @Test func integrationRoundTripThroughEngine() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home)
        try await engine.installIntegration(.claude)
        var statuses = await engine.integrationStatuses()
        #expect(statuses.first { $0.kind == .claude }?.installed == true)
        #expect(home.exists(".claude/settings.json"))
        try await engine.uninstallIntegration(.claude)
        statuses = await engine.integrationStatuses()
        #expect(statuses.first { $0.kind == .claude }?.installed == false)
        await #expect(throws: IntegrationError.self) { try await engine.installIntegration(AgentKind(rawValue: "aider")) }
    }
}
