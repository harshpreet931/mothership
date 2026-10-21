import Foundation
import ShipModel

/// How much a signal is trusted. Lower raw values win (ARCHITECTURE §5.1).
public enum SignalTier: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Agent hooks / plugin events.
    case hook = 0
    /// OSC notifications, title, progress, bell from the terminal surface.
    case terminal = 1
    /// Transcripts, agent state files, SQLite.
    case transcript = 2
    /// The process table.
    case process = 3
    /// Screen text, CPU and other guesses.
    case heuristic = 4

    public static func < (lhs: SignalTier, rhs: SignalTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which session a signal is about. The engine resolves it to an `AgentSessionKey`.
public struct SessionHint: Sendable, Codable, Equatable {
    public var kind: AgentKind
    /// The agent's own session id, when the source knows it.
    public var sessionID: String?
    public var pid: Int32?
    public var surface: SurfaceID?
    public var cwd: String?
    public var transcriptPath: String?
    /// Facts about a session that may not exist yet (e.g. Codex's thread-name index): never
    /// creates a session; kept and applied if the session shows up later.
    public var attachOnly: Bool

    public init(
        kind: AgentKind, sessionID: String? = nil, pid: Int32? = nil, surface: SurfaceID? = nil, cwd: String? = nil,
        transcriptPath: String? = nil, attachOnly: Bool = false
    ) {
        self.kind = kind
        self.sessionID = sessionID?.isEmpty == true ? nil : sessionID
        self.pid = pid
        self.surface = surface
        self.cwd = cwd?.isEmpty == true ? nil : cwd
        self.transcriptPath = transcriptPath?.isEmpty == true ? nil : transcriptPath
        self.attachOnly = attachOnly
    }
}

extension AgentState {
    /// Working or blocked on input: a turn is in progress.
    var isBusy: Bool {
        switch self {
        case .working, .needsInput: true
        default: false
        }
    }
}

/// Who named a session.
public enum TitleSource: String, Sendable, Codable {
    /// AI-generated or agent-derived (Claude ai-title, Codex thread name, OpenCode title).
    case agent
    /// Set by the user (Claude custom title / rename). Beats agent titles.
    case user
}

/// Facts that don't change state by themselves.
public struct SessionMetadata: Sendable, Codable, Equatable {
    /// Title from the agent itself (custom/AI title). Overrides a prompt-derived title.
    public var title: String?
    public var titleSource: TitleSource?
    /// The session's first user prompt (title fallback), when the source knows it.
    public var firstUserPrompt: String?
    public var model: String?
    public var cwd: String?
    public var branch: String?
    public var transcriptPath: String?
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// Cost the agent itself reported (not an estimate).
    public var reportedCostUSD: Double?
    /// "Codex Desktop", "Claude" … when the transcript names the client.
    public var hostApp: String?
    public var startedAt: Date?

    public init(
        title: String? = nil, model: String? = nil, cwd: String? = nil, branch: String? = nil,
        transcriptPath: String? = nil, lastUserPrompt: String? = nil, lastAssistantMessage: String? = nil,
        contextTokens: Int? = nil, contextWindow: Int? = nil, reportedCostUSD: Double? = nil,
        hostApp: String? = nil, startedAt: Date? = nil, titleSource: TitleSource? = nil, firstUserPrompt: String? = nil
    ) {
        self.title = title
        self.titleSource = titleSource
        self.firstUserPrompt = firstUserPrompt
        self.model = model
        self.cwd = cwd
        self.branch = branch
        self.transcriptPath = transcriptPath
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.reportedCostUSD = reportedCostUSD
        self.hostApp = hostApp
        self.startedAt = startedAt
    }

    public var isEmpty: Bool { self == SessionMetadata() }
}

public enum UsageMode: String, Sendable, Codable {
    /// Add to the running total (per-message usage).
    case add
    /// Replace the running total (sources that report cumulative totals).
    case replace
}

/// What happened. Each maps onto the state machine of ARCHITECTURE §5.2.
public enum SignalEvent: Sendable, Codable, Equatable {
    case sessionStarted(source: String?)
    case promptSubmitted(prompt: String?)
    case toolStarted(tool: String, summary: String?)
    case toolFinished(tool: String?)
    case permissionRequested(tool: String, summary: String, detail: String?)
    /// The permission prompt was answered (anywhere).
    case permissionCleared
    case inputRequested(InputReason, message: String?)
    case turnCompleted(lastMessage: String?)
    case turnInterrupted
    case failed(message: String)
    case sessionEnded(reason: String?)
    case processSeen
    case processExited
    case subagentStarted
    case subagentStopped
    case compacting
    /// A lower-tier source's view of the state (status files, OSC progress, title glyphs, CPU).
    case observedState(AgentState)
    case metadata(SessionMetadata)
    case usage(TokenUsage, UsageMode)
    /// Only refreshes `lastActivity`.
    case activity
}

/// One observation from any source (ARCHITECTURE §5.1).
public struct AgentSignal: Sendable, Codable, Equatable {
    public var tier: SignalTier
    /// Free-form provenance, e.g. "hook:claude:PreToolUse", "transcript", "osc:progress".
    public var source: String
    public var hint: SessionHint
    public var event: SignalEvent
    public var timestamp: Date
    /// Guesses need two agreeing samples before they change state.
    public var isHeuristic: Bool
    /// Read from history (first sight of a file, startup), not observed as it happened: it
    /// updates state but never raises attention or `unread`.
    public var isReplay: Bool

    public init(
        tier: SignalTier, source: String, hint: SessionHint, event: SignalEvent, timestamp: Date = Date(), isHeuristic: Bool = false,
        isReplay: Bool = false
    ) {
        self.tier = tier
        self.source = source
        self.hint = hint
        self.event = event
        self.timestamp = timestamp
        self.isHeuristic = isHeuristic
        self.isReplay = isReplay
    }

    public var kind: AgentKind { hint.kind }
}
