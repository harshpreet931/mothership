import Foundation

public enum AgentEngineUpdate: Sendable {
    /// Full, coalesced snapshot of every known session (in-app and external).
    case sessions([AgentSession])
    case attention(AttentionEvent)
    /// A held permission request was decided, expired, or released.
    case permissionResolved(PermissionRequestID)
    case integrations([IntegrationStatus])
}

/// The agent engine as the app sees it. Implemented by `AgentKit.AgentEngine`.
public protocol AgentEngineProtocol: AnyObject, Sendable {
    /// Start probing processes and watching transcripts. Idempotent.
    func start() async
    func stop() async

    /// A new independent stream of updates per call.
    func updates() -> AsyncStream<AgentEngineUpdate>
    func sessions() async -> [AgentSession]

    /// Called for every `mship hook` invocation. For permission events this may suspend
    /// until the user decides, the request expires, or the user focuses the pane.
    func handleHook(_ hook: HookEnvelope) async -> HookReply
    func resolvePermission(_ id: PermissionRequestID, decision: PermissionDecision) async

    func surfaceOpened(_ surface: SurfaceID, workspace: WorkspaceID, cwd: String?) async
    func surfaceClosed(_ surface: SurfaceID) async
    func surfaceSignal(_ surface: SurfaceID, _ signal: TerminalSignal) async
    func attentionContextChanged(_ context: AttentionContext) async
    /// Clear `unread` for sessions on this surface (the user looked at it).
    func markRead(surface: SurfaceID) async

    func integrationStatuses() async -> [IntegrationStatus]
    /// Merge Mothership's hooks/plugin into the agent's config (with backup). Only on user consent.
    func installIntegration(_ kind: AgentKind) async throws
    func uninstallIntegration(_ kind: AgentKind) async throws

    /// Command line that resumes this session in a fresh shell, if the agent supports it.
    func resumeCommand(for session: AgentSessionKey) async -> String?
    /// Command line that starts this agent with an initial prompt.
    func launchCommand(_ kind: AgentKind, prompt: String?) async -> String
}
