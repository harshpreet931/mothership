import Foundation

/// Repository root and branch for a directory, read straight from `.git` (no subprocess).
public struct GitInfo: Sendable, Equatable {
    /// The working tree root (the directory containing `.git`).
    public var repoRoot: String
    /// The resolved git directory (`.git`, or `…/.git/worktrees/<name>` for linked worktrees).
    public var gitDirectory: String
    /// Nil when HEAD is detached.
    public var branch: String?
    /// Set when HEAD is detached.
    public var detachedCommit: String?
    public var isLinkedWorktree: Bool

    public init(repoRoot: String, gitDirectory: String, branch: String?, detachedCommit: String? = nil, isLinkedWorktree: Bool = false) {
        self.repoRoot = repoRoot
        self.gitDirectory = gitDirectory
        self.branch = branch
        self.detachedCommit = detachedCommit
        self.isLinkedWorktree = isLinkedWorktree
    }
}

public enum GitProbe {
    /// Walks up from `directory` to the nearest `.git` (directory, or file with `gitdir:`).
    public static func info(forDirectory directory: String) -> GitInfo? {
        let fileManager = FileManager.default
        var current = (directory as NSString).standardizingPath
        var steps = 0
        while !current.isEmpty, steps < 64 {
            steps += 1
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return read(root: current, gitDirectory: dotGit, linked: false)
                }
                if let gitDir = resolveGitFile(dotGit, relativeTo: current) {
                    return read(root: current, gitDirectory: gitDir, linked: true)
                }
                return nil
            }
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `.git` as a file (worktrees, submodules): `gitdir: <path>`, relative to the file's directory.
    static func resolveGitFile(_ path: String, relativeTo root: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let value = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("/") { return (value as NSString).standardizingPath }
            return ((root as NSString).appendingPathComponent(value) as NSString).standardizingPath
        }
        return nil
    }

    static func read(root: String, gitDirectory: String, linked: Bool) -> GitInfo? {
        let headPath = (gitDirectory as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else {
            return GitInfo(repoRoot: root, gitDirectory: gitDirectory, branch: nil, isLinkedWorktree: linked)
        }
        let (branch, commit) = parseHEAD(head)
        return GitInfo(repoRoot: root, gitDirectory: gitDirectory, branch: branch, detachedCommit: commit, isLinkedWorktree: linked)
    }

    /// `ref: refs/heads/main` → ("main", nil); a bare sha → (nil, sha).
    public static func parseHEAD(_ contents: String) -> (branch: String?, commit: String?) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let ref = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if ref.hasPrefix("refs/heads/") { return (String(ref.dropFirst("refs/heads/".count)), nil) }
            return (ref.isEmpty ? nil : ref, nil)
        }
        return (nil, trimmed.isEmpty ? nil : trimmed)
    }
}
