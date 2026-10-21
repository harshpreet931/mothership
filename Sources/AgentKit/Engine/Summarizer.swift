import Foundation
import ShipModel

/// Produces the short "what it's doing" line. The heuristic below is the default; an
/// on-device model (Foundation Models) can be plugged in later through this seam.
public protocol SessionSummarizer: Sendable {
    func summary(for record: SessionRecord) -> String?
}

/// Current tool + target while working, the pending question while blocked, otherwise the
/// first prompt cut to a few words.
public struct HeuristicSummarizer: SessionSummarizer {
    public var maxLength: Int

    public init(maxLength: Int = 60) { self.maxLength = maxLength }

    public func summary(for record: SessionRecord) -> String? {
        let session = record.session
        let topic = (record.hasExplicitTitle ? session.title : nil) ?? record.firstPrompt.map { TextSummary.words($0, count: 6) } ?? session.title
        let text: String?
        switch session.state {
        case .needsInput(.permission):
            if let pending = session.pendingPermission {
                text = pending.summary.isEmpty ? "Approve \(pending.toolName)?" : "Approve \(pending.toolName): \(pending.summary)"
            } else {
                text = record.currentActivity.map { "Waiting on \($0)" } ?? "Waiting for permission"
            }
        case .needsInput:
            text = "Waiting for your input"
        case .working:
            text = record.currentActivity ?? topic.map { "Working: \($0)" } ?? "Working"
        case .error(let message):
            text = "Error: \(message)"
        case .starting:
            text = "Starting"
        case .idle, .ended:
            text = topic
        }
        return text.map { TextSummary.oneLine($0, limit: maxLength) }
    }
}
