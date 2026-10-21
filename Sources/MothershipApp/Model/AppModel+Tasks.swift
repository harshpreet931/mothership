import AgentKit
import Foundation
import GitKit
import ShipModel
import ShipProtocol

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
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw TaskError(message: "Describe the task for the agents first.") }
        guard !request.agents.isEmpty else { throw TaskError(message: "Pick at least one agent for the task.") }
        guard request.useWorktrees || request.agents.count == 1 else {
            throw TaskError(message: "Several agents can't share one folder. Turn on worktrees, or pick a single agent.")
        }
        let git = GitServices.git
        let repo: RepoInfo
        do {
            repo = try await git.repoInfo(at: request.repoRoot)
        } catch let error as GitError {
            switch error.kind {
            case .notARepository:
                throw TaskError(message: "\(PathDisplay.abbreviated(request.repoRoot)) isn't a git repository. Tasks give each agent its own git worktree, so pick a folder inside a repo (or run git init there).")
            default:
                throw TaskError(message: error.message)
            }
        }
        let current = try? await git.currentBranch(in: request.repoRoot)
        let requestedBase = request.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = requestedBase?.isEmpty == false ? requestedBase : current else {
            throw TaskError(message: "\(repo.name) has a detached HEAD. Choose a base branch for the task.")
        }
        guard await git.commitExists(base, in: repo.root) else {
            throw TaskError(message: "There's no branch '\(base)' in \(repo.name). It may not have any commits yet.")
        }
        let title = Self.taskTitle(for: prompt, repoName: repo.name)
        var runs: [TaskRun] = []
        if request.useWorktrees {
            // New worktrees start from base's last commit; uncommitted edits there would be
            // silently left behind.
            if base == current, let tracked = try? await git.changes(in: request.repoRoot).tracked, !tracked.isEmpty {
                let files = tracked.count == 1 ? "1 file" : "\(tracked.count) files"
                throw TaskError(message: "\(repo.name) has uncommitted changes on \(base) (\(files)). Commit or stash them first: each agent's worktree starts from the last commit of \(base), so the agents wouldn't see them.")
            }
            var created: [(agent: AgentKind, branch: String, path: String)] = []
            var taken: Set<String> = []
            do {
                for agent in request.agents {
                    let location = try await git.newRunLocation(prompt: prompt, agent: agent.rawValue, repository: repo.root, excluding: taken)
                    taken.formUnion([location.branch, location.path])
                    try await git.addWorktree(repository: repo.root, branch: location.branch, path: location.path, base: base)
                    created.append((agent, location.branch, location.path))
                }
            } catch {
                for run in created { try? await git.removeWorktree(repository: repo.root, path: run.path, branch: run.branch) }
                throw TaskError(message: (error as? GitError)?.message ?? error.localizedDescription)
            }
            for (index, run) in created.enumerated() {
                let workspace = await launchRun(run.agent, prompt: prompt, in: run.path, repoRoot: repo.root, title: title, focus: index == 0)
                runs.append(TaskRun(id: UUID(), agent: run.agent, branch: run.branch, worktreePath: run.path, workspaceID: workspace, diff: nil, outcome: .running))
            }
        } else {
            let directory = (try? await git.topLevel(of: request.repoRoot)) ?? request.repoRoot
            let agent = request.agents[0]
            let workspace = await launchRun(agent, prompt: prompt, in: directory, repoRoot: repo.root, title: title, focus: true)
            runs.append(TaskRun(id: UUID(), agent: agent, branch: current ?? base, worktreePath: directory, workspaceID: workspace, diff: nil, outcome: .running))
        }
        let task = AgentTask(id: UUID(), title: title, prompt: prompt, repoRoot: repo.root, baseBranch: base, createdAt: Date(), runs: runs)
        tasks.append(task)
        saveTasks()
        noteProjectUsed(repo.root)
        return task
    }

    func refreshDiff(for run: TaskRun.ID) async {
        guard let (taskIndex, runIndex) = indices(of: run) else { return }
        let task = tasks[taskIndex]
        let value = task.runs[runIndex]
        guard value.outcome != .discarded, FileManager.default.fileExists(atPath: value.worktreePath) else { return }
        guard GitServices.diffsInFlight.insert(run).inserted else { return }
        defer { GitServices.diffsInFlight.remove(run) }
        GitServices.lastDiffRefresh[run] = Date()
        guard let stat = try? await GitServices.git.diffStat(in: value.worktreePath, base: task.baseBranch),
            let (t, r) = indices(of: run), tasks[t].runs[r].diff != stat
        else { return }
        tasks[t].runs[r].diff = stat
        saveTasks()
    }

    /// Unified diff of the run against its base, including uncommitted changes.
    func fullDiff(for run: TaskRun.ID) async -> String {
        guard let (taskIndex, runIndex) = indices(of: run) else { return "" }
        let task = tasks[taskIndex]
        let value = task.runs[runIndex]
        guard FileManager.default.fileExists(atPath: value.worktreePath) else { return "" }
        return (try? await GitServices.git.fullDiff(in: value.worktreePath, base: task.baseBranch)) ?? ""
    }

    func keepRun(_ run: TaskRun.ID, mode: KeepMode) async throws {
        guard let (taskIndex, runIndex) = indices(of: run) else { throw TaskError(message: "That run no longer exists.") }
        let task = tasks[taskIndex]
        let value = task.runs[runIndex]
        guard value.outcome != .discarded else { throw TaskError(message: "This run was discarded.") }
        let git = GitServices.git
        let ownWorktree = Self.isOwnWorktree(value, of: task)
        do {
            switch mode {
            case .keepBranch:
                break
            case .mergeIntoBase:
                // A run in the repo itself already worked on its branch.
                if ownWorktree {
                    try await git.commitAll(in: value.worktreePath, message: task.title)
                    // Record what's being kept: once merged, the branch has no diff left against the base.
                    await refreshDiff(for: run)
                    try await git.merge(branch: value.branch, into: task.baseBranch, repository: task.repoRoot, message: "Merge \(value.branch): \(task.title)")
                }
            case .pullRequest:
                guard ownWorktree, value.branch != task.baseBranch else {
                    throw TaskError(message: "This run worked directly on \(task.baseBranch), so there's no branch to open a pull request from.")
                }
                guard let github = GitServices.github, await github.isAvailable() else {
                    throw TaskError(message: "Opening a pull request needs the GitHub CLI. Install gh, then run gh auth login.")
                }
                try await git.commitAll(in: value.worktreePath, message: task.title)
                try await git.push(branch: value.branch, in: value.worktreePath)
                _ = try await github.createPullRequest(
                    head: value.branch, base: task.baseBranch, title: task.title, body: Self.pullRequestBody(task, value), in: value.worktreePath
                )
                await GitServices.monitor.invalidate(repository: task.repoRoot, branch: value.branch)
                if let status = await GitServices.monitor.status(repository: task.repoRoot, branch: value.branch, force: true) {
                    pullRequests[value.workspaceID] = status
                }
            }
        } catch let error as GitError {
            throw TaskError(message: error.message)
        }
        if let (t, r) = indices(of: run) {
            tasks[t].runs[r].outcome = .kept
            saveTasks()
        }
        if mode != .mergeIntoBase { await refreshDiff(for: run) }
    }

    /// Removes the worktree and branch and closes the run's workspace.
    func discardRun(_ run: TaskRun.ID) async throws {
        guard let (taskIndex, runIndex) = indices(of: run) else { return }
        let task = tasks[taskIndex]
        let value = task.runs[runIndex]
        // The agent goes first, so nothing writes into the worktree while it's removed.
        if workspace(id: value.workspaceID) != nil { closeWorkspace(value.workspaceID) }
        pullRequests[value.workspaceID] = nil
        var failure: TaskError?
        if Self.isOwnWorktree(value, of: task) {
            do {
                try await GitServices.git.removeWorktree(repository: task.repoRoot, path: value.worktreePath, branch: value.branch)
            } catch {
                failure = TaskError(message: (error as? GitError)?.message ?? error.localizedDescription)
            }
        }
        if let (t, r) = indices(of: run) {
            tasks[t].runs[r].outcome = .discarded
            tasks[t].runs[r].diff = nil
            saveTasks()
        }
        if let failure { throw failure }
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

// MARK: - Backend

/// Git services shared by tasks and PR status. Extensions can't add stored properties to
/// `AppModel`, so they live here (main-actor state; one model per app).
@MainActor
enum GitServices {
    static var git = Git()
    private(set) static var github: (any GitHubCLI)? = GHClient()
    private(set) static var monitor = PullRequestMonitor(github: github)
    static var diffsInFlight: Set<UUID> = []
    static var lastDiffRefresh: [UUID: Date] = [:]

    /// Nil turns PR features off; a fake keeps everything off GitHub (demo mode, QA).
    static func configure(github: (any GitHubCLI)?) {
        self.github = github
        monitor = PullRequestMonitor(github: github)
    }
}

/// `<support>/tasks.json`.
enum TaskStore {
    static var url: URL { ShipPaths.supportDirectory.appending(path: "tasks.json") }

    static func load(from url: URL = url) -> [AgentTask] {
        guard let data = try? Data(contentsOf: url), let tasks = try? JSONDecoder.ship.decode([AgentTask].self, from: data) else { return [] }
        return tasks
    }

    static func save(_ tasks: [AgentTask], to url: URL = url) {
        guard let data = try? JSONEncoder.ship.encode(tasks) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension AppModel {
    /// Restores tasks, then keeps run diffs fresh: every 10 s while a run's agent works,
    /// right after it stops (a Stop), and every 60 s otherwise. Call once from the app delegate.
    func startTaskServices() {
        if store != nil { tasks = TaskStore.load() }
        Task { [weak self] in
            var working: [UUID: Bool] = [:]
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.refreshRunDiffs(working: &working)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshRunDiffs(working: inout [UUID: Bool]) async {
        let now = Date()
        for run in tasks.flatMap(\.runs) where run.outcome == .running {
            guard let workspace = workspace(id: run.workspaceID) else { continue }
            let isWorking = sessions(in: workspace).contains { $0.state.isWorking }
            let stopped = working[run.id] == true && !isWorking
            working[run.id] = isWorking
            let last = GitServices.lastDiffRefresh[run.id] ?? .distantPast
            if stopped || now.timeIntervalSince(last) >= (isWorking ? 10 : 60) {
                await refreshDiff(for: run.id)
            }
        }
    }

    func saveTasks() {
        guard store != nil else { return }
        TaskStore.save(tasks)
    }

    func indices(of run: TaskRun.ID) -> (Int, Int)? {
        for (taskIndex, task) in tasks.enumerated() {
            if let runIndex = task.runs.firstIndex(where: { $0.id == run }) { return (taskIndex, runIndex) }
        }
        return nil
    }

    /// Opens the run's workspace with `setup.sh` (when the repo has one) and then the agent.
    func launchRun(_ agent: AgentKind, prompt: String, in directory: String, repoRoot: String, title: String, focus: Bool) async -> WorkspaceID {
        let agentCommand = await engine.launchCommand(agent, prompt: prompt)
        let command = Self.runCommand(agentCommand, repoRoot: repoRoot, worktree: directory)
        let (workspace, _) = createWorkspace(cwd: directory, name: "\(title) · \(agent.displayName)", command: command, focus: focus)
        return workspace.id
    }

    /// `<repo>/.mothership/setup.sh` runs first, in the worktree, with its output in the pane
    /// (copy `.env`, install dependencies); the agent starts after it either way.
    static func runCommand(_ agentCommand: String, repoRoot: String, worktree: String, fileManager: FileManager = .default) -> String {
        let setup = repoRoot + "/.mothership/setup.sh"
        guard fileManager.isReadableFile(atPath: setup) else { return agentCommand }
        let quote = ShellQuoting.quote
        return "env MOTHERSHIP_REPO_ROOT=\(quote(repoRoot)) MOTHERSHIP_WORKTREE=\(quote(worktree)) /bin/sh \(quote(setup)); \(agentCommand)"
    }

    static func taskTitle(for prompt: String, repoName: String) -> String {
        TitleCleaner.title(fromPrompt: prompt, fallback: repoName) ?? repoName
    }

    static func isOwnWorktree(_ run: TaskRun, of task: AgentTask) -> Bool {
        let resolve = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.path }
        return resolve(run.worktreePath) != resolve(task.repoRoot)
    }

    /// Lists what changed rather than quoting the prompt: prompts can hold private context,
    /// and a PR on a public repo is public.
    static func pullRequestBody(_ task: AgentTask, _ run: TaskRun) -> String {
        var lines = ["Written by \(run.agent.displayName) in a Mothership task."]
        if let diff = run.diff, !diff.isEmpty {
            let files = diff.files.count == 1 ? "1 file" : "\(diff.files.count) files"
            lines.append("")
            lines.append("\(files) changed, +\(diff.insertions) −\(diff.deletions):")
            lines.append("")
            for file in diff.files.prefix(50) {
                lines.append("- `\(file.path)` (+\(file.insertions) −\(file.deletions))")
            }
            if diff.files.count > 50 { lines.append("- …and \(diff.files.count - 50) more") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - QA

/// `MOTHERSHIP_DEBUG_TASK` (scratch `MOTHERSHIP_HOME` only): a script of task steps run at
/// launch, with every result written to `report`. It exercises the backend end to end
/// before the task UI exists:
///
///     {"report": "/tmp/r.json", "steps": [
///       {"start": {"prompt": "…", "repoRoot": "/tmp/repo", "agents": ["fakeagent"], "useWorktrees": true}},
///       {"wait": 5}, {"diff": 0}, {"keep": 0, "mode": "mergeIntoBase"}, {"discard": 1}]}
///
/// Run indices count runs across all tasks started so far.
struct DebugTaskScript: Codable {
    struct Start: Codable {
        var prompt: String
        var repoRoot: String
        var baseBranch: String?
        var agents: [String]
        var useWorktrees: Bool?
    }

    struct Step: Codable {
        var start: Start?
        var wait: Double?
        var diff: Int?
        var fullDiff: Int?
        var keep: Int?
        var mode: KeepMode?
        var discard: Int?
        /// Log the agent session bound to each run's pane.
        var sessions: Bool?
    }

    var report: String
    var steps: [Step]
}

extension AppModel {
    func runDebugTaskScript(_ json: String) {
        guard ProcessInfo.processInfo.environment["MOTHERSHIP_HOME"] != nil,
            let script = try? JSONDecoder().decode(DebugTaskScript.self, from: Data(json.utf8))
        else { return }
        Task { [weak self] in
            var log: [[String: String]] = []
            @MainActor func runID(_ index: Int) -> TaskRun.ID? {
                let runs = self?.tasks.flatMap(\.runs) ?? []
                return runs.indices.contains(index) ? runs[index].id : nil
            }
            for step in script.steps {
                guard let self else { return }
                if let start = step.start {
                    let request = NewTaskRequest(
                        prompt: start.prompt, repoRoot: start.repoRoot, baseBranch: start.baseBranch,
                        agents: start.agents.map(AgentKind.init(rawValue:)), useWorktrees: start.useWorktrees ?? true
                    )
                    do {
                        let task = try await self.startTask(request)
                        log.append(["step": "start", "title": task.title, "base": task.baseBranch, "runs": task.runs.map { "\($0.branch) @ \($0.worktreePath)" }.joined(separator: "; "),
                                    "workspaces": task.runs.compactMap { self.workspace(id: $0.workspaceID)?.name }.joined(separator: "; ")])
                    } catch {
                        log.append(["step": "start", "error": error.localizedDescription])
                    }
                }
                if let seconds = step.wait { try? await Task.sleep(for: .seconds(seconds)) }
                if step.sessions == true {
                    for (index, run) in self.tasks.flatMap(\.runs).enumerated() {
                        let workspace = self.workspace(id: run.workspaceID)
                        let bound = workspace.map { self.sessions(in: $0) } ?? []
                        log.append(["step": "sessions", "run": String(index), "workspace": workspace?.name ?? "closed",
                                    "bound": bound.map { "\($0.kind.rawValue) \($0.state) surface=\($0.surface.map { workspace?.surfaces[$0] != nil ? "pane" : "other" } ?? "nil")" }.joined(separator: "; ")])
                    }
                }
                if let index = step.diff, let id = runID(index) {
                    await self.refreshDiff(for: id)
                    let diff = self.tasks.flatMap(\.runs).first { $0.id == id }?.diff
                    log.append(["step": "diff", "files": diff?.files.map { "\($0.status.rawValue) \($0.path) +\($0.insertions) -\($0.deletions)" }.joined(separator: "; ") ?? "nil"])
                }
                if let index = step.fullDiff, let id = runID(index) {
                    log.append(["step": "fullDiff", "bytes": String(await self.fullDiff(for: id).utf8.count)])
                }
                if let index = step.keep, let id = runID(index) {
                    do {
                        try await self.keepRun(id, mode: step.mode ?? .keepBranch)
                        log.append(["step": "keep", "mode": (step.mode ?? .keepBranch).rawValue, "ok": "true"])
                    } catch {
                        log.append(["step": "keep", "error": error.localizedDescription])
                    }
                }
                if let index = step.discard, let id = runID(index) {
                    let path = self.tasks.flatMap(\.runs).first { $0.id == id }?.worktreePath ?? ""
                    do {
                        try await self.discardRun(id)
                        log.append(["step": "discard", "ok": "true", "worktreeExists": String(FileManager.default.fileExists(atPath: path))])
                    } catch {
                        log.append(["step": "discard", "error": error.localizedDescription])
                    }
                }
            }
            let outcomes = self?.tasks.flatMap(\.runs).map { "\($0.branch)=\($0.outcome.rawValue)" }.joined(separator: "; ") ?? ""
            log.append(["step": "end", "outcomes": outcomes, "tasksFile": TaskStore.url.path])
            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: script.report))
            }
        }
    }
}
