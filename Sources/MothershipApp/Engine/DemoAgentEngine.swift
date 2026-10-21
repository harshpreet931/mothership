import Foundation
import ShipModel

/// Fabricated agent fleet for UI work and screenshots (`MOTHERSHIP_DEMO=1`). Sessions bind
/// to surfaces in the order the app opens them and cycle through realistic states,
/// including a pending permission request that the sidebar can approve or deny.
actor DemoAgentEngine: AgentEngineProtocol {
    private struct Step: Sendable {
        var duration: TimeInterval
        /// Hold here until the pending permission is resolved (or `duration` passes).
        var waitsForDecision = false
        var apply: @Sendable (inout AgentSession) -> Void
    }

    private struct Script: Sendable {
        var kind: AgentKind
        var cwd: String
        var branch: String
        var title: String
        var model: String
        var steps: [Step]
    }

    private struct Running: Sendable {
        var script: Script
        var index: Int
        var stepStarted: Date
    }

    private var continuations: [UUID: AsyncStream<AgentEngineUpdate>.Continuation] = [:]
    private var sessionsByKey: [AgentSessionKey: AgentSession] = [:]
    private var order: [AgentSessionKey] = []
    private var running: [AgentSessionKey: Running] = [:]
    private var pendingScripts: [Script]
    private var context = AttentionContext()
    private var integrations: [IntegrationStatus]
    private var ticker: Task<Void, Never>?

    init() {
        pendingScripts = Self.scripts()
        integrations = [
            IntegrationStatus(kind: .claude, executablePath: "/opt/homebrew/bin/claude", version: "2.1.306", installed: true, detail: "Hooks · 13 events"),
            IntegrationStatus(kind: .codex, executablePath: "/opt/homebrew/bin/codex", version: "0.146.0", installed: true, detail: "Hooks overwritten by another tool · repair to restore 8 events"),
            IntegrationStatus(kind: .opencode, executablePath: "/Users/demo/.opencode/bin/opencode", version: "1.0.74", installed: false, detail: "Plugin · not connected"),
            IntegrationStatus(kind: .gemini, executablePath: nil, version: nil, installed: false, detail: "Not found on PATH"),
        ]
        for session in Self.externalSessions() {
            sessionsByKey[session.id] = session
            order.append(session.id)
        }
    }

    // MARK: AgentEngineProtocol

    func start() async {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                await self?.tick()
            }
        }
    }

    func stop() async {
        ticker?.cancel()
        ticker = nil
    }

    nonisolated func updates() -> AsyncStream<AgentEngineUpdate> {
        let (stream, continuation) = AsyncStream<AgentEngineUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        Task { await self.register(id, continuation) }
        return stream
    }

    func sessions() async -> [AgentSession] { snapshot() }

    func handleHook(_: HookEnvelope) async -> HookReply { .passthrough }

    func resolvePermission(_ id: PermissionRequestID, decision: PermissionDecision) async {
        guard let key = order.first(where: { sessionsByKey[$0]?.pendingPermission?.id == id }),
              var session = sessionsByKey[key] else { return }
        session.pendingPermission = nil
        switch decision {
        case .allow, .passthrough:
            session.state = .working(tool: "Bash")
            session.summary = "Running the approved command"
        case .deny(let reason):
            session.state = .working(tool: nil)
            session.summary = reason.map { "Denied: \($0)" } ?? "Permission denied, choosing another approach"
        }
        session.lastActivity = Date()
        sessionsByKey[key] = session
        if var run = running[key] {
            run.index = (run.index + 1) % run.script.steps.count
            run.stepStarted = Date()
            running[key] = run
        }
        broadcast(.permissionResolved(id))
        broadcast(.sessions(snapshot()))
    }

    func surfaceOpened(_ surface: SurfaceID, workspace _: WorkspaceID, cwd _: String?) async {
        guard !pendingScripts.isEmpty else { return }
        let script = pendingScripts.removeFirst()
        let key = AgentSessionKey(kind: script.kind, sessionID: UUID().uuidString.lowercased())
        var session = AgentSession(
            id: key, surface: surface, pid: Int32.random(in: 20000 ... 90000), cwd: script.cwd,
            repoRoot: script.cwd, branch: script.branch, state: .starting, title: script.title,
            model: script.model, startedAt: Date().addingTimeInterval(-Double.random(in: 300 ... 4000))
        )
        session.usage = TokenUsage(
            inputTokens: Int.random(in: 40000 ... 400_000), outputTokens: Int.random(in: 4000 ... 40000),
            cacheReadTokens: Int.random(in: 100_000 ... 2_000_000), costUSD: Double.random(in: 0.4 ... 6.5),
            contextTokens: Int.random(in: 30000 ... 150_000), contextWindow: 200_000
        )
        script.steps[0].apply(&session)
        sessionsByKey[key] = session
        order.append(key)
        running[key] = Running(script: script, index: 0, stepStarted: Date())
        broadcast(.sessions(snapshot()))
    }

    func surfaceClosed(_ surface: SurfaceID) async {
        let keys = order.filter { sessionsByKey[$0]?.surface == surface }
        for key in keys {
            sessionsByKey[key] = nil
            running[key] = nil
        }
        order.removeAll { keys.contains($0) }
        if !keys.isEmpty { broadcast(.sessions(snapshot())) }
    }

    func surfaceSignal(_: SurfaceID, _: TerminalSignal) async {}

    func attentionContextChanged(_ context: AttentionContext) async {
        self.context = context
    }

    func markRead(surface: SurfaceID) async {
        var changed = false
        for key in order where sessionsByKey[key]?.surface == surface && sessionsByKey[key]?.unread == true {
            sessionsByKey[key]?.unread = false
            changed = true
        }
        if changed { broadcast(.sessions(snapshot())) }
    }

    func integrationStatuses() async -> [IntegrationStatus] { integrations }

    func installIntegration(_ kind: AgentKind) async throws {
        try await Task.sleep(for: .milliseconds(600))
        if let index = integrations.firstIndex(where: { $0.kind == kind }) {
            integrations[index].installed = true
            integrations[index].detail = "Installed (demo — nothing was written)"
        }
        broadcast(.integrations(integrations))
    }

    func uninstallIntegration(_ kind: AgentKind) async throws {
        try await Task.sleep(for: .milliseconds(400))
        if let index = integrations.firstIndex(where: { $0.kind == kind }) {
            integrations[index].installed = false
            integrations[index].detail = "Not installed (demo)"
        }
        broadcast(.integrations(integrations))
    }

    func resumeCommand(for session: AgentSessionKey) async -> String? {
        switch session.kind {
        case .claude: "claude --resume \(session.sessionID)"
        case .codex: "codex resume \(session.sessionID)"
        case .opencode: "opencode --session \(session.sessionID)"
        default: nil
        }
    }

    func launchCommand(_ kind: AgentKind, prompt: String?) async -> String {
        let base = kind == .claude ? "claude" : kind.rawValue
        guard let prompt else { return base }
        return base + " '" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Timeline

    private func register(_ id: UUID, _ continuation: AsyncStream<AgentEngineUpdate>.Continuation) {
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unregister(id) }
        }
        continuation.yield(.integrations(integrations))
        continuation.yield(.sessions(snapshot()))
    }

    private func unregister(_ id: UUID) {
        continuations[id] = nil
    }

    private func broadcast(_ update: AgentEngineUpdate) {
        for continuation in continuations.values { continuation.yield(update) }
    }

    private func snapshot() -> [AgentSession] {
        order.compactMap { sessionsByKey[$0] }
    }

    private func tick() {
        let now = Date()
        var changed = false
        for (key, run) in running {
            let step = run.script.steps[run.index]
            guard now.timeIntervalSince(run.stepStarted) >= step.duration,
                  var session = sessionsByKey[key] else { continue }
            if step.waitsForDecision, let request = session.pendingPermission {
                // Timed out: the hook releases the prompt back to the TUI.
                session.pendingPermission = nil
                broadcast(.permissionResolved(request.id))
            }
            let nextIndex = (run.index + 1) % run.script.steps.count
            let before = session.state
            run.script.steps[nextIndex].apply(&session)
            session.lastActivity = now
            if session.surface.map({ !context.isWatching($0) }) ?? true, session.state != before {
                switch session.state {
                case .idle, .needsInput, .error: session.unread = true
                default: break
                }
            }
            sessionsByKey[key] = session
            running[key] = Running(script: run.script, index: nextIndex, stepStarted: now)
            changed = true
            if session.state != before { emitAttention(for: session) }
        }
        if changed { broadcast(.sessions(snapshot())) }
    }

    private func emitAttention(for session: AgentSession) {
        let kind: AttentionEvent.Kind
        let body: String
        switch session.state {
        case .needsInput(.permission):
            guard let request = session.pendingPermission else { return }
            kind = .permission(request)
            body = "\(request.toolName): \(request.summary)"
        case .needsInput:
            kind = .needsInput
            body = session.summary ?? "Waiting for your input"
        case .idle:
            kind = .finished
            body = session.lastAssistantMessage ?? "Finished"
        case .error(let message):
            kind = .failed
            body = message
        default:
            return
        }
        let event = AttentionEvent(
            kind: kind, session: session.id, surface: session.surface,
            title: "\(session.kind.displayName) · \(session.title ?? "Session")", body: body,
            shouldNotify: !context.isWatching(session.surface)
        )
        broadcast(.attention(event))
    }

    // MARK: Fixtures

    private static func permission(_ session: AgentSession, tool: String, summary: String, detail: String) -> PermissionRequest {
        PermissionRequest(
            session: session.id, surface: session.surface, toolName: tool, summary: summary, detail: detail,
            expiresAt: Date().addingTimeInterval(120)
        )
    }

    private static func scripts() -> [Script] {
        let claudeRefactor = Script(
            kind: .claude, cwd: "~/code/mothership", branch: "feat/token-refresh",
            title: "Refactor auth middleware", model: "claude-opus-4-5",
            steps: [
                Step(duration: 40, waitsForDecision: true) { session in
                    session.lastUserPrompt = "Refactor the auth middleware so token refresh is testable"
                    session.state = .needsInput(.permission)
                    session.summary = "Wants to run the auth test suite"
                    session.pendingPermission = permission(
                        session, tool: "Bash", summary: "pnpm test --filter @ship/auth -- --run",
                        detail: "{\n  \"command\": \"pnpm test --filter @ship/auth -- --run\",\n  \"timeout\": 120000\n}"
                    )
                    session.unread = true
                },
                Step(duration: 6) { session in
                    session.state = .working(tool: "Bash")
                    session.summary = "Running auth test suite"
                    session.lastAssistantMessage = "Running the auth suite now. refresh.ts takes a Clock so the expiry cases are deterministic."
                },
                Step(duration: 18) { session in
                    session.state = .idle
                    session.summary = "Token refresh extracted · 42 tests green"
                    session.lastAssistantMessage = "Token refresh now lives in src/auth/refresh.ts with its own clock injection; all 42 auth tests pass."
                },
                Step(duration: 7) { session in
                    session.lastUserPrompt = "Now add a test for clock skew during refresh"
                    session.state = .working(tool: "Edit")
                    session.summary = "Writing clock-skew test for refresh"
                    session.activeSubagents = 1
                },
                Step(duration: 6) { session in
                    session.state = .working(tool: "Read")
                    session.summary = "Reading src/auth/session.ts"
                    session.activeSubagents = 0
                },
            ]
        )
        let codexCharts = Script(
            kind: .codex, cwd: "~/code/mothership", branch: "feat/token-refresh",
            title: "Swift Charts migration", model: "gpt-5-codex",
            steps: [
                Step(duration: 9) { session in
                    session.lastUserPrompt = "Port the usage dashboard charts to Swift Charts"
                    session.state = .working(tool: "apply_patch")
                    session.summary = "Porting usage charts to Swift Charts"
                    session.lastAssistantMessage = "Starting with UsageChart, the only one with custom axis formatting. CostChart and ContextGauge follow the same pattern."
                },
                Step(duration: 22) { session in
                    session.state = .idle
                    session.summary = "Charts ported · 3 files changed"
                    session.lastAssistantMessage = "Ported UsageChart, CostChart and ContextGauge to Swift Charts; removed the Canvas fallback."
                },
                Step(duration: 8) { session in
                    session.state = .working(tool: "shell")
                    session.summary = "Running swift build"
                },
            ]
        )
        let geminiDocs = Script(
            kind: .gemini, cwd: "~/code/web-dashboard", branch: "docs/api-reference",
            title: "API reference docs", model: "gemini-2.5-pro",
            steps: [
                Step(duration: 30) { session in
                    session.lastUserPrompt = "Generate the API reference from the OpenAPI spec"
                    session.state = .error("429 · quota exhausted for gemini-2.5-pro")
                    session.summary = "Rate limited by the Gemini API"
                    session.lastAssistantMessage = "Request failed: 429 RESOURCE_EXHAUSTED."
                    session.unread = true
                },
                Step(duration: 10) { session in
                    session.state = .working(tool: "read_file")
                    session.summary = "Reading openapi.yaml (412 endpoints)"
                },
                Step(duration: 25) { session in
                    session.state = .idle
                    session.summary = "Drafted reference for 38 endpoints"
                    session.lastAssistantMessage = "Drafted docs/api/*.md for the billing and auth tags."
                },
            ]
        )
        let claudeInfra = Script(
            kind: .claude, cwd: "~/code/infra", branch: "main",
            title: "Terraform drift check", model: "claude-sonnet-4-5",
            steps: [
                Step(duration: 26) { session in
                    session.lastUserPrompt = "Check prod for terraform drift"
                    session.state = .idle
                    session.summary = "Plan: 3 to add, 1 to change"
                    session.lastAssistantMessage = "terraform plan shows 3 to add, 1 to change, 0 to destroy — the drift is the new CloudFront cache policy."
                    session.unread = true
                },
                Step(duration: 9) { session in
                    session.lastUserPrompt = "Apply only the cache policy change"
                    session.state = .working(tool: "Bash")
                    session.summary = "terraform apply -target=cache_policy"
                    session.lastAssistantMessage = "Applying only the cache policy change; the other three resources stay untouched."
                },
                Step(duration: 30) { session in
                    session.state = .needsInput(.question)
                    session.summary = "Asks whether to invalidate the CDN"
                    session.lastAssistantMessage = "Applied. Should I also invalidate /assets/* on the distribution?"
                },
            ]
        )
        let opencodeAPI = Script(
            kind: .opencode, cwd: "~/code/api-gateway", branch: "fix/rate-limiter",
            title: "Rate limiter fix", model: "claude-sonnet-4-5",
            steps: [
                Step(duration: 12) { session in
                    session.lastUserPrompt = "The sliding-window limiter double counts on retries"
                    session.state = .working(tool: "edit")
                    session.summary = "Fixing double count in sliding window"
                    session.lastAssistantMessage = "Found it: retries mint a fresh token, so the sliding window counts them twice. Reusing the original token instead."
                },
                Step(duration: 20) { session in
                    session.state = .idle
                    session.summary = "Limiter fixed · added retry test"
                    session.lastAssistantMessage = "Retries now reuse the original request token, so they no longer count twice."
                },
            ]
        )
        return [claudeRefactor, codexCharts, geminiDocs, claudeInfra, opencodeAPI]
    }

    /// Dev servers for Home's Ports panel.
    static let demoPorts: [ListeningPort] = [
        ListeningPort(port: 3000, process: "node · vite", workspaceName: "web-dashboard"),
        ListeningPort(port: 8080, process: "go · gateway", workspaceName: "api-gateway"),
        ListeningPort(port: 5432, process: "postgres", workspaceName: nil),
    ]

    private static func externalSessions() -> [AgentSession] {
        [
            AgentSession(
                id: AgentSessionKey(kind: .claude, sessionID: "ext-vscode-1"), hostApp: "Visual Studio Code",
                pid: 41022, cwd: "~/code/landing-page", branch: "redesign", state: .working(tool: "Edit"),
                title: "Hero section polish", summary: "Tightening hero copy and spacing",
                lastUserPrompt: "Make the hero feel calmer: less copy, more air",
                lastAssistantMessage: "Cut the subhead to one line and doubled the top padding. Trying a serif for the headline next.",
                model: "claude-sonnet-4-5",
                usage: TokenUsage(inputTokens: 182_000, outputTokens: 21_400, cacheReadTokens: 1_240_000, costUSD: 2.84, contextTokens: 64000, contextWindow: 200_000),
                startedAt: Date().addingTimeInterval(-1800)
            ),
            AgentSession(
                id: AgentSessionKey(kind: .codex, sessionID: "ext-iterm-1"), hostApp: "iTerm2", pid: 38810,
                cwd: "~/code/payments", branch: "migrate-ledger", state: .needsInput(.question),
                title: "Ledger migration", summary: "Asks: online or offline migration?",
                lastUserPrompt: "Plan the ledger table migration",
                lastAssistantMessage: "Two options: an online backfill (no downtime, ~40 min) or a 3-minute maintenance window. Which do you prefer?",
                model: "gpt-5-codex",
                usage: TokenUsage(inputTokens: 96000, outputTokens: 8800, costUSD: 1.12, contextTokens: 41000, contextWindow: 272_000),
                startedAt: Date().addingTimeInterval(-5400), unread: true
            ),
            AgentSession(
                id: AgentSessionKey(kind: .opencode, sessionID: "ext-tmux-1"), hostApp: "tmux", pid: 29911,
                cwd: "~/code/dotfiles", state: .idle, title: "Neovim LSP config",
                summary: "Switched to native LSP config",
                lastAssistantMessage: "Moved every server to vim.lsp.config; startup is 38 ms faster.",
                usage: TokenUsage(inputTokens: 31000, outputTokens: 4100, costUSD: 0.21, contextTokens: 18000, contextWindow: 128_000),
                startedAt: Date().addingTimeInterval(-9000)
            ),
        ]
    }
}
