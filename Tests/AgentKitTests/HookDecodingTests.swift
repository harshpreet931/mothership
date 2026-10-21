import Foundation
import ShipModel
import Testing

@testable import AgentKit

/// Synthetic payloads shaped like the documented schemas (docs/agents/*.md).
@Suite("Hook decoding")
struct HookDecodingTests {
    let surface = SurfaceID()

    func envelope(_ agent: AgentKind, _ event: String, _ json: String) -> HookEnvelope {
        HookEnvelope(agent: agent, event: event, payload: Data(json.utf8), surface: surface, agentPID: 4242, cwd: "/repo", sentAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func events(_ signals: [AgentSignal]) -> [SignalEvent] { signals.map(\.event).filter { if case .metadata = $0 { false } else { true } } }

    // MARK: Claude Code

    @Test func claudePreToolUseBash() {
        let payload = #"{"session_id":"abc","transcript_path":"/h/.claude/projects/-repo/abc.jsonl","cwd":"/repo","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run tests"},"tool_use_id":"toolu_1"}"#
        let signals = ClaudeAdapter().decodeHook(event: "PreToolUse", payload: Data(payload.utf8), envelope: envelope(.claude, "PreToolUse", payload))
        #expect(events(signals) == [.toolStarted(tool: "Bash", summary: "npm test -- --watch=false")])
        let hint = signals[0].hint
        #expect(hint.sessionID == "abc")
        #expect(hint.surface == surface)
        #expect(hint.transcriptPath == "/h/.claude/projects/-repo/abc.jsonl")
        #expect(signals.allSatisfy { $0.tier == .hook })
    }

    @Test func claudePermissionRequestPrompt() throws {
        let payload = #"{"session_id":"abc","cwd":"/repo","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/repo/Sources/App.swift","old_string":"a","new_string":"b"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Edit"}],"behavior":"allow","destination":"localSettings"}]}"#
        let adapter = ClaudeAdapter()
        let prompt = try #require(adapter.permissionPrompt(event: "PermissionRequest", payload: Data(payload.utf8)))
        #expect(prompt.tool == "Edit")
        #expect(prompt.summary == "Sources/App.swift")
        #expect(prompt.detail?.contains("\"old_string\"") == true)
        #expect(adapter.permissionPrompt(event: "PreToolUse", payload: Data(payload.utf8)) == nil)
        let signals = adapter.decodeHook(event: "PermissionRequest", payload: Data(payload.utf8), envelope: nil)
        #expect(events(signals) == [.permissionRequested(tool: "Edit", summary: "Sources/App.swift", detail: prompt.detail)])
    }

    @Test func claudeMCPToolNamesAreReadable() {
        let payload = #"{"session_id":"abc","tool_name":"mcp__github__create_issue","tool_input":{"title":"Crash on launch"}}"#
        let signals = ClaudeAdapter().decodeHook(event: "PreToolUse", payload: Data(payload.utf8), envelope: nil)
        #expect(events(signals) == [.toolStarted(tool: "github: create_issue", summary: "Crash on launch")])
    }

    @Test func claudeStopCarriesLastMessage() {
        let payload = #"{"session_id":"abc","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done — 3 files changed.","background_tasks":[],"session_crons":[]}"#
        #expect(events(ClaudeAdapter().decodeHook(event: "Stop", payload: Data(payload.utf8), envelope: nil)) == [.turnCompleted(lastMessage: "Done — 3 files changed.")])
    }

    @Test func claudeNotificationTypes() {
        let adapter = ClaudeAdapter()
        func decode(_ type: String, _ message: String = "Claude needs your permission to use Bash") -> [SignalEvent] {
            let payload = #"{"session_id":"abc","hook_event_name":"Notification","message":"\#(message)","notification_type":"\#(type)"}"#
            return events(adapter.decodeHook(event: "Notification", payload: Data(payload.utf8), envelope: nil))
        }
        #expect(decode("permission_prompt") == [.inputRequested(.permission, message: "Claude needs your permission to use Bash")])
        #expect(decode("elicitation_dialog", "Pick one") == [.inputRequested(.question, message: "Pick one")])
        #expect(decode("idle_prompt", "Claude is waiting for your input") == [])
        #expect(decode("auth_success", "ok") == [])
    }

    @Test func claudeSessionLifecycle() {
        let adapter = ClaudeAdapter()
        let start = #"{"session_id":"abc","transcript_path":"/t.jsonl","cwd":"/repo","hook_event_name":"SessionStart","source":"resume","model":"claude-opus-5-5"}"#
        let signals = adapter.decodeHook(event: "SessionStart", payload: Data(start.utf8), envelope: nil)
        #expect(events(signals) == [.sessionStarted(source: "resume")])
        #expect(signals.first?.event == .metadata(SessionMetadata(model: "claude-opus-5-5", cwd: "/repo", transcriptPath: "/t.jsonl")))
        let end = #"{"session_id":"abc","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#
        #expect(events(adapter.decodeHook(event: "SessionEnd", payload: Data(end.utf8), envelope: nil)) == [.sessionEnded(reason: "prompt_input_exit")])
        let failure = #"{"session_id":"abc","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests"}"#
        #expect(events(adapter.decodeHook(event: "StopFailure", payload: Data(failure.utf8), envelope: nil)) == [.failed(message: "429 Too Many Requests")])
        let compact = #"{"session_id":"abc","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"…"}"#
        #expect(events(adapter.decodeHook(event: "PostCompact", payload: Data(compact.utf8), envelope: nil)) == [.toolFinished(tool: "Compacting")])
    }

    @Test func claudeDecisionJSON() throws {
        let adapter = ClaudeAdapter()
        let allow = adapter.permissionReply(.allow, event: "PermissionRequest", payload: Data())
        #expect(allow.exitCode == 0)
        #expect(allow.stdout == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        let deny = adapter.permissionReply(.deny(reason: "Not on prod"), event: "PermissionRequest", payload: Data())
        let stdout = try #require(deny.stdout)
        let json = try #require(JSONNode.parse(stdout))
        #expect(json["hookSpecificOutput"]["decision"]["behavior"].string == "deny")
        #expect(json["hookSpecificOutput"]["decision"]["message"].string == "Not on prod")
        #expect(json["hookSpecificOutput"]["decision"]["updatedInput"].exists == false)
        #expect(adapter.permissionReply(.passthrough, event: "PermissionRequest", payload: Data()) == .passthrough)
    }

    // MARK: Codex

    @Test func codexPermissionRequestApplyPatch() throws {
        let patch = "*** Begin Patch\n*** Update File: src/main.rs\n@@\n-a\n+b\n*** End Patch"
        let payload = try String(decoding: JSONSerialization.data(withJSONObject: [
            "session_id": "019ff1e8-9833-7043-aae0-fd1e33b29607", "turn_id": "t1", "cwd": "/repo", "hook_event_name": "PermissionRequest",
            "model": "gpt-5.5", "permission_mode": "default", "tool_name": "apply_patch", "tool_input": ["command": patch, "description": "Edit main"],
        ]), as: UTF8.self)
        let adapter = CodexAdapter()
        let prompt = try #require(adapter.permissionPrompt(event: "PermissionRequest", payload: Data(payload.utf8)))
        #expect(prompt.tool == "apply_patch")
        #expect(prompt.summary == "Edit src/main.rs")
        let signals = adapter.decodeHook(event: "PermissionRequest", payload: Data(payload.utf8), envelope: nil)
        #expect(signals.first?.event == .metadata(SessionMetadata(model: "gpt-5.5")))
        let deny = adapter.permissionReply(.deny(reason: nil), event: "PermissionRequest", payload: Data())
        let stdout = try #require(deny.stdout)
        let json = try #require(JSONNode.parse(stdout))
        #expect(json["hookSpecificOutput"]["hookEventName"].string == "PermissionRequest")
        #expect(json["hookSpecificOutput"]["decision"]["behavior"].string == "deny")
        #expect(json["hookSpecificOutput"]["decision"]["interrupt"].exists == false)
    }

    @Test func codexStopAndPrompt() {
        let adapter = CodexAdapter()
        let prompt = #"{"session_id":"s","turn_id":"t","cwd":"/r","hook_event_name":"UserPromptSubmit","prompt":"add tests"}"#
        #expect(events(adapter.decodeHook(event: "UserPromptSubmit", payload: Data(prompt.utf8), envelope: nil)) == [.promptSubmitted(prompt: "add tests")])
        let stop = #"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":null}"#
        #expect(events(adapter.decodeHook(event: "Stop", payload: Data(stop.utf8), envelope: nil)) == [.turnCompleted(lastMessage: nil)])
    }

    // MARK: OpenCode (plugin events)

    @Test func openCodePermissionAsked() throws {
        let payload = #"{"type":"permission.asked","directory":"/repo","pid":1,"properties":{"id":"per_1","sessionID":"ses_1","permission":"bash","patterns":["git push --force"],"metadata":{"command":"git push --force"},"always":[]}}"#
        let adapter = OpenCodeAdapter()
        let prompt = try #require(adapter.permissionPrompt(event: "permission.asked", payload: Data(payload.utf8)))
        #expect(prompt.tool == "Bash")
        #expect(prompt.summary == "git push --force")
        #expect(prompt.externalID == "per_1")
        let signals = adapter.decodeHook(event: "permission.asked", payload: Data(payload.utf8), envelope: nil)
        #expect(signals.first?.hint.sessionID == "ses_1")
        #expect(adapter.permissionReply(.allow, event: "permission.asked", payload: Data()).stdout == #"{"decision":"allow"}"#)
        #expect(OpenCodeAdapter.repliedRequestID(Data(#"{"type":"permission.replied","properties":{"sessionID":"ses_1","requestID":"per_1","reply":"once"}}"#.utf8)) == "per_1")
    }

    @Test func openCodeSessionEvents() {
        let adapter = OpenCodeAdapter()
        func decode(_ json: String) -> [SignalEvent] {
            let type = JSONNode.parse(json)?["type"].string ?? ""
            return events(adapter.decodeHook(event: type, payload: Data(json.utf8), envelope: nil))
        }
        #expect(decode(#"{"type":"session.status","properties":{"sessionID":"s","status":{"type":"busy"}}}"#) == [.observedState(.working(tool: nil))])
        #expect(decode(#"{"type":"session.idle","properties":{"sessionID":"s"}}"#) == [.turnCompleted(lastMessage: nil)])
        #expect(decode(#"{"type":"session.error","properties":{"sessionID":"s","error":{"name":"MessageAbortedError","data":{"message":"x"}}}}"#) == [.turnInterrupted])
        #expect(decode(#"{"type":"session.error","properties":{"sessionID":"s","error":{"name":"APIError","data":{"message":"overloaded"}}}}"#) == [.failed(message: "overloaded")])
        #expect(decode(#"{"type":"message.part.updated","properties":{"sessionID":"s","part":{"type":"tool","tool":"read","sessionID":"s","state":{"status":"running","input":{"filePath":"/repo/a.ts"}}}}}"#) == [.toolStarted(tool: "Read", summary: "/repo/a.ts")])
        #expect(decode(#"{"type":"session.created","properties":{"sessionID":"c","info":{"id":"c","parentID":"p","directory":"/r","title":"Child session"}}}"#) == [.subagentStarted])
        #expect(decode(#"{"type":"message.user","properties":{"sessionID":"s","text":"refactor"}}"#) == [.promptSubmitted(prompt: "refactor")])
    }

    // MARK: Gemini

    @Test func geminiEvents() {
        let adapter = GeminiAdapter()
        let before = #"{"session_id":"g","transcript_path":"/t","cwd":"/r","hook_event_name":"BeforeTool","timestamp":"2026-10-21T10:00:00Z","tool_name":"run_shell_command","tool_input":{"command":"ls -la"}}"#
        #expect(events(adapter.decodeHook(event: "BeforeTool", payload: Data(before.utf8), envelope: nil)) == [.toolStarted(tool: "run_shell_command", summary: "ls -la")])
        let after = #"{"session_id":"g","hook_event_name":"AfterAgent","prompt":"hi","prompt_response":"Hello!","stop_hook_active":false}"#
        #expect(events(adapter.decodeHook(event: "AfterAgent", payload: Data(after.utf8), envelope: nil)) == [.turnCompleted(lastMessage: "Hello!")])
        let notification = #"{"session_id":"g","hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow shell?","details":{}}"#
        #expect(events(adapter.decodeHook(event: "Notification", payload: Data(notification.utf8), envelope: nil)) == [.inputRequested(.permission, message: "Allow shell?")])
    }

    // MARK: Robustness

    @Test(arguments: ["", "not json", "[]", "null", "42", #"{"session_id":42}"#, #"{"tool_input":"x","tool_name":["a"]}"#, String(repeating: "{", count: 600)])
    func garbageNeverCrashes(_ payload: String) {
        let data = Data(payload.utf8)
        for adapter in AgentEngine.defaultAdapters() {
            for event in ["PreToolUse", "PermissionRequest", "Stop", "permission.asked", "session.status", "BeforeTool", "Nope"] {
                _ = adapter.decodeHook(event: event, payload: data, envelope: nil)
                _ = adapter.permissionPrompt(event: event, payload: data)
            }
            var state = TranscriptDecodeState()
            _ = adapter.decodeTranscript(.line(path: "/x/rollout-1.jsonl", data: data), state: &state)
            _ = adapter.decodeTranscript(.document(path: "/x/chats/session-1.json", data: data), state: &state)
        }
    }

    @Test func unknownEventsOnlyRefreshActivity() {
        let signals = ClaudeAdapter().decodeHook(event: "SomeFutureEvent", payload: Data(#"{"session_id":"abc"}"#.utf8), envelope: nil)
        #expect(events(signals) == [.activity])
    }
}
