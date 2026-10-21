import Foundation
import ShipModel

/// On-device titles and reply summaries. Requests go to `GeneratedTextQueue` (its own actor,
/// one model call at a time), so the engine never waits on the model. Results come back
/// through `applyGenerated`. Without a generator, or with an unavailable model, nothing here
/// runs and sessions keep their heuristic titles and summaries.
extension AgentEngine {
    /// Runs `generationDelay` after the last published change (and after history loads).
    func scheduleGeneration(after delay: TimeInterval? = nil) {
        guard let generator = configuration.textGenerator else { return }
        if generatedText == nil {
            generatedText = GeneratedTextQueue(generator: generator, cacheURL: configuration.generatedTextCache) { [weak self] delivery in
                await self?.applyGenerated(delivery)
            }
        }
        generationTask?.cancel()
        let delay = delay ?? configuration.generationDelay
        generationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.requestGeneration()
        }
    }

    func requestGeneration() async {
        guard let queue = generatedText else { return }
        // A peek's late prompts would make a title that's replaced as soon as the head loads.
        guard !startingUp, historyLoads == 0 else { return }
        let now = Date()
        let summarize = configuration.textGenerator?.summary != nil
        var waiting = false
        for record in store.records.values {
            let session = record.session
            if session.state == .ended, now.timeIntervalSince(session.lastActivity) > 3600 { continue }
            let key = record.key
            if record.openingReplies.isEmpty, let first = record.openingPrompts.first, now.timeIntervalSince(first.at) <= 30 {
                waiting = true
            }
            if record.nativeTitleRank < 3, let digest = Self.digest(for: record, now: now) {
                let fingerprint = "t:" + digest.fingerprint
                if record.generatedTitleFingerprint != fingerprint, requestedTitles[key] != fingerprint {
                    requestedTitles[key] = fingerprint
                    await queue.requestTitle(key, digest: digest)
                }
            }
            // A long reply that just finished gets a one-line summary; short ones already are one.
            if summarize, session.state == .idle, let reply = session.lastAssistantMessage, reply.count > 160,
                let at = record.assistantAt, now.timeIntervalSince(at) < 1800
            {
                let fingerprint = StableHash.hex(reply)
                if record.generatedSummaryFingerprint != "s:" + fingerprint, requestedSummaries[key] != fingerprint {
                    requestedSummaries[key] = fingerprint
                    await queue.requestSummary(key, reply: String(reply.prefix(4000)), fingerprint: fingerprint, title: session.title)
                }
            }
        }
        requestedTitles = requestedTitles.filter { store[$0.key] != nil }
        requestedSummaries = requestedSummaries.filter { store[$0.key] != nil }
        // A prompt with no reply yet gets its title from the prompt alone after 30 s.
        if waiting { scheduleGeneration(after: 31) }
    }

    func applyGenerated(_ delivery: GeneratedTextQueue.Delivery) {
        guard let before = store[delivery.key] else { return }
        store.update(delivery.key) { record in
            switch delivery.kind {
            case .title:
                record.generatedTitleFingerprint = delivery.fingerprint
                // A failed attempt keeps whatever title the session had.
                if let text = delivery.text {
                    record.generatedTitle = text
                    var session = record.session
                    AgentReducer.refreshTitle(&session, record: &record)
                    record.session = session
                }
            case .summary:
                record.generatedSummaryFingerprint = delivery.fingerprint
                record.generatedSummary = delivery.text
            }
        }
        guard store[delivery.key] != before else { return }
        switch delivery.kind {
        case .title: metrics.generatedTitles += 1
        case .summary: metrics.generatedSummaries += 1
        }
        markDirty()
    }

    /// The opening as plain text. Prompt-only sessions wait 30 s for a first reply.
    static func digest(for record: SessionRecord, now: Date) -> SessionDigest? {
        let prompts = record.openingPrompts.compactMap { TitleCleaner.plainText($0.text, limit: 400) }
        guard let first = record.openingPrompts.first, !prompts.isEmpty else { return nil }
        let replies = record.openingReplies.compactMap { TitleCleaner.plainText($0.text, limit: 400) }
        guard !replies.isEmpty || now.timeIntervalSince(first.at) > 30 else { return nil }
        let cwd = record.session.cwd
        return SessionDigest(
            kind: record.key.kind, folder: cwd.isEmpty ? nil : (cwd as NSString).lastPathComponent, prompts: prompts, replies: replies
        )
    }

    /// The generated summary, while it still describes the latest reply of an idle session.
    static func generatedSummary(for record: SessionRecord) -> String? {
        guard let summary = record.generatedSummary, record.session.state == .idle, let reply = record.session.lastAssistantMessage,
            record.generatedSummaryFingerprint == "s:" + StableHash.hex(reply)
        else { return nil }
        return summary
    }

    /// Model calls, failures and per-call latencies (most recent 200), for tools.
    public func generationStats() async -> (calls: Int, failures: Int, latencies: [Duration]) {
        await generatedText?.stats ?? (0, 0, [])
    }
}
