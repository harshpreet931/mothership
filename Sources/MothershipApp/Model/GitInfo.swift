import Foundation

/// Branch and repo name read straight from `.git/HEAD`: a couple of small file reads, no
/// `git` process, so it can run on every directory change.
struct GitInfo: Equatable, Sendable {
    /// Folder that contains `.git` (the worktree root for linked worktrees).
    var root: String
    var repoName: String
    /// Branch name, or a short commit hash when detached.
    var branch: String?
    var isWorktree: Bool

    static func read(at directory: String) -> GitInfo? {
        let fileManager = FileManager.default
        var current = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
        for _ in 0 ..< 64 {
            let dotGit = current.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitInfo(root: current.path, repoName: current.lastPathComponent, branch: readHead(in: dotGit), isWorktree: false)
                }
                // Linked worktree or submodule: `.git` is a file with `gitdir: <path>`.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
                else { return nil }
                var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                if !gitDir.hasPrefix("/") { gitDir = current.appending(path: gitDir).standardizedFileURL.path }
                return GitInfo(
                    root: current.path, repoName: current.lastPathComponent,
                    branch: readHead(in: URL(fileURLWithPath: gitDir)), isWorktree: gitDir.contains("/worktrees/")
                )
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func readHead(in gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let ref = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }
}

enum PathDisplay {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// `/Users/me/code/app` → `~/code/app`.
    static func abbreviated(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Keeps the last components when a path is long: `~/…/mothership/Sources`.
    static func short(_ path: String, maxComponents: Int = 3) -> String {
        let abbreviated = abbreviated(path)
        let parts = abbreviated.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > maxComponents else { return abbreviated }
        let tail = parts.suffix(maxComponents - 1).joined(separator: "/")
        let head = abbreviated.hasPrefix("~") ? "~" : ""
        return head + "/…/" + tail
    }

    static func folderName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return path == home ? "Home" : (name.isEmpty ? path : name)
    }
}
