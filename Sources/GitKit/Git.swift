import Foundation

public struct GitError: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case gitMissing, notARepository, missingBranch, dirty, conflict, failed, unsafe
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Shells out to `git` (no libgit2). Every call has a timeout, never prompts (no terminal,
/// `BatchMode` ssh) and ignores `GIT_DIR`-style variables inherited from a shell.
public struct Git: Sendable {
    public struct Worktree: Sendable, Equatable {
        public var path: String
        public var branch: String?
        public var head: String?
    }

    public let executable: String?
    let runner: any CommandRunning
    let environment: [String: String]
    public var timeout: Duration

    /// - Parameter environment: Extra variables for every git call (tests pin identity and
    ///   config here).
    public init(
        executable: String? = ExecutableLocator.find("git"), runner: any CommandRunning = ProcessRunner(),
        environment: [String: String] = [:], timeout: Duration = .seconds(30)
    ) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ExecutableLocator.searchPath
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX"] { env[name] = nil }
        env.merge(environment) { _, new in new }
        return env
    }

    @discardableResult
    func git(_ arguments: [String], in directory: String, timeout: Duration? = nil, check: Bool = true) async throws -> CommandResult {
        guard let executable else {
            throw GitError(.gitMissing, "git isn't installed. Install the Xcode Command Line Tools (xcode-select --install).")
        }
        let result: CommandResult
        do {
            result = try await runner.run(executable, arguments, directory: directory, environment: childEnvironment, timeout: timeout ?? self.timeout)
        } catch let error as CommandError {
            throw GitError(.failed, error.localizedDescription)
        }
        if check, !result.succeeded {
            let detail = result.errorLine.isEmpty ? "exit \(result.status)" : result.errorLine
            throw GitError(.failed, "git \(arguments.first ?? "") failed: \(detail)")
        }
        return result
    }

    // MARK: Repository

    /// Root, branch, default branch and GitHub remote of the repo containing `path`.
    public func repoInfo(at path: String) async throws -> RepoInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError(.notARepository, "\(path) doesn't exist.")
        }
        let paths = try await git(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], in: path, check: false)
        let lines = paths.output.split(separator: "\n").map(String.init)
        guard paths.succeeded, lines.count >= 2 else {
            throw GitError(.notARepository, "\(Self.display(path)) isn't a git repository.")
        }
        let top = lines[0]
        let common = lines[1]
        // For a linked worktree the common dir is the main repo's `.git`.
        let root = common.hasSuffix("/.git") ? String(common.dropLast("/.git".count)) : top
        let remote = try await git(["config", "--get", "remote.origin.url"], in: path, check: false)
        return RepoInfo(
            root: root, name: (root as NSString).lastPathComponent, branch: try await currentBranch(in: path),
            defaultBranch: await defaultBranch(in: path),
            github: remote.succeeded ? GitParsing.gitHubRepo(fromRemote: remote.output) : nil
        )
    }

    /// The top of the worktree containing `path` (for a linked worktree, that worktree).
    public func topLevel(of path: String) async throws -> String {
        let result = try await git(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: path, check: false)
        guard result.succeeded else { throw GitError(.notARepository, "\(Self.display(path)) isn't a git repository.") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when HEAD is detached.
    public func currentBranch(in directory: String) async throws -> String? {
        let result = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory, check: false)
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !name.isEmpty ? name : nil
    }

    /// `origin/HEAD`'s branch, else a local `main` or `master`.
    public func defaultBranch(in directory: String) async -> String? {
        if let result = try? await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: directory, check: false),
            result.succeeded
        {
            let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/") { return String(name.dropFirst("origin/".count)) }
        }
        for candidate in ["main", "master"] where await branchExists(candidate, in: directory) { return candidate }
        return nil
    }

    public func branchExists(_ branch: String, in directory: String) async -> Bool {
        (try? await git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: directory, check: false))?.succeeded ?? false
    }

    public func commitExists(_ revision: String, in directory: String) async -> Bool {
        (try? await git(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], in: directory, check: false))?.succeeded ?? false
    }

    func revision(_ revision: String, in directory: String) async throws -> String {
        try await git(["rev-parse", "--verify", "\(revision)^{commit}"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tracked files with uncommitted changes (staged or not), and untracked files.
    public func changes(in directory: String) async throws -> (tracked: [String], untracked: [String]) {
        let status = GitParsing.porcelainV2(try await git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: directory).stdout)
        return (status.tracked, status.untracked)
    }

    /// Local branches, most recently committed first (for a base-branch picker).
    public func branches(in directory: String) async throws -> [String] {
        let result = try await git(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], in: directory)
        return result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func worktrees(in directory: String) async throws -> [Worktree] {
        GitParsing.worktrees(try await git(["worktree", "list", "--porcelain"], in: directory).output)
    }

    public func mergeBase(_ base: String, in directory: String) async -> String? {
        guard let result = try? await git(["merge-base", base, "HEAD"], in: directory, check: false), result.succeeded else { return nil }
        let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    // MARK: Worktrees

    /// `"Add retries to the uploader"` → `add-retries-uploader`; `task` when nothing's left.
    public static func slug(fromPrompt prompt: String) -> String {
        let slug = GitParsing.slug(prompt, maxWords: 4, maxLength: 32)
        return slug.isEmpty ? "task" : slug
    }

    /// `<repo>/../<repo-name>.worktrees`.
    public static func worktreeContainer(forRepository root: String) -> String {
        let url = URL(fileURLWithPath: root)
        return url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".worktrees").path
    }

    /// A branch `mship/<slug>-<agent>` and its worktree path, unique among existing branches,
    /// directories and `taken` names (`-2`, `-3`… as needed).
    public func newRunLocation(prompt: String, agent: String, repository root: String, excluding taken: Set<String> = []) async throws
        -> (branch: String, path: String)
    {
        let agentSlug = GitParsing.slug(agent, maxWords: 2, maxLength: 16)
        let name = Self.slug(fromPrompt: prompt) + (agentSlug.isEmpty ? "" : "-" + agentSlug)
        let container = Self.worktreeContainer(forRepository: root)
        for attempt in 1 ... 99 {
            let candidate = attempt == 1 ? name : "\(name)-\(attempt)"
            let branch = "mship/\(candidate)"
            let path = container + "/" + candidate
            guard !taken.contains(branch), !taken.contains(path), !FileManager.default.fileExists(atPath: path) else { continue }
            guard await !branchExists(branch, in: root) else { continue }
            return (branch, path)
        }
        throw GitError(.failed, "Couldn't find a free branch name for \(name).")
    }

    /// `git worktree add -b <branch> <path> <base>`.
    public func addWorktree(repository root: String, branch: String, path: String, base: String) async throws {
        guard await commitExists(base, in: root) else {
            throw GitError(.missingBranch, "There's no branch '\(base)' in \((root as NSString).lastPathComponent).")
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let result = try await git(["worktree", "add", "-b", branch, path, base], in: root, timeout: .seconds(120), check: false)
        guard result.succeeded else {
            throw GitError(.failed, "Couldn't create a worktree for \(branch): \(result.errorLine)")
        }
    }

    /// Removes a linked worktree (even with uncommitted changes) and deletes its branch.
    /// Never touches the main worktree or a directory git doesn't know as a worktree.
    public func removeWorktree(repository root: String, path: String, branch: String?) async throws {
        let target = Self.resolved(path)
        let known = try await worktrees(in: root)
        if target == Self.resolved(root) || known.first.map({ Self.resolved($0.path) == target }) == true {
            throw GitError(.unsafe, "Refusing to remove the repository's main worktree (\(Self.display(path))).")
        }
        if known.contains(where: { Self.resolved($0.path) == target }) {
            let result = try await git(["worktree", "remove", "--force", "--force", path], in: root, timeout: .seconds(60), check: false)
            guard result.succeeded else { throw GitError(.failed, "Couldn't remove the worktree at \(Self.display(path)): \(result.errorLine)") }
        } else if FileManager.default.fileExists(atPath: path) {
            throw GitError(.unsafe, "\(Self.display(path)) isn't a worktree of this repository; leaving it alone.")
        }
        _ = try? await git(["worktree", "prune"], in: root, check: false)
        if let branch, await branchExists(branch, in: root) {
            try await git(["branch", "-D", branch], in: root)
        }
    }

    // MARK: Diffs

    /// Files changed on the worktree's branch since it left `base`: commits, staged and
    /// unstaged edits, and untracked files.
    public func diffStat(in worktree: String, base: String) async throws -> DiffStat {
        let from = await mergeBase(base, in: worktree) ?? base
        async let numstat = git(["diff", "--numstat", "-z", "-M", "--no-ext-diff", from], in: worktree)
        async let names = git(["diff", "--name-status", "-z", "-M", "--no-ext-diff", from], in: worktree)
        async let status = git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: worktree)
        let counts = GitParsing.numstat(try await numstat.stdout)
        var files: [FileChange] = GitParsing.nameStatus(try await names.stdout).map { entry in
            let count = counts[entry.path]
            return FileChange(path: entry.path, status: entry.status, insertions: count?.insertions ?? 0, deletions: count?.deletions ?? 0)
        }
        let listed = Set(files.map(\.path))
        for path in GitParsing.porcelainV2(try await status.stdout).untracked where !listed.contains(path) {
            let lines = Self.lineCount(ofFileAt: (worktree as NSString).appendingPathComponent(path))
            files.append(FileChange(path: path, status: .untracked, insertions: lines, deletions: 0))
        }
        return DiffStat(files: files.sorted { $0.path < $1.path })
    }

    /// Unified diff of the worktree against where it left `base`, untracked files included
    /// (as new files). Capped at `limit` bytes.
    public func fullDiff(in worktree: String, base: String, limit: Int = 4 << 20) async throws -> String {
        let from = await mergeBase(base, in: worktree) ?? base
        var text = try await git(["diff", "-M", "--no-color", "--no-ext-diff", from], in: worktree, timeout: .seconds(60)).output
        let untracked = GitParsing.porcelainV2(try await git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: worktree).stdout).untracked
        for (index, path) in untracked.enumerated() {
            if text.utf8.count >= limit { break }
            if index == 200 {
                text += "# … \(untracked.count - 200) more untracked files not shown\n"
                break
            }
            let full = (worktree as NSString).appendingPathComponent(path)
            let size = ((try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.intValue ?? 0
            if size > 1 << 20 {
                text += "# \(path): untracked, \(size / 1024) KB, not shown\n"
                continue
            }
            // `--no-index` exits 1 when the files differ, which is the point.
            let result = try await git(["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", path], in: worktree, check: false)
            if result.status <= 1 { text += result.output }
        }
        guard text.utf8.count > limit else { return text }
        let clipped = String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self)
        let cut = clipped.lastIndex(of: "\n").map { String(clipped[...$0]) } ?? clipped
        return cut + "# … diff truncated at \(limit / 1024) KB\n"
    }

    static func lineCount(ofFileAt path: String) -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2 << 20), !data.isEmpty else { return 0 }
        if data.prefix(8000).contains(0) { return 0 }  // binary
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    // MARK: Keeping work

    /// Stages everything and commits it. False when there was nothing to commit.
    @discardableResult
    public func commitAll(in worktree: String, message: String) async throws -> Bool {
        try await git(["add", "-A"], in: worktree, timeout: .seconds(60))
        let staged = try await git(["diff", "--cached", "--quiet"], in: worktree, check: false)
        guard staged.status == 1 else { return false }
        let result = try await git(["commit", "-q", "-m", message], in: worktree, timeout: .seconds(120), check: false)
        guard result.succeeded else {
            if result.stderr.contains("Please tell me who you are") || result.stderr.contains("user.email") {
                throw GitError(.failed, "git doesn't know who you are. Set user.name and user.email (git config --global user.email you@example.com).")
            }
            throw GitError(.failed, "Committing the run's changes failed: \(result.errorLine)")
        }
        return true
    }

    /// Merges `branch` into `base` where `base` is checked out (it must be clean there). When
    /// `base` isn't checked out anywhere, only a fast-forward is possible.
    public func merge(branch: String, into base: String, repository root: String, message: String) async throws {
        if let tree = try await worktrees(in: root).first(where: { $0.branch == base }) {
            guard try await changes(in: tree.path).tracked.isEmpty else {
                throw GitError(.dirty, "\(Self.display(tree.path)) has uncommitted changes. Commit or stash them before merging into \(base).")
            }
            let result = try await git(["merge", "--no-ff", "--no-edit", "-m", message, branch], in: tree.path, timeout: .seconds(120), check: false)
            guard result.succeeded else {
                let conflicted = result.output.contains("CONFLICT")
                _ = try? await git(["merge", "--abort"], in: tree.path, check: false)
                if conflicted {
                    throw GitError(.conflict, "\(branch) conflicts with \(base). Merge \(base) into the run's worktree, resolve, and keep it again.")
                }
                throw GitError(.failed, "Merging \(branch) into \(base) failed: \(result.errorLine)")
            }
            return
        }
        let ancestor = try await git(["merge-base", "--is-ancestor", base, branch], in: root, check: false)
        guard ancestor.status == 0 else {
            throw GitError(.failed, "\(base) isn't checked out, so only a fast-forward is possible, and \(branch) has diverged from it. Check out \(base) and keep the run again.")
        }
        let new = try await revision(branch, in: root)
        let old = try await revision(base, in: root)
        try await git(["update-ref", "-m", message, "refs/heads/\(base)", new, old], in: root)
    }

    public func push(branch: String, in directory: String, remote: String = "origin") async throws {
        let result = try await git(["push", "--set-upstream", remote, branch], in: directory, timeout: .seconds(120), check: false)
        guard result.succeeded else { throw GitError(.failed, "Pushing \(branch) failed: \(result.errorLine)") }
    }

    // MARK: Helpers

    /// The real path (`/var` → `/private/var`), as git reports it; standardized when missing.
    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }

    static func display(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
