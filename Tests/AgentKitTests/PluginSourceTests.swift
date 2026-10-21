import Foundation
import Testing

@testable import AgentKit

@Suite("OpenCode plugin source")
struct PluginSourceTests {
    static var node: String? {
        ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The generated plugin must at least parse as an ES module.
    @Test(.enabled(if: node != nil, "node not installed"))
    func pluginParsesAsESModule() throws {
        let node = try #require(Self.node)
        let file = FileManager.default.temporaryDirectory.appending(path: "mothership-plugin-\(UUID().uuidString).mjs")
        let source = OpenCodePluginInstaller.pluginSource(shim: "/Users/a b/Library/Application Support/Mothership/bin/mship", permissionTimeoutMs: 630_000)
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--check", file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(message)")
    }

    /// Runs the plugin in node with a fake shim and a fake OpenCode client: events are forwarded
    /// in order (deduplicated tool status), and an "allow" from the app becomes `reply: "once"`.
    @Test(.enabled(if: node != nil, "node not installed"))
    func pluginForwardsEventsAndRelaysDecisions() throws {
        let node = try #require(Self.node)
        let directory = FileManager.default.temporaryDirectory.appending(path: "plugin-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "shim.log").path
        let shim = directory.appending(path: "mship")
        try Data("""
            #!/bin/sh
            payload=$(cat)
            printf '%s %s\\n' "$3" "$payload" >> "\(log)"
            if [ "$3" = "permission.asked" ]; then printf '{"decision":"allow"}'; fi
            exit 0

            """.utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let plugin = directory.appending(path: "mothership.mjs")
        try Data(OpenCodePluginInstaller.pluginSource(shim: shim.path, permissionTimeoutMs: 5000).utf8).write(to: plugin)
        let driver = directory.appending(path: "driver.mjs")
        try Data("""
            import { MothershipPlugin } from "./mothership.mjs";
            const replies = [];
            const client = { permission: { reply: async (args) => { replies.push(args); } } };
            const hooks = await MothershipPlugin({ client, directory: "/work/web", serverUrl: new URL("http://127.0.0.1:4096") });
            const send = (type, properties) => hooks.event({ event: { type, properties } });
            await send("session.status", { sessionID: "ses_1", status: { type: "busy" } });
            const part = (status) => ({ sessionID: "ses_1", part: { id: "p1", type: "tool", tool: "bash", callID: "c1", sessionID: "ses_1", state: { status, input: { command: "ls", secret: "x" } } } });
            await send("message.part.updated", part("running"));
            await send("message.part.updated", part("running"));
            await send("message.part.updated", part("completed"));
            await send("message.part.delta", { sessionID: "ses_1", delta: "ignored" });
            await send("permission.asked", { id: "per_1", sessionID: "ses_1", permission: "bash", patterns: ["rm -rf build"], metadata: {} });
            await send("session.idle", { sessionID: "ses_1" });
            // Generous: under a loaded parallel test run the fake shim answers slowly.
            await new Promise((resolve) => setTimeout(resolve, 5000));
            console.log(JSON.stringify(replies));

            """.utf8).write(to: driver)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [driver.path]
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(replies.contains(#""requestID":"per_1""#))
        #expect(replies.contains(#""reply":"once""#))
        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map { String($0) }
        let events = lines.map { $0.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "" }
        let ordered = events.filter { $0 != "permission.asked" }
        #expect(ordered == ["session.status", "message.part.updated", "message.part.updated", "session.idle"])
        #expect(events.contains("permission.asked"))
        #expect(!lines.contains { $0.contains("secret") })
        #expect(lines.first?.contains(#""directory":"/work/web""#) == true)
    }
}
