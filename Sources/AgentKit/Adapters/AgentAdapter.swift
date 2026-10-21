import Foundation
import ShipModel
import SystemProbe
import Synchronization

/// A process plus what was read about it.
public struct ObservedProcess: Sendable {
    public var snapshot: ProcessSnapshot
    public var arguments: ProcessArguments
    public var cwd: String?

    public init(snapshot: ProcessSnapshot, arguments: ProcessArguments, cwd: String? = nil) {
        self.snapshot = snapshot
        self.arguments = arguments
        self.cwd = cwd
    }

    public var pid: Int32 { snapshot.pid }
}

/// What an adapter learned about which agent session a live process is running.
public struct SessionBinding: Sendable, Equatable {
    public var sessionID: String
    public var transcriptPath: String?
    /// Extra signals the binding source carries (e.g. Claude's per-pid status file).
    public var signals: [AgentSignal]

    public init(sessionID: String, transcriptPath: String? = nil, signals: [AgentSignal] = []) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.signals = signals
    }
}

/// Inputs for `AgentAdapter.bindSession`.
public struct BindingContext: Sendable {
    public var home: URL
    public var table: ProcessTable
    public var now: Date
    /// Open file paths of a pid (libproc). Injected so tests don't need real processes.
    public var openFiles: @Sendable (Int32) -> [String]
    /// OpenCode sessions by directory, newest first, when the database is readable.
    public var openCodeSessions: @Sendable (String) -> [OpenCodeSessionRow]

    public init(
        home: URL, table: ProcessTable, now: Date = Date(),
        openFiles: @escaping @Sendable (Int32) -> [String] = { pid in ProcessInspector.openFilePaths(pid: pid) },
        openCodeSessions: @escaping @Sendable (String) -> [OpenCodeSessionRow] = { _ in [] }
    ) {
        self.home = home
        self.table = table
        self.now = now
        self.openFiles = openFiles
        self.openCodeSessions = openCodeSessions
    }
}

/// Where an adapter's transcripts / state live, and how to read them.
public struct TranscriptSource: Sendable {
    public enum Format: Sendable, Equatable {
        /// Append-only JSON lines, tailed with byte offsets.
        case jsonl
        /// A small JSON document rewritten in place (re-read whole on change).
        case jsonDocument
        /// A read-only SQLite database, polled when its WAL changes.
        case sqlite
    }

    public var format: Format
    /// Directory (or file, for SQLite) to watch with FSEvents.
    public var root: URL
    /// Whether a changed path belongs to this source.
    public var accepts: @Sendable (String) -> Bool
    /// JSONL prefilter: lines containing none of these substrings are skipped unparsed.
    public var lineMarkers: [String]?

    public init(format: Format, root: URL, lineMarkers: [String]? = nil, accepts: @escaping @Sendable (String) -> Bool) {
        self.format = format
        self.root = root
        self.lineMarkers = lineMarkers
        self.accepts = accepts
    }
}

/// One unit of transcript input.
public enum TranscriptRecord: Sendable {
    case line(path: String, data: Data)
    case document(path: String, data: Data)
    case openCodeSession(OpenCodeSessionRow)
}

/// Per-file decoder state (e.g. the session id from a header line, last message id for
/// usage de-duplication).
public struct TranscriptDecodeState: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    public var lastMessageID: String?
    public var lastMessageUsage: TokenUsage?
    /// Running usage total for sources that report per-message usage.
    public var usageTotal: TokenUsage = .zero
    /// True while replaying history on first sight of a file.
    public var isInitialLoad: Bool
    /// Skip the rest of this file (e.g. a subagent rollout).
    public var ignored: Bool
    public var values: [String: String]

    public init(sessionID: String? = nil, isInitialLoad: Bool = false) {
        self.sessionID = sessionID
        self.isInitialLoad = isInitialLoad
        self.ignored = false
        self.values = [:]
    }
}

/// A blocking permission prompt extracted from a hook payload.
public struct PermissionPrompt: Sendable, Equatable {
    public var tool: String
    public var summary: String
    public var detail: String?
    /// The agent's own request id (OpenCode), for matching a later "replied" event.
    public var externalID: String?

    public init(tool: String, summary: String, detail: String? = nil, externalID: String? = nil) {
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.externalID = externalID
    }
}

/// Regex → state rule for screen text (Tier 4).
public struct ScreenRule: Sendable, Codable, Equatable {
    public var pattern: String
    public var state: AgentState

    public init(pattern: String, state: AgentState) {
        self.pattern = pattern
        self.state = state
    }
}

/// Terminal-title conventions (Tier 1, treated as a heuristic).
public struct TitleRule: Sendable, Codable, Equatable {
    public var working: String?
    public var idle: String?
    public var needsInput: String?
    /// Removed from the title before using it as the session title.
    public var strip: String?

    public init(working: String? = nil, idle: String? = nil, needsInput: String? = nil, strip: String? = nil) {
        self.working = working
        self.idle = idle
        self.needsInput = needsInput
        self.strip = strip
    }

    public func state(for title: String) -> AgentState? {
        if let needsInput, RegexCache.matches(needsInput, title) { return .needsInput(.question) }
        if let working, RegexCache.matches(working, title) { return .working(tool: nil) }
        if let idle, RegexCache.matches(idle, title) { return .idle }
        return nil
    }

    public func cleanTitle(_ title: String) -> String {
        var cleaned = title
        if let strip { cleaned = RegexCache.replace(strip, in: cleaned, with: "") }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The per-agent integration surface (ARCHITECTURE §5.4).
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    var displayName: String { get }
    /// CLI names to look for on PATH (for integration status).
    var executableNames: [String] { get }

    /// Cheap filter on `p_comm` before argv is read.
    func isCandidate(comm: String) -> Bool
    /// True when this process is the agent itself (not a wrapper's helper, MCP server, …).
    func matchesRoot(_ process: ObservedProcess) -> Bool

    func integration() -> (any IntegrationInstaller)?
    func decodeHook(event: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal]
    /// Non-nil when this hook event blocks on a permission decision.
    func permissionPrompt(event: String, payload: Data) -> PermissionPrompt?
    func permissionReply(_ decision: PermissionDecision, event: String, payload: Data) -> HookReply

    func transcriptSources(home: URL) -> [TranscriptSource]
    func decodeTranscript(_ record: TranscriptRecord, state: inout TranscriptDecodeState) -> [AgentSignal]
    /// Resolve the agent's own session id for a live root process.
    func bindSession(_ process: ObservedProcess, context: BindingContext) -> SessionBinding?
    /// The transcript file for a known session, if it exists.
    func transcriptPath(sessionID: String, cwd: String, home: URL) -> String?

    func screenRules() -> [ScreenRule]
    func titleRule() -> TitleRule?
    /// Whether CPU time is a usable working/idle guess for this agent (no hooks or transcripts).
    var usesCPUHeuristic: Bool { get }

    func resumeCommand(session: String, cwd: String) -> [String]?
    func launchCommand(prompt: String?, cwd: String) -> [String]
}

extension AgentAdapter {
    public var displayName: String { kind.displayName }
    public var executableNames: [String] { [kind.rawValue] }
    public func integration() -> (any IntegrationInstaller)? { nil }
    public func decodeHook(event: String, payload: Data, envelope: HookEnvelope?) -> [AgentSignal] { [] }
    public func permissionPrompt(event: String, payload: Data) -> PermissionPrompt? { nil }
    public func permissionReply(_ decision: PermissionDecision, event: String, payload: Data) -> HookReply { .passthrough }
    public func transcriptSources(home: URL) -> [TranscriptSource] { [] }
    public func decodeTranscript(_ record: TranscriptRecord, state: inout TranscriptDecodeState) -> [AgentSignal] { [] }
    public func bindSession(_ process: ObservedProcess, context: BindingContext) -> SessionBinding? { nil }
    public func transcriptPath(sessionID: String, cwd: String, home: URL) -> String? { nil }
    public func screenRules() -> [ScreenRule] { [] }
    public func titleRule() -> TitleRule? { nil }
    public var usesCPUHeuristic: Bool { false }
}

/// Process-matching helpers shared by adapters and manifests.
enum ProcessMatching {
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]

    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python3.") || name.hasPrefix("node")
    }

    /// argv entries after the interpreter's own flags (`node --max-old-space-size=… script.js`).
    static func scriptArguments(_ arguments: [String]) -> [String] {
        Array(arguments.dropFirst().drop { $0.hasPrefix("-") }.prefix(2))
    }

    /// The first argument that isn't a flag, after the program name (the subcommand).
    static func subcommand(_ arguments: [String], skipping: Int = 1) -> String? {
        arguments.dropFirst(skipping).first { !$0.hasPrefix("-") }
    }

    static func isVersionLike(_ comm: String) -> Bool {
        let parts = comm.split(separator: ".")
        return parts.count >= 2 && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

/// Compiled-regex cache shared across adapters and manifests.
enum RegexCache {
    private static let cache = Mutex<[String: NSRegularExpression]>([:])

    static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = cache.withLock({ $0[pattern] }) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        cache.withLock { $0[pattern] = compiled }
        return compiled
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Shell-quotes an argv into one command line.
public enum ShellQuoting {
    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    public static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
