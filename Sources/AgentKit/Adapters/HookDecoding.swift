import Foundation
import ShipModel

/// Decoder for the hook payload family Claude Code, Codex and Gemini CLI share: one JSON
/// object on stdin with `session_id`, `transcript_path`, `cwd`, `hook_event_name`, plus
/// event-specific fields. Unknown events and fields are ignored.
struct ClaudeStyleHookDecoder: Sendable {
    /// Canonical event names this decoder understands.
    enum Event: Sendable {
        case sessionStart, sessionEnd, promptSubmit, preTool, postTool, permissionRequest
        case notification, stop, stopFailure, subagentStart, subagentStop, preCompact, postCompact
        case interrupt, ignored
    }

    let kind: AgentKind
    /// Agent event name → canonical event.
    let events: [String: Event]
    /// Field holding the assistant's final text on stop events.
    var stopMessageKeys: [String] = ["last_assistant_message"]
    var promptKeys: [String] = ["prompt"]

    func decode(event name: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal] {
        let json = JSONNode.parse(payload) ?? JSONNode(nil)
        let event = events[name] ?? events[json["hook_event_name"].string ?? ""] ?? .ignored
        let timestamp = envelope?.sentAt ?? Date()
        let cwd = json["cwd"].text ?? envelope?.cwd
        let hint = SessionHint(
            kind: kind, sessionID: json["session_id"].text, surface: envelope?.surface, cwd: cwd,
            transcriptPath: json["transcript_path"].text
        )
        func signal(_ event: SignalEvent) -> AgentSignal {
            AgentSignal(tier: .hook, source: "hook:\(kind.rawValue):\(name)", hint: hint, event: event, timestamp: timestamp)
        }
        var signals: [AgentSignal] = []

        switch event {
        case .sessionStart:
            signals.append(signal(.sessionStarted(source: json["source"].text)))
        case .sessionEnd:
            signals.append(signal(.sessionEnded(reason: json["reason"].text)))
        case .promptSubmit:
            let prompt = promptKeys.lazy.compactMap { json[$0].text }.first
            signals.append(signal(.promptSubmitted(prompt: prompt)))
        case .preTool:
            let tool = toolName(json)
            signals.append(signal(.toolStarted(tool: tool, summary: nonEmpty(TextSummary.toolSummary(tool: tool, input: json["tool_input"], cwd: cwd)))))
        case .postTool:
            signals.append(signal(.toolFinished(tool: json["tool_name"].text.map(TextSummary.displayToolName))))
        case .permissionRequest:
            let prompt = permissionPrompt(json, cwd: cwd)
            signals.append(signal(.permissionRequested(tool: prompt.tool, summary: prompt.summary, detail: prompt.detail)))
        case .notification:
            let type = json["notification_type"].text ?? ""
            let message = json["message"].text
            switch type {
            case "permission_prompt", "ToolPermission":
                signals.append(signal(.inputRequested(.permission, message: message)))
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                signals.append(signal(.inputRequested(.question, message: message)))
            case "idle_prompt", "auth_success", "agent_completed", "elicitation_complete", "elicitation_response":
                // Reminders and confirmations; the state is already known from Stop/answers.
                break
            default:
                if let message, message.localizedCaseInsensitiveContains("permission") {
                    signals.append(signal(.inputRequested(.permission, message: message)))
                }
            }
        case .stop:
            let message = stopMessageKeys.lazy.compactMap { json[$0].text }.first
            signals.append(signal(.turnCompleted(lastMessage: message)))
        case .stopFailure:
            let reason = json["error_details"].text ?? json["error"].text ?? "Turn failed"
            signals.append(signal(.failed(message: TextSummary.oneLine(reason))))
        case .subagentStart:
            signals.append(signal(.subagentStarted))
        case .subagentStop:
            signals.append(signal(.subagentStopped))
        case .preCompact:
            signals.append(signal(.compacting))
        case .postCompact:
            if json["trigger"].text == "manual" {
                signals.append(signal(.turnCompleted(lastMessage: nil)))
            } else {
                signals.append(signal(.toolFinished(tool: "Compacting")))
            }
        case .interrupt:
            signals.append(signal(.turnInterrupted))
        case .ignored:
            signals.append(signal(.activity))
        }
        var metadata = SessionMetadata(title: json["session_title"].text, model: modelName(json["model"]))
        if event == .sessionStart {
            metadata.cwd = cwd
            metadata.transcriptPath = json["transcript_path"].text
        }
        if !metadata.isEmpty { signals.insert(signal(.metadata(metadata)), at: 0) }
        return signals
    }

    func permissionPrompt(_ json: JSONNode, cwd: String?) -> PermissionPrompt {
        let tool = toolName(json)
        let input = json["tool_input"]
        var summary = TextSummary.toolSummary(tool: tool, input: input, cwd: cwd)
        if summary.isEmpty, let description = input["description"].text { summary = TextSummary.oneLine(description) }
        return PermissionPrompt(tool: tool, summary: summary, detail: TextSummary.detail(input))
    }

    func toolName(_ json: JSONNode) -> String {
        TextSummary.displayToolName(json["tool_name"].text ?? "Tool")
    }

    func modelName(_ node: JSONNode) -> String? {
        if let text = node.text { return text }
        return node["id"].text ?? node["display_name"].text
    }

    /// `hookSpecificOutput.decision` JSON for PermissionRequest (Claude Code and Codex share it).
    static func permissionDecisionJSON(_ decision: PermissionDecision, eventName: String = "PermissionRequest") -> HookReply {
        let body: [String: Any]
        switch decision {
        case .passthrough:
            return .passthrough
        case .allow:
            body = ["behavior": "allow"]
        case .deny(let reason):
            body = ["behavior": "deny", "message": reason?.isEmpty == false ? reason ?? "" : "Denied from Mothership"]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": eventName, "decision": body]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .passthrough
        }
        return HookReply(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
    }
}

func nonEmpty(_ string: String?) -> String? {
    guard let string, !string.isEmpty else { return nil }
    return string
}
