import Foundation
import Testing
@testable import ShipProtocol

@Suite("Workspace policy")
struct WorkspacePolicyTests {
    let home = "/Users/me"

    // MARK: Naming

    @Test func baseNamePrefersAgentTitleThenRepoThenFolder() {
        #expect(WorkspaceNaming.baseName(directory: "/Users/me/src/api/lib", repoName: "api", agentTitle: "Fix the login bug", home: home) == "Fix the login bug")
        #expect(WorkspaceNaming.baseName(directory: "/Users/me/src/api/lib", repoName: "api", agentTitle: nil, home: home) == "api")
        #expect(WorkspaceNaming.baseName(directory: "/Users/me/notes/", repoName: nil, agentTitle: "  ", home: home) == "notes")
        #expect(WorkspaceNaming.baseName(directory: "/Users/me", repoName: nil, agentTitle: nil, home: home) == "Home")
        #expect(WorkspaceNaming.baseName(directory: "/Users/me/", repoName: "dotfiles", agentTitle: nil, home: home) == "Home")
        #expect(WorkspaceNaming.baseName(directory: "/", repoName: nil, agentTitle: nil, home: home) == "Root")
    }

    @Test func agentTitlesAreOneBoundedLine() {
        let long = String(repeating: "word ", count: 30)
        let name = WorkspaceNaming.baseName(directory: "/x", repoName: nil, agentTitle: long, home: home)
        #expect(name.count == WorkspaceNaming.maxTitleLength)
        #expect(name.hasSuffix("…"))
        #expect(WorkspaceNaming.baseName(directory: "/x", repoName: nil, agentTitle: "Refactor\nauth  middleware", home: home) == "Refactor")
    }

    @Test func duplicatesGetNumbers() {
        let names = WorkspaceNaming.uniqueNames([
            .init(base: "Home", isCustom: false),
            .init(base: "Home", isCustom: false),
            .init(base: "api", isCustom: false),
            .init(base: "Home", isCustom: false),
        ])
        #expect(names == ["Home", "Home 2", "api", "Home 3"])
    }

    @Test func customNamesWinAndAreNeverSuffixed() {
        let names = WorkspaceNaming.uniqueNames([
            .init(base: "api", isCustom: false),
            .init(base: "API", isCustom: true),
            .init(base: "api 2", isCustom: true),
            .init(base: "api", isCustom: false),
        ])
        // The first auto "api" collides (ignoring case) with the custom "API", as does "api 2".
        #expect(names == ["api 3", "API", "api 2", "api 4"])
    }

    @Test func numberingSkipsTakenSuffixes() {
        let names = WorkspaceNaming.uniqueNames([
            .init(base: "web 2", isCustom: false),
            .init(base: "web", isCustom: false),
            .init(base: "web", isCustom: false),
        ])
        #expect(names == ["web 2", "web", "web 3"])
    }

    // MARK: Folders

    @Test func homeAndItsAncestorsAreNotProjects() {
        #expect(!ProjectFolders.isProject("/Users/me", home: home))
        #expect(!ProjectFolders.isProject("/Users/me/", home: home))
        #expect(!ProjectFolders.isProject("/Users", home: home))
        #expect(!ProjectFolders.isProject("/", home: home))
        #expect(ProjectFolders.isProject("/Users/me/src/api", home: home))
        #expect(ProjectFolders.isProject("/tmp/scratch", home: home))
        #expect(ProjectFolders.isProject("/Users/meadow", home: home))  // a sibling, not an ancestor
    }

    @Test func recentProjectsAreDistinctNewestFirstAndExist() {
        let now = Date()
        let candidates = [
            ProjectFolders.Candidate(path: "/Users/me/src/old", lastUsed: now.addingTimeInterval(-500)),
            ProjectFolders.Candidate(path: "/Users/me", lastUsed: now),
            ProjectFolders.Candidate(path: "/Users/me/src/api/", lastUsed: now.addingTimeInterval(-10)),
            ProjectFolders.Candidate(path: "/Users/me/src/api", lastUsed: now.addingTimeInterval(-100)),
            ProjectFolders.Candidate(path: "/Users/me/src/gone", lastUsed: now.addingTimeInterval(-50)),
        ]
        let recent = ProjectFolders.recent(candidates, home: home) { $0 != "/Users/me/src/gone" }
        #expect(recent == ["/Users/me/src/api", "/Users/me/src/old"])
        #expect(ProjectFolders.recent(candidates, home: home, limit: 1) { _ in true } == ["/Users/me/src/api"])
    }

    @Test func taskDirectoryNeverDefaultsToHome() {
        #expect(ProjectFolders.taskDirectory(focused: "/Users/me/src/api", recent: ["/Users/me/src/web"], home: home) == "/Users/me/src/api")
        #expect(ProjectFolders.taskDirectory(focused: "/Users/me", recent: ["/Users/me/src/web"], home: home) == "/Users/me/src/web")
        #expect(ProjectFolders.taskDirectory(focused: nil, recent: ["/Users/me/src/web"], home: home) == "/Users/me/src/web")
        #expect(ProjectFolders.taskDirectory(focused: "/Users/me", recent: [], home: home) == nil)
    }

    // MARK: Quit

    @Test func quitSentence() {
        #expect(QuitSummary.sentence(agents: 0, commands: 0) == nil)
        #expect(QuitSummary.sentence(agents: 1, commands: 0) == "1 agent is still running.")
        #expect(QuitSummary.sentence(agents: 0, commands: 1) == "1 command is still running.")
        #expect(QuitSummary.sentence(agents: 2, commands: 1) == "2 agents and 1 command are still running.")
        #expect(QuitSummary.sentence(agents: 0, commands: 3) == "3 commands are still running.")
    }
}
