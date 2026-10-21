import Foundation
import ShipModel

/// All known sessions plus the indexes that attribute a signal to one of them. Pure value
/// type: the engine owns one, golden-trace tests drive another.
public struct SessionStore: Sendable {
    public private(set) var records: [AgentSessionKey: SessionRecord] = [:]
    /// pid → the session currently running in that process.
    public private(set) var pidIndex: [Int32: AgentSessionKey] = [:]
    public var lease: TimeInterval

    public init(lease: TimeInterval = AgentReducer.defaultLease) {
        self.lease = lease
    }

    /// The outcome of applying one signal.
    public struct Change: Sendable, Equatable {
        public var key: AgentSessionKey
        public var previous: AgentState?
        public var current: AgentState
        /// Set when a provisional (`pid:`) session was promoted to this key.
        public var renamedFrom: AgentSessionKey?
        /// Sessions ended because their process moved on to this one.
        public var replaced: [AgentSessionKey]

        public var stateChanged: Bool { previous != current }
    }

    public subscript(key: AgentSessionKey) -> SessionRecord? {
        get { records[key] }
        set { records[key] = newValue }
    }

    public var sessions: [AgentSession] { records.values.map(\.session) }

    // MARK: Applying signals

    @discardableResult
    public mutating func apply(_ signal: AgentSignal, now: Date, watched: (SurfaceID?) -> Bool) -> Change? {
        guard let resolution = resolve(signal) else { return nil }
        guard let record = records[resolution.key] else { return nil }
        let previous = record.session.state
        let next = AgentReducer.reduce(record, signal, now: now, watched: watched(record.session.surface), lease: lease)
        records[resolution.key] = next
        if next.session.state == .ended {
            for (pid, key) in pidIndex where key == resolution.key { pidIndex[pid] = nil }
        }
        return Change(
            key: resolution.key, previous: resolution.created ? nil : previous, current: next.session.state,
            renamedFrom: resolution.renamedFrom, replaced: resolution.replaced
        )
    }

    /// Lease expiry: applies deferred lower-tier states.
    public mutating func tick(now: Date, watched: (SurfaceID?) -> Bool) -> [Change] {
        var changes: [Change] = []
        for (key, record) in records where record.deferred != nil {
            let next = AgentReducer.tick(record, now: now, watched: watched(record.session.surface))
            records[key] = next
            if next.session.state != record.session.state {
                changes.append(Change(key: key, previous: record.session.state, current: next.session.state, renamedFrom: nil, replaced: []))
            }
        }
        return changes
    }

    // MARK: Resolution

    struct Resolution {
        var key: AgentSessionKey
        var created: Bool
        var renamedFrom: AgentSessionKey?
        var replaced: [AgentSessionKey]
    }

    mutating func resolve(_ signal: AgentSignal) -> Resolution? {
        let hint = signal.hint
        if let sessionID = hint.sessionID {
            let key = AgentSessionKey(kind: hint.kind, sessionID: sessionID)
            var created = false
            var renamed: AgentSessionKey?
            var replaced: [AgentSessionKey] = []
            if records[key] == nil {
                if let candidate = provisionalCandidate(for: hint, tier: signal.tier) {
                    rekey(candidate, to: key)
                    renamed = candidate
                } else {
                    create(key, hint: hint, at: signal.timestamp)
                    created = true
                }
            } else if let pid = hint.pid, let other = pidIndex[pid], other != key, other.isProvisional, other.kind == key.kind {
                merge(other, into: key)
                renamed = other
            }
            if let pid = hint.pid {
                if let other = pidIndex[pid], other != key, !other.isProvisional, other.kind == key.kind,
                    let otherRecord = records[other], otherRecord.session.state != .ended
                {
                    // One process runs one session at a time: it moved on (/clear, /resume).
                    let end = AgentSignal(tier: signal.tier, source: "store:replaced", hint: SessionHint(kind: other.kind, sessionID: other.sessionID), event: .sessionEnded(reason: "replaced"), timestamp: signal.timestamp)
                    records[other] = AgentReducer.reduce(otherRecord, end, now: signal.timestamp, watched: true, lease: lease)
                    replaced.append(other)
                }
                if records[key]?.session.state != .ended || isStart(signal.event) {
                    pidIndex[pid] = key
                }
                if var record = records[key], record.session.pid == nil {
                    record.session.pid = pid
                    records[key] = record
                }
            }
            return Resolution(key: key, created: created, renamedFrom: renamed, replaced: replaced)
        }
        if let pid = hint.pid {
            if let key = pidIndex[pid], records[key] != nil {
                return Resolution(key: key, created: false, renamedFrom: nil, replaced: [])
            }
            // A dead pid can't start a new provisional session.
            if signal.event == .processExited { return nil }
            let key = AgentSessionKey.provisional(kind: hint.kind, pid: pid)
            if records[key] == nil || records[key]?.session.state == .ended {
                create(key, hint: hint, at: signal.timestamp)
            }
            pidIndex[pid] = key
            return Resolution(key: key, created: true, renamedFrom: nil, replaced: [])
        }
        if let surface = hint.surface, let key = liveSession(onSurface: surface, kind: hint.kind) {
            return Resolution(key: key, created: false, renamedFrom: nil, replaced: [])
        }
        return nil
    }

    private func isStart(_ event: SignalEvent) -> Bool {
        if case .sessionStarted = event { return true }
        return false
    }

    /// A provisional session that this real id most likely belongs to.
    func provisionalCandidate(for hint: SessionHint, tier: SignalTier) -> AgentSessionKey? {
        if let pid = hint.pid, let key = pidIndex[pid], key.isProvisional, key.kind == hint.kind { return key }
        let provisional = records.values.filter {
            $0.key.isProvisional && $0.key.kind == hint.kind && $0.session.state != .ended
        }
        if let surface = hint.surface {
            let onSurface = provisional.filter { $0.session.surface == surface }
            if onSurface.count == 1 { return onSurface[0].key }
        }
        // Only a live agent (hook) may claim by cwd; transcripts can belong to any session.
        if tier == .hook, let cwd = hint.cwd {
            let sameDirectory = provisional.filter { $0.session.cwd == cwd }
            if sameDirectory.count == 1 { return sameDirectory[0].key }
        }
        return nil
    }

    mutating func create(_ key: AgentSessionKey, hint: SessionHint, at date: Date) {
        let session = AgentSession(
            id: key, surface: hint.surface, pid: hint.pid, cwd: hint.cwd ?? "", state: .starting,
            transcriptPath: hint.transcriptPath, startedAt: date, lastActivity: date
        )
        records[key] = SessionRecord(session: session, lastStateChange: date)
    }

    mutating func rekey(_ old: AgentSessionKey, to new: AgentSessionKey) {
        guard var record = records.removeValue(forKey: old) else { return }
        record.session.id = new
        if let pending = record.session.pendingPermission {
            var updated = pending
            updated.session = new
            record.session.pendingPermission = updated
        }
        records[new] = record
        for (pid, key) in pidIndex where key == old { pidIndex[pid] = new }
    }

    /// Fold a provisional session into the real one; the real one's facts win, state goes to
    /// whichever has the newer evidence.
    public mutating func merge(_ source: AgentSessionKey, into target: AgentSessionKey) {
        guard let from = records.removeValue(forKey: source), var into = records[target] else { return }
        var session = into.session
        session.pid = session.pid ?? from.session.pid
        session.surface = session.surface ?? from.session.surface
        session.hostApp = session.hostApp ?? from.session.hostApp
        if session.cwd.isEmpty { session.cwd = from.session.cwd }
        session.repoRoot = session.repoRoot ?? from.session.repoRoot
        session.branch = session.branch ?? from.session.branch
        session.title = session.title ?? from.session.title
        session.model = session.model ?? from.session.model
        session.transcriptPath = session.transcriptPath ?? from.session.transcriptPath
        session.lastUserPrompt = session.lastUserPrompt ?? from.session.lastUserPrompt
        session.lastAssistantMessage = session.lastAssistantMessage ?? from.session.lastAssistantMessage
        session.startedAt = min(session.startedAt, from.session.startedAt)
        session.lastActivity = max(session.lastActivity, from.session.lastActivity)
        session.unread = session.unread || from.session.unread
        session.activeSubagents = max(session.activeSubagents, from.session.activeSubagents)
        if session.usage == .zero { session.usage = from.session.usage }
        if session.pendingPermission == nil, var pending = from.session.pendingPermission {
            pending.session = target
            session.pendingPermission = pending
        }
        let fromIsNewer = from.lastStateChange > into.lastStateChange || into.session.state == .starting
        if fromIsNewer, from.session.state != .starting {
            session.state = from.session.state
            into.lastStateChange = from.lastStateChange
            into.stateTier = from.stateTier
            into.leaseUntil = from.leaseUntil
            into.currentActivity = from.currentActivity ?? into.currentActivity
        }
        into.firstPrompt = into.firstPrompt ?? from.firstPrompt
        into.lastHookAt = [into.lastHookAt, from.lastHookAt].compactMap { $0 }.max()
        into.hostAppHint = into.hostAppHint ?? from.hostAppHint
        into.session = session
        records[target] = into
        for (pid, key) in pidIndex where key == source { pidIndex[pid] = target }
    }

    // MARK: Queries & housekeeping

    public func liveSession(onSurface surface: SurfaceID, kind: AgentKind? = nil) -> AgentSessionKey? {
        records.values
            .filter { $0.session.surface == surface && $0.session.state != .ended && (kind == nil || $0.key.kind == kind) }
            .max { $0.session.lastActivity < $1.session.lastActivity }?
            .key
    }

    public func key(forPID pid: Int32) -> AgentSessionKey? { pidIndex[pid] }

    public mutating func update(_ key: AgentSessionKey, _ body: (inout SessionRecord) -> Void) {
        guard var record = records[key] else { return }
        body(&record)
        records[key] = record
    }

    /// Bind a pid explicitly (used for process-table discoveries).
    public mutating func bind(pid: Int32, to key: AgentSessionKey) {
        pidIndex[pid] = key
    }

    /// Remove ended sessions older than `retention`.
    @discardableResult
    public mutating func prune(now: Date, retention: TimeInterval) -> [AgentSessionKey] {
        let stale = records.values.filter { $0.session.state == .ended && now.timeIntervalSince($0.session.lastActivity) > retention }.map(\.key)
        for key in stale {
            records[key] = nil
            for (pid, value) in pidIndex where value == key { pidIndex[pid] = nil }
        }
        return stale
    }
}
