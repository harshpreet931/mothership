import Foundation
import ShipModel

/// Installer for the `{"hooks": {"<Event>": [{"matcher"?, "hooks": [{type, command, timeout}]}]}}`
/// schema shared by Claude Code (`settings.json`), Codex (`hooks.json`) and Gemini CLI
/// (`settings.json`). Mothership's entries are recognised by their command
/// (`…/mship" hook <agent> <Event>`); new groups are appended at the end of each event's
/// list so other tools' entries keep their positions (Codex keys hook trust by index).
public struct JSONHooksInstaller: IntegrationInstaller {
    public struct EventSpec: Sendable, Equatable {
        public var name: String
        /// In the config's unit (seconds for Claude/Codex, milliseconds for Gemini).
        public var timeout: Int?

        public init(_ name: String, timeout: Int? = nil) {
            self.name = name
            self.timeout = timeout
        }
    }

    public let kind: AgentKind
    public let relativePath: String
    public let events: [EventSpec]
    /// Integrations that need a minimum CLI version (Gemini hooks arrived in 0.26).
    public let minimumVersion: String?
    /// Read Codex's `config.toml` to report hook-trust review status.
    public let reportsCodexTrust: Bool

    public init(kind: AgentKind, relativePath: String, events: [EventSpec], minimumVersion: String? = nil, reportsCodexTrust: Bool = false) {
        self.kind = kind
        self.relativePath = relativePath
        self.events = events
        self.minimumVersion = minimumVersion
        self.reportsCodexTrust = reportsCodexTrust
    }

    /// Claude Code 2.1: every useful event. PermissionRequest outlives the engine's hold.
    public static func claude(permissionTimeout: Int) -> JSONHooksInstaller {
        let quick = 10
        return JSONHooksInstaller(
            kind: .claude, relativePath: ".claude/settings.json",
            events: [
                EventSpec("SessionStart", timeout: quick), EventSpec("SessionEnd"), EventSpec("UserPromptSubmit", timeout: quick),
                EventSpec("PreToolUse", timeout: quick), EventSpec("PostToolUse", timeout: quick),
                EventSpec("PermissionRequest", timeout: permissionTimeout), EventSpec("Notification", timeout: quick),
                EventSpec("Stop", timeout: quick), EventSpec("StopFailure", timeout: quick),
                EventSpec("SubagentStart", timeout: quick), EventSpec("SubagentStop", timeout: quick),
                EventSpec("PreCompact", timeout: quick), EventSpec("PostCompact", timeout: quick),
            ]
        )
    }

    /// Codex 0.146 `hooks.json` (events confirmed in the installed binary). `notify` in
    /// config.toml is left alone.
    public static func codex(permissionTimeout: Int) -> JSONHooksInstaller {
        let quick = 10
        return JSONHooksInstaller(
            kind: .codex, relativePath: ".codex/hooks.json",
            events: [
                EventSpec("SessionStart", timeout: quick), EventSpec("SessionEnd", timeout: 2),
                EventSpec("UserPromptSubmit", timeout: quick), EventSpec("PreToolUse", timeout: quick),
                EventSpec("PermissionRequest", timeout: permissionTimeout), EventSpec("PostToolUse", timeout: quick),
                EventSpec("Stop", timeout: quick), EventSpec("SubagentStart", timeout: quick),
                EventSpec("SubagentStop", timeout: quick), EventSpec("PreCompact", timeout: quick),
                EventSpec("PostCompact", timeout: quick),
            ],
            reportsCodexTrust: true
        )
    }

    /// Gemini CLI ≥ 0.26 `settings.json` hooks (timeouts in milliseconds).
    public static func gemini() -> JSONHooksInstaller {
        let quick = 10_000
        return JSONHooksInstaller(
            kind: .gemini, relativePath: ".gemini/settings.json",
            events: [
                EventSpec("SessionStart", timeout: quick), EventSpec("SessionEnd", timeout: quick),
                EventSpec("BeforeAgent", timeout: quick), EventSpec("AfterAgent", timeout: quick),
                EventSpec("BeforeTool", timeout: quick), EventSpec("AfterTool", timeout: quick),
                EventSpec("Notification", timeout: quick), EventSpec("PreCompress", timeout: quick),
            ],
            minimumVersion: "0.26.0"
        )
    }

    public func configURL(home: URL) -> URL { home.appending(path: relativePath) }

    func command(for event: String, shim: String) -> String {
        "\(ConfigFiles.shellQuoted(shim)) hook \(kind.rawValue) \(event)"
    }

    /// Any `mship hook <agent> …` command counts as ours, whatever the shim path.
    func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("mship\" hook \(kind.rawValue) ") || command.contains("mship hook \(kind.rawValue) ")
            || command.contains("mship' hook \(kind.rawValue) ")
    }

    func desiredEntry(_ spec: EventSpec, shim: String) -> OrderedJSON {
        var pairs: [(key: String, value: OrderedJSON)] = [("type", .string("command")), ("command", .string(command(for: spec.name, shim: shim)))]
        if let timeout = spec.timeout { pairs.append(("timeout", .int(timeout))) }
        return .object(pairs)
    }

    func versionGate(_ context: IntegrationContext) -> String? {
        guard let minimumVersion else { return nil }
        guard let version = context.agentVersion else { return "version unknown (needs ≥ \(minimumVersion))" }
        return VersionCompare.isAtLeast(version, minimumVersion) ? nil : "\(kind.displayName) \(version) has no hooks (needs ≥ \(minimumVersion))"
    }

    // MARK: Reading

    struct Loaded {
        var root: OrderedJSON
        var existed: Bool
        var original: String
        var indent: String
        var trailingNewline: Bool
    }

    func load(_ file: URL) throws -> Loaded {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return Loaded(root: .object([]), existed: false, original: "", indent: "  ", trailingNewline: true)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Loaded(root: .object([]), existed: true, original: text, indent: "  ", trailingNewline: true)
        }
        let root: OrderedJSON
        do {
            root = try OrderedJSON.parse(text)
        } catch {
            throw IntegrationError.invalidConfig(path: file.path, reason: "\(error)")
        }
        guard root.objectValue != nil else { throw IntegrationError.invalidConfig(path: file.path, reason: "top level is not an object") }
        return Loaded(root: root, existed: true, original: text, indent: Self.detectIndent(text), trailingNewline: text.hasSuffix("\n"))
    }

    static func detectIndent(_ text: String) -> String {
        for line in text.split(separator: "\n").dropFirst() {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if !leading.isEmpty { return String(leading) }
        }
        return "  "
    }

    func render(_ loaded: Loaded, _ root: OrderedJSON) -> String {
        root.serialized(indent: loaded.indent) + (loaded.trailingNewline ? "\n" : "")
    }

    // MARK: Merge

    /// Returns the merged root and whether anything changed.
    func merged(_ root: OrderedJSON, shim: String, path: String) throws -> OrderedJSON {
        var root = root
        var hooks = root["hooks"] ?? .object([])
        guard hooks.objectValue != nil else { throw IntegrationError.invalidConfig(path: path, reason: "\"hooks\" is not an object") }
        let wanted = Dictionary(uniqueKeysWithValues: events.map { ($0.name, $0) })
        // Drop our entries for events we no longer install.
        for (event, value) in hooks.objectValue ?? [] where wanted[event] == nil {
            if let groups = value.arrayValue {
                let (cleaned, removed) = removeOurs(from: groups)
                if removed { hooks.set(event, cleaned.isEmpty ? nil : .array(cleaned)) }
            }
        }
        for spec in events {
            let desired = desiredEntry(spec, shim: shim)
            var groups: [OrderedJSON] = []
            if let existing = hooks[spec.name] {
                guard let array = existing.arrayValue else {
                    throw IntegrationError.invalidConfig(path: path, reason: "hooks.\(spec.name) is not an array")
                }
                groups = array
            }
            var placed = false
            var result: [OrderedJSON] = []
            for group in groups {
                guard var entries = group["hooks"]?.arrayValue else {
                    result.append(group)
                    continue
                }
                var kept: [OrderedJSON] = []
                var hadOurs = false
                for entry in entries {
                    guard isOurs(entry["command"]?.stringValue) else {
                        kept.append(entry)
                        continue
                    }
                    hadOurs = true
                    if !placed {
                        kept.append(entry == desired ? entry : desired)
                        placed = true
                    }
                }
                if hadOurs && kept.isEmpty { continue }
                entries = kept
                var updated = group
                updated.set("hooks", .array(entries))
                result.append(updated)
            }
            if !placed { result.append(.object([("hooks", .array([desired]))])) }
            hooks.set(spec.name, .array(result))
        }
        root.set("hooks", hooks)
        return root
    }

    /// Removes our entries; drops groups that only held ours.
    func removeOurs(from groups: [OrderedJSON]) -> (groups: [OrderedJSON], removed: Bool) {
        var removed = false
        var result: [OrderedJSON] = []
        for group in groups {
            guard let entries = group["hooks"]?.arrayValue else {
                result.append(group)
                continue
            }
            let kept = entries.filter { !isOurs($0["command"]?.stringValue) }
            if kept.count == entries.count {
                result.append(group)
                continue
            }
            removed = true
            if kept.isEmpty { continue }
            var updated = group
            updated.set("hooks", .array(kept))
            result.append(updated)
        }
        return (result, removed)
    }

    // MARK: IntegrationInstaller

    public func plannedContents(_ context: IntegrationContext) throws -> String? {
        if let reason = versionGate(context) { throw IntegrationError.unsupported(reason) }
        let file = configURL(home: context.home)
        let loaded = try load(file)
        let root = try merged(loaded.root, shim: context.shimPath, path: file.path)
        let rendered = render(loaded, root)
        return rendered == loaded.original ? nil : rendered
    }

    @discardableResult
    public func install(_ context: IntegrationContext) throws -> InstallOutcome {
        if let reason = versionGate(context) { throw IntegrationError.unsupported(reason) }
        let file = configURL(home: context.home)
        let loaded = try load(file)
        let root = try merged(loaded.root, shim: context.shimPath, path: file.path)
        let rendered = render(loaded, root)
        let previous = InstallRecordStore.record(kind, in: context.stateDirectory)
        let record = InstallRecord(
            installedAt: context.now, configPath: file.path, shimPath: context.shimPath, items: events.map(\.name),
            createdFile: previous?.createdFile ?? !loaded.existed,
            hadHooksKey: previous?.hadHooksKey ?? (loaded.root["hooks"] != nil)
        )
        guard rendered != loaded.original else {
            try InstallRecordStore.save(record, for: kind, in: context.stateDirectory)
            return InstallOutcome(changed: false, configPath: file)
        }
        let backup = try ConfigFiles.backup(file, kind: kind, context: context)
        try ConfigFiles.write(rendered, to: file)
        try InstallRecordStore.save(record, for: kind, in: context.stateDirectory)
        return InstallOutcome(changed: true, configPath: file, backup: backup)
    }

    @discardableResult
    public func uninstall(_ context: IntegrationContext) throws -> InstallOutcome {
        let file = configURL(home: context.home)
        let record = InstallRecordStore.record(kind, in: context.stateDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            try InstallRecordStore.save(nil, for: kind, in: context.stateDirectory)
            return InstallOutcome(changed: false, configPath: file)
        }
        let loaded = try load(file)
        var root = loaded.root
        guard var hooks = root["hooks"], hooks.objectValue != nil else {
            try InstallRecordStore.save(nil, for: kind, in: context.stateDirectory)
            return InstallOutcome(changed: false, configPath: file)
        }
        var changed = false
        for (event, value) in hooks.objectValue ?? [] {
            guard let groups = value.arrayValue else { continue }
            let (cleaned, removed) = removeOurs(from: groups)
            if removed {
                changed = true
                hooks.set(event, cleaned.isEmpty ? nil : .array(cleaned))
            }
        }
        guard changed else {
            try InstallRecordStore.save(nil, for: kind, in: context.stateDirectory)
            return InstallOutcome(changed: false, configPath: file)
        }
        if hooks.objectValue?.isEmpty == true, record?.hadHooksKey != true {
            root.set("hooks", nil)
        } else {
            root.set("hooks", hooks)
        }
        let backup = try ConfigFiles.backup(file, kind: kind, context: context)
        if record?.createdFile == true, root.objectValue?.isEmpty == true {
            try? FileManager.default.removeItem(at: file)
        } else {
            try ConfigFiles.write(render(loaded, root), to: file)
        }
        try InstallRecordStore.save(nil, for: kind, in: context.stateDirectory)
        return InstallOutcome(changed: true, configPath: file, backup: backup)
    }

    public func inspect(_ context: IntegrationContext) -> IntegrationInspection {
        let file = configURL(home: context.home)
        if let reason = versionGate(context) {
            return IntegrationInspection(health: .unsupported(reason), configPath: file.path)
        }
        let record = InstallRecordStore.record(kind, in: context.stateDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return IntegrationInspection(health: record == nil ? .notInstalled : .overwritten, configPath: file.path)
        }
        let loaded: Loaded
        do {
            loaded = try load(file)
        } catch {
            return IntegrationInspection(health: .unreadable(error.localizedDescription), configPath: file.path)
        }
        var exact = 0
        var stale = 0
        var groupIndices: [String: Int] = [:]
        for spec in events {
            let desired = desiredEntry(spec, shim: context.shimPath)
            guard let groups = loaded.root["hooks"]?[spec.name]?.arrayValue else { continue }
            var found: OrderedJSON?
            for (index, group) in groups.enumerated() {
                if let entry = group["hooks"]?.arrayValue?.first(where: { isOurs($0["command"]?.stringValue) }) {
                    found = entry
                    groupIndices[spec.name] = index
                    break
                }
            }
            guard let found else { continue }
            if found == desired { exact += 1 } else { stale += 1 }
        }
        let expected = events.count
        var notes: [String] = []
        if reportsCodexTrust, exact + stale > 0 { notes += codexTrustNotes(context: context, configPath: file.path, groupIndices: groupIndices) }
        let health: IntegrationHealth
        if exact == expected {
            health = .installed(count: expected)
        } else if stale > 0 && exact + stale == expected {
            health = .stale("hook commands point at an old mship path or timeout")
        } else if exact + stale > 0 {
            health = .partial(present: exact + stale, expected: expected)
        } else {
            health = record == nil ? .notInstalled : .overwritten
        }
        return IntegrationInspection(health: health, configPath: file.path, notes: notes)
    }

    /// Codex records hook trust in config.toml as `[hooks.state."<file>:<event>:<group>:<hook>"]`.
    func codexTrustNotes(context: IntegrationContext, configPath: String, groupIndices: [String: Int]) -> [String] {
        let toml = context.home.appending(path: ".codex/config.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return [] }
        var notes: [String] = []
        if Self.codexHooksDisabled(text) { notes.append("Hooks are disabled in ~/.codex/config.toml ([features] hooks = false)") }
        let untrusted = groupIndices.filter { event, group in
            let key = "\(configPath):\(Self.snakeCase(event)):\(group):0"
            return !text.contains("[hooks.state.\"\(key)\"]")
        }
        if !untrusted.isEmpty {
            notes.append("Codex trust pending for \(untrusted.count) hook(s): run /hooks in Codex to review")
        }
        return notes
    }

    static func codexHooksDisabled(_ toml: String) -> Bool {
        var inFeatures = false
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inFeatures = line == "[features]"
                continue
            }
            guard inFeatures else { continue }
            let compact = line.replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("hooks=false") || compact.hasPrefix("codex_hooks=false") { return true }
        }
        return false
    }

    /// "PermissionRequest" → "permission_request".
    static func snakeCase(_ name: String) -> String {
        var result = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase, index > 0 { result.append("_") }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }
}
