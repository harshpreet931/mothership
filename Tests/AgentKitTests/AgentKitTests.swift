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
}

@Suite("Summaries")
struct SummaryTests {
    func record(_ state: AgentState, tool: String? = nil, target: String? = nil) -> SessionRecord {
        var record = SessionRecord(session: AgentSession(id: AgentSessionKey(kind: .claude, sessionID: "x"), cwd: "/r", state: state))
        record.currentTool = tool
        record.currentTarget = target
        return record
    }

    let summarizer = HeuristicSummarizer()

    @Test func workingShowsToolAndTarget() {
        #expect(summarizer.summary(for: record(.working(tool: "Edit"), tool: "Edit", target: "Sources/App/AppModel.swift")) == "Editing AppModel.swift")
        #expect(summarizer.summary(for: record(.working(tool: "Bash"), tool: "Bash", target: "cd web && pnpm test")) == "Running pnpm test")
        #expect(summarizer.summary(for: record(.working(tool: "Bash"), tool: "Bash", target: "FOO=1 BAR=2 npm run build")) == "Running npm run build")
        #expect(summarizer.summary(for: record(.working(tool: "Read"), tool: "Read", target: "/repo/README.md")) == "Reading README.md")
        #expect(summarizer.summary(for: record(.working(tool: "Grep"), tool: "Grep", target: "TODO\\(")) == "Searching TODO\\(")
        #expect(summarizer.summary(for: record(.working(tool: "WebFetch"), tool: "WebFetch", target: "https://docs.swift.org/x")) == "Fetching docs.swift.org")
        #expect(summarizer.summary(for: record(.working(tool: "apply_patch"), tool: "apply_patch", target: "Edit src/health.rs")) == "Editing health.rs")
        #expect(summarizer.summary(for: record(.working(tool: "Write"), tool: "Write", target: nil)) == "Writing")
        #expect(summarizer.summary(for: record(.working(tool: "Compacting"))) == "Compacting context")
        #expect(summarizer.summary(for: record(.working(tool: "github: create_issue"), tool: "github: create_issue", target: "Crash")) == "github: create_issue Crash")
        #expect(summarizer.summary(for: record(.working(tool: nil), tool: "Bash", target: "ls")) == "Thinking…")
    }

    @Test func idleShowsFirstSentenceOfLastReply() {
        var idle = record(.idle)
        idle.session.lastAssistantMessage = "## Summary\n\nI fixed the **flaky** `AuthTests` by awaiting the [token refresh](https://x.dev). Next I'd add a retry."
        #expect(summarizer.summary(for: idle) == "I fixed the flaky AuthTests by awaiting the token refresh.")
        idle.session.lastAssistantMessage = "Done, e.g. the cache now expires. Anything else?"
        #expect(summarizer.summary(for: idle) == "Done, e.g. the cache now expires.")
        idle.session.lastAssistantMessage = String(repeating: "word ", count: 40)
        let long = summarizer.summary(for: idle) ?? ""
        #expect(long.count <= 80)
        #expect(long.hasSuffix("…"))
        idle.session.lastAssistantMessage = nil
        idle.session.title = "Dark mode toggle"
        #expect(summarizer.summary(for: idle) == "Dark mode toggle")
    }

    @Test func blockedStates() {
        var blocked = record(.needsInput(.permission), tool: "Bash", target: "rm -rf build")
        #expect(summarizer.summary(for: blocked) == "Waiting for approval: running rm -rf build")
        blocked.session.pendingPermission = PermissionRequest(session: blocked.key, surface: nil, toolName: "Bash", summary: "rm -rf build", expiresAt: Date())
        #expect(summarizer.summary(for: blocked) == "Approve Bash: rm -rf build")
        #expect(summarizer.summary(for: record(.needsInput(.question))) == "Waiting for your input")
        #expect(summarizer.summary(for: record(.error("rate limit"))) == "Error: rate limit")
    }
}

@Suite("Title cleaner")
struct TitleCleanerTests {
    func title(_ prompt: String, fallback: String? = "my-repo") -> String? {
        TitleCleaner.title(fromPrompt: prompt, fallback: fallback)
    }

    @Test func quotedScreenshotPathIsDropped() {
        #expect(title("'/Users/someone/Desktop/Screenshot 2026-10-21 at 10.15.32.png' the sidebar overflows on small windows") == "The sidebar overflows on small windows")
        #expect(title("there is one issue, that, '/var/folders/ab/xyz/T/TemporaryItems/img.png' shows a blank card")
            == "There is one issue, that, shows a blank card")
    }

    @Test func markdownAndNumberingAreStripped() {
        #expect(title("# Consistency and Conventions") == "Consistency and Conventions")
        let idea = title("#: 1 Idea: Your apartment's floor plan → a playable DOOM level generator") ?? ""
        #expect(idea.hasPrefix("Idea: Your apartment's floor plan"))
        #expect(idea.count <= 48)
        #expect(title("> - [Image #1] fix the layout on iPad") == "Fix the layout on iPad")
        #expect(title("2. Add retries to the uploader") == "Add retries to the uploader")
        #expect(title("3 bugs in the login flow") == "3 bugs in the login flow")
    }

    @Test func fileRefsQuotesAndURLs() {
        let video = title("@../05_AI/05_Draft_Vid.mp4 i have made this, now can you edit it into a short reel") ?? ""
        #expect(video.hasPrefix("I have made this, now can you edit"))
        let quoted = title("\"Security & Cryptography Drill must-do PYQs Collapse all Multiple choice questions") ?? ""
        #expect(quoted.hasPrefix("Security & Cryptography Drill must-do"))
        #expect(!quoted.contains("\""))
        #expect(title("https://github.com/org/repo/pull/12 review this PR please") == "Review this PR please")
        #expect(title("@src/a.ts @src/b.ts why do these differ?") == "Why do these differ?")
        #expect(title("<pasted_content id=\"ea67\"> Refactor the parser </pasted_content>") == "Refactor the parser")
    }

    @Test func prefersOwnWordsOverPastedContent() {
        #expect(title("<pasted_content id=\"fc18\">\nAccessibility Menu\nDrill must-do PYQs\n</pasted_content>\nmake flashcards from these") == "Make flashcards from these")
        #expect(title("<pasted_content id=\"ea67\">\n# Consistency and Conventions\nBody text\n</pasted_content>") == "Consistency and Conventions")
    }

    @Test func fallsBackToFolderWhenNothingIsLeft() {
        #expect(title("/Users/someone/Desktop/notes.md") == "my-repo")
        #expect(title("@a.png") == "my-repo")
        #expect(title("   ") == "my-repo")
        #expect(title("~/Downloads/x.zip", fallback: nil) == nil)
    }

    @Test func usesTheFirstMeaningfulLine() {
        #expect(title("'/Users/someone/Desktop/Screenshot 1.png'\n\nwhy is this card so tall") == "Why is this card so tall")
    }

    @Test func cutsAtAWordBoundary() {
        let long = "please refactor the authentication middleware so that refresh tokens rotate correctly"
        let cut = title(long) ?? ""
        #expect(cut.count <= 48)
        #expect(cut.hasSuffix("…"))
        let words = Set(long.split(separator: " ").map(String.init))
        let kept = cut.dropLast().split(separator: " ").map(String.init)
        #expect(kept.allSatisfy { words.contains($0.lowercased()) || words.contains($0) })
        #expect(cut.hasPrefix("Please refactor the authentication middleware"))
    }
}
