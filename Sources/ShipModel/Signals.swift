import Foundation

/// Everything a terminal surface reports that the agent engine may care about.
/// Produced by the app from libghostty delegate callbacks.
public enum TerminalSignal: Sendable, Codable, Equatable {
    case title(String)
    case workingDirectory(String)
    case bell
    /// OSC 9 / 99 / 777.
    case desktopNotification(title: String, body: String)
    /// OSC 9;4. `state` is one of "remove", "set", "error", "indeterminate", "pause".
    case progress(state: String, percent: Int?)
    /// OSC 133;D from shell integration.
    case commandFinished(exitCode: Int?, durationNanos: UInt64)
    case processExited
}

/// What the engine needs to decide whether to notify or hold a permission hook.
public struct AttentionContext: Sendable, Codable, Equatable {
    public var focusedSurface: SurfaceID?
    public var appIsActive: Bool
    public var visibleSurfaces: Set<SurfaceID>

    public init(focusedSurface: SurfaceID? = nil, appIsActive: Bool = false, visibleSurfaces: Set<SurfaceID> = []) {
        self.focusedSurface = focusedSurface
        self.appIsActive = appIsActive
        self.visibleSurfaces = visibleSurfaces
    }

    /// The user is looking at this surface right now.
    public func isWatching(_ surface: SurfaceID?) -> Bool {
        guard let surface else { return false }
        return appIsActive && focusedSurface == surface
    }
}

/// Something worth the user's attention, emitted by the engine.
public struct AttentionEvent: Identifiable, Sendable, Codable, Equatable {
    public enum Kind: Sendable, Codable, Equatable {
        case permission(PermissionRequest)
        case needsInput
        case finished
        case failed
        /// A raw terminal notification (OSC 9/99/777) not attributable to a known agent state.
        case notification
    }

    public let id: UUID
    public var kind: Kind
    public var session: AgentSessionKey?
    public var surface: SurfaceID?
    public var title: String
    public var body: String
    public var date: Date
    /// False when the user is already watching the surface; the app still updates badges.
    public var shouldNotify: Bool

    public init(
        id: UUID = UUID(), kind: Kind, session: AgentSessionKey?, surface: SurfaceID?, title: String,
        body: String, date: Date = Date(), shouldNotify: Bool
    ) {
        self.id = id
        self.kind = kind
        self.session = session
        self.surface = surface
        self.title = title
        self.body = body
        self.date = date
        self.shouldNotify = shouldNotify
    }
}

/// One `mship hook <agent> <event>` invocation, forwarded over the control socket.
public struct HookEnvelope: Sendable, Codable, Equatable {
    public var agent: AgentKind
    /// The agent's event name, verbatim ("Stop", "PermissionRequest", "session.idle", …).
    public var event: String
    /// The raw bytes the agent wrote to the hook's stdin (or argv JSON for Codex `notify`).
    public var payload: Data
    /// From `MOTHERSHIP_SURFACE_ID`; nil when the agent runs outside Mothership.
    public var surface: SurfaceID?
    public var workspace: WorkspaceID?
    /// The hook's parent process, usually the agent itself.
    public var agentPID: Int32?
    public var cwd: String?
    public var sentAt: Date

    public init(
        agent: AgentKind, event: String, payload: Data, surface: SurfaceID? = nil,
        workspace: WorkspaceID? = nil, agentPID: Int32? = nil, cwd: String? = nil, sentAt: Date = Date()
    ) {
        self.agent = agent
        self.event = event
        self.payload = payload
        self.surface = surface
        self.workspace = workspace
        self.agentPID = agentPID
        self.cwd = cwd
        self.sentAt = sentAt
    }
}

/// What `mship hook` writes back to the agent. The engine builds agent-specific output
/// (e.g. a permission decision JSON) so the CLI stays dumb.
public struct HookReply: Sendable, Codable, Equatable {
    public var stdout: String?
    public var exitCode: Int32

    public init(stdout: String? = nil, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.exitCode = exitCode
    }

    /// No output, exit 0: the agent proceeds as if no hook ran.
    public static let passthrough = HookReply()
}
