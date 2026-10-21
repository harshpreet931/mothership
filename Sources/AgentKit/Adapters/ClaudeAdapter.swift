import Foundation
import ShipModel
import SystemProbe

/// Claude Code (native binary, 2.1.x). See docs/agents/claude.md.
public struct ClaudeAdapter: AgentAdapter {
    public let kind = AgentKind.claude
    public var executableNames: [String] { ["claude"] }
    /// Seconds Mothership may hold a PermissionRequest; the installed hook timeout is longer.
    public var permissionHoldSeconds: Int

    public init(permissionHoldSeconds: Int = 600) {
        self.permissionHoldSeconds = permissionHoldSeconds
    }

    static let hookEvents: [String: ClaudeStyleHookDecoder.Event] = [
        "SessionStart": .sessionStart, "SessionEnd": .sessionEnd, "UserPromptSubmit": .promptSubmit,
        "PreToolUse": .preTool, "PostToolUse": .postTool, "PostToolUseFailure": .postTool,
        "PermissionRequest": .permissionRequest, "Notification": .notification, "Stop": .stop,
        "StopFailure": .stopFailure, "SubagentStart": .subagentStart, "SubagentStop": .subagentStop,
        "PreCompact": .preCompact, "PostCompact": .postCompact,
    ]

    /// Management subcommands that are not agent sessions.
    static let excludedSubcommands: Set<String> = [
        "mcp", "config", "doctor", "update", "install", "migrate-installer", "setup-token", "plugin", "auth",
    ]

    var decoder: ClaudeStyleHookDecoder { ClaudeStyleHookDecoder(kind: kind, events: Self.hookEvents) }

    // MARK: Process matching

    public func isCandidate(comm: String) -> Bool {
        comm == "claude" || ProcessMatching.isVersionLike(comm) || ProcessMatching.isInterpreter(comm)
    }

    public func matchesRoot(_ process: ObservedProcess) -> Bool {
        let arguments = process.arguments
        let exe = arguments.executablePath
        let isNative = arguments.executableName == "claude" || arguments.argv0Name == "claude"
            || exe.contains("/claude/versions/")
        if isNative {
            if let first = arguments.arguments.dropFirst().first, Self.excludedSubcommands.contains(first) { return false }
            return true
        }
        let interpreter = ProcessMatching.isInterpreter(arguments.executableName) || ProcessMatching.isInterpreter(process.snapshot.comm)
        guard interpreter else { return false }
        let scripts = ProcessMatching.scriptArguments(arguments.arguments)
        guard let script = scripts.first else { return false }
        let matches = script.contains("@anthropic-ai/claude-code") || (script as NSString).lastPathComponent == "claude"
        guard matches else { return false }
        if let sub = scripts.dropFirst().first, Self.excludedSubcommands.contains(sub) { return false }
        return true
    }

    // MARK: Hooks

    public func integration() -> (any IntegrationInstaller)? {
        JSONHooksInstaller.claude(permissionTimeout: permissionHoldSeconds + 60)
    }

    public func decodeHook(event: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal] {
        decoder.decode(event: event, payload: payload, envelope: envelope)
    }

    public func permissionPrompt(event: String, payload: Data) -> PermissionPrompt? {
        guard event == "PermissionRequest" else { return nil }
        let json = JSONNode.parse(payload) ?? JSONNode(nil)
        return decoder.permissionPrompt(json, cwd: json["cwd"].text)
    }

    public func permissionReply(_ decision: PermissionDecision, event: String, payload: Data) -> HookReply {
        ClaudeStyleHookDecoder.permissionDecisionJSON(decision)
    }

    // MARK: Transcripts

    static func projectsRoot(_ home: URL) -> URL { home.appending(path: ".claude/projects", directoryHint: .isDirectory) }
    static func sessionsRoot(_ home: URL) -> URL { home.appending(path: ".claude/sessions", directoryHint: .isDirectory) }

    static let lineMarkers = [
        "\"type\":\"assistant\"", "\"type\":\"user\"", "\"type\":\"system\"", "\"type\":\"last-prompt\"",
        "\"type\":\"ai-title\"", "\"type\":\"custom-title\"", "\"type\":\"summary\"",
    ]

    public func transcriptSources(home: URL) -> [TranscriptSource] {
        let projects = Self.projectsRoot(home).path
        let sessions = Self.sessionsRoot(home).path
        return [
            TranscriptSource(format: .jsonl, root: Self.projectsRoot(home), lineMarkers: Self.lineMarkers) { path in
                // <projects>/<escaped-cwd>/<session>.jsonl, not subagent files below it.
                guard path.hasSuffix(".jsonl"), path.hasPrefix(projects + "/") else { return false }
                return path.dropFirst(projects.count + 1).split(separator: "/").count == 2
            },
            TranscriptSource(format: .jsonDocument, root: Self.sessionsRoot(home)) { path in
                guard path.hasPrefix(sessions + "/"), path.hasSuffix(".json") else { return false }
                let name = (path as NSString).lastPathComponent.dropLast(5)
                return !name.isEmpty && name.allSatisfy(\.isNumber)
            },
        ]
    }

    /// Claude escapes the cwd by replacing every non-alphanumeric character with "-".
    static func escapedProjectName(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public func transcriptPath(sessionID: String, cwd: String, home: URL) -> String? {
        let projects = Self.projectsRoot(home)
        let direct = projects.appending(path: Self.escapedProjectName(cwd)).appending(path: "\(sessionID).jsonl").path
        if FileManager.default.fileExists(atPath: direct) { return direct }
        guard let directories = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for directory in directories {
            let candidate = projects.appending(path: directory).appending(path: "\(sessionID).jsonl").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func decodeTranscript(_ record: TranscriptRecord, state: inout TranscriptDecodeState) -> [AgentSignal] {
        switch record {
        case .line(let path, let data):
            return decodeLine(path: path, data: data, state: &state)
        case .document(let path, let data):
            return decodeStatusFile(path: path, data: data, processStart: nil)?.signals ?? []
        case .openCodeSession:
            return []
        }
    }

    func decodeLine(path: String, data: Data, state: inout TranscriptDecodeState) -> [AgentSignal] {
        guard let json = JSONNode.parse(data) else { return [] }
        if let id = json["sessionId"].text { state.sessionID = id }
        if state.sessionID == nil {
            state.sessionID = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        if let cwd = json["cwd"].text { state.cwd = cwd }
        let hint = SessionHint(kind: kind, sessionID: state.sessionID, cwd: state.cwd, transcriptPath: path)
        let timestamp = json["timestamp"].date ?? Date()
        func signal(_ event: SignalEvent) -> AgentSignal {
            AgentSignal(tier: .transcript, source: "transcript:claude", hint: hint, event: event, timestamp: timestamp)
        }
        var signals: [AgentSignal] = []
        let sidechain = json["isSidechain"].bool == true

        switch json["type"].string {
        case "user":
            guard !sidechain, json["isMeta"].bool != true else { return [] }
            let content = json["message"]["content"]
            if let text = content.text {
                if !Self.isSyntheticPrompt(text) { signals.append(signal(.promptSubmitted(prompt: text))) }
            } else if let items = content.array {
                if items.contains(where: { $0["type"].string == "tool_result" }) {
                    signals.append(signal(.toolFinished(tool: nil)))
                } else if let text = items.compactMap({ $0["type"].string == "text" ? $0["text"].text : nil }).first,
                    !Self.isSyntheticPrompt(text)
                {
                    signals.append(signal(.promptSubmitted(prompt: text)))
                }
            }
            if let branch = json["gitBranch"].text, branch != "HEAD" {
                signals.append(signal(.metadata(SessionMetadata(branch: branch))))
            }
        case "assistant":
            let message = json["message"]
            let model = message["model"].text.flatMap { $0.hasPrefix("<") ? nil : $0 }
            if let model { state.model = model }
            var metadata = SessionMetadata(model: model)
            if let usage = Self.usage(message["usage"]) {
                let delta: TokenUsage
                if let id = message["id"].text, id == state.lastMessageID, let previous = state.lastMessageUsage {
                    delta = Self.subtract(usage, previous)
                } else {
                    delta = usage
                }
                state.lastMessageID = message["id"].text
                state.lastMessageUsage = usage
                if delta != .zero { signals.append(signal(.usage(delta, .add))) }
                if !sidechain {
                    metadata.contextTokens = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
                    metadata.contextWindow = Pricing.contextWindow(for: state.model)
                }
            }
            guard !sidechain else { return signals }
            var lastText: String?
            for item in message["content"].array ?? [] {
                switch item["type"].string {
                case "tool_use":
                    let tool = TextSummary.displayToolName(item["name"].text ?? "Tool")
                    let summary = TextSummary.toolSummary(tool: tool, input: item["input"], cwd: state.cwd)
                    signals.append(signal(.toolStarted(tool: tool, summary: nonEmpty(summary))))
                case "text":
                    if let text = item["text"].text { lastText = text }
                default:
                    break
                }
            }
            if let lastText { metadata.lastAssistantMessage = lastText }
            if !metadata.isEmpty { signals.insert(signal(.metadata(metadata)), at: 0) }
            if message["stop_reason"].string == "end_turn" {
                signals.append(signal(.turnCompleted(lastMessage: lastText)))
            }
        case "system":
            if json["subtype"].string == "turn_duration" { signals.append(signal(.turnCompleted(lastMessage: nil))) }
        case "last-prompt":
            if let prompt = json["lastPrompt"].text { signals.append(signal(.metadata(SessionMetadata(lastUserPrompt: prompt)))) }
        case "ai-title":
            if let title = json["aiTitle"].text { signals.append(signal(.metadata(SessionMetadata(title: title)))) }
        case "custom-title":
            if let title = json["customTitle"].text { signals.append(signal(.metadata(SessionMetadata(title: title)))) }
        case "summary":
            if let title = json["summary"].text { signals.append(signal(.metadata(SessionMetadata(title: title)))) }
        default:
            break
        }
        return signals
    }

    /// Slash-command echoes and injected context aren't user prompts.
    static func isSyntheticPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command")
            || trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("Caveat: ") || trimmed.hasPrefix("[Request interrupted")
    }

    static func usage(_ node: JSONNode) -> TokenUsage? {
        guard node.object != nil else { return nil }
        return TokenUsage(
            inputTokens: node["input_tokens"].int ?? 0, outputTokens: node["output_tokens"].int ?? 0,
            cacheReadTokens: node["cache_read_input_tokens"].int ?? 0,
            cacheWriteTokens: node["cache_creation_input_tokens"].int ?? 0
        )
    }

    static func subtract(_ lhs: TokenUsage, _ rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(0, lhs.inputTokens - rhs.inputTokens), outputTokens: max(0, lhs.outputTokens - rhs.outputTokens),
            cacheReadTokens: max(0, lhs.cacheReadTokens - rhs.cacheReadTokens),
            cacheWriteTokens: max(0, lhs.cacheWriteTokens - rhs.cacheWriteTokens)
        )
    }

    // MARK: Per-pid status files (~/.claude/sessions/<pid>.json)

    /// Reads only non-secret fields: pid, sessionId, cwd, status, name, timestamps.
    func decodeStatusFile(path: String, data: Data, processStart: Date?) -> SessionBinding? {
        guard let json = JSONNode.parse(data), let sessionID = json["sessionId"].text, let pid = json["pid"].int else { return nil }
        let updated = json["updatedAt"].date
        if let processStart, let updated, updated < processStart.addingTimeInterval(-5) { return nil }
        let cwd = json["cwd"].text
        let home = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let transcript = cwd.flatMap { transcriptPath(sessionID: sessionID, cwd: $0, home: home) }
        let hint = SessionHint(kind: kind, sessionID: sessionID, pid: Int32(pid), cwd: cwd, transcriptPath: transcript)
        let timestamp = json["statusUpdatedAt"].date ?? updated ?? Date()
        var signals: [AgentSignal] = []
        var metadata = SessionMetadata(cwd: cwd, transcriptPath: transcript)
        if let name = json["name"].text { metadata.title = name }
        metadata.startedAt = json["startedAt"].date
        signals.append(AgentSignal(tier: .transcript, source: "status:claude", hint: hint, event: .metadata(metadata), timestamp: timestamp))
        let state: AgentState? =
            switch json["status"].string {
            case "busy": .working(tool: nil)
            case "idle": .idle
            case "waiting":
                (json["waitingFor"].text ?? "").localizedCaseInsensitiveContains("permission")
                    ? .needsInput(.permission) : .needsInput(.question)
            default: nil
            }
        if let state {
            signals.append(AgentSignal(tier: .transcript, source: "status:claude", hint: hint, event: .observedState(state), timestamp: timestamp))
        }
        return SessionBinding(sessionID: sessionID, transcriptPath: transcript, signals: signals)
    }

    public func bindSession(_ process: ObservedProcess, context: BindingContext) -> SessionBinding? {
        let file = Self.sessionsRoot(context.home).appending(path: "\(process.pid).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return decodeStatusFile(path: file.path, data: data, processStart: process.snapshot.startTime)
    }

    // MARK: Terminal

    public func titleRule() -> TitleRule? {
        TitleRule(working: "^[\\x{2800}-\\x{28FF}]", idle: "^✳", strip: "^[\\x{2800}-\\x{28FF}✳✶✻✽✢·*]+\\s*")
    }

    public func screenRules() -> [ScreenRule] {
        [
            ScreenRule(pattern: "Do you want to (proceed|make this edit|create)", state: .needsInput(.permission)),
            ScreenRule(pattern: "esc to interrupt", state: .working(tool: nil)),
        ]
    }

    public func resumeCommand(session: String, cwd: String) -> [String]? { ["claude", "--resume", session] }

    public func launchCommand(prompt: String?, cwd: String) -> [String] {
        guard let prompt, !prompt.isEmpty else { return ["claude"] }
        return ["claude", prompt]
    }
}
