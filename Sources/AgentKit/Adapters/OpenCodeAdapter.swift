import Foundation
import ShipModel
import SystemProbe

/// OpenCode (v2, native binary; TUI talks to a background `opencode serve --service`).
/// Hooks come from Mothership's plugin; history from the read-only SQLite DB.
/// See docs/agents/opencode.md.
public struct OpenCodeAdapter: AgentAdapter {
    public let kind = AgentKind.opencode
    public var executableNames: [String] { ["opencode"] }
    public var permissionHoldSeconds: Int

    public init(permissionHoldSeconds: Int = 600) {
        self.permissionHoldSeconds = permissionHoldSeconds
    }

    /// Server, management and one-shot utility subcommands.
    static let excludedSubcommands: Set<String> = [
        "serve", "service", "acp", "web", "mcp", "upgrade", "update", "uninstall", "auth", "models", "stats",
        "debug", "session", "plugin", "api", "export", "import", "github", "agent", "completion", "help",
    ]

    // MARK: Process matching

    public func isCandidate(comm: String) -> Bool {
        comm == "opencode" || ProcessMatching.isInterpreter(comm)
    }

    public func matchesRoot(_ process: ObservedProcess) -> Bool {
        guard let rest = arguments(process) else { return false }
        if let sub = ProcessMatching.subcommand(rest, skipping: 0), Self.excludedSubcommands.contains(sub) { return false }
        return true
    }

    func arguments(_ process: ObservedProcess) -> [String]? {
        let arguments = process.arguments
        if arguments.executableName == "opencode" || arguments.argv0Name == "opencode" {
            return Array(arguments.arguments.dropFirst())
        }
        guard ProcessMatching.isInterpreter(arguments.executableName) || ProcessMatching.isInterpreter(process.snapshot.comm) else {
            return nil
        }
        let all = arguments.arguments
        guard let scriptIndex = all.indices.dropFirst().first(where: { !all[$0].hasPrefix("-") }) else { return nil }
        let script = all[scriptIndex]
        guard (script as NSString).lastPathComponent == "opencode" || script.contains("opencode-ai/") else { return nil }
        return Array(all[(scriptIndex + 1)...])
    }

    // MARK: Plugin events

    public func integration() -> (any IntegrationInstaller)? {
        OpenCodePluginInstaller(permissionTimeout: permissionHoldSeconds + 30)
    }

    static func toolDisplayName(_ tool: String) -> String {
        guard let first = tool.first else { return tool }
        if tool.hasPrefix("mcp__") { return TextSummary.displayToolName(tool) }
        return first.uppercased() + tool.dropFirst()
    }

    public func decodeHook(event: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal] {
        let json = JSONNode.parse(payload) ?? JSONNode(nil)
        let properties = json["properties"]
        let type = json["type"].string ?? event
        let timestamp = envelope?.sentAt ?? Date()
        let info = properties["info"]
        let part = properties["part"]
        let sessionID = properties["sessionID"].text ?? info["sessionID"].text ?? part["sessionID"].text
            ?? (type.hasPrefix("session.") ? info["id"].text : nil)
        let directory = info["directory"].text ?? json["directory"].text ?? envelope?.cwd
        func signal(_ event: SignalEvent, session: String? = sessionID) -> AgentSignal {
            let hint = SessionHint(kind: kind, sessionID: session, surface: envelope?.surface, cwd: directory)
            return AgentSignal(tier: .hook, source: "hook:opencode:\(type)", hint: hint, event: event, timestamp: timestamp)
        }
        let parent = info["parentID"].text

        switch type {
        case "session.created":
            if let parent { return [signal(.subagentStarted, session: parent)] }
            var signals = [signal(.sessionStarted(source: nil))]
            signals.append(signal(.metadata(SessionMetadata(title: Self.informativeTitle(info["title"].text), cwd: directory))))
            return signals
        case "session.updated":
            guard parent == nil else { return [] }
            if info["time"]["archived"].exists { return [signal(.sessionEnded(reason: "archived"))] }
            guard let title = Self.informativeTitle(info["title"].text) else { return [] }
            return [signal(.metadata(SessionMetadata(title: title)))]
        case "session.deleted":
            if let parent { return [signal(.subagentStopped, session: parent)] }
            return [signal(.sessionEnded(reason: "deleted"))]
        case "session.status":
            switch properties["status"]["type"].string {
            case "busy", "retry": return [signal(.observedState(.working(tool: nil)))]
            case "idle": return [signal(.turnCompleted(lastMessage: nil))]
            default: return []
            }
        case "session.idle":
            return [signal(.turnCompleted(lastMessage: nil))]
        case "session.error":
            let error = properties["error"]
            let name = error["name"].text ?? "Error"
            if name == "MessageAbortedError" { return [signal(.turnInterrupted)] }
            return [signal(.failed(message: TextSummary.oneLine(error["data"]["message"].text ?? name)))]
        case "session.compacted":
            return [signal(.toolFinished(tool: "Compacting"))]
        case "message.updated":
            guard info["role"].string == "assistant" else { return [] }
            return [signal(.metadata(SessionMetadata(model: info["modelID"].text)))]
        case "message.user":
            return [signal(.promptSubmitted(prompt: properties["text"].text))]
        case "message.part.updated":
            guard part["type"].string == "tool" else { return [] }
            let tool = Self.toolDisplayName(part["tool"].text ?? "tool")
            switch part["state"]["status"].string {
            case "pending", "running":
                let summary = part["state"]["title"].text ?? TextSummary.toolSummary(tool: tool, input: part["state"]["input"], cwd: directory)
                return [signal(.toolStarted(tool: tool, summary: nonEmpty(summary)))]
            case "completed", "error":
                return [signal(.toolFinished(tool: tool))]
            default:
                return []
            }
        case "permission.asked":
            guard let prompt = Self.prompt(properties, cwd: directory) else { return [] }
            return [signal(.permissionRequested(tool: prompt.tool, summary: prompt.summary, detail: prompt.detail))]
        case "permission.replied":
            return [signal(.permissionCleared)]
        case "question.asked":
            let question = properties["questions"][0]["question"].text
            return [signal(.inputRequested(.question, message: question))]
        case "question.replied", "question.rejected":
            return [signal(.permissionCleared)]
        default:
            return [signal(.activity)]
        }
    }

    static func informativeTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
            !title.hasPrefix("New session"), !title.hasPrefix("Child session")
        else { return nil }
        return title
    }

    static func prompt(_ properties: JSONNode, cwd: String?) -> PermissionPrompt? {
        guard let id = properties["id"].text else { return nil }
        let permission = properties["permission"].text ?? properties["type"].text ?? "permission"
        let patterns = properties["patterns"].array?.compactMap(\.text) ?? properties["pattern"].array?.compactMap(\.text) ?? []
        var summary = patterns.joined(separator: " && ")
        if summary.isEmpty { summary = properties["title"].text ?? "" }
        if permission == "edit" || permission == "write" || permission == "read", let first = patterns.first {
            summary = TextSummary.relativePath(first, cwd: cwd)
        }
        let detail = TextSummary.detail(properties["metadata"])
        return PermissionPrompt(tool: toolDisplayName(permission), summary: TextSummary.oneLine(summary), detail: detail, externalID: id)
    }

    public func permissionPrompt(event: String, payload: Data) -> PermissionPrompt? {
        guard event == "permission.asked", let json = JSONNode.parse(payload) else { return nil }
        return Self.prompt(json["properties"], cwd: json["directory"].text)
    }

    /// Our plugin's reply protocol: `{"decision":"allow"|"deny","message":…}`; empty = no decision.
    public func permissionReply(_ decision: PermissionDecision, event: String, payload: Data) -> HookReply {
        let body: [String: String]
        switch decision {
        case .passthrough: return .passthrough
        case .allow: body = ["decision": "allow"]
        case .deny(let reason): body = ["decision": "deny", "message": reason ?? "Denied from Mothership"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return .passthrough }
        return HookReply(stdout: String(decoding: data, as: UTF8.self))
    }

    /// The request id inside a `permission.replied` payload.
    static func repliedRequestID(_ payload: Data) -> String? {
        JSONNode.parse(payload)?["properties"]["requestID"].text
    }

    // MARK: Database

    static func databasePath(_ home: URL) -> URL { home.appending(path: ".local/share/opencode/opencode.db") }

    public func transcriptSources(home: URL) -> [TranscriptSource] {
        let database = Self.databasePath(home)
        let prefix = database.path
        return [TranscriptSource(format: .sqlite, root: database) { $0.hasPrefix(prefix) }]
    }

    public func decodeTranscript(_ record: TranscriptRecord, state: inout TranscriptDecodeState) -> [AgentSignal] {
        guard case .openCodeSession(let row) = record, row.parentID == nil else { return [] }
        let hint = SessionHint(kind: kind, sessionID: row.id, cwd: row.directory)
        func signal(_ event: SignalEvent) -> AgentSignal {
            AgentSignal(tier: .transcript, source: "db:opencode", hint: hint, event: event, timestamp: row.updatedAt)
        }
        if row.archived { return [signal(.sessionEnded(reason: "archived"))] }
        var metadata = SessionMetadata(
            title: Self.informativeTitle(row.title), model: row.model, cwd: row.directory,
            lastUserPrompt: row.lastUserText, lastAssistantMessage: row.lastAssistantText, startedAt: row.createdAt
        )
        metadata.contextWindow = Pricing.contextWindow(for: row.model)
        if row.cost > 0 { metadata.reportedCostUSD = row.cost }
        var signals = [signal(.metadata(metadata)), signal(.usage(row.usage, .replace))]
        if let state = row.state { signals.append(signal(.observedState(state))) }
        return signals
    }

    public func bindSession(_ process: ObservedProcess, context: BindingContext) -> SessionBinding? {
        let rest = arguments(process) ?? []
        for flag in ["--session", "-s"] {
            if let index = rest.firstIndex(of: flag), rest.indices.contains(index + 1) {
                return SessionBinding(sessionID: rest[index + 1])
            }
        }
        if let value = rest.first(where: { $0.hasPrefix("--session=") }) {
            return SessionBinding(sessionID: String(value.dropFirst("--session=".count)))
        }
        guard let cwd = process.cwd else { return nil }
        let start = process.snapshot.startTime.addingTimeInterval(-5)
        guard let row = context.openCodeSessions(cwd).first(where: { $0.parentID == nil && $0.updatedAt >= start }) else { return nil }
        return SessionBinding(sessionID: row.id)
    }

    public func screenRules() -> [ScreenRule] {
        [ScreenRule(pattern: "Permission required|Allow (once|always)", state: .needsInput(.permission))]
    }

    public func resumeCommand(session: String, cwd: String) -> [String]? { ["opencode", "--session", session] }

    public func launchCommand(prompt: String?, cwd: String) -> [String] {
        guard let prompt, !prompt.isEmpty else { return ["opencode"] }
        return ["opencode", "--prompt", prompt]
    }
}
