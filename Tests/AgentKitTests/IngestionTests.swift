import Foundation
import ShipModel
import Testing

@testable import AgentKit

@Suite("Transcript ingestion")
struct IngestionTests {
    static let session = "aaaaaaaa-1111-2222-3333-444444444444"

    func line(_ json: String) -> String { json + "\n" }

    func userLine(_ text: String, at seconds: Int) -> String {
        line(#"{"type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(iso(seconds))","cwd":"/work/app","sessionId":"\#(Self.session)"}"#)
    }

    func assistantLine(_ id: String, text: String? = nil, tool: String? = nil, stop: String?, at seconds: Int) -> String {
        var content: [String] = []
        if let text { content.append(#"{"type":"text","text":"\#(text)"}"#) }
        if let tool { content.append(#"{"type":"tool_use","id":"t_\#(id)","name":"Bash","input":{"command":"\#(tool)"}}"#) }
        let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
        return line(#"{"type":"assistant","message":{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[\#(content.joined(separator: ","))],"stop_reason":\#(stopJSON),"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"\#(iso(seconds))","sessionId":"\#(Self.session)"}"#)
    }

    func iso(_ seconds: Int) -> String {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(seconds)).formatted(.iso8601)
    }

    /// Applies signals the way the engine does and returns the session.
    func fold(_ signals: [AgentSignal], into store: inout SessionStore) -> SessionRecord? {
        for signal in signals { store.apply(signal, now: Date(timeIntervalSince1970: 1_800_100_000)) { _ in true } }
        return store[AgentSessionKey(kind: .claude, sessionID: Self.session)]
    }

    @Test func hugeTranscriptKeepsFirstPromptAndBuriedTitle() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var text = userLine("'/Users/someone/Desktop/Screenshot 1.png' set up the monorepo", at: 0)
        for index in 0..<60 { text += assistantLine("m\(index)", text: "filler step \(index) with some padding text", stop: "end_turn", at: 1 + index) }
        text += line(#"{"type":"ai-title","aiTitle":"Monorepo setup","sessionId":"\#(Self.session)"}"#)
        for index in 60..<120 { text += assistantLine("m\(index)", text: "more filler \(index) with some padding text", stop: "end_turn", at: 1 + index) }
        text += userLine("now fix CI", at: 500)
        text += assistantLine("last", tool: "swift test", stop: "tool_use", at: 501)
        let relative = ".claude/projects/-work-app/\(Self.session).jsonl"
        try home.write(relative, text)
        let ingestor = TranscriptIngestor(adapters: [ClaudeAdapter()], home: home.root, maxInitialBytes: 2048, headBytes: 400)
        var store = SessionStore()
        let record = try #require(fold(await ingestor.track(path: home.root.appending(path: relative).path), into: &store))
        #expect(record.session.title == "Monorepo setup")
        #expect(record.firstPrompt?.contains("set up the monorepo") == true)
        #expect(record.session.lastUserPrompt == "now fix CI")
        #expect(record.session.state == .working(tool: "Bash"))
    }

    @Test func peekGivesCurrentStateBeforeFullHistory() async throws {
        let home = try TempHome()
        defer { home.remove() }
        var text = userLine("first task", at: 0)
        for index in 0..<200 { text += assistantLine("m\(index)", text: "step \(index) padding padding padding", stop: "end_turn", at: 1 + index) }
        text += userLine("run the tests", at: 300)
        text += assistantLine("t1", tool: "swift test", stop: "tool_use", at: 301)
        let relative = ".claude/projects/-work-app/\(Self.session).jsonl"
        try home.write(relative, text)
        let path = home.root.appending(path: relative).path
        let ingestor = TranscriptIngestor(adapters: [ClaudeAdapter()], home: home.root)
        var store = SessionStore()
        // A live process was seen first (scan time is later than every transcript line).
        store.apply(AgentSignal(tier: .process, source: "process", hint: SessionHint(kind: .claude, sessionID: Self.session, pid: 77), event: .processSeen, timestamp: Date(timeIntervalSince1970: 1_800_100_000)), now: Date(timeIntervalSince1970: 1_800_100_000)) { _ in true }
        let peeked = try #require(fold(await ingestor.peek(path: path, bytes: 1024), into: &store))
        #expect(peeked.session.state == .working(tool: "Bash"))
        #expect(peeked.session.lastUserPrompt == "run the tests")
        // The full replay afterwards must not regress anything, and fills in history.
        let full = try #require(fold(await ingestor.track(path: path), into: &store))
        #expect(full.session.state == .working(tool: "Bash"))
        #expect(full.session.lastUserPrompt == "run the tests")
        #expect(full.firstPrompt == "first task")
        #expect(full.session.title == "First task")
        #expect(await ingestor.peek(path: path).isEmpty)
    }

    @Test func streamingAssistantMeansWorking() throws {
        var state = TranscriptDecodeState()
        let streaming = assistantLine("s1", text: "Let me check", stop: nil, at: 5)
        let events = ClaudeAdapter().decodeTranscript(.line(path: "/p/\(Self.session).jsonl", data: Data(streaming.utf8)), state: &state).map(\.event)
        #expect(events.contains(.observedState(.working(tool: nil))))
    }

    @Test func codexThreadNamesAttachWhenSessionsAppear() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let id = "019ff1e8-9833-7043-aae0-fd1e33b29607"
        try home.write(".codex/session_index.jsonl", line(#"{"id":"\#(id)","thread_name":"Old name","updated_at":"2026-10-21T10:00:00Z"}"#) + line(#"{"id":"\#(id)","thread_name":"Health check build info","updated_at":"2026-10-21T11:00:00Z"}"#) + line(#"{"id":"019f0000-0000-7000-8000-000000000000","thread_name":"Unrelated","updated_at":"2026-10-21T09:00:00Z"}"#))
        let ingestor = TranscriptIngestor(adapters: [CodexAdapter()], home: home.root)
        #expect(await ingestor.eagerFiles() == [home.root.appending(path: ".codex/session_index.jsonl").path])
        var store = SessionStore()
        for path in await ingestor.eagerFiles() {
            for signal in await ingestor.track(path: path) { store.apply(signal, now: Date()) { _ in true } }
        }
        #expect(store.records.isEmpty)
        let rollout = try fixture("transcripts/codex-rollout.jsonl")
        var state = TranscriptDecodeState()
        for raw in rollout.split(whereSeparator: \.isNewline) {
            for signal in CodexAdapter().decodeTranscript(.line(path: "/x/rollout-\(id).jsonl", data: Data(raw.utf8)), state: &state) {
                store.apply(signal, now: Date()) { _ in true }
            }
        }
        #expect(store.records.count == 1)
        let record = try #require(store[AgentSessionKey(kind: .codex, sessionID: id)])
        #expect(record.session.title == "Health check build info")
        #expect(record.hasExplicitTitle)
    }

    @Test func pastedOnlyFirstPromptYieldsToLaterOwnWords() {
        var store = SessionStore()
        let hint = SessionHint(kind: .claude, sessionID: "p", cwd: "/work/exam")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.apply(AgentSignal(tier: .transcript, source: "t", hint: hint, event: .promptSubmitted(prompt: "<pasted_content id=\"a\">\nAccessibility Menu\nQ1. …"), timestamp: base), now: base) { _ in true }
        #expect(store[AgentSessionKey(kind: .claude, sessionID: "p")]?.session.title == "Accessibility Menu")
        store.apply(AgentSignal(tier: .transcript, source: "t", hint: hint, event: .promptSubmitted(prompt: "make flashcards from the questions above"), timestamp: base.addingTimeInterval(30)), now: base) { _ in true }
        #expect(store[AgentSessionKey(kind: .claude, sessionID: "p")]?.session.title == "Make flashcards from the questions above")
        // An even later prompt doesn't change it.
        store.apply(AgentSignal(tier: .transcript, source: "t", hint: hint, event: .promptSubmitted(prompt: "now quiz me"), timestamp: base.addingTimeInterval(60)), now: base) { _ in true }
        #expect(store[AgentSessionKey(kind: .claude, sessionID: "p")]?.session.title == "Make flashcards from the questions above")
    }

    @Test func userTitleBeatsAgentTitle() {
        var store = SessionStore()
        let hint = SessionHint(kind: .claude, sessionID: "t")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.apply(AgentSignal(tier: .transcript, source: "t", hint: hint, event: .promptSubmitted(prompt: "do things"), timestamp: base), now: base) { _ in true }
        store.apply(AgentSignal(tier: .transcript, source: "t", hint: hint, event: .metadata(SessionMetadata(title: "My rename", titleSource: .user)), timestamp: base), now: base) { _ in true }
        store.apply(AgentSignal(tier: .transcript, source: "t", hint: hint, event: .metadata(SessionMetadata(title: "AI title", titleSource: .agent)), timestamp: base.addingTimeInterval(60)), now: base) { _ in true }
        #expect(store[AgentSessionKey(kind: .claude, sessionID: "t")]?.session.title == "My rename")
    }

    @Test func watchRootsCollapseNestedDirectories() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let ingestor = TranscriptIngestor(adapters: AgentEngine.defaultAdapters(), home: home.root)
        let roots = await ingestor.watchRoots()
        #expect(roots.contains(home.root.appending(path: ".codex").path))
        #expect(!roots.contains(home.root.appending(path: ".codex/sessions").path))
    }

    @Test func markerScanFindsLinesAcrossChunks() throws {
        let home = try TempHome()
        defer { home.remove() }
        var text = ""
        for index in 0..<500 { text += line(#"{"type":"assistant","n":\#(index)}"#) }
        text += line(#"{"type":"ai-title","aiTitle":"Found it"}"#)
        for index in 0..<500 { text += line(#"{"type":"assistant","n":\#(index)}"#) }
        try home.write("t.jsonl", text)
        let path = home.root.appending(path: "t.jsonl").path
        let size = UInt64(text.utf8.count)
        let lines = TranscriptIngestor.lines(in: path, from: 0, to: size, containing: [Data("\"type\":\"ai-title\"".utf8)], chunkSize: 1000)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"type":"ai-title","aiTitle":"Found it"}"#])
    }
}
