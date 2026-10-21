import CoreServices
import Foundation
import OSLog
import ShipModel
import Synchronization
import SystemProbe

/// `log stream --predicate 'subsystem == "com.mothership.app" AND category == "AgentEngine"'`
let engineLog = Logger(subsystem: ShipInfo.bundleIdentifier, category: "AgentEngine")

/// The agent engine (ARCHITECTURE §5): merges hooks, terminal signals, transcripts and the
/// process table into one state per session, holds permission hooks (§6), installs
/// integrations, and publishes coalesced updates.
public actor AgentEngine: AgentEngineProtocol {
    public let configuration: AgentEngineConfiguration
    public nonisolated let adapters: [any AgentAdapter]
    let adaptersByKind: [AgentKind: any AgentAdapter]
    public nonisolated let manifestErrors: [String]

    var store: SessionStore
    var surfaces: [SurfaceID: SurfaceState] = [:]
    var attention = AttentionContext()
    var held: [PermissionRequestID: HeldPermission] = [:]
    /// Replies decided before the hook's continuation was registered.
    var earlyReplies: [PermissionRequestID: HookReply] = [:]
    /// Registered synchronously in `updates()` so nothing emitted after subscribing is missed.
    nonisolated let subscribers = Mutex<[UUID: AsyncStream<AgentEngineUpdate>.Continuation]>([:])
    var integrations: [IntegrationStatus] = []
    var integrationFingerprint = ""

    let scanner: ProcessScanner
    let ingestor: TranscriptIngestor
    let exitWatcher = ProcessExitWatcher()
    let locator: AgentCLILocator
    var fileWatcher: FileSystemWatcher?
    /// Per-file/directory kqueue watches on what live sessions write (instant, FSEvents-free).
    var vnodeWatcher: VnodeWatcher?
    /// When each watched directory was last listed (only newer files count as new).
    var directoryStamps: [String: Date] = [:]
    /// Wanted watch targets that don't exist yet (their parent is watched instead).
    var missingWatchTargets: Set<String> = []
    var staticWatchPaths: [String] = []
    var trackedTranscripts: Set<String> = []

    var running = false
    var tasks: [Task<Void, Never>] = []
    var flushTask: Task<Void, Never>?
    var leaseTask: Task<Void, Never>?
    var lastFlush = Date.distantPast
    var lastFullScan = Date.distantPast
    var lastSurfaceScan = Date.distantPast
    var startedAt = Date()
    var ready = false
    var readyWaiters: [CheckedContinuation<Void, Never>] = []
    /// True while `start()` runs: whatever it reads is history, not news.
    var startingUp = false
    /// Frontmost app: scan and poll at full speed; hidden: back off.
    var appActive = true
    /// The last `.sessions` snapshot sent, so identical ones aren't re-sent.
    var lastPublished: [AgentSession]?
    /// Summaries are regex work over long replies; recompute only when their inputs change.
    var summaryCache: [AgentSessionKey: (inputs: SummaryInputs, summary: String?)] = [:]
    var lastDesiredWatches: Set<String> = []
    var lastWatchedCount = -1
    var nextWatchAudit = Date.distantPast
    /// Bumped by every change that gets published (`markDirty`): derived data (watch targets,
    /// which pane agents need CPU samples) is recomputed only when it moves.
    var recordsGeneration = 0
    var watchGeneration = -1
    var paneCPUSamples: (generation: Int, needed: Bool)?

    struct SummaryInputs: Equatable {
        var state: AgentState
        var tool: String?
        var target: String?
        var title: String?
        var lastMessage: String?
        var permission: String?
    }
    var attentionGate = AttentionGate()
    public private(set) var metrics = EngineMetrics()

    struct SurfaceState: Sendable {
        var workspace: WorkspaceID
        var cwd: String?
        var title: String?
    }

    struct HeldPermission {
        var request: PermissionRequest
        var kind: AgentKind
        var event: String
        var payload: Data
        var externalID: String?
        var continuation: CheckedContinuation<HookReply, Never>?
        var timeout: Task<Void, Never>?
    }

    // MARK: Init

    public init(configuration: AgentEngineConfiguration = .standard, adapters: [any AgentAdapter]? = nil) {
        self.configuration = configuration
        let manifests = ManifestLoader.load(directory: configuration.manifestsDirectory)
        let list = adapters ?? Self.defaultAdapters(permissionHoldSeconds: Int(configuration.permissionHoldTimeout.rounded()), manifests: manifests.manifests)
        self.adapters = list
        self.manifestErrors = adapters == nil ? manifests.errors : []
        var byKind: [AgentKind: any AgentAdapter] = [:]
        for adapter in list where byKind[adapter.kind] == nil { byKind[adapter.kind] = adapter }
        self.adaptersByKind = byKind
        self.store = SessionStore(lease: configuration.tier0Lease)
        self.scanner = ProcessScanner(adapters: list, home: configuration.homeDirectory)
        self.ingestor = TranscriptIngestor(adapters: list, home: configuration.homeDirectory)
        self.locator = AgentCLILocator(home: configuration.homeDirectory, allowExecution: configuration.probeCLIVersions)
    }

    /// Native adapters first, then manifest adapters.
    public static func defaultAdapters(permissionHoldSeconds: Int = 600, manifests: [AgentManifest] = ManifestLoader.defaults()) -> [any AgentAdapter] {
        var list: [any AgentAdapter] = [
            ClaudeAdapter(permissionHoldSeconds: permissionHoldSeconds),
            CodexAdapter(permissionHoldSeconds: permissionHoldSeconds),
            OpenCodeAdapter(permissionHoldSeconds: permissionHoldSeconds),
            GeminiAdapter(),
        ]
        list += manifests.map(ManifestAdapter.init)
        return list
    }

    // MARK: Lifecycle

    public func start() async {
        guard !running else { return }
        running = true
        startingUp = true
        defer { startingUp = false }
        startedAt = Date()
        let exits = exitWatcher.exits
        tasks.append(Task { [weak self] in
            for await pid in exits { await self?.processExited(pid) }
        })
        if configuration.transcriptWatching { await startTranscriptWatching() }
        if configuration.processScanning {
            await performScan(.system, deferTranscripts: true)
            tasks.append(Task { [weak self] in await self?.scanLoop() })
        }
        tasks.append(Task { [weak self] in await self?.integrationLoop() })
        ready = true
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters.removeAll()
        markDirty()
    }

    public func stop() async {
        guard running else { return }
        running = false
        for task in tasks { task.cancel() }
        tasks.removeAll()
        leaseTask?.cancel()
        leaseTask = nil
        fileWatcher?.finish()
        fileWatcher = nil
        vnodeWatcher?.close()
        vnodeWatcher = nil
        directoryStamps.removeAll()
        for id in Array(held.keys) { releaseHeld(id, decision: .passthrough) }
        await ingestor.close()
        flush()
    }

    /// Resolves once `start()` finished its first scan.
    public func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    // MARK: Updates

    public nonisolated func updates() -> AsyncStream<AgentEngineUpdate> {
        let (stream, continuation) = AsyncStream<AgentEngineUpdate>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.subscribers.withLock { _ = $0.removeValue(forKey: id) } }
        subscribers.withLock { $0[id] = continuation }
        Task { await self.sendInitialState(to: continuation) }
        return stream
    }

    func sendInitialState(to continuation: AsyncStream<AgentEngineUpdate>.Continuation) {
        continuation.yield(.sessions(snapshot()))
        if !integrations.isEmpty { continuation.yield(.integrations(integrations)) }
    }

    func broadcast(_ update: AgentEngineUpdate) {
        let continuations = subscribers.withLock { Array($0.values) }
        for continuation in continuations { continuation.yield(update) }
    }

    /// Coalesce `.sessions` updates to at most one per `updateInterval`.
    func markDirty() {
        recordsGeneration &+= 1
        guard flushTask == nil else { return }
        let delay = lastFlush.addingTimeInterval(configuration.updateInterval).timeIntervalSinceNow
        flushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            await self?.flush()
        }
    }

    func flush() {
        flushTask = nil
        lastFlush = Date()
        guard !subscribers.withLock({ $0.isEmpty }) else { return }
        let sessions = snapshot()
        // Diff before emitting: an identical snapshot changes nothing downstream.
        guard sessions != lastPublished else { return }
        lastPublished = sessions
        metrics.updatesPublished += 1
        broadcast(.sessions(sessions))
    }

    public func sessions() async -> [AgentSession] { snapshot() }

    func snapshot() -> [AgentSession] {
        store.records.values.map(present).sorted { lhs, rhs in
            if lhs.state.isLive != rhs.state.isLive { return lhs.state.isLive }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    func present(_ record: SessionRecord) -> AgentSession {
        var session = record.session
        session.summary = summary(for: record)
        if record.costIsEstimate { session.usage.costUSD = Pricing.estimateCost(session.usage, model: session.model) }
        if session.usage.contextWindow == nil { session.usage.contextWindow = Pricing.contextWindow(for: session.model) }
        if session.hostApp == nil, session.surface == nil { session.hostApp = record.hostAppHint }
        return session
    }

    func summary(for record: SessionRecord) -> String? {
        let session = record.session
        let inputs = SummaryInputs(
            state: session.state, tool: record.currentTool, target: record.currentTarget, title: session.title,
            lastMessage: session.lastAssistantMessage, permission: session.pendingPermission?.summary
        )
        if let cached = summaryCache[record.key], cached.inputs == inputs { return cached.summary }
        let summary = configuration.summarizer.summary(for: record)
        summaryCache[record.key] = (inputs, summary)
        return summary
    }

    /// The full record (lease, activity, estimate flag) for diagnostics.
    public func record(for key: AgentSessionKey) -> SessionRecord? { store[key] }

    /// False when the agent reported its own cost (OpenCode); true for table estimates.
    public func costIsEstimated(_ key: AgentSessionKey) -> Bool { store[key]?.costIsEstimate ?? true }

    public func pendingPermissions() -> [PermissionRequest] { held.values.map(\.request).sorted { $0.createdAt < $1.createdAt } }

    // MARK: Applying signals

    func apply(_ signals: [AgentSignal], live: Bool = true, suppressAttention: Bool = false) {
        guard !signals.isEmpty else { return }
        let now = Date()
        let context = attention
        var deferredSeen = false
        var changed = false
        for signal in signals {
            // Only what is happening now may notify: not startup, not history, not old evidence.
            let recent = live && !signal.isReplay && !startingUp && signal.timestamp > now.addingTimeInterval(-60)
            metrics.signalsApplied += 1
            guard let change = store.apply(signal, now: now, watched: { recent ? context.isWatching($0) : true }) else { continue }
            if change.recordChanged { changed = true }
            if let old = change.renamedFrom {
                remapHeld(from: old, to: change.key)
                attentionGate.rename(old, to: change.key)
            }
            for replaced in change.replaced { releaseHeld(forSession: replaced) }
            if change.current == .ended { releaseHeld(forSession: change.key) }
            if change.recordChanged, !held.isEmpty { releaseSuperseded(for: change.key) }
            if store[change.key]?.deferred != nil { deferredSeen = true }
            if change.stateChanged { attentionGate.note(change.key, from: change.previous, to: change.current, at: signal.timestamp) }
            if recent, !suppressAttention, change.stateChanged, let previous = change.previous {
                emitAttention(for: change.key, from: previous, at: signal.timestamp)
            }
        }
        if deferredSeen { scheduleLeaseTick() }
        // Repeats (a scan re-seeing the same process, an unchanged status file) change nothing.
        if changed { markDirty() }
    }

    /// Wake when the earliest lease with a deferred state ends.
    func scheduleLeaseTick() {
        let due = store.records.values.compactMap { $0.deferred != nil ? $0.leaseUntil : nil }.min()
        guard let due else { return }
        leaseTask?.cancel()
        let delay = max(0.01, due.timeIntervalSinceNow + 0.01)
        leaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.leaseTick()
        }
    }

    func leaseTick() {
        leaseTask = nil
        let context = attention
        let now = Date()
        let changes = store.tick(now: now) { context.isWatching($0) }
        for change in changes {
            attentionGate.note(change.key, from: change.previous, to: change.current, at: now)
            // A deferred state is only news if its evidence is recent.
            guard let previous = change.previous, !startingUp, let evidence = store[change.key]?.lastStateChange,
                evidence > now.addingTimeInterval(-60)
            else { continue }
            emitAttention(for: change.key, from: previous, at: evidence)
        }
        if store.records.values.contains(where: { $0.deferred != nil }) { scheduleLeaseTick() }
        if !changes.isEmpty { markDirty() }
    }

    func emitAttention(for key: AgentSessionKey, from previous: AgentState, at evidence: Date = Date()) {
        guard let record = store[key] else { return }
        let session = record.session
        let kind: AttentionEvent.Kind
        let gateKind: AttentionGate.Kind
        let body: String
        switch session.state {
        case .needsInput(let reason):
            if reason == .permission, session.pendingPermission != nil { return }
            kind = .needsInput
            gateKind = .needsInput
            if reason == .permission, let tool = record.currentTool {
                body = AttentionText.permission(tool: tool, summary: record.currentTarget)
            } else {
                body = reason == .permission ? "Permission needed" : "Waiting for your input"
            }
        case .idle:
            switch previous {
            case .working, .needsInput: break
            default: return
            }
            kind = .finished
            gateKind = .finished
            body = AttentionText.body(session.lastAssistantMessage, fallback: "Finished")
        case .error(let message):
            kind = .failed
            gateKind = .failed
            body = AttentionText.body(message, fallback: "Failed")
        default:
            return
        }
        guard attentionGate.admit(gateKind, for: key, now: Date()) else { return }
        let event = AttentionEvent(
            kind: kind, session: key, surface: session.surface, title: AttentionText.title(session), body: body, date: evidence,
            shouldNotify: !attention.isWatching(session.surface)
        )
        broadcast(.attention(event))
    }

    // MARK: Hooks

    public func handleHook(_ envelope: HookEnvelope) async -> HookReply {
        guard let adapter = adaptersByKind[envelope.agent] else { return .passthrough }
        metrics.hooksHandled += 1
        var signals = adapter.decodeHook(event: envelope.event, payload: envelope.payload, envelope: envelope)
        let sessionID = signals.lazy.compactMap(\.hint.sessionID).first
        let pid = await resolveAgentPID(envelope, sessionID: sessionID)
        for index in signals.indices {
            if signals[index].hint.pid == nil { signals[index].hint.pid = pid }
            if signals[index].hint.surface == nil { signals[index].hint.surface = envelope.surface }
        }
        if envelope.agent == .opencode, ["permission.replied", "question.replied", "question.rejected"].contains(envelope.event),
            let requestID = OpenCodeAdapter.repliedRequestID(envelope.payload)
        {
            for (id, entry) in held where entry.externalID == requestID { releaseHeld(id, decision: .passthrough) }
        }
        guard let prompt = adapter.permissionPrompt(event: envelope.event, payload: envelope.payload) else {
            apply(signals)
            await trackTranscripts(in: signals)
            return .passthrough
        }
        apply(signals, suppressAttention: true)
        await trackTranscripts(in: signals)
        guard let key = resolvedKey(signals, pid: pid), let record = store[key] else { return .passthrough }
        let surface = record.session.surface ?? envelope.surface
        guard shouldHold(surface: surface) else {
            emitAttention(for: key, from: .working(tool: nil), at: envelope.sentAt)
            return .passthrough
        }
        let now = Date()
        let request = PermissionRequest(
            session: key, surface: surface, toolName: prompt.tool, summary: prompt.summary, detail: prompt.detail,
            createdAt: now, expiresAt: now.addingTimeInterval(configuration.permissionHoldTimeout)
        )
        store.update(key) { $0.session.pendingPermission = request }
        let id = request.id
        let timeout = configuration.permissionHoldTimeout
        held[id] = HeldPermission(
            request: request, kind: envelope.agent, event: envelope.event, payload: envelope.payload, externalID: prompt.externalID,
            timeout: Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                await self?.releaseHeld(id, decision: .passthrough)
            }
        )
        broadcast(
            .attention(
                AttentionEvent(
                    kind: .permission(request), session: key, surface: surface, title: AttentionText.title(record.session),
                    body: AttentionText.permission(tool: prompt.tool, summary: prompt.summary), shouldNotify: true
                )
            )
        )
        markDirty()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerContinuation(id, continuation)
            }
        } onCancel: {
            Task { [weak self] in await self?.releaseHeld(id, decision: .passthrough) }
        }
    }

    func registerContinuation(_ id: PermissionRequestID, _ continuation: CheckedContinuation<HookReply, Never>) {
        if let reply = earlyReplies.removeValue(forKey: id) {
            continuation.resume(returning: reply)
        } else if held[id] != nil {
            held[id]?.continuation = continuation
        } else {
            continuation.resume(returning: .passthrough)
        }
    }

    func shouldHold(surface: SurfaceID?) -> Bool {
        if attention.isWatching(surface) { return false }
        if surface == nil, !configuration.holdPermissionsForExternalSessions { return false }
        return true
    }

    func resolvedKey(_ signals: [AgentSignal], pid: Int32?) -> AgentSessionKey? {
        guard let hint = signals.first?.hint else { return nil }
        if let sessionID = hint.sessionID {
            let key = AgentSessionKey(kind: hint.kind, sessionID: sessionID)
            if store[key] != nil { return key }
        }
        if let pid, let key = store.key(forPID: pid) { return key }
        if let surface = hint.surface { return store.liveSession(onSurface: surface, kind: hint.kind) }
        return nil
    }

    /// The agent root behind a hook: walk from the hook's parent up the process tree.
    func resolveAgentPID(_ envelope: HookEnvelope, sessionID: String?) async -> Int32? {
        guard let agentPID = envelope.agentPID, agentPID > 1 else { return nil }
        if let key = store.key(forPID: agentPID), key.isProvisional || key.sessionID == sessionID { return agentPID }
        guard configuration.processScanning else { return agentPID }
        let chain = await scanner.agentChain(from: agentPID, kind: envelope.agent)
        let chosen = chain.first { root in
            guard let key = store.key(forPID: root.pid) else { return false }
            return key.isProvisional || key.sessionID == sessionID
        } ?? chain.first
        if let chosen { applyRootFacts(chosen) }
        return chosen?.pid
    }

    public func resolvePermission(_ id: PermissionRequestID, decision: PermissionDecision) async {
        releaseHeld(id, decision: decision)
    }

    /// Resume a held hook. `.allow`/`.deny` produce the agent's decision JSON; `.passthrough`
    /// releases it with no output so the agent shows its own prompt.
    func releaseHeld(_ id: PermissionRequestID, decision: PermissionDecision) {
        guard let entry = held.removeValue(forKey: id) else { return }
        entry.timeout?.cancel()
        let reply: HookReply
        if case .passthrough = decision {
            reply = .passthrough
        } else {
            reply = adaptersByKind[entry.kind]?.permissionReply(decision, event: entry.event, payload: entry.payload) ?? .passthrough
        }
        if let continuation = entry.continuation {
            continuation.resume(returning: reply)
        } else {
            earlyReplies[id] = reply
        }
        let key = entry.request.session
        store.update(key) { record in
            if record.session.pendingPermission?.id == id { record.session.pendingPermission = nil }
        }
        let hint = SessionHint(kind: key.kind, sessionID: key.sessionID)
        switch decision {
        case .allow:
            apply([AgentSignal(tier: .hook, source: "permission:allow", hint: hint, event: .toolStarted(tool: entry.request.toolName, summary: nonEmpty(entry.request.summary)))])
        case .deny:
            apply([AgentSignal(tier: .hook, source: "permission:deny", hint: hint, event: .permissionCleared)])
        case .passthrough:
            break
        }
        broadcast(.permissionResolved(id))
        markDirty()
    }

    /// Claude Code shows its own prompt while the hook is held; when the user answers there the
    /// session moves on and its card clears. Release the hook then instead of at the timeout.
    func releaseSuperseded(for key: AgentSessionKey) {
        let current = store[key]?.session.pendingPermission?.id
        for (id, entry) in held where entry.request.session == key && id != current {
            releaseHeld(id, decision: .passthrough)
        }
    }

    func releaseHeld(forSession key: AgentSessionKey) {
        for (id, entry) in held where entry.request.session == key { releaseHeld(id, decision: .passthrough) }
    }

    func remapHeld(from old: AgentSessionKey, to new: AgentSessionKey) {
        for (id, var entry) in held where entry.request.session == old {
            entry.request.session = new
            held[id] = entry
        }
    }

    // MARK: Terminal surfaces

    public func surfaceOpened(_ surface: SurfaceID, workspace: WorkspaceID, cwd: String?) async {
        surfaces[surface] = SurfaceState(workspace: workspace, cwd: cwd)
        requestSurfaceScan()
    }

    public func surfaceClosed(_ surface: SurfaceID) async {
        surfaces[surface] = nil
        for (id, entry) in held where entry.request.surface == surface { releaseHeld(id, decision: .passthrough) }
        requestSurfaceScan()
    }

    public func surfaceSignal(_ surface: SurfaceID, _ signal: TerminalSignal) async {
        let key = store.liveSession(onSurface: surface)
        let adapter = key.flatMap { adaptersByKind[$0.kind] }
        func emit(_ event: SignalEvent, heuristic: Bool = false) {
            guard let key else { return }
            let hint = SessionHint(kind: key.kind, sessionID: key.sessionID, surface: surface)
            apply([AgentSignal(tier: .terminal, source: "terminal", hint: hint, event: event, isHeuristic: heuristic)])
        }
        switch signal {
        case .title(let title):
            surfaces[surface]?.title = title
            guard let adapter, let rule = adapter.titleRule() else { return }
            if let state = rule.state(for: title) { emit(.observedState(state), heuristic: true) }
        case .workingDirectory(let cwd):
            surfaces[surface]?.cwd = cwd
        case .bell:
            if hooksQuiet(key) {
                rawNotification(surface: surface, title: "Bell", body: surfaces[surface]?.title ?? "Terminal bell", session: key)
            }
        case .desktopNotification(let title, let body):
            let text = "\(title) \(body)".lowercased()
            if key != nil, text.contains("permission") || text.contains("approve") || text.contains("allow ") {
                emit(.inputRequested(.permission, message: body))
            } else if hooksQuiet(key) {
                rawNotification(surface: surface, title: title.isEmpty ? "Notification" : title, body: body, session: key)
            }
        case .progress(let state, _):
            switch state {
            case "set", "indeterminate": emit(.observedState(.working(tool: nil)))
            case "remove": emit(.observedState(.idle))
            default: break
            }
        case .commandFinished:
            requestSurfaceScan()
        case .processExited:
            for record in store.records.values where record.session.surface == surface && record.session.state != .ended {
                let hint = SessionHint(kind: record.key.kind, sessionID: record.key.sessionID, surface: surface)
                apply([AgentSignal(tier: .terminal, source: "terminal:exit", hint: hint, event: .processExited)])
            }
        }
    }

    /// No hook from this session in the last few seconds (hooks already produced the alert).
    func hooksQuiet(_ key: AgentSessionKey?) -> Bool {
        guard let key, let lastHook = store[key]?.lastHookAt else { return true }
        return Date().timeIntervalSince(lastHook) > 5
    }

    func rawNotification(surface: SurfaceID, title: String, body: String, session: AgentSessionKey?) {
        let event = AttentionEvent(
            kind: .notification, session: session, surface: surface,
            title: TitleCleaner.plainLine(title, limit: 80) ?? "Notification", body: AttentionText.body(body, fallback: ""),
            shouldNotify: !attention.isWatching(surface)
        )
        broadcast(.attention(event))
    }

    /// Tier-4 seam: the app may pass the visible screen text of a surface (throttled).
    public func screenTextSampled(_ surface: SurfaceID, text: String) async {
        guard let key = store.liveSession(onSurface: surface), let adapter = adaptersByKind[key.kind] else { return }
        guard let rule = adapter.screenRules().first(where: { RegexCache.matches($0.pattern, text) }) else { return }
        let hint = SessionHint(kind: key.kind, sessionID: key.sessionID, surface: surface)
        apply([AgentSignal(tier: .heuristic, source: "screen", hint: hint, event: .observedState(rule.state), isHeuristic: true)])
    }

    public func attentionContextChanged(_ context: AttentionContext) async {
        attention = context
        appActive = context.appIsActive
        if let focused = context.focusedSurface, context.isWatching(focused) {
            clearUnread(surface: focused)
            for (id, entry) in held where entry.request.surface == focused { releaseHeld(id, decision: .passthrough) }
        }
        markDirty()
    }

    public func markRead(surface: SurfaceID) async {
        clearUnread(surface: surface)
        markDirty()
    }

    func clearUnread(surface: SurfaceID) {
        for record in store.records.values where record.session.surface == surface && record.session.unread {
            store.update(record.key) { $0.session.unread = false }
        }
    }

    // MARK: Process scanning

    func scanLoop() async {
        while running, !Task.isCancelled {
            let (interval, systemInterval) = scanIntervals
            try? await Task.sleep(for: .seconds(interval))
            guard running, !Task.isCancelled else { return }
            if Date().timeIntervalSince(lastFullScan) >= systemInterval - 0.05 {
                await performScan(.system)
            } else {
                await performScan(.descendants(of: configuration.appProcessID))
            }
        }
    }

    /// (sleep before the next scan, system-scan interval). Hidden app: no per-second pane scans
    /// (nobody can type into a hidden pane) and half-rate system scans; exits stay event-driven.
    var scanIntervals: (next: TimeInterval, system: TimeInterval) {
        let system = appActive ? configuration.systemScanInterval : configuration.systemScanInterval * 2
        return (surfaces.isEmpty || !appActive ? system : configuration.surfaceScanInterval, system)
    }

    /// The app became frontmost (true) or went to the background (false). Scans and the safety
    /// poll slow down while hidden; also follows `AttentionContext.appIsActive`.
    public func setAppActive(_ active: Bool) {
        appActive = active
    }

    func requestSurfaceScan() {
        guard running, configuration.processScanning, Date().timeIntervalSince(lastSurfaceScan) > 0.25 else { return }
        lastSurfaceScan = Date()
        let pid = configuration.appProcessID
        tasks.append(Task { [weak self] in await self?.performScan(.descendants(of: pid), force: true) })
        tasks.removeAll { $0.isCancelled }
    }

    /// Run a scan now (used by `mship-probe`).
    public func scanNow(systemWide: Bool = true) async {
        await performScan(systemWide ? .system : .descendants(of: configuration.appProcessID))
    }

    /// `deferTranscripts`: load newly bound transcripts in the background (used by `start()`
    /// so the first scan isn't held up by reading history).
    /// `force`: scan the app's tree even if its pids and names look unchanged.
    func performScan(_ scope: ScanScope, deferTranscripts: Bool = false, force: Bool = false) async {
        // The per-second pane scan only matters when the app's process tree changed.
        // Pane agents judged by CPU (manifest adapters) still need their per-second sample.
        if case .descendants(let pid) = scope, configuration.processProvider == nil, !force, !paneAgentsNeedCPUSamples(),
            !(await scanner.descendantsChanged(of: pid))
        {
            metrics.skippedSurfaceScans += 1
            return
        }
        let result: ScanResult
        if let provider = configuration.processProvider {
            let roots = provider(scope)
            let pids = Set(roots.map(\.pid))
            result = ScanResult(
                scope: scope, roots: roots, alive: pids.union(store.pidIndex.keys.filter { kill($0, 0) == 0 || errno == EPERM }),
                scopePIDs: pids, processCount: roots.count, candidateCount: roots.count, argvReads: 0, duration: .zero, capturedAt: Date()
            )
        } else {
            result = await scanner.scan(scope: scope)
        }
        metrics.record(result)
        if scope == .system { lastFullScan = Date() } else { lastSurfaceScan = Date() }
        let now = Date()
        for root in result.roots { applyRoot(root, now: now) }
        // Exits kqueue might have missed (e.g. processes that died before we watched them).
        let gone = store.pidIndex.filter { !result.alive.contains($0.key) }
        for (pid, key) in gone {
            apply([AgentSignal(tier: .process, source: "process:gone", hint: SessionHint(kind: key.kind, pid: pid), event: .processExited, timestamp: now)])
        }
        if scope == .system {
            housekeeping(now: now)
            await evictIdleTranscripts()
            // Dated directories (Codex's YYYY/MM/DD) move at midnight.
            if vnodeWatcher != nil {
                let paths = await ingestor.staticWatchPaths()
                if paths != staticWatchPaths {
                    staticWatchPaths = paths
                    watchGeneration = -1
                }
            }
        }
        refreshWatches()
        var paths: [String] = []
        for root in result.roots {
            if let key = store.key(forPID: root.pid), let path = store[key]?.session.transcriptPath { paths.append(path) }
        }
        let pending = paths.filter { !trackedTranscripts.contains($0) }
        guard !pending.isEmpty else { return }
        if deferTranscripts {
            // Newest 256 KB of each transcript now (current state, latest facts), full history later.
            for path in pending { apply(Self.peekSignals(await ingestor.peek(path: path)), live: false) }
            let clock = ContinuousClock()
            let started = clock.now
            tasks.append(Task { [weak self] in
                for path in pending { await self?.trackTranscript(path) }
                await self?.noteHistoryLoaded(clock.now - started)
            })
        } else {
            for path in pending { await trackTranscript(path) }
        }
    }

    func paneAgentsNeedCPUSamples() -> Bool {
        if let cached = paneCPUSamples, cached.generation == recordsGeneration { return cached.needed }
        let needed = store.records.values.contains { record in
            record.session.surface != nil && record.session.pid != nil && record.session.state != .ended
                && adaptersByKind[record.key.kind]?.usesCPUHeuristic == true
        }
        paneCPUSamples = (recordsGeneration, needed)
        return needed
    }

    func applyRoot(_ root: RootProcess, now: Date) {
        let hint = SessionHint(
            kind: root.kind, sessionID: root.binding?.sessionID, pid: root.pid, surface: root.surface, cwd: root.process.cwd,
            transcriptPath: root.binding?.transcriptPath
        )
        var signals = [AgentSignal(tier: .process, source: "process", hint: hint, event: .processSeen, timestamp: now)]
        for var signal in root.binding?.signals ?? [] {
            signal.hint.pid = root.pid
            signal.hint.surface = signal.hint.surface ?? root.surface
            signals.append(signal)
        }
        if let fraction = root.cpuFraction, adaptersByKind[root.kind]?.usesCPUHeuristic == true {
            let key = store.key(forPID: root.pid)
            let hooksQuiet = key.flatMap { store[$0]?.lastHookAt }.map { now.timeIntervalSince($0) > 120 } ?? true
            if hooksQuiet {
                let state: AgentState = fraction > 0.05 ? .working(tool: nil) : .idle
                signals.append(AgentSignal(tier: .heuristic, source: "cpu", hint: hint, event: .observedState(state), timestamp: now, isHeuristic: true))
            }
        }
        apply(signals)
        applyRootFacts(root)
    }

    /// Test seam: what a scan would do on finding this root process.
    func applyRootForTesting(kind: AgentKind, pid: Int32, surface: SurfaceID?, cwd: String) {
        let snapshot = ProcessSnapshot(pid: pid, ppid: 1, comm: kind.rawValue)
        let process = ObservedProcess(snapshot: snapshot, arguments: ProcessArguments(executablePath: "/x/\(kind.rawValue)", arguments: [kind.rawValue]), cwd: cwd)
        applyRoot(RootProcess(kind: kind, process: process, surface: surface), now: Date())
    }

    /// Host app, git and exit watching for a known root.
    func applyRootFacts(_ root: RootProcess) {
        guard let key = store.key(forPID: root.pid) else { return }
        let before = store[key]
        store.update(key) { record in
            if root.surface == nil, record.session.surface == nil, let host = root.hostApp { record.session.hostApp = host }
            if let git = root.git {
                record.session.repoRoot = git.repoRoot
                if let branch = git.branch { record.session.branch = branch }
            }
            if record.session.cwd.isEmpty, let cwd = root.process.cwd { record.session.cwd = cwd }
        }
        if store[key] != before { markDirty() }
        if !exitWatcher.watchedPIDs.contains(root.pid) { exitWatcher.watch(root.pid) }
    }

    func processExited(_ pid: Int32) {
        guard let key = store.key(forPID: pid) else { return }
        apply([AgentSignal(tier: .process, source: "kqueue", hint: SessionHint(kind: key.kind, pid: pid), event: .processExited)])
    }

    func housekeeping(now: Date) {
        for record in store.records.values where record.session.pid == nil && record.session.state != .ended {
            let quiet = now.timeIntervalSince(record.session.lastActivity)
            let hint = SessionHint(kind: record.key.kind, sessionID: record.key.sessionID)
            if quiet > configuration.transcriptOnlyIdleTimeout {
                apply([AgentSignal(tier: .process, source: "inactive", hint: hint, event: .sessionEnded(reason: "inactive"), timestamp: now)], live: false)
            } else if quiet > 300, record.session.state.isBusy, (record.lastHookAt.map { now.timeIntervalSince($0) > 300 } ?? true) {
                // Without a live process or recent hooks, an unfinished transcript isn't a running turn.
                apply([AgentSignal(tier: .process, source: "no-process", hint: hint, event: .observedState(.idle), timestamp: now)], live: false)
            }
        }
        if !store.prune(now: now, retention: configuration.endedSessionRetention).isEmpty { markDirty() }
        summaryCache = summaryCache.filter { store[$0.key] != nil }
    }

    func noteHistoryLoaded(_ duration: Duration) {
        if metrics.initialHistoryLoad == nil { metrics.initialHistoryLoad = duration }
        engineLog.notice("Initial transcript history loaded in \(duration.components.seconds, privacy: .public)s")
    }

    /// A peek sees only the newest prompts; they must not stand in for the session's first
    /// prompt (the title) until the full history has been read.
    static func peekSignals(_ signals: [AgentSignal]) -> [AgentSignal] {
        signals.flatMap { signal -> [AgentSignal] in
            guard case .promptSubmitted(let prompt) = signal.event else { return [signal] }
            var state = signal
            state.event = .observedState(.working(tool: nil))
            guard let prompt else { return [state] }
            var fact = signal
            fact.event = .metadata(SessionMetadata(lastUserPrompt: prompt))
            return [fact, state]
        }
    }

    /// Forget tails of transcripts no live session uses, so memory stays flat over days.
    func evictIdleTranscripts() async {
        let live = Set(store.records.values.filter { $0.session.state.isLive }.compactMap(\.session.transcriptPath))
        let evicted = await ingestor.evict(olderThan: 2 * 3600, keeping: live)
        trackedTranscripts.subtract(evicted)
    }

    // MARK: Transcripts

    func startTranscriptWatching() async {
        let roots = await ingestor.watchRoots()
        let watcher = FileSystemWatcher(paths: roots, latency: 0.3)
        if watcher.start() {
            engineLog.notice("FSEvents watcher started for \(watcher.paths.count, privacy: .public) of \(roots.count, privacy: .public) transcript roots")
            fileWatcher = watcher
            let changes = watcher.changes
            tasks.append(Task { [weak self] in
                for await batch in changes { await self?.ingest(batch) }
            })
        }
        if configuration.vnodeWatching {
            let watcher = VnodeWatcher()
            vnodeWatcher = watcher
            let changes = watcher.changes
            tasks.append(Task { [weak self] in
                for await batch in changes { await self?.ingestWatched(batch) }
            })
            staticWatchPaths = await ingestor.staticWatchPaths()
        }
        if fileWatcher == nil {
            // FSEvents can be unavailable (it is on macOS 27 for ad-hoc signed apps): kqueue
            // watches live transcripts; a stat poll is the safety net (slower while kqueue works).
            transcriptPolling = true
            engineLog.error("FSEvents watcher could not start; kqueue \(self.vnodeWatcher?.isHealthy == true ? "active" : "unavailable", privacy: .public), polling as a safety net")
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    let interval = await self?.pollInterval ?? 5
                    try? await Task.sleep(for: .seconds(interval))
                    await self?.pollTranscripts()
                }
            })
        }
        apply(await ingestor.pollOpenCode(), live: false)
        for path in await ingestor.eagerFiles() { await trackTranscript(path) }
        refreshWatches()
    }

    /// 1 s without kqueue, `safetyPollInterval` (5 s) while kqueue watches are healthy, three
    /// times that while the app is hidden.
    var pollInterval: TimeInterval {
        guard vnodeWatcher?.isHealthy == true else { return configuration.transcriptPollInterval }
        return appActive ? configuration.safetyPollInterval : configuration.safetyPollInterval * 3
    }

    /// Keep kqueue watches on exactly what matters now: live sessions' transcripts and their
    /// directories (new files after `/clear`), per-session state files, and static paths.
    func refreshWatches(force: Bool = false) {
        guard let watcher = vnodeWatcher else { return }
        let now = Date()
        // Nothing published since the last refresh, no watch dropped by an event, no audit due.
        if !force, watchGeneration == recordsGeneration, watcher.watchedCount == lastWatchedCount,
            missingWatchTargets.isEmpty || now < nextWatchAudit
        {
            return
        }
        watchGeneration = recordsGeneration
        var desired = Set(staticWatchPaths)
        for record in store.records.values where record.session.state.isLive {
            if let path = record.session.transcriptPath {
                desired.insert(path)
                desired.insert((path as NSString).deletingLastPathComponent)
            }
            if let adapter = adaptersByKind[record.key.kind] {
                desired.formUnion(adapter.statePaths(for: record.session, home: configuration.homeDirectory))
            }
        }
        // Same targets and nothing dropped by an event: skip the filesystem checks (they're the
        // cost here), except for a periodic audit of targets that didn't exist yet.
        if !force, desired == lastDesiredWatches, watcher.watchedCount == lastWatchedCount,
            missingWatchTargets.isEmpty || now < nextWatchAudit
        {
            return
        }
        lastDesiredWatches = desired
        nextWatchAudit = now.addingTimeInterval(15)
        // A path that doesn't exist yet is covered by its nearest existing parent (at most two
        // levels up, never the home directory itself) so its creation is noticed.
        let home = configuration.homeDirectory.standardizedFileURL.path
        var resolved = Set<String>()
        var appeared: [String] = []
        for path in desired {
            if FileManager.default.fileExists(atPath: path) {
                resolved.insert(path)
                if missingWatchTargets.remove(path) != nil { appeared.append(path) }
                continue
            }
            missingWatchTargets.insert(path)
            var parent = (path as NSString).deletingLastPathComponent
            for _ in 0..<2 where parent != home && parent.hasPrefix(home + "/") {
                if FileManager.default.fileExists(atPath: parent) {
                    resolved.insert(parent)
                    break
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let current = watcher.watchedPaths
        for path in current.subtracting(resolved) {
            watcher.unwatch(path)
            directoryStamps[path] = nil
        }
        for path in resolved.subtracting(current) where watcher.watch(path) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, directoryStamps[path] == nil {
                directoryStamps[path] = now
            }
        }
        metrics.watchedPaths = watcher.watchedCount
        lastWatchedCount = metrics.watchedPaths
        // Directories that appeared after start may already hold new files: list them now.
        let newDirectories = appeared.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if !newDirectories.isEmpty {
            for path in newDirectories { directoryStamps[path] = startedAt }
            let changes = newDirectories.map { FileChange(path: $0, flags: UInt32(kFSEventStreamEventFlagItemIsDir)) }
            tasks.append(Task { [weak self] in await self?.ingestWatched(changes) })
        }
    }

    /// kqueue events: file writes are tailed; directory writes are listed for new/changed files.
    func ingestWatched(_ batch: [FileChange]) async {
        guard running else { return }
        metrics.watchBatches += 1
        let now = Date()
        var changes = batch.filter { !$0.isDirectory }
        for change in batch where change.isDirectory {
            let since = (directoryStamps[change.path] ?? now).addingTimeInterval(-2)
            directoryStamps[change.path] = now
            changes += await ingestor.changedFiles(inDirectory: change.path, since: since)
        }
        let signals = await ingestor.handle(changes)
        apply(signals)
        await trackTranscripts(in: signals)
        // A deleted/renamed file was unwatched by the watcher: re-check the targets.
        refreshWatches(force: batch.contains { $0.isRemoved || $0.isRenamed || $0.isDirectory })
    }

    func pollTranscripts() async {
        guard running else { return }
        let signals = await ingestor.pollForChanges()
        if !signals.isEmpty { metrics.transcriptBatches += 1 }
        apply(signals)
        await trackTranscripts(in: signals)
        refreshWatches()
    }

    /// True when FSEvents couldn't start and transcripts are polled instead.
    public private(set) var transcriptPolling = false

    func ingest(_ batch: [FileChange]) async {
        metrics.transcriptBatches += 1
        let signals = await ingestor.handle(batch)
        apply(signals)
        await trackTranscripts(in: signals)
    }

    func trackTranscripts(in signals: [AgentSignal]) async {
        let paths = Set(signals.compactMap(\.hint.transcriptPath))
        for path in paths { await trackTranscript(path) }
    }

    func trackTranscript(_ path: String) async {
        guard configuration.transcriptWatching, trackedTranscripts.insert(path).inserted else { return }
        apply(await ingestor.track(path: path), live: false)
        refreshWatches()
    }

    // MARK: Integrations

    func integrationContext(version: String?) -> IntegrationContext {
        IntegrationContext(
            home: configuration.homeDirectory, shimPath: configuration.cliShimPath, backupsDirectory: configuration.backupsDirectory,
            stateDirectory: configuration.supportDirectory, agentVersion: version
        )
    }

    var nativeAdapters: [any AgentAdapter] {
        adapters.filter { [.claude, .codex, .opencode, .gemini].contains($0.kind) }
    }

    public func integrationStatuses() async -> [IntegrationStatus] {
        let adapters = nativeAdapters
        let locator = locator
        let base = integrationContext(version: nil)
        let statuses = await Task.detached(priority: .utility) {
            adapters.map { adapter -> IntegrationStatus in
                let executable = locator.locate(adapter.executableNames)
                let version = executable.flatMap(locator.version(of:))
                guard let installer = adapter.integration() else {
                    return IntegrationStatus(
                        kind: adapter.kind, executablePath: executable, version: version, installed: false,
                        detail: "No integration available", unsupportedReason: "No integration available yet"
                    )
                }
                var context = base
                context.agentVersion = version
                let inspection = installer.inspect(context)
                var detail = inspection.summary
                if executable == nil { detail = "\(adapter.displayName) not found · " + detail }
                var unsupportedReason: String?
                if case .unsupported(let reason) = inspection.health { unsupportedReason = reason }
                return IntegrationStatus(
                    kind: adapter.kind, executablePath: executable, version: version, installed: inspection.isInstalled,
                    detail: detail, unsupportedReason: unsupportedReason
                )
            }
        }.value
        integrations = statuses
        return statuses
    }

    public func installIntegration(_ kind: AgentKind) async throws {
        try await runInstaller(kind, install: true)
    }

    public func uninstallIntegration(_ kind: AgentKind) async throws {
        try await runInstaller(kind, install: false)
    }

    /// The new config contents an install would write, for a consent diff (nil = no change).
    public func plannedIntegrationContents(_ kind: AgentKind) async throws -> String? {
        guard let adapter = adaptersByKind[kind], let installer = adapter.integration() else { throw IntegrationError.unknownAgent(kind.rawValue) }
        let version = locator.locate(adapter.executableNames).flatMap(locator.version(of:))
        let context = integrationContext(version: version)
        return try await Task.detached { try installer.plannedContents(context) }.value
    }

    func runInstaller(_ kind: AgentKind, install: Bool) async throws {
        guard let adapter = adaptersByKind[kind], let installer = adapter.integration() else { throw IntegrationError.unknownAgent(kind.rawValue) }
        let locator = locator
        let names = adapter.executableNames
        var context = integrationContext(version: nil)
        context.now = Date()
        try await Task.detached(priority: .userInitiated) {
            var context = context
            context.agentVersion = locator.locate(names).flatMap(locator.version(of:))
            if install { try installer.install(context) } else { try installer.uninstall(context) }
        }.value
        let statuses = await integrationStatuses()
        integrationFingerprint = fingerprint()
        broadcast(.integrations(statuses))
    }

    func fingerprint() -> String {
        nativeAdapters.compactMap { adapter -> String? in
            guard let path = adapter.integration()?.configURL(home: configuration.homeDirectory).path else { return nil }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path)#\(modified)"
        }.joined(separator: "|")
    }

    /// Self-heal check (§5.5): re-inspect when a config file changes on disk.
    func integrationLoop() async {
        while running, !Task.isCancelled {
            let current = fingerprint()
            if current != integrationFingerprint {
                integrationFingerprint = current
                let statuses = await integrationStatuses()
                broadcast(.integrations(statuses))
            }
            try? await Task.sleep(for: .seconds(configuration.integrationCheckInterval))
        }
    }

    // MARK: Commands

    public func resumeCommand(for session: AgentSessionKey) async -> String? {
        guard !session.isProvisional, let adapter = adaptersByKind[session.kind] else { return nil }
        let cwd = store[session]?.session.cwd ?? ""
        return adapter.resumeCommand(session: session.sessionID, cwd: cwd).map(ShellQuoting.join)
    }

    public func launchCommand(_ kind: AgentKind, prompt: String?) async -> String {
        guard let adapter = adaptersByKind[kind] else {
            return ShellQuoting.join([kind.rawValue] + (prompt.map { [$0] } ?? []))
        }
        return ShellQuoting.join(adapter.launchCommand(prompt: prompt, cwd: ""))
    }
}
