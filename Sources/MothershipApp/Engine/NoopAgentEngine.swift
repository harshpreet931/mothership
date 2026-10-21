import Foundation
import ShipModel

/// Stand-in until `AgentKit.AgentEngine` is wired in: knows no sessions and never emits.
final class NoopAgentEngine: AgentEngineProtocol {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The agent engine isn't available in this build." }
    }

    func start() async {}
    func stop() async {}
    func updates() -> AsyncStream<AgentEngineUpdate> { AsyncStream { _ in } }
    func sessions() async -> [AgentSession] { [] }
    func handleHook(_: HookEnvelope) async -> HookReply { .passthrough }
    func resolvePermission(_: PermissionRequestID, decision _: PermissionDecision) async {}
    func surfaceOpened(_: SurfaceID, workspace _: WorkspaceID, cwd _: String?) async {}
    func surfaceClosed(_: SurfaceID) async {}
    func surfaceSignal(_: SurfaceID, _: TerminalSignal) async {}
    func attentionContextChanged(_: AttentionContext) async {}
    func markRead(surface _: SurfaceID) async {}
    func integrationStatuses() async -> [IntegrationStatus] { [] }
    func installIntegration(_: AgentKind) async throws { throw Unavailable() }
    func uninstallIntegration(_: AgentKind) async throws { throw Unavailable() }
    func resumeCommand(for _: AgentSessionKey) async -> String? { nil }
    func launchCommand(_ kind: AgentKind, prompt: String?) async -> String {
        let executable = switch kind {
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .gemini: "gemini"
        default: kind.rawValue
        }
        guard let prompt, !prompt.isEmpty else { return executable }
        return executable + " '" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
