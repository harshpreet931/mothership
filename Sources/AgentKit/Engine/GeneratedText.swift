import Foundation
import ShipModel

/// What a title model sees of a session: how it opened. That's the user's first prompts and
/// the agent's first replies, as plain text.
public struct SessionDigest: Sendable, Equatable {
    public var kind: AgentKind
    public var folder: String?
    public var prompts: [String]
    public var replies: [String]

    public init(kind: AgentKind, folder: String?, prompts: [String], replies: [String]) {
        self.kind = kind
        self.folder = folder
        self.prompts = prompts
        self.replies = replies
    }

    /// Stable across launches (FNV-1a), so cached titles survive restarts.
    public var fingerprint: String {
        StableHash.hex(([kind.rawValue, folder ?? ""] + prompts + ["\u{1}"] + replies).joined(separator: "\u{0}"))
    }
}

/// The engine's seam for generated titles and reply summaries (on-device Foundation Models,
/// plugged in by the app). Every call may throw or return nil; the engine then keeps its
/// heuristic title and summary.
public struct SessionTextGenerator: Sendable {
    /// False while the model is unavailable (no Apple Intelligence, model not downloaded).
    public var isAvailable: @Sendable () async -> Bool
    public var title: @Sendable (SessionDigest) async throws -> String?
    /// One line about a reply; nil when summaries are off.
    public var summary: (@Sendable (_ reply: String, _ title: String?) async throws -> String?)?

    public init(
        isAvailable: @escaping @Sendable () async -> Bool, title: @escaping @Sendable (SessionDigest) async throws -> String?,
        summary: (@Sendable (_ reply: String, _ title: String?) async throws -> String?)? = nil
    ) {
        self.isAvailable = isAvailable
        self.title = title
        self.summary = summary
    }
}

/// Model output → sidebar text: one line, no quotes or labels, a bounded length.
public enum GeneratedTextCleaner {
    public static func title(_ raw: String?) -> String? {
        guard var text = firstLine(raw) else { return nil }
        text = dropLabel(text, ["title", "session title", "name"])
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?:;,").union(quotes))
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        if words.count > 6 { words = Array(words.prefix(5)) }
        text = words.joined(separator: " ")
        if text.count > TitleCleaner.titleLimit { text = TitleCleaner.truncate(text, limit: TitleCleaner.titleLimit) }
        guard let first = text.first, text.count >= 2 else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    public static func summary(_ raw: String?) -> String? {
        guard var text = firstLine(raw) else { return nil }
        text = dropLabel(text, ["summary", "one-line summary"])
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(quotes))
        guard text.count >= 3 else { return nil }
        return TitleCleaner.plainText(text, limit: TitleCleaner.summaryLimit)
    }

    static let quotes = CharacterSet(charactersIn: "\"'`*“”‘’«»")

    static func firstLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { TextSummary.oneLine($0, limit: 200) }
    }

    static func dropLabel(_ text: String, _ labels: [String]) -> String {
        for label in labels {
            let prefix = label + ":"
            if text.lowercased().hasPrefix(prefix) { return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        return text
    }
}

enum StableHash {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Runs generation off the engine: one model call at a time, spaced by `spacing`, latest
/// request per session wins, and results are cached by input fingerprint (on disk when
/// `cacheURL` is set). Titles go before summaries. When the model is unavailable, requests
/// wait and availability is re-checked every `availabilityRetry`.
actor GeneratedTextQueue {
    enum Kind: String, Codable { case title, summary }

    struct Request {
        var key: AgentSessionKey
        var fingerprint: String
        var work: @Sendable () async throws -> String?
    }

    struct Delivery: Sendable {
        var key: AgentSessionKey
        var kind: Kind
        var fingerprint: String
        var text: String?
    }

    struct CacheEntry: Codable {
        var text: String?
        var at: Date
    }

    let generator: SessionTextGenerator
    let cacheURL: URL?
    let spacing: Duration
    let availabilityRetry: Duration
    let deliver: @Sendable (Delivery) async -> Void
    private var cache: [String: CacheEntry] = [:]
    private var titles: [AgentSessionKey: Request] = [:]
    private var summaries: [AgentSessionKey: Request] = [:]
    private var draining = false
    private var cacheDirty = false
    private(set) var latencies: [Duration] = []
    private(set) var calls = 0
    private(set) var failures = 0

    init(
        generator: SessionTextGenerator, cacheURL: URL?, spacing: Duration = .milliseconds(500), availabilityRetry: Duration = .seconds(120),
        deliver: @escaping @Sendable (Delivery) async -> Void
    ) {
        self.generator = generator
        self.cacheURL = cacheURL
        self.spacing = spacing
        self.availabilityRetry = availabilityRetry
        self.deliver = deliver
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
            let stored = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        {
            cache = stored
        }
    }

    func requestTitle(_ key: AgentSessionKey, digest: SessionDigest) async {
        let generator = self.generator
        await enqueue(Request(key: key, fingerprint: "t:" + digest.fingerprint) { try await generator.title(digest) }, kind: .title)
    }

    func requestSummary(_ key: AgentSessionKey, reply: String, fingerprint: String, title: String?) async {
        guard let summarize = generator.summary else { return }
        await enqueue(Request(key: key, fingerprint: "s:" + fingerprint) { try await summarize(reply, title) }, kind: .summary)
    }

    private func enqueue(_ request: Request, kind: Kind) async {
        if let cached = cache[request.fingerprint] {
            await deliver(Delivery(key: request.key, kind: kind, fingerprint: request.fingerprint, text: cached.text))
            return
        }
        switch kind {
        case .title: titles[request.key] = request
        case .summary: summaries[request.key] = request
        }
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func next() -> (Request, Kind)? {
        if let key = titles.keys.first, let request = titles.removeValue(forKey: key) { return (request, .title) }
        if let key = summaries.keys.first, let request = summaries.removeValue(forKey: key) { return (request, .summary) }
        return nil
    }

    private func drain() async {
        while let (request, kind) = next() {
            if let cached = cache[request.fingerprint] {
                await deliver(Delivery(key: request.key, kind: kind, fingerprint: request.fingerprint, text: cached.text))
                continue
            }
            guard await generator.isAvailable() else {
                // Put it back and look again later; nothing is lost while the model downloads.
                switch kind {
                case .title: titles[request.key] = titles[request.key] ?? request
                case .summary: summaries[request.key] = summaries[request.key] ?? request
                }
                try? await Task.sleep(for: availabilityRetry)
                continue
            }
            let clock = ContinuousClock()
            let started = clock.now
            calls += 1
            var text: String?
            do {
                let raw = try await request.work()
                text = kind == .title ? GeneratedTextCleaner.title(raw) : GeneratedTextCleaner.summary(raw)
            } catch {
                // Guardrails, context size, a busy model: this input keeps the heuristics.
                failures += 1
            }
            latencies.append(clock.now - started)
            if latencies.count > 200 { latencies.removeFirst(latencies.count - 200) }
            cache[request.fingerprint] = CacheEntry(text: text, at: Date())
            cacheDirty = true
            await deliver(Delivery(key: request.key, kind: kind, fingerprint: request.fingerprint, text: text))
            try? await Task.sleep(for: spacing)
        }
        draining = false
        saveCache()
    }

    private func saveCache() {
        guard cacheDirty, let cacheURL else { return }
        cacheDirty = false
        if cache.count > 500 {
            let keep = cache.sorted { $0.value.at > $1.value.at }.prefix(400)
            cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    var stats: (calls: Int, failures: Int, latencies: [Duration]) { (calls, failures, latencies) }
}
