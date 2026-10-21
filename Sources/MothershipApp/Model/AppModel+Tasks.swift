import Foundation
import GitKit
import ShipModel

// CONTRACT between the task backend and the task UI. The signatures below are fixed; the
// backend replaces the stub bodies. Stored state (`tasks`, `pullRequests`) lives in
// `AppModel` because extensions can't hold stored properties.

/// "New Task": one prompt, one or more agents, each in its own worktree (Best-of-N).
struct NewTaskRequest: Sendable, Equatable {
    var prompt: String
    var repoRoot: String
    /// nil = the repo's current branch.
    var baseBranch: String?
    var agents: [AgentKind]
    /// false = run in the repo itself (only valid for a single agent).
    var useWorktrees: Bool
}

struct AgentTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var prompt: String
    var repoRoot: String
    var baseBranch: String
    var createdAt: Date
    var runs: [TaskRun]
}

struct TaskRun: Identifiable, Codable, Equatable {
    enum Outcome: String, Codable { case running, kept, discarded }
    let id: UUID
    var agent: AgentKind
    var branch: String
    var worktreePath: String
    var workspaceID: WorkspaceID
    /// Refreshed by `refreshDiff(for:)` and periodically while the run is live.
    var diff: DiffStat?
    var outcome: Outcome
}

enum KeepMode: String, Codable, CaseIterable {
    /// Push the branch and open a GitHub PR (`gh pr create`).
    case pullRequest
    /// Merge the branch into the base in the main worktree.
    case mergeIntoBase
    /// Leave the branch; just stop tracking it as a candidate.
    case keepBranch
}

struct TaskError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

extension AppModel {
    /// Creates the worktrees and workspaces and launches each agent with the prompt.
    func startTask(_ request: NewTaskRequest) async throws -> AgentTask {
        throw TaskError(message: "Tasks aren't implemented yet")
    }

    func refreshDiff(for run: TaskRun.ID) async {}

    /// Unified diff of the run against its base, including uncommitted changes.
    func fullDiff(for run: TaskRun.ID) async -> String { "" }

    func keepRun(_ run: TaskRun.ID, mode: KeepMode) async throws {
        throw TaskError(message: "Tasks aren't implemented yet")
    }

    /// Removes the worktree and branch and closes the run's workspace.
    func discardRun(_ run: TaskRun.ID) async throws {
        throw TaskError(message: "Tasks aren't implemented yet")
    }

    func task(for workspace: WorkspaceID) -> AgentTask? {
        tasks.first { $0.runs.contains { $0.workspaceID == workspace } }
    }

    func taskRun(for workspace: WorkspaceID) -> TaskRun? {
        tasks.lazy.flatMap(\.runs).first { $0.workspaceID == workspace }
    }

    /// The open PR for the workspace's branch, from the PR monitor's cache.
    func pullRequest(for workspace: WorkspaceID) -> PullRequestStatus? {
        pullRequests[workspace]
    }
}
