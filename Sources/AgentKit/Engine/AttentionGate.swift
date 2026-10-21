import Foundation
import ShipModel

/// Decides which state transitions deserve an `AttentionEvent`, so one turn produces one
/// "finished" no matter how many sources (hook, transcript, OSC, status file) report it, and a
/// flapping source can't repeat "needs input" or "failed". Pure value type; the engine feeds
/// it every transition (live or replayed) and asks it only about live ones.
struct AttentionGate: Sendable {
    /// Repeats of the same kind for a session inside this window are dropped.
    var repeatWindow: TimeInterval = 30
    private var turnStarted: [AgentSessionKey: Date] = [:]
    private var lastEmitted: [AgentSessionKey: (kind: Kind, at: Date)] = [:]

    enum Kind: Equatable, Sendable { case finished, needsInput, failed, permission }

    /// Record a transition. A turn starts when a session goes from not-busy to working.
    mutating func note(_ key: AgentSessionKey, from previous: AgentState?, to current: AgentState, at time: Date) {
        if case .working = current, !(previous?.isBusy ?? false) {
            turnStarted[key] = time
        }
    }

    /// Whether to emit `kind` for this session now (and remember it if so).
    mutating func admit(_ kind: Kind, for key: AgentSessionKey, now: Date) -> Bool {
        let last = lastEmitted[key]
        let turn = turnStarted[key]
        switch kind {
        case .finished:
            // Once per turn: there must be a turn that started after the last "finished".
            guard let turn else { return false }
            if let last, last.kind == .finished, last.at >= turn { return false }
        case .needsInput, .failed, .permission:
            if let last, last.kind == kind, now.timeIntervalSince(last.at) < repeatWindow, (turn.map { $0 <= last.at } ?? true) {
                return false
            }
        }
        lastEmitted[key] = (kind, now)
        return true
    }

    mutating func rename(_ old: AgentSessionKey, to new: AgentSessionKey) {
        if let turn = turnStarted.removeValue(forKey: old) { turnStarted[new] = max(turnStarted[new] ?? turn, turn) }
        if let last = lastEmitted.removeValue(forKey: old), lastEmitted[new] == nil { lastEmitted[new] = last }
    }

    mutating func forget(_ key: AgentSessionKey) {
        turnStarted[key] = nil
        lastEmitted[key] = nil
    }
}

/// Plain-text titles and bodies for attention events, built once at the source so toasts,
/// notifications and status views agree.
enum AttentionText {
    static let bodyLimit = 140

    /// The same title Fleet shows; the folder or agent name when there is none yet.
    static func title(_ session: AgentSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if !session.cwd.isEmpty { return (session.cwd as NSString).lastPathComponent }
        return session.kind.displayName
    }

    static func body(_ text: String?, fallback: String) -> String {
        guard let text, let plain = TitleCleaner.plainText(text, limit: bodyLimit) else { return fallback }
        return plain
    }

    /// "Bash: rm -rf build" (commands are literal: no markdown handling).
    static func permission(tool: String, summary: String?) -> String {
        guard let summary, !summary.isEmpty else { return tool }
        return TitleCleaner.plainLine("\(tool): \(summary)", limit: bodyLimit) ?? tool
    }
}
