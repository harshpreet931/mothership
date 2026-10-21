import Foundation
import ShipModel
import SystemProbe
import Testing

@testable import AgentKit

/// A synthetic Claude installation: per-pid status files and transcripts in a temp home, backed
/// by real (sleeping) processes so exit watching sees them alive.
final class FakeClaudeFleet: @unchecked Sendable {
    // Written once in init, then only read: safe to share with the engine's provider closure.
    let home: TempHome
    var sessions: [(pid: Int32, id: String, cwd: String, transcript: URL)] = []
    private var sleepers: [Process] = []

    init(count: Int, lastActivityAgo: TimeInterval = 20) throws {
        home = try TempHome()
        let now = Date()
        for index in 0..<count {
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["60"]
            try sleeper.run()
            sleepers.append(sleeper)
            let pid = sleeper.processIdentifier
            let id = String(format: "aaaaaaaa-0000-4000-8000-%012d", index)
            let cwd = "/work/project-\(index)"
            let escaped = ClaudeAdapter.escapedProjectName(cwd)
            let relative = ".claude/projects/\(escaped)/\(id).jsonl"
            func iso(_ ago: TimeInterval) -> String { now.addingTimeInterval(-ago).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
            let base = lastActivityAgo
            var text = ""
            text += #"{"type":"user","message":{"role":"user","content":"> 1. @src/a.ts tidy up module \#(index)"},"timestamp":"\#(iso(base + 20))","cwd":"\#(cwd)","sessionId":"\#(id)"}"# + "\n"
            text += #"{"type":"assistant","message":{"id":"m\#(index)a","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t\#(index)","name":"Bash","input":{"command":"npm test"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"\#(iso(base + 15))","sessionId":"\#(id)"}"# + "\n"
            text += #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\#(index)","content":"ok"}]},"timestamp":"\#(iso(base + 10))","sessionId":"\#(id)"}"# + "\n"
            text += #"{"type":"assistant","message":{"id":"m\#(index)b","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"**Done** with module \#(index)."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"\#(iso(base + 1))","sessionId":"\#(id)"}"# + "\n"
            text += #"{"type":"system","subtype":"turn_duration","timestamp":"\#(iso(base))","sessionId":"\#(id)"}"# + "\n"
            try home.write(relative, text)
            let updated = Int(now.addingTimeInterval(-base).timeIntervalSince1970 * 1000)
            try home.write(".claude/sessions/\(pid).json", #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)","status":"idle","nameSource":"derived","name":"p-\#(index)","updatedAt":\#(updated),"statusUpdatedAt":\#(updated)}"#)
            sessions.append((pid, id, cwd, home.root.appending(path: relative)))
        }
    }

    /// What the process scanner would report for these processes.
    func roots(surfaces: [Int32: SurfaceID] = [:]) -> [RootProcess] {
        let adapter = ClaudeAdapter()
        let started = UInt64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
        return sessions.map { session in
            let snapshot = ProcessSnapshot(pid: session.pid, ppid: 1, comm: "claude", startMicros: started)
            let process = ObservedProcess(
                snapshot: snapshot, arguments: ProcessArguments(executablePath: "/x/claude/versions/2.1.306", arguments: ["claude"]), cwd: session.cwd
            )
            let binding = adapter.bindSession(process, context: BindingContext(home: home.root, table: ProcessTable(processes: [snapshot])))
            let surface = surfaces[session.pid]
            return RootProcess(kind: .claude, process: process, surface: surface, hostApp: surface == nil ? "Visual Studio Code" : nil, binding: binding)
        }
    }

    func append(_ index: Int, _ line: String) throws {
        let handle = try FileHandle(forWritingTo: sessions[index].transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    func liveTurn(_ index: Int, reply: String) throws {
        let id = sessions[index].id
        let now = Date()
        func iso(_ offset: TimeInterval) -> String { now.addingTimeInterval(offset).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        try append(index, #"{"type":"user","message":{"role":"user","content":"and the docs"},"timestamp":"\#(iso(-0.4))","cwd":"\#(sessions[index].cwd)","sessionId":"\#(id)"}"#)
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]), as: UTF8.self)
        try append(index, #"{"type":"assistant","message":{"id":"live\#(index)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":\#(quoted)}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"\#(iso(0))","sessionId":"\#(id)"}"#)
    }

    func stop() {
        for sleeper in sleepers where sleeper.isRunning { sleeper.terminate() }
        home.remove()
    }
}

@Suite("Attention events", .serialized)
struct AttentionTests {
    func engine(_ fleet: FakeClaudeFleet, surfaces: [Int32: SurfaceID] = [:]) -> AgentEngine {
        var configuration = AgentEngineConfiguration.isolated(home: fleet.home.root)
        configuration.processScanning = true
        configuration.transcriptWatching = true
        configuration.updateInterval = 0.02
        configuration.transcriptPollInterval = 0.2
        configuration.safetyPollInterval = 0.5
        let roots = fleet.roots(surfaces: surfaces)
        configuration.processProvider = { _ in roots }
        return AgentEngine(configuration: configuration)
    }

    func attention(_ recorder: UpdateRecorder) async -> [AttentionEvent] {
        await recorder.updates.compactMap { if case .attention(let event) = $0 { event } else { nil } }
    }

    @Test func coldStartWithIdleSessionsIsSilent() async throws {
        let fleet = try FakeClaudeFleet(count: 9)
        defer { fleet.stop() }
        let engine = engine(fleet)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        await engine.start()
        try await Task.sleep(for: .seconds(1.5))
        let sessions = await engine.sessions()
        #expect(sessions.count == 9)
        #expect(sessions.allSatisfy { $0.state == .idle })
        #expect(sessions.allSatisfy { $0.title?.hasPrefix("Tidy up module") == true })
        #expect(sessions.allSatisfy { $0.unread == false })
        #expect(await attention(recorder).isEmpty)
        await recorder.stop()
        await engine.stop()
    }

    @Test func liveTurnFinishesExactlyOnceAcrossSources() async throws {
        let fleet = try FakeClaudeFleet(count: 3)
        defer { fleet.stop() }
        let engine = engine(fleet)
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        await engine.start()
        try await Task.sleep(for: .milliseconds(600))
        #expect(await attention(recorder).isEmpty)

        try fleet.liveTurn(1, reply: "## Result\n\nI updated **README.md** and `docs/setup.md` — see [the diff](https://x.dev/d). Saved to /Users/someone/out.txt as well, with a much longer explanation that goes on and on past the limit for a toast body.")
        // The transcript (kqueue) reports it first, well under a second…
        let written = Date()
        #expect(await waitUntil(timeout: 1) { await attention(recorder).count >= 1 })
        #expect(Date().timeIntervalSince(written) < 0.5)
        // …then the same moment arrives again from a hook and the terminal: no second event.
        let hook = HookEnvelope(agent: .claude, event: "Stop", payload: Data(#"{"session_id":"\#(fleet.sessions[1].id)","last_assistant_message":"I updated README.md"}"#.utf8))
        _ = await engine.handleHook(hook)
        try await Task.sleep(for: .milliseconds(700))
        let events = await attention(recorder)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .finished)
        #expect(event.session?.sessionID == fleet.sessions[1].id)
        #expect(event.surface == nil)
        #expect(event.title == "Tidy up module 1")
        #expect(!event.body.contains("**") && !event.body.contains("`") && !event.body.contains("##"))
        #expect(event.body.hasPrefix("I updated README.md and docs/setup.md — see the diff."))
        #expect(event.body.count <= 140)
        await recorder.stop()
        await engine.stop()
    }

    @Test func inAppSessionKeepsItsSurfaceThroughTheKeyMerge() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var configuration = AgentEngineConfiguration.isolated(home: home.root)
        configuration.updateInterval = 0.02
        let engine = AgentEngine(configuration: configuration)
        let surface = SurfaceID()
        let recorder = UpdateRecorder()
        await recorder.start(engine.updates())
        // The process is seen first (surface from its environment), hooks arrive without one.
        await engine.applyRootForTesting(kind: .claude, pid: getpid(), surface: surface, cwd: "/work/app")
        _ = await engine.handleHook(HookEnvelope(agent: .claude, event: "UserPromptSubmit", payload: Data(#"{"session_id":"real-1","prompt":"go"}"#.utf8), agentPID: getpid(), cwd: "/work/app"))
        _ = await engine.handleHook(HookEnvelope(agent: .claude, event: "Stop", payload: Data(#"{"session_id":"real-1","last_assistant_message":"done"}"#.utf8), agentPID: getpid(), cwd: "/work/app"))
        // An external session: no surface anywhere.
        _ = await engine.handleHook(HookEnvelope(agent: .claude, event: "UserPromptSubmit", payload: Data(#"{"session_id":"ext-1","prompt":"go"}"#.utf8), cwd: "/elsewhere"))
        _ = await engine.handleHook(HookEnvelope(agent: .claude, event: "Stop", payload: Data(#"{"session_id":"ext-1","last_assistant_message":"done"}"#.utf8), cwd: "/elsewhere"))
        #expect(await waitUntil { await attention(recorder).count == 2 })
        let events = await attention(recorder)
        #expect(events.first { $0.session?.sessionID == "real-1" }?.surface == surface)
        #expect(events.first { $0.session?.sessionID == "ext-1" }.map { $0.surface == nil } == true)
        #expect(await engine.sessions().count == 2)
        await recorder.stop()
    }
}

@Suite("Attention gate and text")
struct AttentionGateTests {
    let key = AgentSessionKey(kind: .claude, sessionID: "g")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func oneFinishedPerTurn() {
        var gate = AttentionGate()
        let r1 = gate.admit(.finished, for: key, now: t0)
        #expect(!r1)  // no turn seen yet
        gate.note(key, from: .idle, to: .working(tool: nil), at: t0)
        let r2 = gate.admit(.finished, for: key, now: t0.addingTimeInterval(5))
        #expect(r2)
        let r3 = gate.admit(.finished, for: key, now: t0.addingTimeInterval(5.1))
        #expect(!r3)
        // A blip back to working inside the same moment isn't a new turn… unless it comes from idle.
        gate.note(key, from: .needsInput(.permission), to: .working(tool: nil), at: t0.addingTimeInterval(6))
        let r4 = gate.admit(.finished, for: key, now: t0.addingTimeInterval(7))
        #expect(!r4)
        gate.note(key, from: .idle, to: .working(tool: "Bash"), at: t0.addingTimeInterval(20))
        let r5 = gate.admit(.finished, for: key, now: t0.addingTimeInterval(30))
        #expect(r5)
    }

    @Test func repeatsAreDropped() {
        var gate = AttentionGate()
        let r6 = gate.admit(.needsInput, for: key, now: t0)
        #expect(r6)
        let r7 = gate.admit(.needsInput, for: key, now: t0.addingTimeInterval(3))
        #expect(!r7)
        let r8 = gate.admit(.failed, for: key, now: t0.addingTimeInterval(4))
        #expect(r8)
        let r9 = gate.admit(.needsInput, for: key, now: t0.addingTimeInterval(40))
        #expect(r9)
    }

    @Test func plainBodies() {
        #expect(AttentionText.body("I built **Paper Prix**: draw an F1 circuit…", fallback: "x") == "I built Paper Prix: draw an F1 circuit…")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AttentionText.body("# Done\n\nSaved to \(home)/Downloads/a.mp4", fallback: "x") == "Saved to ~/Downloads/a.mp4")
        let long = AttentionText.body(String(repeating: "word ", count: 60), fallback: "x")
        #expect(long.count <= 140 && long.hasSuffix("…"))
        #expect(AttentionText.permission(tool: "Bash", summary: "rm -rf build/*_tmp") == "Bash: rm -rf build/*_tmp")
        #expect(AttentionText.body("   ", fallback: "Finished") == "Finished")
    }
}
