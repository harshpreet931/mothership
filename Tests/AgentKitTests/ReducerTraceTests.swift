import Foundation
import ShipModel
import Testing

@testable import AgentKit

// Golden traces: Fixtures/traces/*.jsonl. Each line is one step (lines starting with # are
// comments). A step either applies a synthetic signal through `SessionStore` (the same path the
// engine uses) or is a pseudo-event (`tick`, `read`, `check`), then asserts expectations.
//
//   at        seconds since trace start (the reducer's `now`); `ts` overrides the signal time
//   tier      hook | terminal | transcript | process | heuristic
//   kind, session, pid, surface   the hint (surface is a symbolic name)
//   event     sessionStart prompt toolStart toolEnd permission permissionCleared input stop
//             interrupt failure sessionEnd processSeen processExited observed usage
//             | tick read check
//   watched   whether the user looks at the session's surface (default false)
//   expect    starting | idle | working | working:<tool> | needsInput:<reason> | error | ended
//   expectKey, expectCount, expectUnread, expectPID, expectTitle, expectActivity,
//   expectLastMessage, expectTokens

struct TraceStep: Decodable {
    var at: Double
    var ts: Double?
    var tier: String?
    var kind: String?
    var session: String?
    var pid: Int32?
    var surface: String?
    var heuristic: Bool?
    var event: String
    var text: String?
    var tool: String?
    var summary: String?
    var source: String?
    var state: String?
    var reason: String?
    var watched: Bool?
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var mode: String?
    var expect: String?
    var expectKey: String?
    var expectCount: Int?
    var expectUnread: Bool?
    var expectPID: Int32?
    var expectTitle: String?
    var expectActivity: String?
    var expectLastMessage: String?
    var expectTokens: Int?
}

enum Trace {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func directory() throws -> URL {
        let resources = try #require(Bundle.module.resourceURL)
        return resources.appending(path: "Fixtures/traces")
    }

    static func names() -> [String] {
        guard let directory = try? directory(),
            let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return files.filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    static func steps(_ name: String) throws -> [TraceStep] {
        let text = try String(contentsOf: try directory().appending(path: name), encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return try JSONDecoder().decode(TraceStep.self, from: Data(trimmed.utf8))
        }
    }

    static func state(_ text: String) -> AgentState? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "starting": return .starting
        case "idle": return .idle
        case "working": return .working(tool: parts.count > 1 ? parts[1] : nil)
        case "needsInput": return .needsInput(InputReason(rawValue: parts.count > 1 ? parts[1] : "other") ?? .other)
        case "error": return .error(parts.count > 1 ? parts[1] : "error")
        case "ended": return .ended
        default: return nil
        }
    }

    static func tier(_ text: String?) -> SignalTier {
        switch text {
        case "terminal": .terminal
        case "transcript": .transcript
        case "process": .process
        case "heuristic": .heuristic
        default: .hook
        }
    }

    static func event(_ step: TraceStep) -> SignalEvent? {
        switch step.event {
        case "sessionStart": .sessionStarted(source: step.source)
        case "prompt": .promptSubmitted(prompt: step.text)
        case "toolStart": .toolStarted(tool: step.tool ?? "Tool", summary: step.summary)
        case "toolEnd": .toolFinished(tool: step.tool)
        case "permission": .permissionRequested(tool: step.tool ?? "Tool", summary: step.summary ?? "", detail: nil)
        case "permissionCleared": .permissionCleared
        case "input": .inputRequested(InputReason(rawValue: step.reason ?? "question") ?? .question, message: step.text)
        case "stop": .turnCompleted(lastMessage: step.text)
        case "interrupt": .turnInterrupted
        case "failure": .failed(message: step.text ?? "error")
        case "sessionEnd": .sessionEnded(reason: step.reason)
        case "processSeen": .processSeen
        case "processExited": .processExited
        case "observed": step.state.flatMap(Trace.state).map { .observedState($0) }
        case "usage":
            .usage(
                TokenUsage(inputTokens: step.input ?? 0, outputTokens: step.output ?? 0, cacheReadTokens: step.cacheRead ?? 0, cacheWriteTokens: step.cacheWrite ?? 0),
                step.mode == "replace" ? .replace : .add
            )
        default: nil
        }
    }

    static func key(_ text: String) -> AgentSessionKey {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        return AgentSessionKey(kind: AgentKind(rawValue: parts[0]), sessionID: parts.count > 1 ? parts[1] : "")
    }
}

@Suite("Reducer golden traces")
struct ReducerTraceTests {
    @Test("trace replays", arguments: Trace.names())
    func replay(_ name: String) throws {
        var store = SessionStore()
        var surfaces: [String: SurfaceID] = [:]
        var lastKey: AgentSessionKey?
        for (index, step) in try Trace.steps(name).enumerated() {
            let now = Trace.epoch.addingTimeInterval(step.at)
            let location = "\(name) step \(index + 1) (\(step.event) @\(step.at))"
            switch step.event {
            case "tick":
                _ = store.tick(now: now) { _ in step.watched ?? false }
            case "read":
                if let key = step.expectKey.map(Trace.key) { store.update(key) { $0.session.unread = false } }
            case "check":
                break
            default:
                let event = try #require(Trace.event(step), "unknown event in \(location)")
                let surface = step.surface.map { name in surfaces[name] ?? { let id = SurfaceID(); surfaces[name] = id; return id }() }
                let hint = SessionHint(kind: AgentKind(rawValue: step.kind ?? "claude"), sessionID: step.session, pid: step.pid, surface: surface)
                let signal = AgentSignal(
                    tier: Trace.tier(step.tier), source: "trace", hint: hint, event: event,
                    timestamp: Trace.epoch.addingTimeInterval(step.ts ?? step.at), isHeuristic: step.heuristic ?? false
                )
                let change = store.apply(signal, now: now) { _ in step.watched ?? false }
                lastKey = change?.key ?? lastKey
            }
            let key = step.expectKey.map(Trace.key) ?? lastKey
            if let count = step.expectCount {
                #expect(store.records.count == count, "\(location): session count")
            }
            guard step.expect != nil || step.expectUnread != nil || step.expectPID != nil || step.expectTitle != nil
                || step.expectActivity != nil || step.expectLastMessage != nil || step.expectTokens != nil
            else { continue }
            let resolvedKey = try #require(key, "\(location): no session key")
            let record = try #require(store[resolvedKey], "\(location): no session \(resolvedKey)")
            if let expected = step.expect.flatMap(Trace.state) {
                if case .error = expected, case .error = record.session.state {
                    // Any error message matches "error".
                } else {
                    #expect(record.session.state == expected, "\(location): state")
                }
            }
            if let unread = step.expectUnread { #expect(record.session.unread == unread, "\(location): unread") }
            if let pid = step.expectPID { #expect(record.session.pid == pid, "\(location): pid") }
            if let title = step.expectTitle { #expect(record.session.title == title, "\(location): title") }
            if let activity = step.expectActivity { #expect(record.currentActivity == activity, "\(location): activity") }
            if let message = step.expectLastMessage { #expect(record.session.lastAssistantMessage == message, "\(location): last message") }
            if let tokens = step.expectTokens {
                let usage = record.session.usage
                #expect(usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens == tokens, "\(location): tokens")
            }
        }
    }

    @Test func everyTraceFileIsDiscovered() {
        #expect(Trace.names().count >= 6)
    }
}

@Suite("Reducer rules")
struct ReducerRuleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ state: AgentState = .idle) -> SessionRecord {
        SessionRecord(session: AgentSession(id: AgentSessionKey(kind: .claude, sessionID: "x"), cwd: "/tmp", state: state, startedAt: start, lastActivity: start), lastStateChange: start)
    }

    func signal(_ event: SignalEvent, tier: SignalTier = .hook, at seconds: Double = 0, heuristic: Bool = false) -> AgentSignal {
        AgentSignal(tier: tier, source: "test", hint: SessionHint(kind: .claude, sessionID: "x"), event: event, timestamp: start.addingTimeInterval(seconds), isHeuristic: heuristic)
    }

    @Test func pendingPermissionBlocksLowerTiers() {
        var current = record(.needsInput(.permission))
        current.session.pendingPermission = PermissionRequest(session: current.key, surface: nil, toolName: "Bash", summary: "ls", expiresAt: start.addingTimeInterval(600))
        let next = AgentReducer.reduce(current, signal(.observedState(.idle), tier: .transcript, at: 20), now: start.addingTimeInterval(20), watched: false)
        #expect(next.session.state == .needsInput(.permission))
        let exited = AgentReducer.reduce(current, signal(.processExited, tier: .process, at: 21), now: start.addingTimeInterval(21), watched: false)
        #expect(exited.session.state == .ended)
        #expect(exited.session.pendingPermission == nil)
    }

    @Test func idleFromStartingDoesNotMarkUnread() {
        let next = AgentReducer.reduce(record(.starting), signal(.sessionStarted(source: "startup")), now: start, watched: false)
        #expect(next.session.state == .idle)
        #expect(next.session.unread == false)
    }

    @Test func subagentCountsNeverGoNegative() {
        var current = record(.working(tool: nil))
        current = AgentReducer.reduce(current, signal(.subagentStarted), now: start, watched: false)
        current = AgentReducer.reduce(current, signal(.subagentStopped), now: start, watched: false)
        current = AgentReducer.reduce(current, signal(.subagentStopped), now: start, watched: false)
        #expect(current.session.activeSubagents == 0)
    }

    @Test func explicitTitleBeatsPromptTitle() {
        var current = record(.idle)
        current = AgentReducer.reduce(current, signal(.promptSubmitted(prompt: "<pasted_content id=\"1\"> Fix login")), now: start, watched: false)
        #expect(current.session.title == "Fix login")
        current = AgentReducer.reduce(current, signal(.metadata(SessionMetadata(title: "Login fix"))), now: start, watched: false)
        #expect(current.session.title == "Login fix")
        #expect(current.hasExplicitTitle)
    }

    @Test func reportedCostClearsEstimateFlag() {
        var current = record(.idle)
        #expect(current.costIsEstimate)
        current = AgentReducer.reduce(current, signal(.metadata(SessionMetadata(reportedCostUSD: 1.25)), tier: .transcript), now: start, watched: false)
        #expect(current.costIsEstimate == false)
        #expect(current.session.usage.costUSD == 1.25)
    }
}
