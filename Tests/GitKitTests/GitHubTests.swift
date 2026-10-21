import Foundation
import Synchronization
import Testing

@testable import GitKit

/// Records every command and answers from a script; never runs anything.
final class FakeRunner: CommandRunning {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var directory: String?
    }

    private let state = Mutex<(calls: [Call], replies: [CommandResult])>(([], []))
    let fallback: CommandResult

    init(replies: [CommandResult] = [], fallback: CommandResult = CommandResult(status: 0)) {
        self.fallback = fallback
        state.withLock { $0.replies = replies }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func run(_ executable: String, _ arguments: [String], directory: String?, environment: [String: String], timeout: Duration) async throws
        -> CommandResult
    {
        state.withLock { state in
            state.calls.append(Call(executable: executable, arguments: arguments, directory: directory))
            return state.replies.isEmpty ? fallback : state.replies.removeFirst()
        }
    }
}

/// A scripted `gh`: counts calls, can be logged out, can fail.
final class FakeGitHub: GitHubCLI {
    private let state = Mutex<(available: Bool, fail: Bool, calls: [String], prs: [String: [PullRequestStatus]], delay: Duration)>(
        (true, false, [], [:], .zero)
    )

    var calls: [String] { state.withLock { $0.calls } }
    func set(available: Bool) { state.withLock { $0.available = available } }
    func set(failing: Bool) { state.withLock { $0.fail = failing } }
    func set(delay: Duration) { state.withLock { $0.delay = delay } }
    func set(_ branch: String, _ prs: [PullRequestStatus]) { state.withLock { $0.prs[branch] = prs } }

    func isAvailable() async -> Bool { state.withLock { $0.available } }

    func pullRequests(head branch: String, in directory: String) async throws -> [PullRequestStatus] {
        let (delay, fail, prs) = state.withLock { state in
            state.calls.append("list \(branch)")
            return (state.delay, state.fail, state.prs[branch] ?? [])
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if fail { throw GitError(.failed, "network") }
        return prs
    }

    func createPullRequest(head: String, base: String, title: String, body: String, in directory: String) async throws -> String {
        state.withLock { $0.calls.append("create \(head)→\(base): \(title)") }
        return "https://github.com/acme/widgets/pull/7"
    }
}

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func pr(_ number: Int, _ state: PullRequestStatus.State = .open) -> PullRequestStatus {
    PullRequestStatus(number: number, title: "PR \(number)", url: "https://github.com/acme/widgets/pull/\(number)", state: state, checks: .none, review: .none)
}

@Suite("GitHub CLI")
struct GitHubCLITests {
    static let listJSON = #"""
    [
      {"number": 12, "title": "Add retries", "url": "https://github.com/acme/widgets/pull/12", "state": "OPEN", "isDraft": false,
       "reviewDecision": "APPROVED",
       "statusCheckRollup": [
         {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"},
         {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SKIPPED"},
         {"__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS"}
       ]},
      {"number": 11, "title": "Draft idea", "url": "https://github.com/acme/widgets/pull/11", "state": "OPEN", "isDraft": true,
       "reviewDecision": "", "statusCheckRollup": [{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]},
      {"number": 9, "title": "Old", "url": "https://github.com/acme/widgets/pull/9", "state": "MERGED", "isDraft": false,
       "reviewDecision": "CHANGES_REQUESTED", "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "FAILURE"}]},
      {"number": 8, "state": "CLOSED", "reviewDecision": "REVIEW_REQUIRED", "statusCheckRollup": [{"state": "ERROR"}], "extra": {"ignored": 1}},
      {"number": 7, "state": "SOMETHING_NEW", "statusCheckRollup": null}
    ]
    """#

    @Test func decodesStatesChecksAndReviews() throws {
        let prs = try GHClient.decodePullRequests(Data(Self.listJSON.utf8))
        #expect(prs.map(\.number) == [12, 11, 9, 8, 7])
        #expect(prs.map(\.state) == [.open, .draft, .merged, .closed, .open])
        #expect(prs.map(\.checks) == [.passing, .pending, .failing, .failing, .none])
        #expect(prs.map(\.review) == [.approved, .none, .changesRequested, .reviewRequired, .none])
        #expect(prs[0].title == "Add retries")
        #expect(prs[3].title == "")
        #expect(throws: (any Error).self) { try GHClient.decodePullRequests(Data("{not json".utf8)) }
        #expect(try GHClient.decodePullRequests(Data("[]".utf8)).isEmpty)
    }

    @Test func pendingStatusContextAndFailureWinOrder() {
        typealias Check = GHClient.Check
        #expect(GHClient.checks([Check(status: "COMPLETED", conclusion: "SUCCESS"), Check(state: "PENDING")]) == .pending)
        #expect(GHClient.checks([Check(state: "PENDING"), Check(status: "COMPLETED", conclusion: "TIMED_OUT")]) == .failing)
        #expect(GHClient.checks([Check(status: "COMPLETED", conclusion: "CANCELLED")]) == .passing)
        #expect(GHClient.checks([Check(status: "QUEUED")]) == .pending)
        #expect(GHClient.checks([]) == .none)
    }

    @Test func preferredIsTheNewestOpenPR() {
        #expect(GHClient.preferred([pr(3, .merged), pr(5, .draft), pr(4)])?.number == 5)
        #expect(GHClient.preferred([pr(3, .merged), pr(6, .closed)])?.number == 6)
        #expect(GHClient.preferred([]) == nil)
    }

    @Test func listAndCreateCallGhWithoutPrompts() async throws {
        let runner = FakeRunner(replies: [
            CommandResult(status: 0, stdout: Data(Self.listJSON.utf8)),
            CommandResult(status: 0, stdout: Data("Creating pull request for mship/x into main\n\nhttps://github.com/acme/widgets/pull/13\n".utf8)),
            CommandResult(status: 1, stderr: "You are not logged into any GitHub hosts.\n"),
        ])
        let client = GHClient(executable: "/opt/fake/gh", runner: runner)
        let prs = try await client.pullRequests(head: "mship/x", in: "/repo")
        #expect(prs.count == 5)
        let url = try await client.createPullRequest(head: "mship/x", base: "main", title: "Add retries", body: "Body", in: "/repo/wt")
        #expect(url == "https://github.com/acme/widgets/pull/13")
        #expect(await client.isAvailable() == false)
        let calls = runner.calls
        #expect(calls[0] == .init(
            executable: "/opt/fake/gh",
            arguments: ["pr", "list", "--head", "mship/x", "--state", "all", "--limit", "10", "--json", "number,title,url,state,isDraft,statusCheckRollup,reviewDecision"],
            directory: "/repo"
        ))
        #expect(calls[1].arguments == ["pr", "create", "--head", "mship/x", "--base", "main", "--title", "Add retries", "--body", "Body"])
        #expect(calls[1].directory == "/repo/wt")
        #expect(calls[2].arguments == ["auth", "status", "--hostname", "github.com"])
        #expect(client.environment["GH_PROMPT_DISABLED"] == "1")
    }

    @Test func missingGhIsUnavailable() async {
        let client = GHClient(executable: nil, runner: FakeRunner())
        #expect(await client.isAvailable() == false)
        await #expect(throws: GitError.self) { _ = try await client.pullRequests(head: "x", in: "/repo") }
    }

    @Test func failedListIsAnError() async {
        let client = GHClient(executable: "/opt/fake/gh", runner: FakeRunner(fallback: CommandResult(status: 1, stderr: "HTTP 502\n")))
        do {
            _ = try await client.pullRequests(head: "x", in: "/repo")
            Issue.record("expected an error")
        } catch let error as GitError {
            #expect(error.message.contains("HTTP 502"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("Pull request monitor")
struct PullRequestMonitorTests {
    func make(_ github: FakeGitHub?, clock: TestClock) -> PullRequestMonitor {
        PullRequestMonitor(github: github, refreshInterval: 60, availabilityInterval: 600, now: { clock.now })
    }

    @Test func cachesForSixtySecondsPerBranch() async {
        let github = FakeGitHub()
        github.set("mship/a", [pr(1)])
        github.set("mship/b", [pr(2, .merged)])
        let clock = TestClock()
        let monitor = make(github, clock: clock)
        #expect(await monitor.status(repository: "/repo", branch: "mship/a")?.number == 1)
        clock.advance(30)
        #expect(await monitor.status(repository: "/repo", branch: "mship/a")?.number == 1)
        #expect(github.calls == ["list mship/a"])
        // A different branch (the workspace switched) is fetched at once.
        #expect(await monitor.status(repository: "/repo", branch: "mship/b")?.state == .merged)
        clock.advance(31)
        github.set("mship/a", [pr(1), pr(3)])
        #expect(await monitor.status(repository: "/repo", branch: "mship/a")?.number == 3)
        #expect(github.calls == ["list mship/a", "list mship/b", "list mship/a"])
        #expect(await monitor.cachedStatus(repository: "/repo", branch: "mship/b")?.number == 2)
        // force and invalidate both fetch now.
        _ = await monitor.status(repository: "/repo", branch: "mship/b", force: true)
        await monitor.invalidate(repository: "/repo", branch: "mship/a")
        _ = await monitor.status(repository: "/repo", branch: "mship/a")
        #expect(await monitor.fetches == 5)
    }

    @Test func concurrentRequestsShareOneFetch() async {
        let github = FakeGitHub()
        github.set("mship/a", [pr(1)])
        github.set(delay: .milliseconds(150))
        let monitor = make(github, clock: TestClock())
        async let first = monitor.status(repository: "/repo", branch: "mship/a")
        async let second = monitor.status(repository: "/repo", branch: "mship/a")
        let results = await [first, second]
        #expect(results.map { $0?.number } == [1, 1])
        #expect(github.calls == ["list mship/a"])
    }

    @Test func quietlyOffWithoutGhOrLogin() async {
        let clock = TestClock()
        #expect(await make(nil, clock: clock).status(repository: "/repo", branch: "x") == nil)
        let github = FakeGitHub()
        github.set(available: false)
        github.set("x", [pr(1)])
        let monitor = make(github, clock: clock)
        #expect(await monitor.status(repository: "/repo", branch: "x") == nil)
        #expect(github.calls.isEmpty)
        // Logging in is noticed at the next availability check.
        github.set(available: true)
        #expect(await monitor.status(repository: "/repo", branch: "x") == nil)
        clock.advance(601)
        #expect(await monitor.status(repository: "/repo", branch: "x")?.number == 1)
    }

    @Test func failuresKeepTheLastKnownStatus() async {
        let github = FakeGitHub()
        github.set("x", [pr(4)])
        let clock = TestClock()
        let monitor = make(github, clock: clock)
        #expect(await monitor.status(repository: "/repo", branch: "x")?.number == 4)
        github.set(failing: true)
        clock.advance(61)
        #expect(await monitor.status(repository: "/repo", branch: "x")?.number == 4)
        // A branch without PRs is nil, not an error.
        github.set(failing: false)
        #expect(await monitor.status(repository: "/repo", branch: "none") == nil)
    }
}
