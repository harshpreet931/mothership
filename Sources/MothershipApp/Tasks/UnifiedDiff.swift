import Foundation

/// `git diff` output parsed into files, hunks and numbered lines for the diff viewer.
struct UnifiedDiff: Equatable, Sendable {
    struct File: Identifiable, Equatable, Sendable {
        enum Change: String, Sendable { case added, deleted, renamed, modified, binary }

        var id: String { path }
        /// The new path (the old one for deletions).
        var path: String
        var oldPath: String?
        var change: Change
        var hunks: [Hunk]

        var insertions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

        /// "M", "A", "D", "R", "B".
        var letter: String {
            switch change {
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .modified: "M"
            case .binary: "B"
            }
        }
    }

    struct Hunk: Identifiable, Equatable, Sendable {
        /// Unique within the diff (file index · hunk index).
        var id: String
        /// The `@@ -a,b +c,d @@ context` line.
        var header: String
        /// What follows the second `@@` (often the enclosing function).
        var context: String
        var lines: [Line]
    }

    struct Line: Identifiable, Equatable, Sendable {
        enum Kind: Sendable { case context, added, removed, note }
        var id: String
        var kind: Kind
        var oldNumber: Int?
        var newNumber: Int?
        var text: String
    }

    var files: [File]

    var insertions: Int { files.reduce(0) { $0 + $1.insertions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    // MARK: Parsing

    static func parse(_ text: String) -> UnifiedDiff {
        var files: [File] = []
        var current: File?
        var hunk: Hunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let finished = current { files.append(finished) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                let paths = gitPaths(line)
                current = File(path: paths.new ?? paths.old ?? "file", oldPath: paths.old, change: .modified, hunks: [])
                continue
            }
            if hunk == nil, current != nil {
                if line.hasPrefix("new file mode") { current?.change = .added; continue }
                if line.hasPrefix("deleted file mode") { current?.change = .deleted; continue }
                if line.hasPrefix("rename from ") { current?.oldPath = String(line.dropFirst("rename from ".count)); current?.change = .renamed; continue }
                if line.hasPrefix("rename to ") { current?.path = String(line.dropFirst("rename to ".count)); current?.change = .renamed; continue }
                if line.hasPrefix("Binary files ") { current?.change = .binary; continue }
                if line.hasPrefix("--- ") {
                    if line == "--- /dev/null" { current?.change = .added }
                    continue
                }
                if line.hasPrefix("+++ ") {
                    if line == "+++ /dev/null" {
                        current?.change = .deleted
                        if let old = current?.oldPath { current?.path = old }
                    } else if let path = stripPrefix(String(line.dropFirst(4))), current?.change != .renamed {
                        current?.path = path
                    }
                    continue
                }
                if line.hasPrefix("index ") || line.hasPrefix("similarity index") || line.hasPrefix("old mode") || line.hasPrefix("new mode") { continue }
            }
            if line.hasPrefix("@@") {
                if current == nil { current = File(path: "changes", oldPath: nil, change: .modified, hunks: []) }
                closeHunk()
                let (old, new, context) = hunkHeader(line)
                oldLine = old
                newLine = new
                let fileIndex = files.count
                let hunkIndex = current?.hunks.count ?? 0
                hunk = Hunk(id: "\(fileIndex).\(hunkIndex)", header: line, context: context, lines: [])
                continue
            }
            guard hunk != nil else { continue }
            let lineID = "\(hunk?.id ?? "").\(hunk?.lines.count ?? 0)"
            if line.hasPrefix("+") {
                hunk?.lines.append(Line(id: lineID, kind: .added, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunk?.lines.append(Line(id: lineID, kind: .removed, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                hunk?.lines.append(Line(id: lineID, kind: .note, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
            } else if line.hasPrefix(" ") || line.isEmpty {
                // An empty line inside a hunk is a blank context line whose space was trimmed.
                if line.isEmpty, raw.endIndex == text.endIndex { continue }
                hunk?.lines.append(Line(id: lineID, kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
        }
        closeFile()
        return UnifiedDiff(files: files)
    }

    /// `diff --git a/x b/y` → (x, y). Handles paths with spaces when both sides match.
    private static func gitPaths(_ line: String) -> (old: String?, new: String?) {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("a/"), let range = rest.range(of: " b/", options: .backwards) {
            return (String(rest[rest.index(rest.startIndex, offsetBy: 2) ..< range.lowerBound]), String(rest[range.upperBound...]))
        }
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first.flatMap(stripPrefix), parts.count > 1 ? stripPrefix(parts[1]) : nil)
    }

    private static func stripPrefix(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if trimmed == "/dev/null" { return nil }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }

    /// `@@ -12,7 +12,9 @@ func limit()` → (12, 12, "func limit()").
    private static func hunkHeader(_ line: String) -> (Int, Int, String) {
        let body = line.dropFirst(2)
        guard let end = body.range(of: "@@") else { return (1, 1, "") }
        let ranges = body[..<end.lowerBound].split(separator: " ")
        func start(_ token: Substring?) -> Int {
            guard let token else { return 1 }
            let digits = token.dropFirst().split(separator: ",").first ?? "1"
            return Int(digits) ?? 1
        }
        let old = start(ranges.first { $0.hasPrefix("-") })
        let new = start(ranges.first { $0.hasPrefix("+") })
        return (old, new, body[end.upperBound...].trimmingCharacters(in: .whitespaces))
    }
}
