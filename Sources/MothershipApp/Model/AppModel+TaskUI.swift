import AppKit
import GitKit
import ShipModel

/// The New Task sheet's state.
struct NewTaskDraft: Equatable {
    var prompt: String
    var repoRoot: String?
    /// nil = the repo's current branch.
    var baseBranch: String?
    /// In selection order; two or more is Best-of-N.
    var agents: [AgentKind]
    var useWorktrees: Bool
    var error: String?
    var isStarting = false

    var isBestOfN: Bool { agents.count > 1 }
    /// Separate worktrees are forced on for Best-of-N.
    var worktreesForced: Bool { isBestOfN }

    var canStart: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && repoRoot != nil && !agents.isEmpty && !isStarting
    }

    func request() -> NewTaskRequest? {
        guard let repoRoot, canStart else { return nil }
        return NewTaskRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), repoRoot: repoRoot, baseBranch: baseBranch,
            agents: agents, useWorktrees: useWorktrees || worktreesForced
        )
    }
}

/// A task's state at a glance (the sidebar header, Compare).
enum TaskPhase: Equatable {
    case needsYou, working, failed, done, kept

    var label: String {
        switch self {
        case .needsYou: "needs you"
        case .working: "working"
        case .failed: "failed"
        case .done: "done"
        case .kept: "kept"
        }
    }
}

/// Navigation and read-only helpers the task UI uses on top of the task contract
/// (`AppModel+Tasks.swift`).
extension AppModel {
    // MARK: New Task

    /// Agents whose CLI is on this Mac, in a stable order.
    var installedTaskAgents: [AgentKind] {
        let order: [AgentKind] = [.claude, .codex, .opencode, .gemini]
        let present = Set(integrations.filter { $0.executablePath != nil }.map(\.kind))
        return order.filter(present.contains)
    }

    /// Opens New Task, prefilled. The repo defaults to the focused project (or the most
    /// recent one); the agent to the composer's.
    func presentNewTask(prompt: String = "", repo: String? = nil, agents: [AgentKind]? = nil) {
        let installed = installedTaskAgents
        let preferred = agents ?? [composerAgent]
        var chosen = preferred.filter(installed.contains)
        if chosen.isEmpty, let first = installed.first { chosen = [first] }
        let folder = repo ?? taskDirectory()
        let root = folder.map { GitInfo.read(at: $0)?.root ?? $0 }
        isPalettePresented = false
        newTaskDraft = NewTaskDraft(prompt: prompt, repoRoot: root, baseBranch: nil, agents: chosen, useWorktrees: true)
    }

    func dismissNewTask() {
        newTaskDraft = nil
        if screen == .workspaces, let focused = focusedSurface?.id { requestFocus(focused) }
    }

    /// Starts the drafted task; errors stay in the sheet.
    func submitNewTask() {
        guard var draft = newTaskDraft, let request = draft.request() else { return }
        draft.isStarting = true
        draft.error = nil
        newTaskDraft = draft
        Task { [weak self] in
            guard let self else { return }
            do {
                let task = try await self.startTask(request)
                self.newTaskDraft = nil
                self.noteProjectUsed(request.repoRoot)
                if task.runs.count > 1 {
                    self.openCompare(task.id)
                } else if let run = task.runs.first {
                    self.selectWorkspace(run.workspaceID)
                }
            } catch {
                self.newTaskDraft?.isStarting = false
                self.newTaskDraft?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// ⌘⏎ from the composer: start right away with the defaults, or open the sheet when
    /// something's missing (or it fails).
    func quickStartTask(prompt: String, repo: String?) {
        presentNewTask(prompt: prompt, repo: repo)
        if newTaskDraft?.canStart == true { submitNewTask() }
    }

    /// Current branch and local branches of a repo, read from `.git` (no `git` process).
    func branches(in repoRoot: String) -> (current: String?, all: [String]) {
        let current = GitInfo.read(at: repoRoot)?.branch
        return (current, LocalBranches.list(repoRoot: repoRoot))
    }

    // MARK: Lookup

    func task(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    func taskAndRun(_ runID: TaskRun.ID) -> (AgentTask, TaskRun)? {
        for task in tasks {
            if let run = task.runs.first(where: { $0.id == runID }) { return (task, run) }
        }
        return nil
    }

    /// The agent session working on a run (in the run's workspace).
    func session(for run: TaskRun) -> AgentSession? {
        guard let workspace = workspace(id: run.workspaceID) else { return nil }
        let sessions = sessions(in: workspace)
        return sessions.first { $0.kind == run.agent } ?? sessions.first
    }

    func phase(of run: TaskRun) -> TaskPhase {
        if run.outcome == .kept { return .kept }
        guard let session = session(for: run) else { return .done }
        if session.needsYou { return .needsYou }
        if session.state.isError { return .failed }
        if session.state.isWorking { return .working }
        return .done
    }

    func phase(of task: AgentTask) -> TaskPhase {
        let phases = task.runs.filter { $0.outcome != .discarded }.map { phase(of: $0) }
        if phases.contains(.kept) { return .kept }
        for candidate in [TaskPhase.needsYou, .working, .failed] where phases.contains(candidate) { return candidate }
        return .done
    }

    // MARK: Navigation

    func openCompare(_ taskID: UUID) {
        compareTaskID = taskID
        show(.compare)
    }

    func openDiff(_ runID: TaskRun.ID) {
        diffReturnScreen = screen == .diff ? diffReturnScreen : screen
        diffRunID = runID
        show(.diff)
    }

    /// Esc and the ‹ circles: Diff → where it came from, everything else → the panes.
    func goBack() {
        if screen == .diff, diffReturnScreen != .diff, diffReturnScreen != .workspaces {
            show(diffReturnScreen)
        } else {
            show(.workspaces)
        }
    }

    func openRunPane(_ run: TaskRun) {
        selectWorkspace(run.workspaceID)
    }

    /// The run's diff: the backend's, else a demo fixture.
    func diffText(for runID: TaskRun.ID) async -> String {
        let text = await fullDiff(for: runID)
        if text.isEmpty, let fixture = diffFixture?(runID) { return fixture }
        return text
    }

    /// Opens a PR in a browser split beside its workspace.
    func openPullRequest(_ status: PullRequestStatus, in workspaceID: WorkspaceID) {
        guard let url = URL(string: status.url) else { return }
        selectWorkspace(workspaceID)
        openBrowserSplit(url: url)
    }
}

/// Local branch names from `refs/heads` and `packed-refs`.
enum LocalBranches {
    static func list(repoRoot: String) -> [String] {
        let gitDir = URL(fileURLWithPath: (repoRoot as NSString).expandingTildeInPath).appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        var names: Set<String> = []
        let heads = gitDir.appending(path: "refs/heads")
        if let enumerator = FileManager.default.enumerator(at: heads, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.insert(String(url.path.dropFirst(heads.path.count + 1)))
            }
        }
        if let packed = try? String(contentsOf: gitDir.appending(path: "packed-refs"), encoding: .utf8) {
            for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let parts = line.split(separator: " ")
                if parts.count == 2, parts[1].hasPrefix("refs/heads/") { names.insert(String(parts[1].dropFirst("refs/heads/".count))) }
            }
        }
        // Mothership's own run branches aren't bases.
        return names.filter { !$0.hasPrefix("mship/") }.sorted { lhs, rhs in
            let rank = { (name: String) in ["main", "master", "develop", "trunk"].firstIndex(of: name) ?? 99 }
            return rank(lhs) == rank(rhs) ? lhs < rhs : rank(lhs) < rank(rhs)
        }
    }
}
