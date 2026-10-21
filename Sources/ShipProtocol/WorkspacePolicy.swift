import Foundation

// Pure decisions behind workspace names, project folders and the quit prompt. The app target
// has no test target, so they live here where ControlPlaneTests can pin them down.

/// Sidebar names: meaningful and unique.
public enum WorkspaceNaming {
    /// Longest automatic name taken from an agent's session title.
    public static let maxTitleLength = 48

    /// The automatic name before de-duplication: the live agent's session title if there is
    /// one, else the git repo name, else the folder name ("Home" for `$HOME`).
    public static func baseName(directory: String, repoName: String?, agentTitle: String?, home: String) -> String {
        if let title = cleanTitle(agentTitle) { return title }
        let directory = trimmedPath(directory)
        let home = trimmedPath(home)
        if directory == home { return "Home" }
        if let repoName, !repoName.isEmpty { return repoName }
        if directory == "/" || directory.isEmpty { return "Root" }
        return (directory as NSString).lastPathComponent
    }

    public struct Entry: Sendable, Equatable {
        public var base: String
        /// The user named it; never changed or suffixed.
        public var isCustom: Bool

        public init(base: String, isCustom: Bool) {
            self.base = base
            self.isCustom = isCustom
        }
    }

    /// Final names in `entries` order (oldest workspace first, so it keeps the plain name).
    /// Automatic names that collide with an earlier or a custom name get " 2", " 3", …
    /// Comparison ignores case ("API" and "api" would read as duplicates).
    public static func uniqueNames(_ entries: [Entry]) -> [String] {
        var taken = Set(entries.filter(\.isCustom).map { $0.base.lowercased() })
        return entries.map { entry in
            if entry.isCustom { return entry.base }
            var candidate = entry.base
            var number = 2
            while taken.contains(candidate.lowercased()) {
                candidate = "\(entry.base) \(number)"
                number += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    /// One line, trimmed, bounded; nil when there's nothing worth showing.
    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxTitleLength else { return collapsed }
        return String(collapsed.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func trimmedPath(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Where agents start. Never `$HOME` without the user choosing it: agents ask to trust the
/// whole folder they start in, and a home folder is everything.
public enum ProjectFolders {
    public struct Candidate: Sendable, Equatable {
        public var path: String
        public var lastUsed: Date

        public init(path: String, lastUsed: Date) {
            self.path = path
            self.lastUsed = lastUsed
        }
    }

    /// A folder an agent may start in without asking: not `$HOME`, `/`, or anything above home.
    public static func isProject(_ path: String, home: String) -> Bool {
        let path = WorkspaceNaming.trimmedPath(path)
        let home = WorkspaceNaming.trimmedPath(home)
        guard !path.isEmpty, path != "/", path != home else { return false }
        return !(home + "/").hasPrefix(path + "/")
    }

    /// Distinct project folders, most recently used first.
    public static func recent(
        _ candidates: [Candidate], home: String, limit: Int = 8, exists: (String) -> Bool
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in candidates.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            let path = WorkspaceNaming.trimmedPath(candidate.path)
            guard isProject(path, home: home), seen.insert(path).inserted, exists(path) else { continue }
            result.append(path)
            if result.count == limit { break }
        }
        return result
    }

    /// "Start a task" and ⌘T: the focused workspace's folder when it's a project, else the
    /// most recent project; nil means ask.
    public static func taskDirectory(focused: String?, recent: [String], home: String) -> String? {
        if let focused, isProject(focused, home: home) { return WorkspaceNaming.trimmedPath(focused) }
        return recent.first
    }
}

/// The quit confirmation's wording.
public enum QuitSummary {
    /// "2 agents and 1 command are still running." Nil when nothing is running.
    public static func sentence(agents: Int, commands: Int) -> String? {
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) agent\(agents == 1 ? "" : "s")") }
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return nil }
        let verb = agents + commands == 1 ? "is" : "are"
        return parts.joined(separator: " and ") + " \(verb) still running."
    }
}
