import Foundation
import ShipModel

/// A small embedded price table for cost *estimates* (USD per million tokens).
/// Agents that report their own cost (OpenCode) override it; everything else is an estimate
/// and the engine marks it so (`SessionRecord.costIsEstimate`).
public enum Pricing {
    public struct Rate: Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheWrite: Double
        public var cacheRead: Double
        public var contextWindow: Int?

        public init(input: Double, output: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil, contextWindow: Int? = nil) {
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite ?? input * 1.25
            self.cacheRead = cacheRead ?? input * 0.1
            self.contextWindow = contextWindow
        }
    }

    /// Longest matching prefix wins. Anthropic rates as of 2026-10 (claude-api skill table);
    /// OpenAI / Google rates are rough list prices.
    static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25, contextWindow: 1_000_000)),
        ("claude-mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.25, contextWindow: 1_000_000)),
        ("claude-fable-5", Rate(input: 10, output: 50, contextWindow: 1_000_000)),
        ("claude-mythos", Rate(input: 10, output: 50, contextWindow: 1_000_000)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20, contextWindow: 1_000_000)),
        ("claude-opus-5", Rate(input: 5, output: 25, contextWindow: 1_000_000)),
        ("claude-opus-4-8", Rate(input: 5, output: 25, contextWindow: 1_000_000)),
        ("claude-opus-4-7", Rate(input: 5, output: 25, contextWindow: 1_000_000)),
        ("claude-opus-4-6", Rate(input: 5, output: 25, contextWindow: 1_000_000)),
        ("claude-opus-4-5", Rate(input: 5, output: 25, contextWindow: 200_000)),
        ("claude-opus-4", Rate(input: 15, output: 75, contextWindow: 200_000)),
        ("claude-sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.20, contextWindow: 1_000_000)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, contextWindow: 1_000_000)),
        ("claude-sonnet-4-6", Rate(input: 3, output: 15, contextWindow: 1_000_000)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, contextWindow: 200_000)),
        ("claude-3-7-sonnet", Rate(input: 3, output: 15, contextWindow: 200_000)),
        ("claude-haiku-5-5", Rate(input: 0.10, output: 0.50, contextWindow: 1_000_000)),
        ("claude-haiku-4-5", Rate(input: 1, output: 5, contextWindow: 200_000)),
        ("claude-3-5-haiku", Rate(input: 0.8, output: 4, contextWindow: 200_000)),
        ("gpt-5-mini", Rate(input: 0.25, output: 2, cacheWrite: 0.25, cacheRead: 0.025, contextWindow: 400_000)),
        ("gpt-5-nano", Rate(input: 0.05, output: 0.4, cacheWrite: 0.05, cacheRead: 0.005, contextWindow: 400_000)),
        ("gpt-5", Rate(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125, contextWindow: 400_000)),
        ("codex-mini", Rate(input: 1.5, output: 6, cacheWrite: 1.5, cacheRead: 0.375, contextWindow: 200_000)),
        ("gpt-4.1", Rate(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.5, contextWindow: 1_000_000)),
        ("o4-mini", Rate(input: 1.1, output: 4.4, cacheWrite: 1.1, cacheRead: 0.275, contextWindow: 200_000)),
        ("o3", Rate(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.5, contextWindow: 200_000)),
        ("gemini-3-pro", Rate(input: 2, output: 12, cacheWrite: 2, cacheRead: 0.2, contextWindow: 1_048_576)),
        ("gemini-2.5-pro", Rate(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.31, contextWindow: 1_048_576)),
        ("gemini-2.5-flash-lite", Rate(input: 0.1, output: 0.4, cacheWrite: 0.1, cacheRead: 0.025, contextWindow: 1_048_576)),
        ("gemini-2.5-flash", Rate(input: 0.3, output: 2.5, cacheWrite: 0.3, cacheRead: 0.075, contextWindow: 1_048_576)),
    ]

    /// "anthropic/claude-opus-5-5[1m]" → "claude-opus-5-5".
    public static func normalize(_ model: String) -> String {
        var name = model.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if name.hasPrefix("us.anthropic.") || name.hasPrefix("anthropic.") {
            name = String(name.drop { $0 != "." }.dropFirst())
            if name.hasPrefix("anthropic.") { name = String(name.dropFirst("anthropic.".count)) }
        }
        // Claude ids use dashes for versions ("claude-opus-4-5"); tolerate "claude-opus-4.5".
        return name.hasPrefix("claude") ? name.replacingOccurrences(of: ".", with: "-") : name
    }

    public static func rate(for model: String?) -> Rate? {
        guard let model, !model.isEmpty else { return nil }
        let name = normalize(model)
        return table.filter { name.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.rate
    }

    /// Estimated USD for a usage total, or nil when the model is unknown.
    public static func estimateCost(_ usage: TokenUsage, model: String?) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let million = 1_000_000.0
        return Double(usage.inputTokens) * rate.input / million
            + Double(usage.outputTokens) * rate.output / million
            + Double(usage.cacheWriteTokens) * rate.cacheWrite / million
            + Double(usage.cacheReadTokens) * rate.cacheRead / million
    }

    public static func contextWindow(for model: String?) -> Int? {
        if let model, model.lowercased().contains("[1m]") { return 1_000_000 }
        return rate(for: model)?.contextWindow
    }
}
