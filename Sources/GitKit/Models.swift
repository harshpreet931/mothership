import Foundation

/// A git repository as Mothership sees it.
public struct RepoInfo: Sendable, Equatable, Codable {
    /// The main worktree's root (for a linked worktree, the repo it belongs to).
    public var root: String
    public var name: String
    public var branch: String?
    /// `origin/HEAD`'s branch (usually `main`), when known.
    public var defaultBranch: String?
    public var github: GitHubRepo?

    public init(root: String, name: String, branch: String?, defaultBranch: String?, github: GitHubRepo?) {
        self.root = root
        self.name = name
        self.branch = branch
        self.defaultBranch = defaultBranch
        self.github = github
    }
}

public struct GitHubRepo: Sendable, Equatable, Hashable, Codable {
    public var owner: String
    public var name: String
    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

public struct FileChange: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable { case added, modified, deleted, renamed, untracked }
    public var id: String { path }
    public var path: String
    public var status: Status
    public var insertions: Int
    public var deletions: Int

    public init(path: String, status: Status, insertions: Int, deletions: Int) {
        self.path = path
        self.status = status
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// Changes on a branch relative to its base, including uncommitted work in the worktree.
public struct DiffStat: Sendable, Equatable, Codable {
    public var files: [FileChange]
    public var insertions: Int { files.reduce(0) { $0 + $1.insertions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    public var isEmpty: Bool { files.isEmpty }

    public init(files: [FileChange]) { self.files = files }
    public static let empty = DiffStat(files: [])
}

public struct PullRequestStatus: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case open, draft, merged, closed }
    public enum Checks: String, Sendable, Codable { case passing, failing, pending, none }
    public enum Review: String, Sendable, Codable { case approved, changesRequested, reviewRequired, none }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var checks: Checks
    public var review: Review

    public init(number: Int, title: String, url: String, state: State, checks: Checks, review: Review) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
        self.review = review
    }
}
