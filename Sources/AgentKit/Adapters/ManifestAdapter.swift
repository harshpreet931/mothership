import Foundation
import ShipModel
import SystemProbe

/// A long-tail agent described by JSON (ARCHITECTURE §5.4). Defaults are embedded below;
/// users add or override them with `*.json` files in `ShipPaths.agentManifests`.
public struct AgentManifest: Sendable, Codable, Equatable {
    public struct ProcessMatcher: Sendable, Codable, Equatable {
        /// Executable / argv[0] basenames.
        public var executables: [String]
        /// For interpreter-launched agents: substrings of the script path (`@sourcegraph/amp`).
        public var scripts: [String]?
        /// First non-flag argument values that mean "not a session" (`mcp`, `serve`, …).
        public var excludeSubcommands: [String]?

        public init(executables: [String], scripts: [String]? = nil, excludeSubcommands: [String]? = nil) {
            self.executables = executables
            self.scripts = scripts
            self.excludeSubcommands = excludeSubcommands
        }
    }

    public struct Screen: Sendable, Codable, Equatable {
        public var working: [String]?
        public var needsInput: [String]?
        public var idle: [String]?
    }

    public var kind: String
    public var displayName: String?
    public var process: ProcessMatcher
    public var title: TitleRule?
    public var screen: Screen?
    /// argv template; `{prompt}` is replaced, and arguments containing it are dropped when there's no prompt.
    public var launch: [String]?
    /// argv template with `{session}`; nil when the agent can't resume by id.
    public var resume: [String]?
    /// Use CPU time as a (two-sample) working/idle guess.
    public var cpuHeuristic: Bool?

    public init(
        kind: String, displayName: String? = nil, process: ProcessMatcher, title: TitleRule? = nil, screen: Screen? = nil,
        launch: [String]? = nil, resume: [String]? = nil, cpuHeuristic: Bool? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.process = process
        self.title = title
        self.screen = screen
        self.launch = launch
        self.resume = resume
        self.cpuHeuristic = cpuHeuristic
    }
}

public struct ManifestAdapter: AgentAdapter {
    public let manifest: AgentManifest
    public var kind: AgentKind { AgentKind(rawValue: manifest.kind) }
    public var displayName: String { manifest.displayName ?? kind.displayName }
    public var executableNames: [String] { manifest.process.executables }
    public var usesCPUHeuristic: Bool { manifest.cpuHeuristic ?? true }

    public init(manifest: AgentManifest) { self.manifest = manifest }

    public func isCandidate(comm: String) -> Bool {
        manifest.process.executables.contains(comm) || (manifest.process.scripts != nil && ProcessMatching.isInterpreter(comm))
            || manifest.process.executables.contains { $0.count > 15 && $0.hasPrefix(comm) }
    }

    public func matchesRoot(_ process: ObservedProcess) -> Bool {
        let arguments = process.arguments
        var rest: [String]?
        if manifest.process.executables.contains(arguments.executableName) || manifest.process.executables.contains(arguments.argv0Name) {
            rest = Array(arguments.arguments.dropFirst())
        } else if let scripts = manifest.process.scripts,
            ProcessMatching.isInterpreter(arguments.executableName) || ProcessMatching.isInterpreter(process.snapshot.comm)
        {
            let all = arguments.arguments
            if let index = all.indices.dropFirst().first(where: { !all[$0].hasPrefix("-") }) {
                let script = all[index]
                let name = (script as NSString).lastPathComponent
                if scripts.contains(where: { script.contains($0) }) || manifest.process.executables.contains(name) {
                    rest = Array(all[(index + 1)...])
                }
            }
        }
        guard let rest else { return false }
        if let excluded = manifest.process.excludeSubcommands, let sub = ProcessMatching.subcommand(rest, skipping: 0), excluded.contains(sub) {
            return false
        }
        return true
    }

    public func titleRule() -> TitleRule? { manifest.title }

    public func screenRules() -> [ScreenRule] {
        guard let screen = manifest.screen else { return [] }
        return (screen.needsInput ?? []).map { ScreenRule(pattern: $0, state: .needsInput(.question)) }
            + (screen.working ?? []).map { ScreenRule(pattern: $0, state: .working(tool: nil)) }
            + (screen.idle ?? []).map { ScreenRule(pattern: $0, state: .idle) }
    }

    public func resumeCommand(session: String, cwd: String) -> [String]? {
        manifest.resume.map { $0.map { $0.replacingOccurrences(of: "{session}", with: session).replacingOccurrences(of: "{cwd}", with: cwd) } }
    }

    public func launchCommand(prompt: String?, cwd: String) -> [String] {
        let template = manifest.launch ?? [manifest.process.executables.first ?? manifest.kind]
        return template.compactMap { argument in
            guard argument.contains("{prompt}") else { return argument.replacingOccurrences(of: "{cwd}", with: cwd) }
            guard let prompt, !prompt.isEmpty else { return nil }
            return argument.replacingOccurrences(of: "{prompt}", with: prompt)
        }
    }
}

public enum ManifestLoader {
    /// Kinds handled by native adapters; manifests can't shadow them.
    static let nativeKinds: Set<String> = ["claude", "codex", "opencode", "gemini"]

    /// Embedded defaults merged with user manifests (user files win by `kind`).
    public static func load(directory: URL?) -> (manifests: [AgentManifest], errors: [String]) {
        var byKind: [String: AgentManifest] = [:]
        var order: [String] = []
        var errors: [String] = []
        for manifest in defaults() {
            byKind[manifest.kind] = manifest
            order.append(manifest.kind)
        }
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: file)
                    let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
                    guard !nativeKinds.contains(manifest.kind), !manifest.process.executables.isEmpty else {
                        errors.append("\(file.lastPathComponent): kind '\(manifest.kind)' is reserved or has no executables")
                        continue
                    }
                    if byKind[manifest.kind] == nil { order.append(manifest.kind) }
                    byKind[manifest.kind] = manifest
                } catch {
                    errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return (order.compactMap { byKind[$0] }, errors)
    }

    public static func defaults() -> [AgentManifest] {
        (try? JSONDecoder().decode([AgentManifest].self, from: Data(defaultManifestsJSON.utf8))) ?? []
    }

    /// Process matchers and command templates for the long tail. Best effort; verify with each
    /// tool's `--help` and override in the manifests directory.
    static let defaultManifestsJSON = #"""
        [
          {
            "kind": "aider", "displayName": "Aider",
            "process": { "executables": ["aider"], "scripts": ["/bin/aider", "aider/__main__"] },
            "screen": { "needsInput": ["\\(Y\\)es/\\(N\\)o", "Add .+ to the chat\\?"] },
            "launch": ["aider", "--message", "{prompt}"],
            "resume": ["aider", "--restore-chat-history"]
          },
          {
            "kind": "amp", "displayName": "Amp",
            "process": { "executables": ["amp"], "scripts": ["@sourcegraph/amp", "/bin/amp"], "excludeSubcommands": ["mcp", "login", "logout", "update"] },
            "screen": { "working": ["Esc to cancel"], "needsInput": ["Allow\\?|Approve"] },
            "launch": ["amp"],
            "resume": ["amp", "threads", "continue", "{session}"]
          },
          {
            "kind": "cursor-agent", "displayName": "Cursor Agent",
            "process": { "executables": ["cursor-agent"], "scripts": ["cursor-agent"], "excludeSubcommands": ["login", "logout", "status", "update", "mcp"] },
            "screen": { "needsInput": ["Run this command\\?|\\(y\\) \\(enter\\)"] },
            "launch": ["cursor-agent", "{prompt}"],
            "resume": ["cursor-agent", "--resume", "{session}"]
          },
          {
            "kind": "copilot", "displayName": "GitHub Copilot CLI",
            "process": { "executables": ["copilot"], "scripts": ["@github/copilot"], "excludeSubcommands": ["help", "login", "mcp"] },
            "screen": { "needsInput": ["Do you want to (run|allow)"] , "working": ["Esc to cancel"] },
            "launch": ["copilot", "-i", "{prompt}"],
            "resume": ["copilot", "--resume", "{session}"]
          },
          {
            "kind": "goose", "displayName": "Goose",
            "process": { "executables": ["goose"], "excludeSubcommands": ["mcp", "configure", "info", "update", "web", "schedule", "project", "projects"] },
            "launch": ["goose", "session"],
            "resume": ["goose", "session", "--resume", "--name", "{session}"]
          },
          {
            "kind": "crush", "displayName": "Crush",
            "process": { "executables": ["crush"], "excludeSubcommands": ["logs", "update-providers", "schema", "dirs"] },
            "screen": { "needsInput": ["Permission Required|Allow (for session|once)"] },
            "launch": ["crush"],
            "resume": null
          },
          {
            "kind": "qwen", "displayName": "Qwen Code",
            "process": { "executables": ["qwen"], "scripts": ["@qwen-code/qwen-code"], "excludeSubcommands": ["mcp", "extensions"] },
            "screen": { "needsInput": ["Allow execution|Apply this change\\?"], "working": ["esc to cancel"] },
            "launch": ["qwen", "-i", "{prompt}"],
            "resume": null
          },
          {
            "kind": "kiro", "displayName": "Kiro CLI",
            "process": { "executables": ["kiro-cli", "kiro-cli-chat", "q"], "excludeSubcommands": ["login", "logout", "doctor", "settings", "update", "mcp", "integrations"] },
            "screen": { "needsInput": ["Allow this action\\?|\\[y/n/t\\]"] },
            "launch": ["kiro-cli", "chat", "{prompt}"],
            "resume": ["kiro-cli", "chat", "--resume"]
          },
          {
            "kind": "droid", "displayName": "Factory Droid",
            "process": { "executables": ["droid"], "excludeSubcommands": ["mcp", "login", "update"] },
            "screen": { "needsInput": ["Allow|Approve this"] },
            "launch": ["droid", "{prompt}"],
            "resume": ["droid", "--resume", "{session}"]
          }
        ]
        """#
}
