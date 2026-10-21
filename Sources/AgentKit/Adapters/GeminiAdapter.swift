import CryptoKit
import Foundation
import ShipModel
import SystemProbe

/// Gemini CLI (node). Hooks exist from v0.26; 0.18.x has the hook runner but never fires it,
/// so on older versions this adapter relies on the process table and chat files.
/// See docs/agents/gemini.md.
public struct GeminiAdapter: AgentAdapter {
    public let kind = AgentKind.gemini
    public var executableNames: [String] { ["gemini"] }

    public init() {}

    static let hookEvents: [String: ClaudeStyleHookDecoder.Event] = [
        "SessionStart": .sessionStart, "SessionEnd": .sessionEnd, "BeforeAgent": .promptSubmit,
        "AfterAgent": .stop, "BeforeTool": .preTool, "AfterTool": .postTool, "Notification": .notification,
        "PreCompress": .preCompact, "BeforeModel": .ignored, "AfterModel": .ignored, "BeforeToolSelection": .ignored,
    ]

    var decoder: ClaudeStyleHookDecoder {
        var decoder = ClaudeStyleHookDecoder(kind: kind, events: Self.hookEvents)
        decoder.stopMessageKeys = ["prompt_response", "last_assistant_message"]
        return decoder
    }

    // MARK: Process matching

    public func isCandidate(comm: String) -> Bool { comm == "gemini" || ProcessMatching.isInterpreter(comm) }

    public func matchesRoot(_ process: ObservedProcess) -> Bool {
        let arguments = process.arguments
        var rest: [String]
        if arguments.executableName == "gemini" || arguments.argv0Name == "gemini" {
            rest = Array(arguments.arguments.dropFirst())
        } else {
            guard ProcessMatching.isInterpreter(arguments.executableName) || ProcessMatching.isInterpreter(process.snapshot.comm) else {
                return false
            }
            let all = arguments.arguments
            guard let scriptIndex = all.indices.dropFirst().first(where: { !all[$0].hasPrefix("-") }) else { return false }
            let script = all[scriptIndex]
            guard script.contains("@google/gemini-cli") || (script as NSString).lastPathComponent == "gemini" else { return false }
            rest = Array(all[(scriptIndex + 1)...])
        }
        if let sub = rest.first(where: { !$0.hasPrefix("-") }), ["mcp", "extensions"].contains(sub) { return false }
        return true
    }

    // MARK: Hooks (v0.26+)

    public func integration() -> (any IntegrationInstaller)? { JSONHooksInstaller.gemini() }

    public func decodeHook(event: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal] {
        decoder.decode(event: event, payload: payload, envelope: envelope)
    }

    // MARK: Chat files (~/.gemini/tmp/<sha256(cwd)>/chats/session-*.json)

    static func tmpRoot(_ home: URL) -> URL { home.appending(path: ".gemini/tmp", directoryHint: .isDirectory) }

    static func projectHash(_ cwd: String) -> String {
        SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func transcriptSources(home: URL) -> [TranscriptSource] {
        let root = Self.tmpRoot(home).path
        return [
            TranscriptSource(format: .jsonDocument, root: Self.tmpRoot(home)) { path in
                path.hasPrefix(root + "/") && path.contains("/chats/session-") && path.hasSuffix(".json")
            }
        ]
    }

    public func transcriptPath(sessionID: String, cwd: String, home: URL) -> String? {
        let chats = Self.tmpRoot(home).appending(path: Self.projectHash(cwd)).appending(path: "chats")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: chats.path) else { return nil }
        let prefix = String(sessionID.prefix(8))
        return files.first { $0.hasPrefix("session-") && $0.contains(prefix) }.map { chats.appending(path: $0).path }
    }

    public func bindSession(_ process: ObservedProcess, context: BindingContext) -> SessionBinding? {
        guard let cwd = process.cwd else { return nil }
        let chats = Self.tmpRoot(context.home).appending(path: Self.projectHash(cwd)).appending(path: "chats")
        guard let files = try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let start = process.snapshot.startTime.addingTimeInterval(-5)
        let newest = files.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date >= start else {
                    return nil
                }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
        guard let (url, _) = newest, let data = try? Data(contentsOf: url), let id = JSONNode.parse(data)?["sessionId"].text else {
            return nil
        }
        return SessionBinding(sessionID: id, transcriptPath: url.path)
    }

    /// The chat file is rewritten whole; recompute totals each time.
    public func decodeTranscript(_ record: TranscriptRecord, state: inout TranscriptDecodeState) -> [AgentSignal] {
        guard case .document(let path, let data) = record, let json = JSONNode.parse(data), let sessionID = json["sessionId"].text else {
            return []
        }
        state.sessionID = sessionID
        let hint = SessionHint(kind: kind, sessionID: sessionID, transcriptPath: path)
        let timestamp = json["lastUpdated"].date ?? Date()
        func signal(_ event: SignalEvent) -> AgentSignal {
            AgentSignal(tier: .transcript, source: "transcript:gemini", hint: hint, event: event, timestamp: timestamp)
        }
        var usage = TokenUsage()
        var model: String?
        var lastUser: String?
        var lastAssistant: String?
        var lastType: String?
        var lastError: String?
        for message in json["messages"].array ?? [] {
            let type = message["type"].string
            switch type {
            case "user":
                lastUser = message["content"].text ?? lastUser
            case "gemini", "model", "assistant":
                lastAssistant = message["content"].text ?? lastAssistant
                model = message["model"].text ?? model
                let tokens = message["tokens"]
                let cached = tokens["cached"].int ?? 0
                usage.inputTokens += max(0, (tokens["input"].int ?? 0) - cached)
                usage.cacheReadTokens += cached
                usage.outputTokens += (tokens["output"].int ?? 0) + (tokens["thoughts"].int ?? 0)
                usage.contextTokens = tokens["total"].int ?? usage.contextTokens
            case "error":
                lastError = message["content"].text
            default:
                break
            }
            if type == "user" || type == "gemini" || type == "error" { lastType = type }
        }
        state.model = model
        usage.contextWindow = Pricing.contextWindow(for: model)
        var signals = [
            signal(.metadata(SessionMetadata(model: model, lastUserPrompt: lastUser, lastAssistantMessage: lastAssistant, startedAt: json["startTime"].date))),
            signal(.usage(usage, .replace)),
        ]
        switch lastType {
        case "user": signals.append(signal(.observedState(.working(tool: nil))))
        case "gemini": signals.append(signal(.observedState(.idle)))
        case "error": signals.append(signal(.observedState(.error(TextSummary.oneLine(lastError ?? "Error")))))
        default: break
        }
        return signals
    }

    public func screenRules() -> [ScreenRule] {
        [
            ScreenRule(pattern: "Allow execution|Apply this change\\?|Waiting for user confirmation", state: .needsInput(.permission)),
            ScreenRule(pattern: "esc to cancel", state: .working(tool: nil)),
        ]
    }

    public func resumeCommand(session: String, cwd: String) -> [String]? { ["gemini", "--resume", session] }

    public func launchCommand(prompt: String?, cwd: String) -> [String] {
        guard let prompt, !prompt.isEmpty else { return ["gemini"] }
        return ["gemini", "-i", prompt]
    }
}
