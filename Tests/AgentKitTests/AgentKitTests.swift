import Foundation
import ShipModel
import Testing

@testable import AgentKit

@Suite("Text helpers")
struct TextSummaryTests {
    @Test func toolSummaries() {
        #expect(TextSummary.toolSummary(tool: "Bash", input: JSONNode(["command": "git status\ngit diff"]), cwd: nil) == "git status")
        #expect(TextSummary.toolSummary(tool: "Edit", input: JSONNode(["file_path": "/repo/Sources/A.swift"]), cwd: "/repo") == "Sources/A.swift")
        #expect(TextSummary.toolSummary(tool: "WebFetch", input: JSONNode(["url": "https://example.com"]), cwd: nil) == "https://example.com")
        #expect(TextSummary.toolSummary(tool: "Bash", input: JSONNode(["command": ["ls", "-la"]]), cwd: nil) == "ls -la")
        #expect(TextSummary.patchSummary("*** Begin Patch\n*** Add File: a.txt\n*** Update File: b.txt\n*** End Patch") == "Add a.txt (+1 files)")
    }

    @Test func oneLineTruncates() {
        #expect(TextSummary.oneLine(String(repeating: "a", count: 200), limit: 10) == "aaaaaaaaa…")
        #expect(TextSummary.oneLine("\n\n  first   line\nsecond") == "first line")
        #expect(TextSummary.cleanPrompt("<pasted_content id=\"x\"> body </pasted_content>") == "body")
    }

    @Test func shellQuoting() {
        #expect(ShellQuoting.join(["claude", "--resume", "abc-123"]) == "claude --resume abc-123")
        #expect(ShellQuoting.join(["echo", "it's", ""]) == #"echo 'it'\''s' ''"#)
    }

    @Test func summarizerPrefersActivity() {
        var record = SessionRecord(session: AgentSession(id: AgentSessionKey(kind: .claude, sessionID: "x"), cwd: "/r", state: .working(tool: "Bash")))
        record.currentActivity = "Bash: swift test"
        #expect(HeuristicSummarizer().summary(for: record) == "Bash: swift test")
        record.session.state = .idle
        record.firstPrompt = "Please refactor the authentication middleware so tokens refresh"
        #expect(HeuristicSummarizer().summary(for: record) == "Please refactor the authentication middleware so…")
        record.session.state = .needsInput(.permission)
        record.session.pendingPermission = PermissionRequest(session: record.key, surface: nil, toolName: "Bash", summary: "rm -rf build", expiresAt: Date())
        #expect(HeuristicSummarizer().summary(for: record) == "Approve Bash: rm -rf build")
    }
}
