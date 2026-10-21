import Foundation

/// Pure parsers for git's machine-readable output (`-z` forms, so any path is safe).
enum GitParsing {
    /// `git diff --numstat -z -M`: `ins\tdel\tpath\0`, or for a rename `ins\tdel\t\0src\0dst\0`.
    /// Binary files report `-`, counted as 0. Keyed by the (new) path.
    static func numstat(_ data: Data) -> [String: (insertions: Int, deletions: Int)] {
        var result: [String: (Int, Int)] = [:]
        var fields = split(data)
        while !fields.isEmpty {
            let head = fields.removeFirst()
            let parts = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let insertions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            var path = String(parts[2])
            if path.isEmpty {
                // Rename: the source and destination follow as their own fields.
                guard fields.count >= 2 else { break }
                fields.removeFirst()
                path = fields.removeFirst()
            }
            result[path] = (insertions, deletions)
        }
        return result
    }

    /// `git diff --name-status -z -M`: `X\0path\0`, or `R100\0src\0dst\0` / `C…`.
    static func nameStatus(_ data: Data) -> [(path: String, status: FileChange.Status)] {
        var result: [(String, FileChange.Status)] = []
        var fields = split(data)
        while !fields.isEmpty {
            let code = fields.removeFirst()
            guard let letter = code.first, !fields.isEmpty else { break }
            switch letter {
            case "R", "C":
                guard fields.count >= 2 else { return result }
                fields.removeFirst()
                result.append((fields.removeFirst(), letter == "R" ? .renamed : .added))
            case "A":
                result.append((fields.removeFirst(), .added))
            case "D":
                result.append((fields.removeFirst(), .deleted))
            default:
                // M, T (type change), U (unmerged), X: all "modified" for a diff stat.
                result.append((fields.removeFirst(), .modified))
            }
        }
        return result
    }

    struct Status: Equatable {
        /// Tracked files with staged or unstaged changes (or conflicts).
        var tracked: [String] = []
        var untracked: [String] = []
    }

    /// `git status --porcelain=v2 -z --untracked-files=all`.
    static func porcelainV2(_ data: Data) -> Status {
        var status = Status()
        var fields = split(data)
        while !fields.isEmpty {
            let entry = fields.removeFirst()
            guard let kind = entry.first else { continue }
            switch kind {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                if let path = field(entry, after: 8) { status.tracked.append(path) }
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path\0origPath
                if let path = field(entry, after: 9) { status.tracked.append(path) }
                if !fields.isEmpty { fields.removeFirst() }
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                if let path = field(entry, after: 10) { status.tracked.append(path) }
            case "?":
                status.untracked.append(String(entry.dropFirst(2)))
            default:
                break  // "!" ignored, "#" headers
            }
        }
        return status
    }

    /// The rest of a space-separated record after `count` fields (paths may contain spaces).
    private static func field(_ entry: String, after count: Int) -> String? {
        let parts = entry.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
        guard parts.count == count + 1 else { return nil }
        return String(parts[count])
    }

    /// NUL-separated fields, without the trailing empty one.
    static func split(_ data: Data) -> [String] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        while fields.last?.isEmpty == true { fields.removeLast() }
        return fields
    }

    /// `git worktree list --porcelain`: blocks of `worktree <path>`, `HEAD <sha>`,
    /// `branch refs/heads/<name>` | `detached`, separated by blank lines.
    static func worktrees(_ text: String) -> [Git.Worktree] {
        var result: [Git.Worktree] = []
        var current: Git.Worktree?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = Git.Worktree(path: String(line.dropFirst("worktree ".count)), branch: nil, head: nil)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = line.dropFirst("branch ".count)
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// `git@github.com:owner/name.git`, `https://github.com/owner/name`, `ssh://git@github.com/owner/name.git`.
    static func gitHubRepo(fromRemote url: String) -> GitHubRepo? {
        var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
            if let at = rest.firstIndex(of: "@"), rest[..<at].contains(where: { $0 == "/" }) == false { rest = String(rest[rest.index(after: at)...]) }
            guard rest.lowercased().hasPrefix("github.com/") || rest.lowercased().hasPrefix("github.com:") else { return nil }
            rest = String(rest.dropFirst("github.com/".count))
        } else if let at = rest.firstIndex(of: "@") {
            // scp-like: git@github.com:owner/name.git
            rest = String(rest[rest.index(after: at)...])
            guard rest.lowercased().hasPrefix("github.com:") else { return nil }
            rest = String(rest.dropFirst("github.com:".count))
        } else {
            return nil
        }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        return GitHubRepo(owner: parts[0], name: name)
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "to", "and", "or", "of", "in", "on", "for", "with", "at", "by", "from", "into", "is", "are", "be",
        "it", "its", "this", "that", "these", "those", "please", "can", "could", "would", "you", "your", "we", "our", "i",
        "me", "my", "let", "lets", "us", "so", "then", "just", "some", "all", "any", "do", "make", "sure", "hey", "hi",
    ]

    /// A short, ref-safe slug: `"Add retries to the uploader!"` → `add-retries-uploader`.
    static func slug(_ text: String, maxWords: Int, maxLength: Int) -> String {
        var cleaned = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        // URLs and paths make poor branch names.
        for pattern in [#"\S+://\S+"#, #"(?:^|\s)[~./]\S*/\S*"#, #"@\S+"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        var words: [String] = []
        for raw in cleaned.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }) {
            let word = String(raw)
            if stopWords.contains(word) { continue }
            words.append(word)
            if words.count == maxWords { break }
        }
        var slug = ""
        for word in words {
            let candidate = slug.isEmpty ? word : slug + "-" + word
            if candidate.count > maxLength {
                if slug.isEmpty { slug = String(word.prefix(maxLength)) }
                break
            }
            slug = candidate
        }
        return slug
    }
}
