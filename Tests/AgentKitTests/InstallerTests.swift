import Foundation
import ShipModel
import Testing

@testable import AgentKit

/// A throwaway home directory. Installers never see the real `~`.
struct TempHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "mothership-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var support: URL { root.appending(path: "support", directoryHint: .isDirectory) }

    func context(shim: String = "/Users/test/Library/Application Support/Mothership/bin/mship", version: String? = nil) -> IntegrationContext {
        IntegrationContext(
            home: root, shimPath: shim, backupsDirectory: support.appending(path: "backups"), stateDirectory: support,
            agentVersion: version, now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func write(_ relative: String, _ contents: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: relative).path) }

    func backups(_ kind: AgentKind) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: support.appending(path: "backups/\(kind.rawValue)").path)) ?? []
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func fixture(_ path: String) throws -> String {
    let url = try #require(Bundle.module.resourceURL).appending(path: "Fixtures/\(path)")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Integration installers")
struct InstallerTests {
    let claude = JSONHooksInstaller.claude(permissionTimeout: 660)
    let codex = JSONHooksInstaller.codex(permissionTimeout: 660)

    @Test func freshClaudeInstallCreatesFile() throws {
        let home = try TempHome()
        defer { home.remove() }
        #expect(claude.inspect(home.context()).health == .notInstalled)
        let outcome = try claude.install(home.context())
        #expect(outcome.changed)
        #expect(outcome.backup == nil)
        let text = try home.read(".claude/settings.json")
        let root = try OrderedJSON.parse(text)
        let events = root["hooks"]?.objectValue?.map(\.key) ?? []
        #expect(events.count == 13)
        let permission = try #require(root["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
        #expect(permission["command"]?.stringValue == #""/Users/test/Library/Application Support/Mothership/bin/mship" hook claude PermissionRequest"#)
        #expect(permission["timeout"] == .int(660))
        #expect(claude.inspect(home.context()).health == .installed(count: 13))
    }

    @Test func mergeKeepsThirdPartyEntriesAndOrder() throws {
        let home = try TempHome()
        defer { home.remove() }
        let original = try fixture("configs/claude-settings-thirdparty.json")
        try home.write(".claude/settings.json", original)
        let outcome = try claude.install(home.context())
        #expect(outcome.changed)
        #expect(home.backups(.claude).count == 1)
        let merged = try home.read(".claude/settings.json")
        let root = try OrderedJSON.parse(merged)
        // Top-level keys keep their order; literals keep their text.
        #expect(root.objectValue?.map(\.key) == ["env", "permissions", "model", "hooks", "statusLine", "enabledPlugins", "effortLevel", "ratio"])
        #expect(merged.contains("\"ratio\": 1.50"))
        #expect(merged.contains("stopped — ✓"))
        // Third-party groups stay first and untouched; ours is appended.
        let permission = try #require(root["hooks"]?["PermissionRequest"]?.arrayValue)
        #expect(permission.count == 2)
        #expect(permission[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue?.contains("Relay/bin/relay") == true)
        #expect(permission[0]["hooks"]?.arrayValue?.first?["statusMessage"]?.stringValue == "Relaying agent activity locally")
        #expect(permission[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue?.hasSuffix("hook claude PermissionRequest") == true)
        #expect(root["hooks"]?["Stop"]?.arrayValue?.count == 2)
        #expect(root["hooks"]?["Notification"]?.arrayValue?.first?["matcher"]?.stringValue == "*")
    }

    @Test func installIsIdempotent() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".claude/settings.json", try fixture("configs/claude-settings-thirdparty.json"))
        try claude.install(home.context())
        let once = try home.read(".claude/settings.json")
        let second = try claude.install(home.context())
        #expect(second.changed == false)
        #expect(try home.read(".claude/settings.json") == once)
        #expect(home.backups(.claude).count == 1)
        #expect(try claude.plannedContents(home.context()) == nil)
    }

    @Test func uninstallIsExact() throws {
        let home = try TempHome()
        defer { home.remove() }
        let original = try fixture("configs/claude-settings-thirdparty.json")
        try home.write(".claude/settings.json", original)
        try claude.install(home.context())
        let outcome = try claude.uninstall(home.context())
        #expect(outcome.changed)
        #expect(try home.read(".claude/settings.json") == original)
        #expect(claude.inspect(home.context()).health == .notInstalled)
    }

    @Test func uninstallOfCreatedFileRemovesIt() throws {
        let home = try TempHome()
        defer { home.remove() }
        try claude.install(home.context())
        try claude.uninstall(home.context())
        #expect(home.exists(".claude/settings.json") == false)
    }

    @Test func detectsOverwrittenPartialAndStale() throws {
        let home = try TempHome()
        defer { home.remove() }
        let original = try fixture("configs/claude-settings-thirdparty.json")
        try home.write(".claude/settings.json", original)
        try claude.install(home.context())
        #expect(claude.inspect(home.context(shim: "/Applications/Other/mship")).health == .stale("hook commands point at an old mship path or timeout"))

        // Another tool drops one of our events.
        var root = try OrderedJSON.parse(try home.read(".claude/settings.json"))
        var hooks = try #require(root["hooks"])
        hooks.set("PreToolUse", nil)
        root.set("hooks", hooks)
        try home.write(".claude/settings.json", root.serialized())
        #expect(claude.inspect(home.context()).health == .partial(present: 12, expected: 13))

        // Another tool rewrites the whole file.
        try home.write(".claude/settings.json", original)
        #expect(claude.inspect(home.context()).health == .overwritten)
        // Reinstall repairs it.
        try claude.install(home.context())
        #expect(claude.inspect(home.context()).health == .installed(count: 13))
    }

    @Test func refusesInvalidJSONWithoutTouchingIt() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".claude/settings.json", "{ \"hooks\": [ oops")
        #expect(throws: IntegrationError.self) { try claude.install(home.context()) }
        #expect(try home.read(".claude/settings.json") == "{ \"hooks\": [ oops")
        if case .unreadable = claude.inspect(home.context()).health {} else { Issue.record("expected unreadable") }
    }

    @Test func codexInstallKeepsDescriptionAndTrustIndices() throws {
        let home = try TempHome()
        defer { home.remove() }
        let original = try fixture("configs/codex-hooks-thirdparty.json")
        try home.write(".codex/hooks.json", original)
        let notify = "notify = [\"/Applications/Other.app/client\", \"turn-ended\"]\n"
        try home.write(".codex/config.toml", notify)
        try codex.install(home.context())
        let root = try OrderedJSON.parse(try home.read(".codex/hooks.json"))
        #expect(root["description"]?.stringValue == "User hooks including a local session bridge.")
        let permission = try #require(root["hooks"]?["PermissionRequest"]?.arrayValue)
        #expect(permission.count == 3)
        #expect(permission[2]["hooks"]?.arrayValue?.first?["command"]?.stringValue?.hasSuffix("hook codex PermissionRequest") == true)
        #expect(try home.read(".codex/config.toml") == notify)

        // Trust: our PermissionRequest group is index 2, SessionStart index 1, others 0.
        let path = home.root.appending(path: ".codex/hooks.json").path
        var inspection = codex.inspect(home.context())
        #expect(inspection.health == .installed(count: 11))
        #expect(inspection.notes.contains { $0.contains("trust pending for 11") })
        var toml = notify
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"] {
            let group = event == "PermissionRequest" ? 2 : (event == "SessionStart" ? 1 : 0)
            toml += "\n[hooks.state.\"\(path):\(JSONHooksInstaller.snakeCase(event)):\(group):0\"]\ntrusted_hash = \"sha256:x\"\n"
        }
        try home.write(".codex/config.toml", toml)
        inspection = codex.inspect(home.context())
        #expect(inspection.notes.isEmpty)

        try codex.uninstall(home.context())
        #expect(try home.read(".codex/hooks.json") == original)
    }

    @Test func codexDisabledHooksAreReported() throws {
        let home = try TempHome()
        defer { home.remove() }
        try codex.install(home.context())
        try home.write(".codex/config.toml", "model = \"x\"\n\n[features]\nhooks = false\n")
        #expect(codex.inspect(home.context()).notes.contains { $0.contains("disabled") })
    }

    @Test func geminiVersionGate() throws {
        let home = try TempHome()
        defer { home.remove() }
        let gemini = JSONHooksInstaller.gemini()
        #expect(throws: IntegrationError.self) { try gemini.install(home.context(version: "0.18.4")) }
        #expect(home.exists(".gemini/settings.json") == false)
        if case .unsupported = gemini.inspect(home.context(version: "0.18.4")).health {} else { Issue.record("expected unsupported") }
        try home.write(".gemini/settings.json", "{\n  \"theme\": \"Dracula\"\n}\n")
        try gemini.install(home.context(version: "0.26.1"))
        let root = try OrderedJSON.parse(try home.read(".gemini/settings.json"))
        #expect(root["theme"]?.stringValue == "Dracula")
        #expect(root["hooks"]?["BeforeTool"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["timeout"] == .int(10_000))
        #expect(gemini.inspect(home.context(version: "0.26.1")).health == .installed(count: 8))
    }

    @Test func openCodePluginLifecycle() throws {
        let home = try TempHome()
        defer { home.remove() }
        let plugin = OpenCodePluginInstaller(permissionTimeout: 630)
        try home.write(".config/opencode/plugins/vibe.js", "export default async () => ({})\n")
        try plugin.install(home.context())
        let source = try home.read(".config/opencode/plugins/mothership.js")
        #expect(source.contains(OpenCodePluginInstaller.marker))
        #expect(source.contains(#"const SHIM = "/Users/test/Library/Application Support/Mothership/bin/mship";"#))
        #expect(source.contains("const PERMISSION_TIMEOUT_MS = 630000;"))
        #expect(try home.read(".config/opencode/plugins/vibe.js") == "export default async () => ({})\n")
        #expect(plugin.inspect(home.context()).isInstalled)
        #expect(try plugin.install(home.context()).changed == false)

        try FileManager.default.removeItem(at: home.root.appending(path: ".config/opencode/plugins/mothership.js"))
        #expect(plugin.inspect(home.context()).health == .overwritten)

        try home.write(".config/opencode/plugins/mothership.js", "// someone else's file\n")
        #expect(throws: IntegrationError.self) { try plugin.install(home.context()) }
        #expect(throws: IntegrationError.self) { try plugin.uninstall(home.context()) }
        try FileManager.default.removeItem(at: home.root.appending(path: ".config/opencode/plugins/mothership.js"))

        try plugin.install(home.context())
        try plugin.uninstall(home.context())
        #expect(home.exists(".config/opencode/plugins/mothership.js") == false)
        #expect(home.exists(".config/opencode/plugins/vibe.js"))
        #expect(plugin.inspect(home.context()).health == .notInstalled)
    }

    @Test func orderedJSONRoundTripsUntouchedValues() throws {
        let text = "{\n  \"a\": 1e3,\n  \"b\": \"caf\\u00e9 \\\"q\\\"\",\n  \"c\": [],\n  \"d\": {},\n  \"e\": [\n    true,\n    null\n  ]\n}"
        #expect(try OrderedJSON.parse(text).serialized() == text)
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse("{\"a\": 1,}") }
    }

    @Test func versionComparison() {
        #expect(VersionCompare.isAtLeast("0.26.0", "0.26.0"))
        #expect(VersionCompare.isAtLeast("0.30.1-preview.2", "0.26.0"))
        #expect(VersionCompare.isAtLeast("0.18.4", "0.26.0") == false)
        #expect(AgentCLILocator.firstSemver(in: "opencode v2.1.2\n") == "2.1.2")
        #expect(AgentCLILocator.versionFromLayout("/Users/x/.local/share/claude/versions/2.1.306") == "2.1.306")
    }
}
