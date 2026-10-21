import Foundation
import ShipModel
import Synchronization
import Testing

@testable import AgentKit

/// A stand-in for the on-device model: scripted answers, call log, concurrency check.
final class FakeModel: Sendable {
    struct State {
        var available = true
        var titles: [String] = []
        var summaries: [String] = []
        var fail = false
        var digests: [SessionDigest] = []
        var summaryCalls = 0
        var running = 0
        var maxRunning = 0
        var delay: Duration = .zero
    }

    let state = Mutex(State())

    init(titles: [String] = ["\"Paper Prix F1 notebook.\""], summaries: [String] = ["Summary: Added the pit-stop model and its tests."]) {
        state.withLock {
            $0.titles = titles
            $0.summaries = summaries
        }
    }

    var digests: [SessionDigest] { state.withLock { $0.digests } }
    var summaryCalls: Int { state.withLock { $0.summaryCalls } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    var generator: SessionTextGenerator {
        SessionTextGenerator(
            isAvailable: { self.state.withLock { $0.available } },
            title: { digest in try await self.title(digest) },
            summary: { _, _ in
                self.state.withLock { $0.summaryCalls += 1 }
                return self.state.withLock { $0.summaries.isEmpty ? nil : $0.summaries.removeFirst() }
            }
        )
    }

    func title(_ digest: SessionDigest) async throws -> String? {
        let delay = state.withLock { state in
            state.digests.append(digest)
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            return state.delay
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try state.withLock { state in
            state.running -= 1
            if state.fail { throw GenerationFailure() }
            return state.titles.isEmpty ? nil : state.titles.removeFirst()
        }
    }

    struct GenerationFailure: Error {}
}

@Suite("Generated titles and summaries", .serialized)
struct GenerationTests {
    let surface = SurfaceID()

    func makeEngine(home: TempHome, model: FakeModel?, cache: URL? = nil) -> AgentEngine {
        var configuration = AgentEngineConfiguration.isolated(home: home.root)
        configuration.updateInterval = 0.02
        configuration.generationDelay = 0.05
        configuration.textGenerator = model?.generator
        configuration.generatedTextCache = cache
        return AgentEngine(configuration: configuration)
    }

    func hook(_ event: String, _ json: String) -> HookEnvelope {
        HookEnvelope(agent: .claude, event: event, payload: Data(json.utf8), surface: surface, agentPID: 4242, cwd: "/work/f1-notebook")
    }

    func runTurn(_ engine: AgentEngine, session: String = "s-1", prompt: String = "make a notebook that simulates the paper prix f1 race", reply: String = "Done.") async {
        _ = await engine.handleHook(hook("UserPromptSubmit", #"{"session_id":"\#(session)","prompt":"\#(prompt)"}"#))
        _ = await engine.handleHook(hook("Stop", #"{"session_id":"\#(session)","last_assistant_message":"\#(reply)"}"#))
    }

    func title(_ engine: AgentEngine) async -> String? { await engine.sessions().first?.title }

    @Test func generatedTitleReplacesThePromptTitle() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let model = FakeModel()
        let engine = makeEngine(home: home, model: model)
        await runTurn(engine, reply: "I created **notebook.ipynb** with a lap simulator.")
        #expect(await waitUntil { await title(engine) == "Paper Prix F1 notebook" })
        let digest = try #require(model.digests.first)
        #expect(digest.prompts == ["make a notebook that simulates the paper prix f1 race"])
        #expect(digest.replies == ["I created notebook.ipynb with a lap simulator."])
        #expect(digest.folder == "f1-notebook")
        #expect(await engine.record(for: AgentSessionKey(kind: .claude, sessionID: "s-1"))?.hasExplicitTitle == true)
        // Nothing new in the opening: no second call.
        _ = await engine.handleHook(hook("PreToolUse", #"{"session_id":"s-1","tool_name":"Read","tool_input":{"file_path":"/work/a.swift"}}"#))
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.digests.count == 1)
        #expect(await engine.metrics.generatedTitles == 1)
    }

    @Test func unavailableModelKeepsHeuristics() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let model = FakeModel()
        model.state.withLock { $0.available = false }
        let engine = makeEngine(home: home, model: model)
        await runTurn(engine)
        try await Task.sleep(for: .milliseconds(300))
        let heuristic = await title(engine)
        #expect(heuristic == "Make a notebook that simulates the paper prix…")
        #expect(model.digests.isEmpty)
        #expect(await engine.sessions().first?.summary == "Done.")
    }

    @Test func noGeneratorIsTheOldBehaviour() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let engine = makeEngine(home: home, model: nil)
        await runTurn(engine)
        try await Task.sleep(for: .milliseconds(150))
        let heuristic = await title(engine)
        #expect(heuristic == "Make a notebook that simulates the paper prix…")
        #expect(await engine.generationStats().calls == 0)
    }

    @Test func failuresFallBackAndAreNotRetried() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let model = FakeModel()
        model.state.withLock { $0.fail = true }
        let engine = makeEngine(home: home, model: model)
        await runTurn(engine)
        #expect(await waitUntil { model.digests.count == 1 })
        try await Task.sleep(for: .milliseconds(150))
        let heuristic = await title(engine)
        #expect(heuristic == "Make a notebook that simulates the paper prix…")
        // Same opening, more activity (past the queue's spacing): the failed input isn't sent again.
        _ = await engine.handleHook(hook("PreToolUse", #"{"session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"}}"#))
        _ = await engine.handleHook(hook("PostToolUse", #"{"session_id":"s-1","tool_name":"Bash"}"#))
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.digests.count == 1)
        #expect(await engine.generationStats().failures == 1)
        // Garbage output is a failure too.
        #expect(GeneratedTextCleaner.title("  \n ") == nil)
    }

    @Test func userRenameWinsOverGeneratedTitle() async throws {
        var record = SessionRecord(session: AgentSession(id: AgentSessionKey(kind: .claude, sessionID: "x"), cwd: "/work/app"))
        record.generatedTitle = "Generated name"
        record.nativeTitle = "Agent's own title"
        record.nativeTitleRank = 2
        var session = record.session
        AgentReducer.refreshTitle(&session, record: &record)
        #expect(session.title == "Generated name")
        record.nativeTitle = "My rename"
        record.nativeTitleRank = 3
        AgentReducer.refreshTitle(&session, record: &record)
        #expect(session.title == "My rename")
    }

    @Test func titlesAreCachedByInputAcrossEngines() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let cache = home.root.appending(path: "generated.json")
        let first = FakeModel()
        let engine = makeEngine(home: home, model: first, cache: cache)
        await runTurn(engine)
        #expect(await waitUntil { await title(engine) == "Paper Prix F1 notebook" })
        // The cache is written once the queue is idle.
        #expect(await waitUntil { FileManager.default.fileExists(atPath: cache.path) })
        let second = FakeModel(titles: ["Something else"])
        let again = makeEngine(home: home, model: second, cache: cache)
        await runTurn(again)
        #expect(await waitUntil { await title(again) == "Paper Prix F1 notebook" })
        #expect(second.digests.isEmpty)
    }

    @Test func oneModelCallAtATime() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let model = FakeModel(titles: ["One", "Two", "Three"].map { "\($0) title here" })
        model.state.withLock { $0.delay = .milliseconds(60) }
        let engine = makeEngine(home: home, model: model)
        for index in 1 ... 3 { await runTurn(engine, session: "s-\(index)", prompt: "task number \(index) for the queue") }
        #expect(await waitUntil(timeout: 5) { model.digests.count == 3 })
        #expect(model.maxRunning == 1)
        #expect(await waitUntil { await engine.sessions().allSatisfy { $0.title?.hasSuffix("title here") == true } })
    }

    @Test func longIdleRepliesGetAOneLineSummary() async throws {
        let home = try TempHome()
        defer { home.remove() }
        let model = FakeModel()
        let engine = makeEngine(home: home, model: model)
        let long = String(repeating: "I updated the pit-stop model and wired it into the race loop. ", count: 4)
        await runTurn(engine, reply: long)
        #expect(await waitUntil { await engine.sessions().first?.summary == "Added the pit-stop model and its tests." })
        #expect(model.summaryCalls == 1)
        // Working again: the summary is the live activity, not the old reply's.
        _ = await engine.handleHook(hook("PreToolUse", #"{"session_id":"s-1","tool_name":"Bash","tool_input":{"command":"pytest"}}"#))
        #expect(await waitUntil { await engine.sessions().first?.summary == "Running pytest" })
        // A short reply is its own summary: no model call.
        await runTurn(engine, reply: "All green.")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await engine.sessions().first?.summary == "All green.")
        #expect(model.summaryCalls == 1)
    }

    @Test func openingKeepsTheEarliestPromptsAndReplies() {
        var list: [SessionRecord.OpeningText] = []
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // History arrives newest-first (a peek), then from the head.
        for offset in [50, 40, 30, 10, 0, 20] {
            AgentReducer.noteOpening("p\(offset)", at: base.addingTimeInterval(Double(offset)), in: &list, limit: 3)
        }
        AgentReducer.noteOpening("p0", at: base, in: &list, limit: 3)
        #expect(list.map(\.text) == ["p0", "p10", "p20"])
    }

    @Test func cleanerTrimsLabelsQuotesAndLength() {
        #expect(GeneratedTextCleaner.title("Title: \"Fix sidebar overflow.\"") == "Fix sidebar overflow")
        #expect(GeneratedTextCleaner.title("**stripe webhook retries**\nExplanation: …") == "Stripe webhook retries")
        #expect(GeneratedTextCleaner.title("Refactor the very large and slow payment reconciliation job") == "Refactor the very large and")
        #expect(GeneratedTextCleaner.title("“Mothership release build”") == "Mothership release build")
        #expect(GeneratedTextCleaner.title("") == nil)
        #expect(GeneratedTextCleaner.title("x") == nil)
        #expect(GeneratedTextCleaner.summary("Summary: \"Added retries to the uploader.\"") == "Added retries to the uploader.")
        #expect(GeneratedTextCleaner.summary(nil) == nil)
    }
}
