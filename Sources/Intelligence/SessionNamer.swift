import Foundation
import FoundationModels

/// On-device session titles and reply summaries with Apple's Foundation Models. Every entry
/// point returns nil when the model isn't available (no Apple Intelligence, model not yet
/// downloaded), so callers keep their own heuristics. Nothing leaves the Mac.
public struct SessionNamer: Sendable {
    public init() {}

    public static var isAvailable: Bool { model.isAvailable }

    /// "available", or why not, for logs and Settings.
    public static var availabilityDescription: String {
        switch model.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "this Mac can't run Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
            case .modelNotReady: return "the on-device model isn't ready yet (still downloading)"
            @unknown default: return "unavailable"
            }
        }
    }

    /// The text being titled or summarized is the user's own (prompts, agent replies), so the
    /// guardrails for transforming provided content apply, not those for open generation.
    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    static let titleInstructions = """
        You title coding-agent sessions for a sidebar. Reply with a title of 2 to 5 words that \
        names the concrete subject: the project, feature, file, bug or tool. Prefer the user's \
        own nouns. Use title case only for names. No quotes, no ending punctuation, and no \
        generic words such as Session, Task, Help, Request, Question or Coding.
        Good titles: Paper Prix F1 notebook; Sidebar overflow fix; Stripe webhook retries; \
        Release build signing.
        """

    static let summaryInstructions = """
        You summarize a coding agent's reply for a status line. Reply with one plain sentence \
        of at most 14 words saying what the agent did or found. No markdown, no quotes, and \
        don't start with "The agent".
        """

    /// A 2–5 word title from how the session opened.
    public func title(prompts: [String], replies: [String], folder: String?) async throws -> String? {
        let model = Self.model
        guard model.isAvailable, !prompts.isEmpty else { return nil }
        let session = LanguageModelSession(model: model, instructions: Self.titleInstructions)
        let response = try await session.respond(
            to: Self.titlePrompt(prompts: prompts, replies: replies, folder: folder), generating: GeneratedTitle.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 32)
        )
        return response.content.title
    }

    /// One line about what a reply says.
    public func summary(of reply: String, title: String?) async throws -> String? {
        let model = Self.model
        guard model.isAvailable, !reply.isEmpty else { return nil }
        let session = LanguageModelSession(model: model, instructions: Self.summaryInstructions)
        var prompt = ""
        if let title { prompt += "Session: \(title)\n" }
        prompt += "Reply:\n" + String(reply.prefix(3000))
        let response = try await session.respond(
            to: prompt, generating: GeneratedSummary.self, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 48)
        )
        return response.content.summary
    }

    /// Warms the model up so the first title doesn't pay the load time.
    public func prewarm() {
        let model = Self.model
        guard model.isAvailable else { return }
        LanguageModelSession(model: model, instructions: Self.titleInstructions).prewarm()
    }

    static func titlePrompt(prompts: [String], replies: [String], folder: String?) -> String {
        var text = ""
        if let folder, !folder.isEmpty { text += "Folder: \(folder)\n" }
        text += "The user asked:\n"
        for prompt in prompts { text += "- \(prompt)\n" }
        if !replies.isEmpty {
            text += "The agent replied:\n"
            for reply in replies { text += "- \(reply)\n" }
        }
        text += "Title for this session:"
        return text
    }
}

@Generable
struct GeneratedTitle {
    @Guide(description: "2 to 5 words naming the session's concrete subject, like Paper Prix F1 notebook")
    var title: String
}

@Generable
struct GeneratedSummary {
    @Guide(description: "One plain sentence of at most 14 words")
    var summary: String
}
