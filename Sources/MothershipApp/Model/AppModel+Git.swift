import Foundation
import GitKit
import ShipModel

/// PR status for workspaces: a workspace whose folder is a GitHub repo on a branch other than
/// the default gets `pullRequests[workspace.id]` from the `PullRequestMonitor` (`gh pr list`,
/// at most once a minute per branch, at once when the branch changes). Only while the app is
/// active, and only for the selected workspace, workspaces selected in the last 30 minutes and
/// task runs.
extension AppModel {
    /// Call once from the app delegate.
    func startPullRequestStatus() {
        Task { [weak self] in
            var seen: [WorkspaceID: Date] = [:]
            var repos: [String: (info: RepoInfo?, at: Date)] = [:]
            while !Task.isCancelled {
                guard let model = self else { return }
                if model.appIsActive { await model.refreshPullRequests(seen: &seen, repos: &repos) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshPullRequests(seen: inout [WorkspaceID: Date], repos: inout [String: (info: RepoInfo?, at: Date)]) async {
        let now = Date()
        if let selected = selectedWorkspaceID { seen[selected] = now }
        let live = Set(workspaces.map(\.id))
        for id in pullRequests.keys where !live.contains(id) { pullRequests[id] = nil }
        seen = seen.filter { live.contains($0.key) }
        let runWorkspaces = Set(tasks.flatMap(\.runs).filter { $0.outcome != .discarded }.map(\.workspaceID))
        let candidates = workspaces.filter { workspace in
            workspace.id == selectedWorkspaceID || runWorkspaces.contains(workspace.id)
                || seen[workspace.id].map { now.timeIntervalSince($0) < 1800 } == true
        }
        for workspace in candidates.prefix(12) {
            let status = await pullRequestStatus(for: workspace, repos: &repos, now: now)
            if pullRequests[workspace.id] != status { pullRequests[workspace.id] = status }
        }
    }

    private func pullRequestStatus(for workspace: Workspace, repos: inout [String: (info: RepoInfo?, at: Date)], now: Date) async
        -> PullRequestStatus?
    {
        // Branch from `.git/HEAD` (re-read every few seconds); a detached HEAD reads as a short hash.
        guard let git = workspace.git, let branch = git.branch, !Self.looksLikeCommit(branch) else { return nil }
        // Remote and default branch rarely change: one `git` lookup per repo every 5 minutes.
        if repos[git.root].map({ now.timeIntervalSince($0.at) > 300 }) ?? true {
            repos[git.root] = (try? await GitServices.git.repoInfo(at: git.root), now)
        }
        guard let repo = repos[git.root]?.info, repo.github != nil, branch != repo.defaultBranch else { return nil }
        return await GitServices.monitor.status(repository: repo.root, branch: branch)
    }

    static func looksLikeCommit(_ name: String) -> Bool {
        name.count == 7 && name.allSatisfy(\.isHexDigit) && name.contains(where: \.isNumber)
    }
}
