import Foundation
import ShipModel

/// An `AgentSession` plus the bookkeeping the reducer needs (leases, heuristic samples,
/// evidence and fact timestamps).
public struct SessionRecord: Sendable, Equatable {
    public var session: AgentSession
    /// Until when the last Tier-0 state is protected from lower tiers.
    public var leaseUntil: Date?
    /// Timestamp of the evidence behind the current state (`.distantPast` = none yet).
    public var lastStateChange: Date
    public var stateTier: SignalTier?
    /// A heuristic state seen once, waiting for a second agreeing sample.
    public var pendingSample: PendingSample?
    /// A newer lower-tier state that arrived inside a lease; applied by `tick` once the lease ends.
    public var deferred: DeferredState?
    /// The tool of the latest tool call and its target ("Bash", "npm test").
    public var currentTool: String?
    public var currentTarget: String?
    /// The earliest user prompt seen (title fallback).
    public var firstPrompt: String?
    public var firstPromptAt: Date?
    /// The earliest prompt with the user's own words (not only pasted text): the preferred
    /// title source when the agent has no title of its own.
    public var titlePrompt: String?
    public var titlePromptAt: Date?
    /// The agent's own title (AI title, thread name, DB title) or the user's rename.
    public var nativeTitle: String?
    /// 0 none, 2 agent-generated, 3 user-set. Higher wins; newest wins within a rank.
    public var nativeTitleRank: Int
    public var nativeTitleAt: Date?
    /// True when the title came from the agent or user rather than the first prompt.
    public var hasExplicitTitle: Bool
    /// False once the agent reported a real cost.
    public var costIsEstimate: Bool
    /// When the last hook (Tier-0) signal arrived; sessions with live hooks ignore CPU guesses.
    public var lastHookAt: Date?
    public var hostAppHint: String?
    /// Timestamps of the evidence behind "latest" facts, so replaying older history (or reading
    /// a transcript out of order) never overwrites newer facts.
    public var promptAt: Date?
    public var assistantAt: Date?
    public var modelAt: Date?
    public var contextAt: Date?
    public var usageAt: Date?
    /// How the session opened (the earliest prompts and replies), for generated titles.
    public var openingPrompts: [OpeningText] = []
    public var openingReplies: [OpeningText] = []
    /// A title from the on-device model, and the digest fingerprint it was made from.
    public var generatedTitle: String?
    public var generatedTitleFingerprint: String?
    /// A one-line summary of `lastAssistantMessage`, and that reply's fingerprint.
    public var generatedSummary: String?
    public var generatedSummaryFingerprint: String?

    public struct OpeningText: Sendable, Equatable {
        public var text: String
        public var at: Date
    }

    public static let openingPromptLimit = 3
    public static let openingReplyLimit = 2

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
        self.lastStateChange = lastStateChange ?? .distantPast
        self.nativeTitleRank = 0
        self.hasExplicitTitle = false
        self.costIsEstimate = true
    }

    public var key: AgentSessionKey { session.id }

    /// "Bash: npm test".
    public var currentActivity: String? {
        guard let currentTool else { return nil }
        guard let currentTarget, !currentTarget.isEmpty else { return currentTool }
        return "\(currentTool): \(currentTarget)"
    }
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
            next.session.pendingPermission = nil
            return next
        }
        // An ended session only comes back through a hook (e.g. SessionStart on resume).
        if current == .ended {
            guard signal.tier == .hook, case .sessionStarted = signal.event else { return next }
            transition(&next, to: desired, signal: signal, now: now, watched: watched, lease: lease)
            return next
        }
        if signal.tier > .hook {
            // Evidence older than what produced the current state is stale — unless it comes
            // from a better tier (a transcript beats "the process exists", whatever the clock says).
            if signal.timestamp < next.lastStateChange, signal.tier >= (next.stateTier ?? .heuristic) { return next }
            // A held permission is resolved only by hooks or the user.
            if next.session.pendingPermission != nil { return next }
            if let leaseUntil = next.leaseUntil, now < leaseUntil {
                // Event-driven sources (transcripts, status files) won't repeat themselves, so a
                // newer one is kept for when the lease ends. Heuristics re-sample; drop them.
                if signal.isHeuristic {
                    next.pendingSample = nil
                } else if desired != current {
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
            if signal.tier < (next.stateTier ?? .heuristic) {
                // Better evidence for the same state replaces the weaker one (and its clock).
                next.lastStateChange = signal.timestamp
                next.stateTier = signal.tier
            } else if signal.tier == next.stateTier {
                next.lastStateChange = max(next.lastStateChange, signal.timestamp)
            }
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
        if signal.tier == .hook || signal.tier < (record.stateTier ?? .heuristic) {
            record.lastStateChange = signal.timestamp
        } else {
            record.lastStateChange = max(record.lastStateChange, signal.timestamp)
        }
        record.stateTier = signal.tier
        record.pendingSample = nil
        if signal.tier == .hook {
            record.leaseUntil = state == .ended ? nil : now.addingTimeInterval(lease)
            record.deferred = nil
        } else if let deferred = record.deferred, deferred.timestamp <= signal.timestamp {
            record.deferred = nil
        }
        if state != .needsInput(.permission) { record.session.pendingPermission = nil }
        if state == .ended { record.session.activeSubagents = 0 }
        if case .working(let tool?) = state, tool != record.currentTool {
            record.currentTool = tool
            record.currentTarget = nil
        }
        updateUnread(&record, from: previous, watched: watched)
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

    // MARK: - Facts (applied regardless of tier or lease, newest evidence wins)

    /// True when `date` is at least as new as `current` (records the new time).
    static func isNewer(_ date: Date, than current: inout Date?) -> Bool {
        if let existing = current, date < existing { return false }
        current = date
        return true
    }

    static func applyFacts(_ record: inout SessionRecord, _ signal: AgentSignal) {
        var session = record.session
        let titleInputs = (record.firstPrompt, record.titlePrompt, record.nativeTitle, session.cwd.isEmpty)
        let time = signal.timestamp
        if signal.tier == .hook { record.lastHookAt = max(record.lastHookAt ?? time, time) }
        switch signal.event {
        case .processSeen:
            break
        default:
            if time > session.lastActivity { session.lastActivity = time }
        }
        if session.pid == nil, let pid = signal.hint.pid { session.pid = pid }
        if session.surface == nil, let surface = signal.hint.surface { session.surface = surface }
        if session.cwd.isEmpty, let cwd = signal.hint.cwd { session.cwd = cwd }
        if session.transcriptPath == nil, let path = signal.hint.transcriptPath { session.transcriptPath = path }

        switch signal.event {
        case .promptSubmitted(let prompt?):
            notePrompt(prompt, at: time, session: &session, record: &record, isFirstCandidate: true)
        case .toolStarted(let tool, let summary):
            record.currentTool = tool
            record.currentTarget = summary
        case .permissionRequested(let tool, let summary, _):
            record.currentTool = tool
            record.currentTarget = summary.isEmpty ? nil : summary
        case .turnCompleted(let message?):
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { noteOpening(cleaned, at: time, in: &record.openingReplies, limit: SessionRecord.openingReplyLimit) }
            if !cleaned.isEmpty, isNewer(time, than: &record.assistantAt) { session.lastAssistantMessage = cleaned }
        case .subagentStarted:
            session.activeSubagents += 1
        case .subagentStopped:
            session.activeSubagents = max(0, session.activeSubagents - 1)
        case .turnInterrupted:
            session.activeSubagents = 0
        case .metadata(let metadata):
            apply(metadata, at: time, to: &session, record: &record)
        case .usage(let usage, let mode):
            var total = session.usage
            switch mode {
            case .add:
                total.inputTokens += usage.inputTokens
                total.outputTokens += usage.outputTokens
                total.cacheReadTokens += usage.cacheReadTokens
                total.cacheWriteTokens += usage.cacheWriteTokens
            case .replace:
                guard isNewer(time, than: &record.usageAt) else { break }
                total.inputTokens = usage.inputTokens
                total.outputTokens = usage.outputTokens
                total.cacheReadTokens = usage.cacheReadTokens
                total.cacheWriteTokens = usage.cacheWriteTokens
                if let cost = usage.costUSD {
                    total.costUSD = cost
                    record.costIsEstimate = false
                }
            }
            if usage.contextTokens != nil || usage.contextWindow != nil, isNewer(time, than: &record.contextAt) {
                if let context = usage.contextTokens { total.contextTokens = context }
                if let window = usage.contextWindow { total.contextWindow = window }
            }
            if mode == .add, let cost = usage.costUSD {
                total.costUSD = cost
                record.costIsEstimate = false
            }
            session.usage = total
        default:
            break
        }
        if titleInputs != (record.firstPrompt, record.titlePrompt, record.nativeTitle, session.cwd.isEmpty) {
            refreshTitle(&session, record: &record)
        }
        record.session = session
    }

    static func notePrompt(_ prompt: String, at time: Date, session: inout AgentSession, record: inout SessionRecord, isFirstCandidate: Bool) {
        let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if isNewer(time, than: &record.promptAt) { session.lastUserPrompt = cleaned }
        guard isFirstCandidate else { return }
        noteOpening(cleaned, at: time, in: &record.openingPrompts, limit: SessionRecord.openingPromptLimit)
        if record.firstPromptAt.map({ time < $0 }) ?? true {
            record.firstPrompt = cleaned
            record.firstPromptAt = time
        }
        if record.titlePromptAt.map({ time < $0 }) ?? true, TitleCleaner.ownWordsTitle(cleaned) != nil {
            record.titlePrompt = cleaned
            record.titlePromptAt = time
        }
    }

    /// Keeps the earliest `limit` texts (history can arrive newest-first: a peek, then the head).
    static func noteOpening(_ text: String, at time: Date, in list: inout [SessionRecord.OpeningText], limit: Int) {
        let clipped = String(text.prefix(600))
        guard !list.contains(where: { $0.at == time && $0.text == clipped }) else { return }
        if list.count >= limit, let last = list.last, time >= last.at { return }
        list.append(.init(text: clipped, at: time))
        list.sort { $0.at < $1.at }
        if list.count > limit { list.removeLast(list.count - limit) }
    }

    /// The user's own name for the session, then the agent's own title (so Mothership matches
    /// what the agent's resume list shows), then the on-device model's, then the cleaned first
    /// prompt; the folder name is the last resort.
    static func refreshTitle(_ session: inout AgentSession, record: inout SessionRecord) {
        record.hasExplicitTitle = record.nativeTitle != nil || record.generatedTitle != nil
        if let native = record.nativeTitle {
            session.title = native
            return
        }
        if let generated = record.generatedTitle {
            session.title = generated
            return
        }
        guard let prompt = record.titlePrompt ?? record.firstPrompt else { return }
        let folder = session.cwd.isEmpty ? nil : (session.cwd as NSString).lastPathComponent
        session.title = TitleCleaner.title(fromPrompt: prompt, fallback: folder)
    }

    static func apply(_ metadata: SessionMetadata, at time: Date, to session: inout AgentSession, record: inout SessionRecord) {
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let rank = metadata.titleSource == .user ? 3 : 2
            if rank > record.nativeTitleRank || (rank == record.nativeTitleRank && (record.nativeTitleAt.map { time >= $0 } ?? true)) {
                record.nativeTitle = TextSummary.oneLine(title, limit: 80)
                record.nativeTitleRank = rank
                record.nativeTitleAt = time
            }
        }
        if let model = metadata.model, !model.isEmpty, isNewer(time, than: &record.modelAt) { session.model = model }
        if let cwd = metadata.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let branch = metadata.branch, !branch.isEmpty { session.branch = branch }
        if let path = metadata.transcriptPath, !path.isEmpty { session.transcriptPath = path }
        if let first = metadata.firstUserPrompt {
            notePrompt(first, at: metadata.startedAt ?? time, session: &session, record: &record, isFirstCandidate: true)
        }
        if let prompt = metadata.lastUserPrompt {
            // "Latest prompt" facts never become the title source: only real prompts do.
            notePrompt(prompt, at: time, session: &session, record: &record, isFirstCandidate: false)
        }
        if let message = metadata.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            noteOpening(message, at: time, in: &record.openingReplies, limit: SessionRecord.openingReplyLimit)
            if isNewer(time, than: &record.assistantAt) { session.lastAssistantMessage = message }
        }
        if metadata.contextTokens != nil || metadata.contextWindow != nil, isNewer(time, than: &record.contextAt) {
            if let context = metadata.contextTokens { session.usage.contextTokens = context }
            if let window = metadata.contextWindow { session.usage.contextWindow = window }
        }
        if let cost = metadata.reportedCostUSD {
            session.usage.costUSD = cost
            record.costIsEstimate = false
        }
        if let host = metadata.hostApp, session.hostApp == nil { record.hostAppHint = host }
        if let started = metadata.startedAt, started < session.startedAt { session.startedAt = started }
    }
}
