import Foundation
import ShipModel
import SystemProbe

/// OpenAI Codex CLI (0.146, npm node wrapper → native binary). See docs/agents/codex.md.
public struct CodexAdapter: AgentAdapter {
    public let kind = AgentKind.codex
    public var executableNames: [String] { ["codex"] }
    public var permissionHoldSeconds: Int

    public init(permissionHoldSeconds: Int = 600) {
        self.permissionHoldSeconds = permissionHoldSeconds
    }

    static let hookEvents: [String: ClaudeStyleHookDecoder.Event] = [
        "SessionStart": .sessionStart, "SessionEnd": .sessionEnd, "UserPromptSubmit": .promptSubmit,
        "PreToolUse": .preTool, "PostToolUse": .postTool, "PermissionRequest": .permissionRequest,
        "Stop": .stop, "SubagentStart": .subagentStart, "SubagentStop": .subagentStop,
        "PreCompact": .preCompact, "PostCompact": .postCompact, "Interrupt": .interrupt,
    ]

    /// Subcommands that are servers or management tools, not sessions.
    static let excludedSubcommands: Set<String> = [
        "app-server", "mcp-server", "exec-server", "login", "logout", "mcp", "completion", "update", "doctor",
        "sandbox", "debug", "apply", "cloud", "features", "remote-control", "app", "archive", "delete",
        "unarchive", "help", "plugin",
    ]

    var decoder: ClaudeStyleHookDecoder { ClaudeStyleHookDecoder(kind: kind, events: Self.hookEvents) }

    // MARK: Process matching

    public func isCandidate(comm: String) -> Bool {
        comm == "codex" || ProcessMatching.isInterpreter(comm)
    }

    public func matchesRoot(_ process: ObservedProcess) -> Bool {
        let arguments = arguments(process)
        guard let rest = arguments else { return false }
        if let sub = ProcessMatching.subcommand(rest, skipping: 0), Self.excludedSubcommands.contains(sub) { return false }
        return true
    }

    /// Arguments after the program (native) or after the script (node wrapper); nil if not Codex.
    func arguments(_ process: ObservedProcess) -> [String]? {
        let arguments = process.arguments
        if arguments.executableName == "codex" || arguments.argv0Name == "codex" {
            return Array(arguments.arguments.dropFirst())
        }
        guard ProcessMatching.isInterpreter(arguments.executableName) || ProcessMatching.isInterpreter(process.snapshot.comm) else {
            return nil
        }
        let all = arguments.arguments
        guard let scriptIndex = all.indices.dropFirst().first(where: { !all[$0].hasPrefix("-") }) else { return nil }
        let script = all[scriptIndex]
        let name = (script as NSString).lastPathComponent
        guard name == "codex" || name == "codex.js" && script.contains("@openai/codex") else { return nil }
        return Array(all[(scriptIndex + 1)...])
    }

    // MARK: Hooks

    public func integration() -> (any IntegrationInstaller)? {
        JSONHooksInstaller.codex(permissionTimeout: permissionHoldSeconds + 60)
    }

    public func decodeHook(event: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal] {
        decoder.decode(event: event, payload: payload, envelope: envelope)
    }

    public func permissionPrompt(event: String, payload: Data) -> PermissionPrompt? {
        guard event == "PermissionRequest" else { return nil }
        let json = JSONNode.parse(payload) ?? JSONNode(nil)
        return decoder.permissionPrompt(json, cwd: json["cwd"].text)
    }

    /// Same `hookSpecificOutput.decision` shape as Claude; never `updatedInput`/`interrupt`
    /// (Codex fails closed on those).
    public func permissionReply(_ decision: PermissionDecision, event: String, payload: Data) -> HookReply {
        ClaudeStyleHookDecoder.permissionDecisionJSON(decision)
    }

    // MARK: Transcripts

    static func sessionsRoot(_ home: URL) -> URL { home.appending(path: ".codex/sessions", directoryHint: .isDirectory) }

    static let lineMarkers = [
        "\"session_meta\"", "\"turn_context\"", "\"task_started\"", "\"task_complete\"", "\"turn_aborted\"",
        "\"user_message\"", "\"agent_message\"", "\"token_count\"", "\"function_call", "\"custom_tool_call",
        "approval_request\"",
    ]

    static func sessionIndex(_ home: URL) -> URL { home.appending(path: ".codex/session_index.jsonl") }

    /// `~/.codex/sessions/YYYY/MM/DD` for a date (where new rollouts appear).
    static func dayDirectory(_ home: URL, _ date: Date) -> URL {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return sessionsRoot(home).appending(path: String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    }

    public func transcriptSources(home: URL) -> [TranscriptSource] {
        let root = Self.sessionsRoot(home).path
        let index = Self.sessionIndex(home)
        let indexPath = index.path
        return [
            TranscriptSource(
                format: .jsonl, root: Self.sessionsRoot(home), lineMarkers: Self.lineMarkers,
                watchDirectories: { date in [Self.dayDirectory(home, date)] }
            ) { path in
                guard path.hasPrefix(root + "/"), path.hasSuffix(".jsonl") else { return false }
                return (path as NSString).lastPathComponent.hasPrefix("rollout-")
            },
            // `{id, thread_name, updated_at}` per line: Codex's own session titles.
            TranscriptSource(format: .jsonl, root: index.deletingLastPathComponent(), eagerFiles: [index]) { $0 == indexPath },
        ]
    }

    /// A `session_index.jsonl` line → an attach-only title for that thread.
    func decodeIndexLine(_ json: JSONNode) -> [AgentSignal] {
        guard let id = json["id"].text, let name = json["thread_name"].text else { return [] }
        let hint = SessionHint(kind: kind, sessionID: id, attachOnly: true)
        let metadata = SessionMetadata(title: name, titleSource: .agent)
        return [AgentSignal(tier: .transcript, source: "index:codex", hint: hint, event: .metadata(metadata), timestamp: json["updated_at"].date ?? .distantPast)]
    }

    /// `rollout-2026-08-11T23-09-40-<uuid>.jsonl` → `<uuid>`.
    static func sessionID(fromRolloutPath path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.hasPrefix("rollout-"), name.count >= 36 else { return nil }
        let candidate = String(name.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    static func isRolloutPath(_ path: String) -> Bool {
        path.contains("/sessions/") && (path as NSString).lastPathComponent.hasPrefix("rollout-") && path.hasSuffix(".jsonl")
    }

    public func transcriptPath(sessionID: String, cwd: String, home: URL) -> String? {
        // Rollouts live under YYYY/MM/DD; look back a week.
        let root = Self.sessionsRoot(home)
        let calendar = Calendar(identifier: .gregorian)
        for daysAgo in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let directory = root.appending(path: String(format: "%04d/%02d/%02d", year, month, dayOfMonth))
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            if let match = files.first(where: { $0.hasSuffix("\(sessionID).jsonl") }) {
                return directory.appending(path: match).path
            }
        }
        return nil
    }

    public func bindSession(_ process: ObservedProcess, context: BindingContext) -> SessionBinding? {
        // The native binary keeps its rollout file open; the node wrapper's child holds it.
        let pids = [process.pid] + context.table.descendants(of: process.pid).prefix(4).map(\.pid)
        for pid in pids {
            if let path = context.openFiles(pid).first(where: Self.isRolloutPath), let id = Self.sessionID(fromRolloutPath: path) {
                return SessionBinding(sessionID: id, transcriptPath: path)
            }
        }
        // `codex resume <id>`.
        let rest = arguments(process) ?? []
        if let index = rest.firstIndex(of: "resume"), rest.indices.contains(index + 1), UUID(uuidString: rest[index + 1]) != nil {
            let id = rest[index + 1]
            return SessionBinding(sessionID: id, transcriptPath: transcriptPath(sessionID: id, cwd: process.cwd ?? "", home: context.home))
        }
        return nil
    }

    public func decodeTranscript(_ record: TranscriptRecord, state: inout TranscriptDecodeState) -> [AgentSignal] {
        guard case .line(let path, let data) = record, !state.ignored, let json = JSONNode.parse(data) else { return [] }
        if path.hasSuffix("/session_index.jsonl") { return decodeIndexLine(json) }
        if state.sessionID == nil { state.sessionID = Self.sessionID(fromRolloutPath: path) }
        let payload = json["payload"]
        let timestamp = json["timestamp"].date ?? Date()
        var signals: [AgentSignal] = []
        func signal(_ event: SignalEvent) -> AgentSignal {
            let hint = SessionHint(kind: kind, sessionID: state.sessionID, cwd: state.cwd, transcriptPath: path)
            return AgentSignal(tier: .transcript, source: "transcript:codex", hint: hint, event: event, timestamp: timestamp)
        }

        switch json["type"].string {
        case "session_meta":
            // Subagent rollouts belong to their parent thread; don't surface them as sessions.
            if payload["source"]["subagent"].exists || payload["parent_thread_id"].text != nil && payload["source"].object != nil {
                state.ignored = true
                return []
            }
            if let id = payload["id"].text { state.sessionID = id }
            if let cwd = payload["cwd"].text { state.cwd = cwd }
            var metadata = SessionMetadata(cwd: state.cwd, transcriptPath: path, startedAt: payload["timestamp"].date)
            if let originator = payload["originator"].text, !originator.hasPrefix("codex_cli") { metadata.hostApp = originator }
            if let branch = payload["git"]["branch"].text { metadata.branch = branch }
            signals.append(signal(.metadata(metadata)))
        case "turn_context":
            if let cwd = payload["cwd"].text { state.cwd = cwd }
            if let model = payload["model"].text { state.model = model }
            signals.append(signal(.metadata(SessionMetadata(model: payload["model"].text, cwd: payload["cwd"].text))))
        case "event_msg":
            switch payload["type"].string {
            case "task_started":
                signals.append(signal(.promptSubmitted(prompt: nil)))
                if let window = payload["model_context_window"].int {
                    signals.append(signal(.metadata(SessionMetadata(contextWindow: window))))
                }
            case "task_complete":
                signals.append(signal(.turnCompleted(lastMessage: payload["last_agent_message"].text)))
            case "turn_aborted":
                signals.append(signal(.turnInterrupted))
            case "user_message":
                if let message = payload["message"].text, !message.hasPrefix("<") {
                    signals.append(signal(.promptSubmitted(prompt: message)))
                }
            case "agent_message":
                if let message = payload["message"].text {
                    signals.append(signal(.metadata(SessionMetadata(lastAssistantMessage: message))))
                }
            case "token_count":
                let info = payload["info"]
                if let total = Self.usage(info["total_token_usage"]) {
                    var usage = total
                    usage.contextTokens = info["last_token_usage"]["total_tokens"].int
                    usage.contextWindow = info["model_context_window"].int
                    signals.append(signal(.usage(usage, .replace)))
                }
            case "exec_approval_request", "apply_patch_approval_request":
                let command = payload["command"].array?.compactMap(\.string).joined(separator: " ")
                signals.append(signal(.inputRequested(.permission, message: command)))
            default:
                break
            }
        case "response_item":
            switch payload["type"].string {
            case "function_call", "custom_tool_call", "local_shell_call":
                let name = payload["name"].text ?? "shell"
                let tool = Self.toolName(name)
                var input = payload["input"]
                if let arguments = payload["arguments"].string, let parsed = JSONNode.parse(arguments) { input = parsed }
                let summary: String
                if let text = input.string {
                    summary = tool == "apply_patch" ? (TextSummary.patchSummary(text) ?? TextSummary.oneLine(text)) : TextSummary.oneLine(text)
                } else {
                    summary = TextSummary.toolSummary(tool: tool, input: input, cwd: state.cwd)
                }
                signals.append(signal(.toolStarted(tool: tool, summary: nonEmpty(summary))))
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                signals.append(signal(.toolFinished(tool: nil)))
            default:
                break
            }
        default:
            break
        }
        return signals
    }

    static func toolName(_ name: String) -> String {
        switch name {
        case "exec_command", "shell", "exec", "local_shell", "container.exec": "Bash"
        default: TextSummary.displayToolName(name)
        }
    }

    /// OpenAI usage: cached tokens are a subset of input tokens.
    static func usage(_ node: JSONNode) -> TokenUsage? {
        guard node.object != nil else { return nil }
        let input = node["input_tokens"].int ?? 0
        let cached = node["cached_input_tokens"].int ?? 0
        return TokenUsage(
            inputTokens: max(0, input - cached), outputTokens: node["output_tokens"].int ?? 0,
            cacheReadTokens: cached, cacheWriteTokens: node["cache_write_input_tokens"].int ?? 0
        )
    }

    // MARK: Commands

    public func screenRules() -> [ScreenRule] {
        [
            ScreenRule(pattern: "Allow command\\?|Would you like to run|approve this", state: .needsInput(.permission)),
            ScreenRule(pattern: "esc to interrupt", state: .working(tool: nil)),
        ]
    }

    public func resumeCommand(session: String, cwd: String) -> [String]? { ["codex", "resume", session] }

    public func launchCommand(prompt: String?, cwd: String) -> [String] {
        guard let prompt, !prompt.isEmpty else { return ["codex"] }
        return ["codex", prompt]
    }
}
