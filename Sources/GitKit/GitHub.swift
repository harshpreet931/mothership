import Foundation

/// The GitHub operations Mothership needs. `GHClient` shells out to `gh`; tests inject a fake
/// so nothing ever reaches a real account.
public protocol GitHubCLI: Sendable {
    /// `gh` is installed and logged in to github.com.
    func isAvailable() async -> Bool
    /// Pull requests whose head is `branch`, any state, for the repo at `directory`.
    func pullRequests(head branch: String, in directory: String) async throws -> [PullRequestStatus]
    /// Opens a PR and returns its URL.
    func createPullRequest(head: String, base: String, title: String, body: String, in directory: String) async throws -> String
}

public struct GHClient: GitHubCLI {
    public let executable: String?
    let runner: any CommandRunning
    public var timeout: Duration

    public init(executable: String? = ExecutableLocator.find("gh"), runner: any CommandRunning = ProcessRunner(), timeout: Duration = .seconds(20)) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

    static let listFields = "number,title,url,state,isDraft,statusCheckRollup,reviewDecision"

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ExecutableLocator.searchPath
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        for name in ["GIT_DIR", "GIT_WORK_TREE"] { env[name] = nil }
        return env
    }

    func gh(_ arguments: [String], in directory: String?, timeout: Duration? = nil) async throws -> CommandResult {
        guard let executable else { throw GitError(.gitMissing, "The GitHub CLI (gh) isn't installed.") }
        do {
            return try await runner.run(executable, arguments, directory: directory, environment: environment, timeout: timeout ?? self.timeout)
        } catch let error as CommandError {
            throw GitError(.failed, error.localizedDescription)
        }
    }

    public func isAvailable() async -> Bool {
        guard executable != nil else { return false }
        return (try? await gh(["auth", "status", "--hostname", "github.com"], in: nil))?.succeeded ?? false
    }

    public func pullRequests(head branch: String, in directory: String) async throws -> [PullRequestStatus] {
        let result = try await gh(
            ["pr", "list", "--head", branch, "--state", "all", "--limit", "10", "--json", Self.listFields], in: directory
        )
        guard result.succeeded else { throw GitError(.failed, "gh pr list failed: \(result.errorLine)") }
        return try Self.decodePullRequests(result.stdout)
    }

    public func createPullRequest(head: String, base: String, title: String, body: String, in directory: String) async throws -> String {
        let result = try await gh(
            ["pr", "create", "--head", head, "--base", base, "--title", title, "--body", body], in: directory, timeout: .seconds(60)
        )
        guard result.succeeded else { throw GitError(.failed, "gh pr create failed: \(result.errorLine)") }
        // gh prints the new PR's URL last.
        let url = result.output.split(whereSeparator: \.isNewline).last { $0.hasPrefix("https://") }.map(String.init)
        return url ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Decoding

    private struct Item: Decodable {
        var number: Int
        var title: String?
        var url: String?
        var state: String?
        var isDraft: Bool?
        var reviewDecision: String?
        var statusCheckRollup: [Check]?
    }

    /// A CheckRun (`status` + `conclusion`) or a commit StatusContext (`state`).
    struct Check: Decodable {
        var status: String?
        var conclusion: String?
        var state: String?
    }

    /// Unknown or missing fields degrade to `.none`/`.open`; malformed JSON throws.
    static func decodePullRequests(_ data: Data) throws -> [PullRequestStatus] {
        let items = try JSONDecoder().decode([Item].self, from: data)
        return items.map { item in
            let state: PullRequestStatus.State =
                switch item.state?.uppercased() {
                case "MERGED": .merged
                case "CLOSED": .closed
                default: item.isDraft == true ? .draft : .open
                }
            let review: PullRequestStatus.Review =
                switch item.reviewDecision?.uppercased() {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "REVIEW_REQUIRED": .reviewRequired
                default: .none
                }
            return PullRequestStatus(
                number: item.number, title: item.title ?? "", url: item.url ?? "", state: state,
                checks: checks(item.statusCheckRollup ?? []), review: review
            )
        }
    }

    static func checks(_ rollup: [Check]) -> PullRequestStatus.Checks {
        guard !rollup.isEmpty else { return .none }
        var pending = false
        for check in rollup {
            if let state = check.state?.uppercased() {
                // StatusContext
                switch state {
                case "FAILURE", "ERROR": return .failing
                case "PENDING", "EXPECTED": pending = true
                default: break
                }
                continue
            }
            if check.status?.uppercased() != "COMPLETED" {
                pending = true
                continue
            }
            switch check.conclusion?.uppercased() {
            case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failing
            default: break  // SUCCESS, NEUTRAL, SKIPPED, CANCELLED, STALE
            }
        }
        return pending ? .pending : .passing
    }

    /// The PR that represents a branch: the newest open one, else the newest at all.
    public static func preferred(_ pullRequests: [PullRequestStatus]) -> PullRequestStatus? {
        let open = pullRequests.filter { $0.state == .open || $0.state == .draft }
        return (open.isEmpty ? pullRequests : open).max { $0.number < $1.number }
    }
}
