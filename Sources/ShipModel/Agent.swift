import Foundation

/// Which coding agent a session belongs to. Open-ended so manifest adapters can add kinds
/// without a release.
public struct AgentKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claude = AgentKind(rawValue: "claude")
    public static let codex = AgentKind(rawValue: "codex")
    public static let opencode = AgentKind(rawValue: "opencode")
    public static let gemini = AgentKind(rawValue: "gemini")

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identity of an agent session: the agent's own session id when known (from hooks or
/// transcripts), otherwise `pid:<pid>` until a better id arrives.
public struct AgentSessionKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var kind: AgentKind
    public var sessionID: String

    public init(kind: AgentKind, sessionID: String) {
        self.kind = kind
        self.sessionID = sessionID
    }

    public static func provisional(kind: AgentKind, pid: Int32) -> AgentSessionKey {
        AgentSessionKey(kind: kind, sessionID: "pid:\(pid)")
    }

    public var isProvisional: Bool { sessionID.hasPrefix("pid:") }
    public var description: String { "\(kind.rawValue)/\(sessionID)" }
}

public enum InputReason: String, Sendable, Codable {
    /// The agent is blocked on a tool-permission prompt.
    case permission
    /// The agent asked a question or is waiting for the next prompt after a notification.
    case question
    case other
}

public enum AgentState: Sendable, Codable, Equatable {
    case starting
    case idle
    case working(tool: String?)
    case needsInput(InputReason)
    case error(String)
    case ended

    public var isLive: Bool { self != .ended }

    public var needsAttention: Bool {
        switch self {
        case .needsInput, .error: true
        default: false
        }
    }
}

public struct TokenUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double?
    /// Tokens currently in the context window (latest turn), when the transcript reports it.
    public var contextTokens: Int?
    public var contextWindow: Int?

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0, costUSD: Double? = nil, contextTokens: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
    }

    public static let zero = TokenUsage()
}

public struct PermissionRequest: Identifiable, Sendable, Codable, Equatable {
    public let id: PermissionRequestID
    public var session: AgentSessionKey
    public var surface: SurfaceID?
    /// e.g. "Bash", "Edit", "WebFetch".
    public var toolName: String
    /// One line for a notification body, e.g. the shell command or the file path.
    public var summary: String
    /// Pretty-printed tool input for an expanded view.
    public var detail: String?
    public var createdAt: Date
    /// When the held hook gives up and releases the prompt to the TUI.
    public var expiresAt: Date

    public init(
        id: PermissionRequestID = PermissionRequestID(), session: AgentSessionKey,
        surface: SurfaceID?, toolName: String, summary: String, detail: String? = nil,
        createdAt: Date = Date(), expiresAt: Date
    ) {
        self.id = id
        self.session = session
        self.surface = surface
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum PermissionDecision: Sendable, Codable, Equatable {
    case allow
    case deny(reason: String?)
    /// Release the hook with no decision so the agent shows its normal TUI prompt.
    case passthrough
}

public struct AgentSession: Identifiable, Sendable, Codable, Equatable {
    public var id: AgentSessionKey
    public var kind: AgentKind { id.kind }
    /// The Mothership pane hosting this session; nil for sessions running elsewhere.
    public var surface: SurfaceID?
    /// For external sessions: the app that owns the terminal ("Visual Studio Code", "iTerm2", …).
    public var hostApp: String?
    public var pid: Int32?
    public var cwd: String
    public var repoRoot: String?
    public var branch: String?
    public var state: AgentState
    public var pendingPermission: PermissionRequest?
    /// First user prompt or agent-provided title.
    public var title: String?
    /// Short "what it's doing" line (on-device model or heuristic).
    public var summary: String?
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    public var model: String?
    public var usage: TokenUsage
    public var activeSubagents: Int
    public var transcriptPath: String?
    public var startedAt: Date
    public var lastActivity: Date
    /// Finished, failed, or needs input while its surface wasn't focused.
    public var unread: Bool

    public init(
        id: AgentSessionKey, surface: SurfaceID? = nil, hostApp: String? = nil, pid: Int32? = nil,
        cwd: String, repoRoot: String? = nil, branch: String? = nil, state: AgentState = .starting,
        pendingPermission: PermissionRequest? = nil, title: String? = nil, summary: String? = nil,
        lastUserPrompt: String? = nil, lastAssistantMessage: String? = nil, model: String? = nil,
        usage: TokenUsage = .zero, activeSubagents: Int = 0, transcriptPath: String? = nil,
        startedAt: Date = Date(), lastActivity: Date = Date(), unread: Bool = false
    ) {
        self.id = id
        self.surface = surface
        self.hostApp = hostApp
        self.pid = pid
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.branch = branch
        self.state = state
        self.pendingPermission = pendingPermission
        self.title = title
        self.summary = summary
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.model = model
        self.usage = usage
        self.activeSubagents = activeSubagents
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.unread = unread
    }
}

/// Per-agent integration health, shown in Settings and the sidebar footer.
public struct IntegrationStatus: Sendable, Codable, Equatable, Identifiable {
    public var id: AgentKind { kind }
    public var kind: AgentKind
    /// Path of the agent CLI if found on this machine.
    public var executablePath: String?
    public var version: String?
    public var installed: Bool
    /// Human-readable state, e.g. "Hooks installed (13 events)" or "Overwritten by another tool".
    public var detail: String

    public init(kind: AgentKind, executablePath: String?, version: String?, installed: Bool, detail: String) {
        self.kind = kind
        self.executablePath = executablePath
        self.version = version
        self.installed = installed
        self.detail = detail
    }
}
