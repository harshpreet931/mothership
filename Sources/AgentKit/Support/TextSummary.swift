import Foundation

/// Small text helpers shared by adapters: titles from prompts, one-line tool summaries.
public enum TextSummary {
    /// First line of a prompt, collapsed and cut to `limit` characters.
    public static func title(fromPrompt prompt: String, limit: Int = 60) -> String {
        oneLine(cleanPrompt(prompt), limit: limit)
    }

    /// Drops markup agents wrap around pasted content (`<pasted_content id="…">`, `<command-name>`).
    public static func cleanPrompt(_ prompt: String) -> String {
        let stripped = RegexCache.replace("</?[A-Za-z_][A-Za-z0-9_-]*(\\s[^<>]{0,120})?>", in: prompt, with: " ")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? prompt : trimmed
    }

    /// Collapses whitespace and truncates with an ellipsis.
    public static func oneLine(_ text: String, limit: Int = 120) -> String {
        let firstMeaningful = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let collapsed = firstMeaningful.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(1, limit - 1))) + "…"
    }

    /// First `count` words, for sidebar summaries.
    public static func words(_ text: String, count: Int) -> String {
        let parts = cleanPrompt(text).split(whereSeparator: \.isWhitespace)
        let head = parts.prefix(count).joined(separator: " ")
        return parts.count > count ? head + "…" : head
    }

    /// One-line description of a tool call, e.g. the shell command or the file path.
    static func toolSummary(tool: String, input: JSONNode, cwd: String?) -> String {
        func path(_ value: String) -> String { relativePath(value, cwd: cwd) }
        let lowered = tool.lowercased()
        if let command = input["command"].text {
            if lowered == "apply_patch" || command.hasPrefix("*** Begin Patch") {
                return patchSummary(command) ?? oneLine(command)
            }
            return oneLine(command)
        }
        if let commandArray = input["command"].array?.compactMap(\.string), !commandArray.isEmpty {
            return oneLine(commandArray.joined(separator: " "))
        }
        for key in ["file_path", "filePath", "path", "notebook_path", "absolute_path"] {
            if let value = input[key].text { return path(value) }
        }
        for key in ["url", "pattern", "query", "description", "prompt", "subject", "title"] {
            if let value = input[key].text { return oneLine(value) }
        }
        if let patterns = input["patterns"].array?.compactMap(\.text), let first = patterns.first {
            return oneLine(patterns.count > 1 ? "\(first) (+\(patterns.count - 1))" : first)
        }
        if let object = input.object {
            for key in object.keys.sorted() {
                if let value = input[key].text { return oneLine(value) }
            }
        }
        return ""
    }

    /// "Update Sources/Foo.swift (+2 files)" from an apply_patch body.
    static func patchSummary(_ patch: String) -> String? {
        var files: [String] = []
        var verb = "Edit"
        for line in patch.split(whereSeparator: \.isNewline) {
            for (prefix, name) in [("*** Update File: ", "Edit"), ("*** Add File: ", "Add"), ("*** Delete File: ", "Delete")] where line.hasPrefix(prefix) {
                if files.isEmpty { verb = name }
                files.append(String(line.dropFirst(prefix.count)))
            }
        }
        guard let first = files.first else { return nil }
        return files.count > 1 ? "\(verb) \(first) (+\(files.count - 1) files)" : "\(verb) \(first)"
    }

    static func relativePath(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Pretty JSON for an expanded permission view, capped so huge edits stay manageable.
    static func detail(_ input: JSONNode, limit: Int = 4000) -> String? {
        guard input.exists, let text = input.serialized(pretty: true) else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…"
    }

    /// "mcp__github__create_issue" → "github: create_issue".
    static func displayToolName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return tool }
        return "\(parts[0]): \(parts.dropFirst().joined(separator: "__"))"
    }
}
