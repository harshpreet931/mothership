import Foundation

/// PR status per (repository, branch), from `gh pr list --head`. Each branch is fetched at
/// most once per `refreshInterval` (a new branch is fetched at once); concurrent requests share
/// one fetch. When `gh` is missing or logged out it quietly returns nil, re-checking every
/// `availabilityInterval`.
public actor PullRequestMonitor {
    public struct Key: Hashable, Sendable {
        public var repository: String
        public var branch: String
    }

    struct Entry {
        var status: PullRequestStatus?
        var fetchedAt: Date
        var usedAt: Date
    }

    let github: (any GitHubCLI)?
    let refreshInterval: TimeInterval
    let availabilityInterval: TimeInterval
    let now: @Sendable () -> Date
    var cache: [Key: Entry] = [:]
    var inFlight: [Key: Task<[PullRequestStatus]?, Never>] = [:]
    var available: Bool?
    var availabilityCheckedAt = Date.distantPast
    /// `gh pr list` calls made (for tests and diagnostics).
    public private(set) var fetches = 0

    public init(
        github: (any GitHubCLI)?, refreshInterval: TimeInterval = 60, availabilityInterval: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.github = github
        self.refreshInterval = refreshInterval
        self.availabilityInterval = availabilityInterval
        self.now = now
    }

    public func isEnabled() async -> Bool {
        guard let github else { return false }
        let time = now()
        if let available, time.timeIntervalSince(availabilityCheckedAt) < availabilityInterval { return available }
        availabilityCheckedAt = time
        let ok = await github.isAvailable()
        available = ok
        return ok
    }

    /// The PR for `branch`, fetching when the cached value is older than `refreshInterval`
    /// (or `force`). A failed fetch keeps the last known value.
    public func status(repository: String, branch: String, force: Bool = false) async -> PullRequestStatus? {
        guard await isEnabled(), let github else { return nil }
        let key = Key(repository: repository, branch: branch)
        let time = now()
        if !force, let entry = cache[key], time.timeIntervalSince(entry.fetchedAt) < refreshInterval {
            cache[key]?.usedAt = time
            return entry.status
        }
        let task: Task<[PullRequestStatus]?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { try? await github.pullRequests(head: branch, in: repository) }
            inFlight[key] = task
            fetches += 1
        }
        let fetched = await task.value
        inFlight[key] = nil
        let finished = now()
        if fetched == nil {
            // Auth may have lapsed; look again on the next request.
            availabilityCheckedAt = .distantPast
        }
        let status = fetched.map(GHClient.preferred) ?? cache[key]?.status
        cache[key] = Entry(status: status, fetchedAt: finished, usedAt: finished)
        cache = cache.filter { finished.timeIntervalSince($0.value.usedAt) < 1800 }
        return status
    }

    public func cachedStatus(repository: String, branch: String) -> PullRequestStatus? {
        cache[Key(repository: repository, branch: branch)]?.status
    }

    /// Forget a branch (e.g. after creating its PR) so the next request fetches.
    public func invalidate(repository: String, branch: String) {
        cache[Key(repository: repository, branch: branch)] = nil
    }
}
