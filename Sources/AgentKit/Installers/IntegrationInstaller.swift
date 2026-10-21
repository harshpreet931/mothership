import Foundation
import ShipModel

/// Everything an installer needs. `home` is a parameter so tests run against temp dirs;
/// the engine passes the real home directory.
public struct IntegrationContext: Sendable {
    public var home: URL
    /// The stable `mship` path hook configs point at (`ShipPaths.cliShim`).
    public var shimPath: String
    public var backupsDirectory: URL
    /// Where Mothership records what it installed (to detect "overwritten by another tool").
    public var stateDirectory: URL
    /// Version of the agent CLI, when known (gates version-dependent integrations).
    public var agentVersion: String?
    public var now: Date

    public init(home: URL, shimPath: String, backupsDirectory: URL, stateDirectory: URL, agentVersion: String? = nil, now: Date = Date()) {
        self.home = home
        self.shimPath = shimPath
        self.backupsDirectory = backupsDirectory
        self.stateDirectory = stateDirectory
        self.agentVersion = agentVersion
        self.now = now
    }
}

public enum IntegrationHealth: Sendable, Equatable {
    case notInstalled
    case installed(count: Int)
    case partial(present: Int, expected: Int)
    /// Mothership installed it and the entries are gone (another tool rewrote the file).
    case overwritten
    /// Present but pointing at an old shim path / timeout; reinstall to repair.
    case stale(String)
    case unsupported(String)
    case unreadable(String)
}

public struct IntegrationInspection: Sendable, Equatable {
    public var health: IntegrationHealth
    public var configPath: String
    /// Extra advice, e.g. Codex's hook trust review.
    public var notes: [String]

    public init(health: IntegrationHealth, configPath: String, notes: [String] = []) {
        self.health = health
        self.configPath = configPath
        self.notes = notes
    }

    public var isInstalled: Bool {
        if case .installed = health { return true }
        return false
    }

    public var summary: String {
        let base: String =
            switch health {
            case .notInstalled: "Not installed"
            case .installed(let count): "Hooks installed (\(count) events)"
            case .partial(let present, let expected): "Partially installed (\(present)/\(expected) events) — reinstall to repair"
            case .overwritten: "Overwritten by another tool — reinstall"
            case .stale(let reason): "Needs repair: \(reason)"
            case .unsupported(let reason): "Unsupported: \(reason)"
            case .unreadable(let reason): "Config unreadable: \(reason)"
            }
        return ([base] + notes).joined(separator: " · ")
    }
}

public struct InstallOutcome: Sendable, Equatable {
    public var changed: Bool
    public var configPath: URL
    public var backup: URL?

    public init(changed: Bool, configPath: URL, backup: URL? = nil) {
        self.changed = changed
        self.configPath = configPath
        self.backup = backup
    }
}

public enum IntegrationError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case invalidConfig(path: String, reason: String)
    /// A file at our path that Mothership didn't write.
    case notOurs(path: String)
    case writeFailed(path: String, reason: String)
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): "Unsupported: \(reason)"
        case .invalidConfig(let path, let reason): "Can't edit \(path): \(reason)"
        case .notOurs(let path): "\(path) exists and wasn't created by Mothership"
        case .writeFailed(let path, let reason): "Couldn't write \(path): \(reason)"
        case .unknownAgent(let kind): "No integration for \(kind)"
        }
    }
}

/// Merges Mothership's hooks / plugin into one agent's config. Install is idempotent,
/// uninstall removes exactly what install added, third-party entries are never touched,
/// and every write is preceded by a timestamped backup.
public protocol IntegrationInstaller: Sendable {
    var kind: AgentKind { get }
    func configURL(home: URL) -> URL
    func inspect(_ context: IntegrationContext) -> IntegrationInspection
    /// The file contents install would write (for a consent diff). Nil if nothing would change.
    func plannedContents(_ context: IntegrationContext) throws -> String?
    @discardableResult func install(_ context: IntegrationContext) throws -> InstallOutcome
    @discardableResult func uninstall(_ context: IntegrationContext) throws -> InstallOutcome
}

// MARK: - Install records

/// What Mothership installed, per agent, in `<stateDirectory>/integrations.json`.
struct InstallRecord: Codable, Equatable, Sendable {
    var installedAt: Date
    var configPath: String
    var shimPath: String
    var items: [String]
    /// The config file didn't exist before install.
    var createdFile: Bool
    /// The `hooks` key existed (possibly empty) before install.
    var hadHooksKey: Bool
}

enum InstallRecordStore {
    static func url(_ directory: URL) -> URL { directory.appending(path: "integrations.json") }

    static func load(_ directory: URL) -> [String: InstallRecord] {
        guard let data = try? Data(contentsOf: url(directory)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: InstallRecord].self, from: data)) ?? [:]
    }

    static func record(_ kind: AgentKind, in directory: URL) -> InstallRecord? { load(directory)[kind.rawValue] }

    static func save(_ record: InstallRecord?, for kind: AgentKind, in directory: URL) throws {
        var all = load(directory)
        all[kind.rawValue] = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: url(directory), options: .atomic)
    }
}

// MARK: - File helpers

enum ConfigFiles {
    /// `<backups>/<kind>/<name>.<timestamp>.bak`; returns nil when there was nothing to back up.
    static func backup(_ file: URL, kind: AgentKind, context: IntegrationContext) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let directory = context.backupsDirectory.appending(path: kind.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = timestamp(context.now)
        var destination = directory.appending(path: "\(file.lastPathComponent).\(stamp).bak")
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            counter += 1
            destination = directory.appending(path: "\(file.lastPathComponent).\(stamp)-\(counter).bak")
        }
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d-%02d-%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Atomic replace that keeps the original file's permissions.
    static func write(_ contents: String, to file: URL) throws {
        let fileManager = FileManager.default
        let permissions = (try? fileManager.attributesOfItem(atPath: file.path))?[.posixPermissions]
        do {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file, options: .atomic)
            if let permissions { try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        } catch {
            throw IntegrationError.writeFailed(path: file.path, reason: error.localizedDescription)
        }
    }

    /// Double-quoted for `sh -c` (paths contain spaces: "Application Support").
    static func shellQuoted(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "\"\\$`".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }
}

/// Semantic-version comparison good enough for CLI version gates ("0.26.0" ≥ "0.18.4").
enum VersionCompare {
    static func components(_ version: String) -> [Int] {
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let lhs = components(version)
        let rhs = components(minimum)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return true
    }
}
