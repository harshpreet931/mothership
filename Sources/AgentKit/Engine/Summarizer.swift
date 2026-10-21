import Foundation
import ShipModel

/// Produces the short "what it's doing" line. The heuristic below is the default; an
/// on-device model (Foundation Models) can be plugged in later through this seam.
public protocol SessionSummarizer: Sendable {
    func summary(for record: SessionRecord) -> String?
}

/// While working: the current tool and target ("Editing AppModel.swift", "Running pnpm test").
/// While blocked: what it's waiting for. Idle or done: the first sentence of the last reply.
public struct HeuristicSummarizer: SessionSummarizer {
    public var maxLength: Int

    public init(maxLength: Int = TitleCleaner.summaryLimit) { self.maxLength = maxLength }

    public func summary(for record: SessionRecord) -> String? {
        let session = record.session
        let text: String?
        switch session.state {
        case .working(let tool?):
            let target = tool == record.currentTool ? record.currentTarget : nil
            text = ActivityPhrase.describe(tool: tool, target: target, limit: maxLength)
        case .working(nil):
            text = "Thinking…"
        case .needsInput(.permission):
            if let pending = session.pendingPermission {
                text = pending.summary.isEmpty ? "Approve \(pending.toolName)?" : "Approve \(pending.toolName): \(pending.summary)"
            } else if let tool = record.currentTool {
                text = "Waiting for approval: " + ActivityPhrase.describe(tool: tool, target: record.currentTarget).lowercasedFirst
            } else {
                text = "Waiting for approval"
            }
        case .needsInput:
            text = "Waiting for your input"
        case .error(let message):
            text = "Error: \(message)"
        case .starting:
            text = "Starting"
        case .idle, .ended:
            text = session.lastAssistantMessage.flatMap { TitleCleaner.firstSentence($0, limit: maxLength) } ?? session.title
        }
        return text.map { TextSummary.oneLine(TitleCleaner.abbreviatingHome($0), limit: maxLength) }
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first, first.isUppercase, dropFirst().first?.isLowercase ?? true else { return self }
        return first.lowercased() + dropFirst()
    }
}
