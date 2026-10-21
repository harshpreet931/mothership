import Foundation
import Testing

@testable import GitKit

/// A throwaway repository under the temp directory. Git runs with no global or system config
/// and a fixed identity, so tests never read or write the user's git setup.
struct TempRepo {
    let root: String
    let git: Git

    static let environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ]

    init(name: String = "widgets") async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "gitkit-\(UUID().uuidString.prefix(8))")
        let url = base.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // git reports real paths (/private/var/…), so the fixture uses them too.
        root = Git.resolved(url.path)
        git = Git(environment: Self.environment)
        try await run("init", "-q", "-b", "main")
        try write("README.md", "# Widgets\n\nLine two\n")
        try write("src/app.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        try await commit("Initial commit")
    }

    /// The directory holding the repo and its `.worktrees` sibling.
    var parent: String { (root as NSString).deletingLastPathComponent }

    func remove() { try? FileManager.default.removeItem(atPath: parent) }

    @discardableResult
    func run(_ arguments: String..., in directory: String? = nil) async throws -> CommandResult {
        try await git.git(arguments, in: directory ?? root)
    }

    func write(_ path: String, _ text: String, in directory: String? = nil) throws {
        let url = URL(fileURLWithPath: directory ?? root).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func commit(_ message: String, in directory: String? = nil) async throws {
        try await git.git(["add", "-A"], in: directory ?? root)
        try await git.git(["commit", "-q", "-m", message], in: directory ?? root)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

@Suite("Git: repository info")
struct RepoInfoTests {
    @Test func readsRootBranchDefaultAndGitHub() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        try await repo.run("remote", "add", "origin", "git@github.com:acme/widgets.git")
        let info = try await repo.git.repoInfo(at: repo.root + "/src")
        #expect(info.root == repo.root)
        #expect(info.name == "widgets")
        #expect(info.branch == "main")
        #expect(info.defaultBranch == "main")
        #expect(info.github == GitHubRepo(owner: "acme", name: "widgets"))
    }

    @Test func linkedWorktreeBelongsToItsRepo() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = repo.parent + "/widgets.worktrees/feature"
        try await repo.git.addWorktree(repository: repo.root, branch: "feature", path: path, base: "main")
        let info = try await repo.git.repoInfo(at: path)
        #expect(info.root == repo.root)
        #expect(info.branch == "feature")
        #expect(info.github == nil)
        #expect(try await repo.git.topLevel(of: path) == path)
    }

    @Test func notARepositoryIsAClearError() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let git = Git(environment: TempRepo.environment)
        await #expect(throws: GitError.self) { try await git.repoInfo(at: folder.path) }
        do {
            _ = try await git.repoInfo(at: folder.path)
        } catch let error as GitError {
            #expect(error.kind == .notARepository)
            #expect(error.message.contains("isn't a git repository"))
        }
        do {
            _ = try await git.repoInfo(at: folder.path + "/missing")
        } catch let error as GitError {
            #expect(error.kind == .notARepository)
            #expect(error.message.contains("doesn't exist"))
        }
    }

    @Test func branchesNewestFirst() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        try await repo.run("checkout", "-q", "-b", "feature/older")
        try await repo.run("checkout", "-q", "main")
        try await repo.run("checkout", "-q", "-b", "newest")
        try repo.write("new.txt", "new\n")
        try await repo.run("add", "-A")
        // Committer dates have one-second resolution: make "newest" clearly newer.
        _ = try await Git(environment: TempRepo.environment.merging(["GIT_COMMITTER_DATE": "2099-01-01T00:00:00"]) { $1 })
            .git(["commit", "-q", "-m", "Newest"], in: repo.root)
        let branches = try await repo.git.branches(in: repo.root)
        #expect(branches.first == "newest")
        #expect(Set(branches) == ["main", "feature/older", "newest"])
    }

    @Test func detachedHeadHasNoBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        try await repo.run("checkout", "-q", "--detach")
        #expect(try await repo.git.currentBranch(in: repo.root) == nil)
    }

    @Test func gitHubRemoteForms() {
        let expected = GitHubRepo(owner: "acme", name: "widgets")
        for url in [
            "git@github.com:acme/widgets.git", "https://github.com/acme/widgets", "https://github.com/acme/widgets.git",
            "ssh://git@github.com/acme/widgets.git", "https://user@github.com/acme/widgets/", "  git@github.com:acme/widgets\n",
        ] {
            #expect(GitParsing.gitHubRepo(fromRemote: url) == expected, "\(url)")
        }
        for url in ["git@gitlab.com:acme/widgets.git", "https://example.com/acme/widgets", "/srv/git/widgets.git", "github.com", ""] {
            #expect(GitParsing.gitHubRepo(fromRemote: url) == nil, "\(url)")
        }
    }
}

@Suite("Git: branches and worktrees")
struct WorktreeTests {
    @Test func slugsArePromptWordsWithoutFiller() {
        #expect(Git.slug(fromPrompt: "Add retries to the uploader!") == "add-retries-uploader")
        #expect(Git.slug(fromPrompt: "Please fix the login bug in Safari, it crashes on submit") == "fix-login-bug-safari")
        #expect(Git.slug(fromPrompt: "Résumé parser: handle émoji 🎉 names") == "resume-parser-handle-emoji")
        #expect(Git.slug(fromPrompt: "look at https://github.com/acme/widgets/issues/12 and ~/code/app/main.swift") == "look")
        #expect(Git.slug(fromPrompt: "   ") == "task")
        #expect(Git.slug(fromPrompt: "🎉🎉") == "task")
        #expect(Git.slug(fromPrompt: String(repeating: "supercalifragilistic ", count: 5)).count <= 32)
    }

    @Test func runLocationsAreUnique() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let first = try await repo.git.newRunLocation(prompt: "Add retries to the uploader", agent: "claude", repository: repo.root)
        #expect(first.branch == "mship/add-retries-uploader-claude")
        #expect(first.path == repo.parent + "/widgets.worktrees/add-retries-uploader-claude")
        try await repo.git.addWorktree(repository: repo.root, branch: first.branch, path: first.path, base: "main")
        let second = try await repo.git.newRunLocation(prompt: "Add retries to the uploader", agent: "claude", repository: repo.root)
        #expect(second.branch == "mship/add-retries-uploader-claude-2")
        let third = try await repo.git.newRunLocation(
            prompt: "Add retries to the uploader", agent: "claude", repository: repo.root, excluding: [second.branch]
        )
        #expect(third.branch == "mship/add-retries-uploader-claude-3")
        // A leftover directory also counts as taken.
        try FileManager.default.createDirectory(atPath: repo.parent + "/widgets.worktrees/fix-codex", withIntermediateDirectories: true)
        #expect(try await repo.git.newRunLocation(prompt: "fix", agent: "codex", repository: repo.root).branch == "mship/fix-codex-2")
    }

    @Test func addWorktreeChecksTheBase() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = repo.parent + "/widgets.worktrees/x"
        do {
            try await repo.git.addWorktree(repository: repo.root, branch: "mship/x", path: path, base: "nope")
            Issue.record("expected an error")
        } catch let error as GitError {
            #expect(error.kind == .missingBranch)
        }
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/x", path: path, base: "main")
        #expect(repo.exists(path + "/README.md"))
        #expect(try await repo.git.currentBranch(in: path) == "mship/x")
        // Same branch again fails cleanly.
        await #expect(throws: GitError.self) {
            try await repo.git.addWorktree(repository: repo.root, branch: "mship/x", path: path + "-2", base: "main")
        }
    }

    @Test func removeWorktreeDeletesDirectoryAndBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = repo.parent + "/widgets.worktrees/gone"
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/gone", path: path, base: "main")
        try repo.write("scratch.txt", "uncommitted\n", in: path)
        try repo.write("README.md", "edited\n", in: path)
        try await repo.git.removeWorktree(repository: repo.root, path: path, branch: "mship/gone")
        #expect(!repo.exists(path))
        #expect(await repo.git.branchExists("mship/gone", in: repo.root) == false)
        // Already gone: still fine (prunes, branch already deleted).
        try await repo.git.removeWorktree(repository: repo.root, path: path, branch: "mship/gone")
    }

    @Test func removeWorktreeNeverTouchesTheMainWorktreeOrStrangers() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        do {
            try await repo.git.removeWorktree(repository: repo.root, path: repo.root, branch: "main")
            Issue.record("expected a refusal")
        } catch let error as GitError {
            #expect(error.kind == .unsafe)
        }
        #expect(repo.exists(repo.root + "/README.md"))
        #expect(await repo.git.branchExists("main", in: repo.root))
        let stranger = repo.parent + "/widgets.worktrees/not-a-worktree"
        try FileManager.default.createDirectory(atPath: stranger, withIntermediateDirectories: true)
        try "keep me".write(toFile: stranger + "/file.txt", atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) {
            try await repo.git.removeWorktree(repository: repo.root, path: stranger, branch: nil)
        }
        #expect(repo.exists(stranger + "/file.txt"))
    }
}

@Suite("Git: diffs")
struct DiffTests {
    /// A run worktree with one commit and assorted uncommitted work.
    func makeRun(_ repo: TempRepo) async throws -> String {
        let path = repo.parent + "/widgets.worktrees/run"
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/run", path: path, base: "main")
        try repo.write("src/feature.swift", "func feature() {}\n", in: path)
        try await repo.commit("Add feature", in: path)
        // Uncommitted: an edit, a deletion, a rename, an untracked file, a binary.
        try repo.write("src/app.swift", "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\n", in: path)
        try FileManager.default.removeItem(atPath: path + "/README.md")
        try await repo.run("mv", "src/feature.swift", "src/features.swift", in: path)
        try repo.write("notes/todo.md", "one\ntwo\nthree", in: path)
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: path + "/logo.bin"))
        // Meanwhile main moves on; the diff is against where the run started.
        try repo.write("CHANGELOG.md", "main only\n")
        try await repo.commit("Main moves")
        return path
    }

    @Test func diffStatCoversCommitsEditsAndUntrackedFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = try await makeRun(repo)
        let stat = try await repo.git.diffStat(in: path, base: "main")
        let byPath = Dictionary(uniqueKeysWithValues: stat.files.map { ($0.path, $0) })
        #expect(byPath["src/app.swift"]?.status == .modified)
        #expect(byPath["src/app.swift"]?.insertions == 2)
        #expect(byPath["src/app.swift"]?.deletions == 1)
        #expect(byPath["README.md"]?.status == .deleted)
        #expect(byPath["README.md"]?.deletions == 3)
        #expect(byPath["src/features.swift"]?.status == .added)
        #expect(byPath["notes/todo.md"] == FileChange(path: "notes/todo.md", status: .untracked, insertions: 3, deletions: 0))
        #expect(byPath["logo.bin"]?.insertions == 0)
        #expect(byPath["CHANGELOG.md"] == nil)
        #expect(stat.files.map(\.path) == stat.files.map(\.path).sorted())
        #expect(stat.insertions == stat.files.reduce(0) { $0 + $1.insertions })
    }

    @Test func renamesAreReportedOnce() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = repo.parent + "/widgets.worktrees/rename"
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/rename", path: path, base: "main")
        try await repo.run("mv", "src/app.swift", "src/main.swift", in: path)
        try await repo.commit("Rename", in: path)
        let stat = try await repo.git.diffStat(in: path, base: "main")
        #expect(stat.files == [FileChange(path: "src/main.swift", status: .renamed, insertions: 0, deletions: 0)])
    }

    @Test func cleanRunHasAnEmptyDiff() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = repo.parent + "/widgets.worktrees/clean"
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/clean", path: path, base: "main")
        #expect(try await repo.git.diffStat(in: path, base: "main").isEmpty)
        #expect(try await repo.git.fullDiff(in: path, base: "main").isEmpty)
    }

    @Test func fullDiffIncludesUntrackedFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = try await makeRun(repo)
        let diff = try await repo.git.fullDiff(in: path, base: "main")
        #expect(diff.contains("diff --git a/src/app.swift b/src/app.swift"))
        #expect(diff.contains("+let b = 20"))
        #expect(diff.contains("deleted file mode"))
        #expect(diff.contains("b/notes/todo.md"))
        #expect(diff.contains("+three"))
        #expect(!diff.contains("CHANGELOG"))
        let clipped = try await repo.git.fullDiff(in: path, base: "main", limit: 200)
        #expect(clipped.hasSuffix("# … diff truncated at 0 KB\n"))
    }

    @Test func parsersHandleOddPaths() {
        let numstat = Data("1\t2\tplain.txt\0-\t-\tbin.png\0" .utf8) + Data("3\t0\t\0old name.txt\0new name.txt\0".utf8)
        let counts = GitParsing.numstat(numstat)
        #expect(counts["plain.txt"]?.insertions == 1)
        #expect(counts["bin.png"]?.insertions == 0)
        #expect(counts["new name.txt"]?.insertions == 3)
        let names = GitParsing.nameStatus(Data("M\0a b.txt\0R087\0x.txt\0y.txt\0D\0gone\0A\0new\0T\0link\0".utf8))
        #expect(names.map(\.path) == ["a b.txt", "y.txt", "gone", "new", "link"])
        #expect(names.map(\.status) == [.modified, .renamed, .deleted, .added, .modified])
        let status = GitParsing.porcelainV2(Data(
            ("1 .M N... 100644 100644 100644 abc def src/with space.swift\0"
                + "2 R. N... 100644 100644 100644 abc def R100 to.txt\0from.txt\0"
                + "u UU N... 100644 100644 100644 100644 a b c conflict.txt\0"
                + "? new file.txt\0! ignored.log\0").utf8
        ))
        #expect(status.tracked == ["src/with space.swift", "to.txt", "conflict.txt"])
        #expect(status.untracked == ["new file.txt"])
        #expect(GitParsing.numstat(Data()).isEmpty)
        #expect(GitParsing.porcelainV2(Data("garbage\0\0".utf8)) == GitParsing.Status())
    }
}

@Suite("Git: keeping work")
struct KeepTests {
    func runWithCommit(_ repo: TempRepo, name: String = "keep") async throws -> String {
        let path = repo.parent + "/widgets.worktrees/\(name)"
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/\(name)", path: path, base: "main")
        try repo.write("src/kept.swift", "let kept = true\n", in: path)
        return path
    }

    @Test func commitAllCommitsOnlyWhenThereIsWork() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = try await runWithCommit(repo)
        #expect(try await repo.git.commitAll(in: path, message: "Keep it"))
        #expect(try await repo.git.changes(in: path).untracked.isEmpty)
        #expect(try await repo.git.commitAll(in: path, message: "Nothing") == false)
    }

    @Test func mergeIntoCheckedOutBase() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = try await runWithCommit(repo)
        try await repo.git.commitAll(in: path, message: "Keep it")
        try await repo.git.merge(branch: "mship/keep", into: "main", repository: repo.root, message: "Merge mship/keep")
        #expect(repo.exists(repo.root + "/src/kept.swift"))
        let log = try await repo.run("log", "--oneline", "-1").output
        #expect(log.contains("Merge mship/keep"))
    }

    @Test func mergeRefusesADirtyBase() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = try await runWithCommit(repo)
        try await repo.git.commitAll(in: path, message: "Keep it")
        try repo.write("README.md", "local edit\n")
        do {
            try await repo.git.merge(branch: "mship/keep", into: "main", repository: repo.root, message: "Merge")
            Issue.record("expected an error")
        } catch let error as GitError {
            #expect(error.kind == .dirty)
        }
        #expect(!repo.exists(repo.root + "/src/kept.swift"))
    }

    @Test func conflictsAbortTheMerge() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let path = try await runWithCommit(repo)
        try repo.write("README.md", "run's version\n", in: path)
        try await repo.git.commitAll(in: path, message: "Run edit")
        try repo.write("README.md", "main's version\n")
        try await repo.commit("Main edit")
        do {
            try await repo.git.merge(branch: "mship/keep", into: "main", repository: repo.root, message: "Merge")
            Issue.record("expected a conflict")
        } catch let error as GitError {
            #expect(error.kind == .conflict)
        }
        // Aborted: main is clean and unchanged.
        #expect(try await repo.git.changes(in: repo.root).tracked.isEmpty)
        #expect(try String(contentsOfFile: repo.root + "/README.md", encoding: .utf8) == "main's version\n")
    }

    @Test func baseNotCheckedOutFastForwards() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        try await repo.run("branch", "release")
        let path = repo.parent + "/widgets.worktrees/ff"
        try await repo.git.addWorktree(repository: repo.root, branch: "mship/ff", path: path, base: "release")
        try repo.write("ff.txt", "ff\n", in: path)
        try await repo.git.commitAll(in: path, message: "FF")
        try await repo.git.merge(branch: "mship/ff", into: "release", repository: repo.root, message: "Fast-forward")
        let release = try await repo.git.revision("release", in: repo.root)
        let run = try await repo.git.revision("mship/ff", in: repo.root)
        #expect(release == run)
    }

    @Test func pushToARemote() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let remote = repo.parent + "/remote.git"
        try await repo.run("init", "-q", "--bare", remote)
        try await repo.run("remote", "add", "origin", remote)
        let path = try await runWithCommit(repo, name: "pushed")
        try await repo.git.commitAll(in: path, message: "Push me")
        try await repo.git.push(branch: "mship/pushed", in: path)
        #expect(await repo.git.branchExists("mship/pushed", in: remote))
        let upstream = try await repo.run("rev-parse", "--abbrev-ref", "mship/pushed@{upstream}", in: path).output
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/mship/pushed")
    }
}

@Suite("Commands")
struct CommandTests {
    @Test func timeoutKillsTheCommand() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner().run("/bin/sleep", ["5"], directory: nil, environment: [:], timeout: .milliseconds(300))
            Issue.record("expected a timeout")
        } catch let error as CommandError {
            #expect(error == .timedOut(command: "sleep 5", seconds: 0))
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func capturesOutputAndStatus() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh", ["-c", "printf out; printf 'err\\nmore' >&2; exit 3"], directory: "/tmp", environment: [:], timeout: .seconds(5)
        )
        #expect(result.status == 3)
        #expect(result.output == "out")
        #expect(result.errorLine == "err")
        await #expect(throws: CommandError.self) {
            _ = try await ProcessRunner().run("/nonexistent/tool", [], directory: nil, environment: [:], timeout: .seconds(1))
        }
    }

    @Test func missingGitIsAClearError() async {
        let git = Git(executable: nil)
        do {
            _ = try await git.repoInfo(at: "/tmp")
            Issue.record("expected an error")
        } catch let error as GitError {
            #expect(error.kind == .gitMissing)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
