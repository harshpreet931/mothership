import Foundation
import ShipModel

/// An `AgentSession` plus the bookkeeping the reducer needs (leases, heuristic samples).
public struct SessionRecord: Sendable, Equatable {
    public var session: AgentSession
    /// Until when the last Tier-0 state is protected from lower tiers.
    public var leaseUntil: Date?
    /// Timestamp of the evidence behind the current state.
    public var lastStateChange: Date
    public var stateTier: SignalTier?
    /// A heuristic state seen once, waiting for a second agreeing sample.
    public var pendingSample: PendingSample?
    /// A newer lower-tier state that arrived inside a lease; applied by `tick` once the lease ends.
    public var deferred: DeferredState?
    /// The current tool and its target, e.g. "Bash: npm test".
    public var currentActivity: String?
    public var firstPrompt: String?
    /// True when the title came from the agent (custom/AI title) rather than the first prompt.
    public var hasExplicitTitle: Bool
    /// False once the agent reported a real cost.
    public var costIsEstimate: Bool
    /// When the last hook (Tier-0) signal arrived; sessions with live hooks ignore CPU guesses.
    public var lastHookAt: Date?
    public var hostAppHint: String?

    public struct PendingSample: Sendable, Equatable {
        public var state: AgentState
        public var count: Int
    }

    public struct DeferredState: Sendable, Equatable {
        public var state: AgentState
        public var tier: SignalTier
        public var timestamp: Date
    }

    public init(session: AgentSession, lastStateChange: Date? = nil) {
        self.session = session
        self.lastStateChange = lastStateChange ?? session.startedAt
        self.hasExplicitTitle = false
        self.costIsEstimate = true
    }

    public var key: AgentSessionKey { session.id }
}

/// Pure, deterministic state reducer (ARCHITECTURE §5.3). No I/O, so traces replay exactly.
public enum AgentReducer {
    public static let defaultLease: TimeInterval = 10

    /// Apply one signal. `watched` is whether the user is looking at the session's surface
    /// right now; it decides `unread`.
    public static func reduce(_ record: SessionRecord, _ signal: AgentSignal, now: Date, watched: Bool, lease: TimeInterval = defaultLease) -> SessionRecord {
        var next = record
        applyFacts(&next, signal)
        guard let desired = desiredState(for: signal.event, record: next) else {
            if signal.tier == .hook, isStateBearing(signal.event), next.session.state != .ended {
                next.leaseUntil = now.addingTimeInterval(lease)
            }
            return next
        }
        let current = next.session.state

        // Exit and SessionEnd always win.
        if desired == .ended {
            if current != .ended { transition(&next, to: .ended, signal: signal, now: now, watched: watched, lease: lease) }
            next.pendingPermissionCleared()
            return next
        }
        // An ended session only comes back through a hook (e.g. SessionStart on resume).
        if current == .ended {
            guard signal.tier == .hook, case .sessionStarted = signal.event else { return next }
            transition(&next, to: desired, signal: signal, now: now, watched: watched, lease: lease)
            return next
        }
        if signal.tier > .hook {
            // Evidence older than what produced the current state is stale.
            if signal.timestamp < next.lastStateChange { return next }
            // A held permission is resolved only by hooks or the user.
            if next.session.pendingPermission != nil { return next }
            if let leaseUntil = next.leaseUntil, now < leaseUntil {
                if desired != current {
                    next.deferred = .init(state: desired, tier: signal.tier, timestamp: signal.timestamp)
                }
                return next
            }
            if signal.isHeuristic {
                if desired == current {
                    next.pendingSample = nil
                    return next
                }
                if let pending = next.pendingSample, pending.state == desired {
                    next.pendingSample = .init(state: desired, count: pending.count + 1)
                } else {
                    next.pendingSample = .init(state: desired, count: 1)
                }
                guard let pending = next.pendingSample, pending.count >= 2 else { return next }
            }
        }
        if desired == current {
            if signal.tier == .hook { next.leaseUntil = now.addingTimeInterval(lease) }
            if signal.tier <= (next.stateTier ?? .heuristic) { next.lastStateChange = max(next.lastStateChange, signal.timestamp) }
            return next
        }
        transition(&next, to: desired, signal: signal, now: now, watched: watched, lease: lease)
        return next
    }

    /// Time passing: apply a deferred lower-tier state once the lease is over, if it is still
    /// newer than the evidence behind the current state.
    public static func tick(_ record: SessionRecord, now: Date, watched: Bool) -> SessionRecord {
        guard let deferred = record.deferred else { return record }
        var next = record
        if let leaseUntil = next.leaseUntil, now < leaseUntil { return next }
        next.deferred = nil
        guard deferred.timestamp >= next.lastStateChange, next.session.state != .ended,
            next.session.pendingPermission == nil, deferred.state != next.session.state
        else { return next }
        let previous = next.session.state
        next.session.state = deferred.state
        next.stateTier = deferred.tier
        next.lastStateChange = deferred.timestamp
        next.pendingSample = nil
        updateUnread(&next, from: previous, watched: watched)
        updateActivity(&next)
        return next
    }

    // MARK: - State mapping

    static func isStateBearing(_ event: SignalEvent) -> Bool {
        switch event {
        case .metadata, .usage, .activity, .subagentStarted, .subagentStopped, .processSeen: false
        default: true
        }
    }

    /// The state an event asks for, or nil when it doesn't move the state machine.
    static func desiredState(for event: SignalEvent, record: SessionRecord) -> AgentState? {
        let current = record.session.state
        switch event {
        case .sessionStarted(let source):
            if source == "compact" { return current == .ended ? .idle : nil }
            if case .working = current, source == nil { return nil }
            return .idle
        case .promptSubmitted:
            return .working(tool: nil)
        case .toolStarted(let tool, _):
            return .working(tool: tool)
        case .toolFinished:
            switch current {
            case .working, .needsInput(.permission): return .working(tool: nil)
            default: return nil
            }
        case .permissionRequested:
            return .needsInput(.permission)
        case .permissionCleared:
            if case .needsInput = current { return .working(tool: nil) }
            return nil
        case .inputRequested(let reason, _):
            return .needsInput(reason)
        case .turnCompleted, .turnInterrupted:
            return .idle
        case .failed(let message):
            return .error(message)
        case .sessionEnded, .processExited:
            return .ended
        case .processSeen:
            return current == .starting ? .idle : nil
        case .compacting:
            return .working(tool: "Compacting")
        case .observedState(let state):
            return state
        case .metadata, .usage, .activity, .subagentStarted, .subagentStopped:
            return nil
        }
    }

    static func transition(_ record: inout SessionRecord, to state: AgentState, signal: AgentSignal, now: Date, watched: Bool, lease: TimeInterval) {
        let previous = record.session.state
        record.session.state = state
        record.stateTier = signal.tier
        record.lastStateChange = max(signal.timestamp, signal.tier == .hook ? signal.timestamp : record.lastStateChange)
        record.pendingSample = nil
        if signal.tier == .hook {
            record.leaseUntil = state == .ended ? nil : now.addingTimeInterval(lease)
            record.deferred = nil
        } else if let deferred = record.deferred, deferred.timestamp <= signal.timestamp {
            record.deferred = nil
        }
        if state != .needsInput(.permission) { record.session.pendingPermission = nil }
        if state == .ended { record.session.activeSubagents = 0 }
        updateUnread(&record, from: previous, watched: watched)
        updateActivity(&record)
    }

    /// `unread`: the agent finished, failed or needs input while nobody was looking (§5.2).
    static func updateUnread(_ record: inout SessionRecord, from previous: AgentState, watched: Bool) {
        guard !watched else { return }
        switch record.session.state {
        case .needsInput, .error:
            record.session.unread = true
        case .idle:
            switch previous {
            case .working, .needsInput: record.session.unread = true
            default: break
            }
        default:
            break
        }
    }

    static func updateActivity(_ record: inout SessionRecord) {
        switch record.session.state {
        case .working(let tool?):
            if record.currentActivity == nil || record.currentActivity?.hasPrefix(tool) == false {
                record.currentActivity = tool
            }
        case .working(nil), .needsInput:
            break
        default:
            record.currentActivity = nil
        }
    }

    // MARK: - Facts (applied regardless of tier or lease)

    static func applyFacts(_ record: inout SessionRecord, _ signal: AgentSignal) {
        var session = record.session
        if signal.tier == .hook { record.lastHookAt = max(record.lastHookAt ?? signal.timestamp, signal.timestamp) }
        switch signal.event {
        case .processSeen:
            break
        default:
            if signal.timestamp > session.lastActivity { session.lastActivity = signal.timestamp }
        }
        if session.pid == nil, let pid = signal.hint.pid { session.pid = pid }
        if session.surface == nil, let surface = signal.hint.surface { session.surface = surface }
        if session.cwd.isEmpty, let cwd = signal.hint.cwd { session.cwd = cwd }
        if session.transcriptPath == nil, let path = signal.hint.transcriptPath { session.transcriptPath = path }

        switch signal.event {
        case .promptSubmitted(let prompt?):
            let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                session.lastUserPrompt = cleaned
                if record.firstPrompt == nil { record.firstPrompt = cleaned }
                if session.title == nil { session.title = TextSummary.title(fromPrompt: cleaned) }
            }
        case .toolStarted(let tool, let summary):
            record.currentActivity = summary.map { "\(tool): \($0)" } ?? tool
        case .permissionRequested(let tool, let summary, _):
            record.currentActivity = summary.isEmpty ? tool : "\(tool): \(summary)"
        case .turnCompleted(let message?):
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { session.lastAssistantMessage = cleaned }
        case .subagentStarted:
            session.activeSubagents += 1
        case .subagentStopped:
            session.activeSubagents = max(0, session.activeSubagents - 1)
        case .turnInterrupted:
            session.activeSubagents = 0
        case .metadata(let metadata):
            apply(metadata, to: &session, record: &record)
        case .usage(let usage, let mode):
            var total = session.usage
            switch mode {
            case .add:
                total.inputTokens += usage.inputTokens
                total.outputTokens += usage.outputTokens
                total.cacheReadTokens += usage.cacheReadTokens
                total.cacheWriteTokens += usage.cacheWriteTokens
            case .replace:
                total.inputTokens = usage.inputTokens
                total.outputTokens = usage.outputTokens
                total.cacheReadTokens = usage.cacheReadTokens
                total.cacheWriteTokens = usage.cacheWriteTokens
            }
            if let context = usage.contextTokens { total.contextTokens = context }
            if let window = usage.contextWindow { total.contextWindow = window }
            if let cost = usage.costUSD {
                total.costUSD = cost
                record.costIsEstimate = false
            }
            session.usage = total
        default:
            break
        }
        record.session = session
    }

    static func apply(_ metadata: SessionMetadata, to session: inout AgentSession, record: inout SessionRecord) {
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            session.title = title
            record.hasExplicitTitle = true
        }
        if let model = metadata.model, !model.isEmpty { session.model = model }
        if let cwd = metadata.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let branch = metadata.branch, !branch.isEmpty { session.branch = branch }
        if let path = metadata.transcriptPath, !path.isEmpty { session.transcriptPath = path }
        if let prompt = metadata.lastUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            session.lastUserPrompt = prompt
            if record.firstPrompt == nil { record.firstPrompt = prompt }
            if session.title == nil { session.title = TextSummary.title(fromPrompt: prompt) }
        }
        if let message = metadata.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            session.lastAssistantMessage = message
        }
        if let context = metadata.contextTokens { session.usage.contextTokens = context }
        if let window = metadata.contextWindow { session.usage.contextWindow = window }
        if let cost = metadata.reportedCostUSD {
            session.usage.costUSD = cost
            record.costIsEstimate = false
        }
        if let host = metadata.hostApp, session.hostApp == nil { record.hostAppHint = host }
        if let started = metadata.startedAt, started < session.startedAt { session.startedAt = started }
    }
}

extension SessionRecord {
    mutating func pendingPermissionCleared() {
        session.pendingPermission = nil
    }
}
