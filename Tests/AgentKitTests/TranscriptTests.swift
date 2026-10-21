import Foundation
import ShipModel
import Testing

@testable import AgentKit

@Suite("Transcripts")
struct TranscriptTests {
    /// Decode a JSONL fixture through an adapter and fold the signals into a store.
    func replay(_ name: String, adapter: any AgentAdapter, path: String) throws -> SessionRecord {
        let text = try fixture("transcripts/\(name)")
        var state = TranscriptDecodeState(isInitialLoad: true)
        var store = SessionStore()
        var key: AgentSessionKey?
        for line in text.split(whereSeparator: \.isNewline) {
            for signal in adapter.decodeTranscript(.line(path: path, data: Data(line.utf8)), state: &state) {
                key = store.apply(signal, now: signal.timestamp) { _ in true }?.key ?? key
            }
        }
        let resolved = try #require(key)
        return try #require(store[resolved])
    }

    @Test func claudeTranscript() throws {
        let record = try replay("claude-session.jsonl", adapter: ClaudeAdapter(), path: "/h/.claude/projects/-work-app/11111111-2222-3333-4444-555555555555.jsonl")
        let session = record.session
        #expect(session.id == AgentSessionKey(kind: .claude, sessionID: "11111111-2222-3333-4444-555555555555"))
        #expect(session.state == .idle)
        #expect(session.title == "Dark mode toggle in settings")
        #expect(record.hasExplicitTitle)
        #expect(session.lastUserPrompt == "Add a dark mode toggle to settings")
        #expect(session.lastAssistantMessage == "Added a Toggle bound to @AppStorage(\"darkMode\").")
        #expect(session.model == "claude-opus-5-5")
        #expect(session.branch == "feature/dark-mode")
        #expect(session.cwd == "/work/app")
        // msg_01 is written twice (one line per content block); usage counts once, at its final value.
        #expect(session.usage.inputTokens == 130)
        #expect(session.usage.outputTokens == 170)
        #expect(session.usage.cacheWriteTokens == 2500)
        #expect(session.usage.cacheReadTokens == 62000)
        #expect(session.usage.contextTokens == 32520)
        #expect(session.usage.contextWindow == 1_000_000)
        #expect(record.firstPrompt == "Add a dark mode toggle to settings")
    }

    @Test func codexRollout() throws {
        let record = try replay("codex-rollout.jsonl", adapter: CodexAdapter(), path: "/h/.codex/sessions/2026/10/21/rollout-2026-10-21T11-00-00-019ff1e8-9833-7043-aae0-fd1e33b29607.jsonl")
        let session = record.session
        #expect(session.id.sessionID == "019ff1e8-9833-7043-aae0-fd1e33b29607")
        #expect(session.state == .idle)
        #expect(session.model == "gpt-5.5")
        #expect(session.branch == "main")
        #expect(session.cwd == "/work/api")
        #expect(session.lastUserPrompt == "Make the health check return build info")
        #expect(session.lastAssistantMessage == "Health check now includes the git sha.")
        #expect(session.usage.inputTokens == 10_000)
        #expect(session.usage.cacheReadTokens == 40_000)
        #expect(session.usage.outputTokens == 800)
        #expect(session.usage.contextTokens == 21_400)
        #expect(session.usage.contextWindow == 272_000)
    }

    @Test func codexToolSummaries() throws {
        let adapter = CodexAdapter()
        var state = TranscriptDecodeState()
        var started: [SignalEvent] = []
        for line in try fixture("transcripts/codex-rollout.jsonl").split(whereSeparator: \.isNewline) {
            started += adapter.decodeTranscript(.line(path: "/x/rollout-a.jsonl", data: Data(line.utf8)), state: &state).map(\.event).filter {
                if case .toolStarted = $0 { true } else { false }
            }
        }
        #expect(started == [.toolStarted(tool: "Bash", summary: "rg health"), .toolStarted(tool: "apply_patch", summary: "Edit src/health.rs")])
    }

    @Test func codexSubagentRolloutsAreIgnored() {
        var state = TranscriptDecodeState()
        let meta = #"{"timestamp":"2026-10-21T11:00:00Z","type":"session_meta","payload":{"id":"019ff1e8-0000-7000-8000-000000000001","cwd":"/w","source":{"subagent":{"thread_spawn":{}}},"parent_thread_id":"p"}}"#
        #expect(CodexAdapter().decodeTranscript(.line(path: "/x/rollout-b.jsonl", data: Data(meta.utf8)), state: &state).isEmpty)
        #expect(state.ignored)
        let next = #"{"timestamp":"2026-10-21T11:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#
        #expect(CodexAdapter().decodeTranscript(.line(path: "/x/rollout-b.jsonl", data: Data(next.utf8)), state: &state).isEmpty)
    }

    @Test func claudeStatusFileBinding() throws {
        let home = try TempHome()
        defer { home.remove() }
        let status = #"{"pid":321,"sessionId":"sess-321","cwd":"/work/app","startedAt":1800000000000,"version":"2.1.306","kind":"interactive","entrypoint":"cli","name":"app-3f","nameSource":"derived","status":"waiting","waitingFor":"permission to run Bash","updatedAt":1800000100000,"statusUpdatedAt":1800000100000}"#
        try home.write(".claude/sessions/321.json", status)
        try home.write(".claude/projects/-work-app/sess-321.jsonl", "")
        let adapter = ClaudeAdapter()
        let process = ObservedProcess(
            snapshot: .init(pid: 321, ppid: 1, comm: "claude", startMicros: 1_800_000_000 * 1_000_000),
            arguments: .init(executablePath: "/h/.local/share/claude/versions/2.1.306", arguments: ["claude"]), cwd: "/work/app"
        )
        let context = BindingContext(home: home.root, table: .init(processes: [process.snapshot]))
        let binding = try #require(adapter.bindSession(process, context: context))
        #expect(binding.sessionID == "sess-321")
        #expect(binding.transcriptPath == home.root.appending(path: ".claude/projects/-work-app/sess-321.jsonl").path)
        #expect(binding.signals.map(\.event).contains(.observedState(.needsInput(.permission))))
        // Derived names are slugs, not titles.
        #expect(!binding.signals.contains { if case .metadata(let m) = $0.event { m.title != nil } else { false } })
        // A status file older than the process belongs to a previous process with the same pid.
        let later = ObservedProcess(snapshot: .init(pid: 321, ppid: 1, comm: "claude", startMicros: 1_900_000_000 * 1_000_000), arguments: process.arguments)
        #expect(adapter.bindSession(later, context: context) == nil)
    }

    @Test func geminiChatDocument() throws {
        let document = #"{"sessionId":"g-1","projectHash":"x","startTime":"2026-10-21T09:00:00.000Z","lastUpdated":"2026-10-21T09:01:00.000Z","messages":[{"id":"1","timestamp":"2026-10-21T09:00:01Z","type":"user","content":"explain main.go"},{"id":"2","timestamp":"2026-10-21T09:00:05Z","type":"gemini","content":"It starts the server.","model":"gemini-2.5-pro","tokens":{"input":1200,"output":80,"cached":200,"thoughts":40,"tool":0,"total":1320}}]}"#
        var state = TranscriptDecodeState()
        let signals = GeminiAdapter().decodeTranscript(.document(path: "/h/.gemini/tmp/x/chats/session-1.json", data: Data(document.utf8)), state: &state)
        var store = SessionStore()
        for signal in signals { store.apply(signal, now: signal.timestamp) { _ in true } }
        let session = try #require(store[AgentSessionKey(kind: .gemini, sessionID: "g-1")]).session
        #expect(session.state == .idle)
        #expect(session.model == "gemini-2.5-pro")
        #expect(session.usage.inputTokens == 1000)
        #expect(session.usage.cacheReadTokens == 200)
        #expect(session.usage.outputTokens == 120)
        #expect(session.lastAssistantMessage == "It starts the server.")
    }

    @Test func openCodeRowSignals() throws {
        let row = OpenCodeSessionRow(
            id: "ses_1", directory: "/work/web", title: "Fix flaky test", model: "claude-sonnet-5-5",
            usage: TokenUsage(inputTokens: 1000, outputTokens: 200, cacheReadTokens: 5000), cost: 0.42,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_060),
            state: .working(tool: "Bash"), lastUserText: "fix it"
        )
        var state = TranscriptDecodeState()
        var store = SessionStore()
        for signal in OpenCodeAdapter().decodeTranscript(.openCodeSession(row), state: &state) { store.apply(signal, now: signal.timestamp) { _ in true } }
        let record = try #require(store[AgentSessionKey(kind: .opencode, sessionID: "ses_1")])
        #expect(record.session.state == .working(tool: "Bash"))
        #expect(record.session.usage.costUSD == 0.42)
        #expect(record.costIsEstimate == false)
        #expect(record.session.title == "Fix flaky test")
    }

    @Test func pricingEstimates() throws {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)
        #expect(abs(try #require(Pricing.estimateCost(usage, model: "claude-opus-5-5")) - 29.2) < 1e-9)
        #expect(abs(try #require(Pricing.estimateCost(usage, model: "anthropic/claude-opus-5[1m]")) - 36.75) < 1e-9)
        #expect(Pricing.rate(for: "claude-opus-4-1-20250805")?.input == 15)
        #expect(Pricing.estimateCost(usage, model: "mystery-model") == nil)
        #expect(Pricing.contextWindow(for: "claude-haiku-4-5") == 200_000)
    }
}

@Suite("JSONL tailer")
struct JSONLTailerTests {
    func temp() throws -> (URL, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return (url, { try? FileManager.default.removeItem(at: url) })
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func strings(_ read: JSONLTailer.Read) -> [String] { read.lines.map { String(decoding: $0, as: UTF8.self) } }

    @Test func partialLinesWaitForNewline() throws {
        let (url, cleanup) = try temp()
        defer { cleanup() }
        var tailer = JSONLTailer(path: url.path)
        try append("{\"a\":1}\n{\"b\":", to: url)
        #expect(strings(tailer.read()) == ["{\"a\":1}"])
        #expect(tailer.committedOffset == 8)
        #expect(strings(tailer.read()) == [])
        try append("2}\r\n\n{\"c\":3}\n", to: url)
        #expect(strings(tailer.read()) == ["{\"b\":2}", "{\"c\":3}"])
        #expect(tailer.committedOffset == tailer.offset)
    }

    @Test func truncationRestarts() throws {
        let (url, cleanup) = try temp()
        defer { cleanup() }
        var tailer = JSONLTailer(path: url.path)
        try append("{\"a\":1}\n{\"b\":2}\n", to: url)
        #expect(tailer.read().lines.count == 2)
        try Data("{\"x\":9}\n".utf8).write(to: url)  // atomic write: new inode
        let read = tailer.read()
        #expect(read.didReset)
        #expect(strings(read) == ["{\"x\":9}"])
        // In-place truncation (same inode, now smaller than the offset). A truncation that is
        // refilled past the old offset before the next read can't be told from an append.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try append("{}\n", to: url)
        let again = tailer.read()
        #expect(again.didReset)
        #expect(strings(again) == ["{}"])
    }

    @Test func rotationViaRenameRestarts() throws {
        let (url, cleanup) = try temp()
        defer { cleanup() }
        var tailer = JSONLTailer(path: url.path)
        try append("{\"old\":1}\n", to: url)
        _ = tailer.read()
        let rotated = url.appendingPathExtension("1")
        try FileManager.default.moveItem(at: url, to: rotated)
        defer { try? FileManager.default.removeItem(at: rotated) }
        try Data("{\"new\":1}\n{\"new\":2}\n".utf8).write(to: url)
        let read = tailer.read()
        #expect(read.didReset)
        #expect(read.lines.count == 2)
    }

    @Test func boundedReadsReportMore() throws {
        let (url, cleanup) = try temp()
        defer { cleanup() }
        try append(String(repeating: "{\"k\":\"vvvvvvvv\"}\n", count: 100), to: url)
        var tailer = JSONLTailer(path: url.path)
        let first = tailer.read(maxBytes: 100)
        #expect(first.hasMore)
        var total = first.lines.count
        while true {
            let next = tailer.read(maxBytes: 100)
            total += next.lines.count
            if !next.hasMore { break }
        }
        #expect(total == 100)
    }

    @Test func seekSkipsToNextLine() throws {
        let (url, cleanup) = try temp()
        defer { cleanup() }
        try append("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", to: url)
        var tailer = JSONLTailer(path: url.path)
        tailer.seek(toLineAfter: 3)
        #expect(strings(tailer.read()) == ["{\"b\":2}", "{\"c\":3}"])
    }

    @Test func missingFileIsQuiet() {
        var tailer = JSONLTailer(path: "/nonexistent/\(UUID().uuidString).jsonl")
        #expect(tailer.read().lines.isEmpty)
    }
}
