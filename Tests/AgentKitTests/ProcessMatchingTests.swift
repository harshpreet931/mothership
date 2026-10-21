import Foundation
import ShipModel
import SystemProbe
import Testing

@testable import AgentKit

/// Synthetic process trees modelled on what runs on a dev machine: agents with MCP/plugin
/// children whose argv mentions "claude", wrappers around native binaries, servers.
@Suite("Process matching")
struct ProcessMatchingTests {
    struct Fake {
        var processes: [ProcessSnapshot] = []
        var argv: [Int32: ProcessArguments] = [:]

        mutating func add(_ pid: Int32, parent: Int32, comm: String, exe: String, _ arguments: [String], env: [String: String] = [:]) {
            processes.append(ProcessSnapshot(pid: pid, ppid: parent, pgid: pid, comm: comm, startMicros: UInt64(pid) * 1000))
            argv[pid] = ProcessArguments(executablePath: exe, arguments: arguments, environment: env)
        }

        var table: ProcessTable { ProcessTable(processes: processes) }

        func roots() -> [AgentKind: [Int32]] {
            var result: [AgentKind: [Int32]] = [:]
            for root in ProcessScanner.roots(in: table, adapters: AgentEngine.defaultAdapters(), arguments: { argv[$0.pid] }) {
                result[root.kind, default: []].append(root.pid)
            }
            return result.mapValues { $0.sorted() }
        }
    }

    static let claudeExe = "/Users/u/.local/share/claude/versions/2.1.306"

    @Test func claudeChildrenAreExcluded() {
        var fake = Fake()
        fake.add(10, parent: 1, comm: "Code Helper", exe: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", ["Code Helper"])
        fake.add(11, parent: 10, comm: "zsh", exe: "/bin/zsh", ["-zsh"])
        fake.add(12, parent: 11, comm: "claude", exe: Self.claudeExe, ["claude", "--resume", "abc"])
        // MCP servers and plugins whose argv mentions claude.
        fake.add(13, parent: 12, comm: "node", exe: "/usr/local/bin/node", ["node", "/Users/u/.claude/plugins/cache/x/server.js", "--claude"])
        fake.add(14, parent: 12, comm: "bun", exe: "/Users/u/.bun/bin/bun", ["bun", "run", "/Users/u/.claude/plugins/marketplaces/y/index.ts"])
        // A nested headless run started by the agent's Bash tool.
        fake.add(15, parent: 12, comm: "claude", exe: Self.claudeExe, ["claude", "-p", "summarize"])
        // The multi-call binary running its bundled grep.
        fake.add(16, parent: 12, comm: "2.1.306", exe: Self.claudeExe, ["ugrep", "-E", "x"])
        fake.add(17, parent: 1, comm: "2.1.306", exe: Self.claudeExe, ["rg", "--files"])
        // `claude mcp serve` used as an MCP server by another tool.
        fake.add(18, parent: 1, comm: "claude", exe: Self.claudeExe, ["claude", "mcp", "serve"])
        #expect(fake.roots() == [.claude: [12]])
    }

    /// The engine's own CLI version probe (a child of the app) once showed up as an ended session.
    @Test func versionAndHelpQueriesAreNotSessions() {
        var fake = Fake()
        fake.add(30, parent: 1, comm: "Mothership", exe: "/Applications/Mothership.app/Contents/MacOS/Mothership", ["Mothership"])
        fake.add(31, parent: 30, comm: "opencode", exe: "/Users/u/.opencode/bin/opencode", ["opencode", "--version"])
        fake.add(32, parent: 30, comm: "claude", exe: Self.claudeExe, ["claude", "--help"])
        fake.add(33, parent: 30, comm: "opencode", exe: "/Users/u/.opencode/bin/opencode", ["opencode"])
        #expect(fake.roots() == [.opencode: [33]])
    }

    @Test func codexWrapperIsTheRoot() {
        var fake = Fake()
        fake.add(20, parent: 1, comm: "zsh", exe: "/bin/zsh", ["zsh"])
        fake.add(21, parent: 20, comm: "node", exe: "/usr/local/bin/node", ["node", "/Users/u/.npm-global/bin/codex", "--model", "gpt-5.5"])
        fake.add(22, parent: 21, comm: "codex", exe: "/Users/u/.npm-global/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex", ["codex", "--model", "gpt-5.5"])
        // The Codex desktop app's server is not a session.
        fake.add(23, parent: 1, comm: "codex", exe: "/Applications/Codex.app/Contents/Resources/codex", ["codex", "app-server", "--listen", "stdio"])
        fake.add(24, parent: 20, comm: "codex", exe: "/opt/homebrew/bin/codex", ["codex", "exec", "fix lint"])
        #expect(fake.roots() == [.codex: [21, 24]])
    }

    @Test func openCodeServerIsNotASession() {
        var fake = Fake()
        fake.add(30, parent: 1, comm: "opencode", exe: "/Users/u/.opencode/bin/opencode", ["/Users/u/.opencode/bin/opencode", "serve", "--service"])
        fake.add(31, parent: 1, comm: "zsh", exe: "/bin/zsh", ["zsh"])
        fake.add(32, parent: 31, comm: "opencode", exe: "/Users/u/.opencode/bin/opencode", ["opencode", "/work/web"])
        fake.add(33, parent: 31, comm: "opencode", exe: "/Users/u/.opencode/bin/opencode", ["opencode", "auth", "list"])
        #expect(fake.roots() == [.opencode: [32]])
    }

    @Test func geminiNodeRelaunchCollapses() {
        var fake = Fake()
        fake.add(40, parent: 1, comm: "zsh", exe: "/bin/zsh", ["zsh"])
        fake.add(41, parent: 40, comm: "node", exe: "/usr/local/bin/node", ["node", "/Users/u/.npm-global/bin/gemini"])
        fake.add(42, parent: 41, comm: "node", exe: "/usr/local/bin/node", ["node", "--max-old-space-size=8192", "/Users/u/.npm-global/lib/node_modules/@google/gemini-cli/dist/index.js"])
        #expect(fake.roots() == [.gemini: [41]])
    }

    @Test func manifestAgentsMatch() {
        var fake = Fake()
        fake.add(50, parent: 1, comm: "zsh", exe: "/bin/zsh", ["zsh"])
        fake.add(51, parent: 50, comm: "python3.12", exe: "/opt/homebrew/bin/python3.12", ["/opt/homebrew/bin/python3.12", "/Users/u/.local/bin/aider", "--model", "sonnet"])
        fake.add(52, parent: 50, comm: "goose", exe: "/Users/u/.local/bin/goose", ["goose", "session"])
        fake.add(53, parent: 50, comm: "goose", exe: "/Users/u/.local/bin/goose", ["goose", "mcp", "developer"])
        fake.add(54, parent: 50, comm: "node", exe: "/usr/local/bin/node", ["node", "/Users/u/.npm-global/lib/node_modules/@sourcegraph/amp/dist/main.js"])
        let roots = fake.roots()
        #expect(roots[AgentKind(rawValue: "aider")] == [51])
        #expect(roots[AgentKind(rawValue: "goose")] == [52])
        #expect(roots[AgentKind(rawValue: "amp")] == [54])
    }

    @Test func mothershipSurfaceComesFromEnvironment() {
        let surface = SurfaceID()
        let arguments = ProcessArguments(executablePath: Self.claudeExe, arguments: ["claude"], environment: [ShipEnvironment.surfaceID: surface.description])
        #expect(arguments.mothershipSurface == surface)
    }

    @Test func manifestsLoadAndUserFilesOverride() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write("agents/aider.json", #"{"kind":"aider","displayName":"Aider (custom)","process":{"executables":["aider"]},"resume":["aider","--resume","{session}"]}"#)
        try home.write("agents/claude.json", #"{"kind":"claude","process":{"executables":["claude"]}}"#)
        try home.write("agents/broken.json", "{")
        let loaded = ManifestLoader.load(directory: home.root.appending(path: "agents"))
        #expect(loaded.manifests.count == 9)
        let aider = try #require(loaded.manifests.first { $0.kind == "aider" })
        #expect(aider.displayName == "Aider (custom)")
        #expect(ManifestAdapter(manifest: aider).resumeCommand(session: "s1", cwd: "/w") == ["aider", "--resume", "s1"])
        #expect(loaded.errors.count == 2)
        let amp = try #require(loaded.manifests.first { $0.kind == "amp" })
        #expect(ManifestAdapter(manifest: amp).launchCommand(prompt: nil, cwd: "/w") == ["amp"])
        let cursor = try #require(loaded.manifests.first { $0.kind == "cursor-agent" })
        #expect(ManifestAdapter(manifest: cursor).launchCommand(prompt: "fix it", cwd: "/w") == ["cursor-agent", "fix it"])
        #expect(ManifestAdapter(manifest: cursor).launchCommand(prompt: nil, cwd: "/w") == ["cursor-agent"])
    }
}
