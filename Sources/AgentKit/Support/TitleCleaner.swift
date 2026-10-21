import Foundation

/// Turns raw prompts and assistant replies into short display text for Fleet cards.
public enum TitleCleaner {
    public static let titleLimit = 48
    public static let summaryLimit = 80

    /// A title from a first prompt: drops markdown prefixes, quotes, leading `@file` refs,
    /// paths, URLs and paste placeholders; collapses whitespace; cuts at a word boundary.
    /// Returns `fallback` (e.g. the repo or folder name) when nothing meaningful is left.
    public static func title(fromPrompt prompt: String?, fallback: String? = nil, limit: Int = titleLimit) -> String? {
        if let prompt {
            // The user's own words beat whatever they pasted; pasted text is the second choice.
            if let own = ownWordsTitle(prompt, limit: limit) { return own }
            if let pasted = firstMeaningfulLine(prompt, limit: limit) { return pasted }
        }
        return fallback.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A title from the text outside `<pasted_content>` blocks, or nil if the prompt is all paste.
    public static func ownWordsTitle(_ prompt: String, limit: Int = titleLimit) -> String? {
        let own = RegexCache.replace(#"<pasted_content[^>]*>[\s\S]*?(</pasted_content>|$)"#, in: prompt, with: "\n")
        return firstMeaningfulLine(own, limit: limit)
    }

    static func firstMeaningfulLine(_ text: String, limit: Int) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let cleaned = cleanLine(String(line))
            if isMeaningful(cleaned) { return capitalizedFirst(truncate(cleaned, limit: limit)) }
        }
        return nil
    }

    static func cleanLine(_ line: String) -> String {
        // Tags alone on a line (`<pasted_content id="…">`) leave nothing, which is the point.
        var text = RegexCache.replace(#"</?[A-Za-z_][A-Za-z0-9_-]*(\s[^<>]{0,120})?>"#, in: line, with: " ")
        // Quoted paths first ('/Users/a/Screenshot 2026-10-21 at 1.png' contains spaces).
        text = RegexCache.replace(#"(['"“‘])(~|\.{0,2})/[^'"”’]*(['"”’]|$)"#, in: text, with: " ")
        text = RegexCache.replace(#"\b(?:https?|file|ftp)://\S+"#, in: text, with: " ")
        text = RegexCache.replace(#"(?<!\S)(?:~|\.{1,2})?/[^\s]+"#, in: text, with: " ")
        text = RegexCache.replace(#"\[(?:Image|Pasted text|Pasted image|File)[^\]]*\]"#, in: text, with: " ")
        text = collapse(text)
        // Leading markdown and refs, repeatedly ("#: 1 Idea", "> - @a.ts fix").
        var afterMarker = false
        for _ in 0..<16 {
            let before = text
            if removePrefix(#"^(?:#+:?|>+|[-*+•])\s*"#, from: &text) {
                afterMarker = true
            } else if removePrefix(#"^\d{1,2}[.)]\s+"#, from: &text) {
                afterMarker = true
            } else if afterMarker, removePrefix(#"^\d{1,2}:?\s+"#, from: &text) {
                continue
            } else if removePrefix(#"^@\S*\s*"#, from: &text) {
                continue
            }
            text = stripQuotes(text).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—|").union(.whitespaces))
            if text == before { break }
        }
        return text
    }

    static func removePrefix(_ pattern: String, from text: inout String) -> Bool {
        guard let range = text.range(of: pattern, options: .regularExpression), range.lowerBound == text.startIndex, !range.isEmpty else {
            return false
        }
        text.removeSubrange(range)
        return true
    }

    static func stripQuotes(_ text: String) -> String {
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("“", "”"), ("‘", "’"), ("«", "»")]
        var result = text
        for (open, close) in quotes where result.first == open {
            result.removeFirst()
            if let index = result.firstIndex(of: close), result.index(after: index) == result.endIndex {
                result.removeLast()
            }
            break
        }
        if let last = result.last, "\"'”’`".contains(last), result.filter({ $0 == last }).count == 1 {
            result.removeLast()
        }
        return result
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// At least three letters, so "@a.png", "…" or "1." don't become titles.
    static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 3
    }

    /// Cut at the last word boundary that fits, adding "…" within `limit`.
    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let head = String(text.prefix(limit - 1))
        var cut = head
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= limit / 2 {
            cut = String(head[..<space])
        }
        cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—.").union(.whitespaces))
        return cut + "…"
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Summaries

    /// Markdown → plain text: code fences, emphasis, headings, links, list markers.
    public static func stripMarkdown(_ markdown: String) -> String {
        var text = RegexCache.replace(#"```[\s\S]*?(```|$)"#, in: markdown, with: " ")
        text = RegexCache.replace(#"!\[[^\]]*\]\([^)]*\)"#, in: text, with: " ")
        text = RegexCache.replace(#"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
        text = RegexCache.replace(#"(?m)^\s{0,3}(?:#{1,6}|>+|[-*+•]|\d+[.)])\s+"#, in: text, with: "")
        text = RegexCache.replace(#"(\*\*|__|~~|`)"#, in: text, with: "")
        text = RegexCache.replace(#"(?<![\w*])[*_](?=\S)([^*_\n]+?)(?<=\S)[*_](?![\w*])"#, in: text, with: "$1")
        text = RegexCache.replace(#"(?m)^\s*\|.*\|\s*$"#, in: text, with: " ")
        return text
    }

    /// Markdown → one line of plain text: headings dropped, emphasis/code/links unwrapped,
    /// whitespace collapsed, home paths shortened to `~`, cut at a word boundary.
    public static func plainText(_ markdown: String, limit: Int = 140) -> String? {
        let markdown = head(markdown)
        let body = RegexCache.replace(#"(?m)^\s{0,3}#{1,6}\s.*$"#, in: markdown, with: " ")
        var text = collapse(stripMarkdown(body))
        if !isMeaningful(text) { text = collapse(stripMarkdown(markdown)) }
        return plainLine(text, limit: limit)
    }

    /// One line, home paths shortened, cut at a word boundary — no markdown handling (for
    /// commands and paths, where `*` and `_` are literal).
    public static func plainLine(_ text: String, limit: Int = 140) -> String? {
        let line = collapse(abbreviatingHome(text)).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return truncate(line, limit: limit)
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// "/Users/me/Downloads/x.mp4" → "~/Downloads/x.mp4".
    public static func abbreviatingHome(_ text: String) -> String {
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home + "/", with: "~/")
    }

    /// The first sentence of an assistant reply, plain text, at most `limit` characters.
    /// Only the start of a long reply can hold its first sentence or a 140-char body; regex work
    /// over the rest (replies run to tens of KB) is wasted.
    static func head(_ text: String, maxCharacters: Int = 4000) -> String {
        guard text.utf8.count > maxCharacters else { return text }
        let prefix = text.prefix(maxCharacters)
        // Don't cut inside a code fence: drop an unterminated trailing fence.
        if let fence = prefix.range(of: "```", options: .backwards), prefix[..<fence.lowerBound].components(separatedBy: "```").count % 2 == 1 {
            return String(prefix[..<fence.lowerBound])
        }
        return String(prefix)
    }

    public static func firstSentence(_ markdown: String, limit: Int = summaryLimit) -> String? {
        let markdown = head(markdown)
        // Headings ("## Summary") label a reply; they aren't its first sentence.
        let body = RegexCache.replace(#"(?m)^\s{0,3}#{1,6}\s.*$"#, in: markdown, with: "")
        let paragraphs = stripMarkdown(body).components(separatedBy: "\n").map(collapse).filter { isMeaningful($0) }
        guard let paragraph = paragraphs.first else { return nil }
        var sentence = paragraph
        if let regex = RegexCache.regex(#"(?<!\b(?:e\.g|i\.e|etc|vs|Mr|Dr|St))[.!?](?=\s+[A-Z0-9"'(\[]|$)"#),
            let match = regex.firstMatch(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph)),
            let range = Range(match.range, in: paragraph)
        {
            sentence = String(paragraph[..<range.upperBound])
        }
        return truncate(sentence.trimmingCharacters(in: .whitespaces), limit: limit)
    }
}

/// "Editing AppModel.swift", "Running pnpm test": what a tool call is doing, in words.
public enum ActivityPhrase {
    public static func describe(tool: String, target: String?, limit: Int = 60) -> String {
        let target = target?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let name = tool.lowercased()
        func file(_ verb: String) -> String {
            guard let target else { return verb }
            return "\(verb) \(fileName(target))"
        }
        let phrase: String
        switch name {
        case "bash", "shell", "exec", "exec_command", "run_shell_command", "local_shell", "terminal", "command":
            phrase = target.map { "Running \(commandHead($0))" } ?? "Running a command"
        case "edit", "multiedit", "notebookedit", "replace", "str_replace", "patch", "edit_file", "smart_edit":
            phrase = file("Editing")
        case "apply_patch":
            if let target, let parsed = patchTarget(target) {
                phrase = "\(parsed.verb) \(fileName(parsed.file))"
            } else {
                phrase = file("Editing")
            }
        case "write", "write_file", "create", "create_file":
            phrase = file("Writing")
        case "read", "read_file", "view", "read_many_files", "notebookread", "cat":
            phrase = file("Reading")
        case "grep", "glob", "search", "search_file_content", "find", "list", "ls", "list_directory", "codebase_search", "rg":
            phrase = target.map { "Searching \(TextSummary.oneLine($0, limit: 40))" } ?? "Searching"
        case "webfetch", "web_fetch", "fetch":
            phrase = target.map { "Fetching \(host($0))" } ?? "Fetching a page"
        case "websearch", "web_search", "google_web_search":
            phrase = target.map { "Searching the web for \(TextSummary.oneLine($0, limit: 36))" } ?? "Searching the web"
        case "task", "agent", "spawn_agent", "subagent":
            phrase = target.map { "Running subagent: \(TextSummary.oneLine($0, limit: 40))" } ?? "Running a subagent"
        case "todowrite", "update_plan", "todo", "todoread":
            phrase = "Updating the plan"
        case "compacting":
            phrase = "Compacting context"
        case "askuserquestion", "question":
            phrase = "Asking a question"
        default:
            if tool.contains(": ") {
                phrase = target.map { "\(tool) \(TextSummary.oneLine($0, limit: 30))" } ?? tool
            } else {
                phrase = target.map { "Using \(tool): \(TextSummary.oneLine($0, limit: 36))" } ?? "Using \(tool)"
            }
        }
        return TitleCleaner.truncate(phrase, limit: limit)
    }

    static func fileName(_ path: String) -> String {
        let first = path.split(separator: " ").first.map(String.init) ?? path
        let name = (first as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The meaningful part of a shell command: skips `cd x &&`, env assignments and `sudo`.
    static func commandHead(_ command: String) -> String {
        var line = TextSummary.oneLine(command, limit: 200)
        if let range = line.range(of: #"^cd\s+\S+\s*(&&|;)\s*"#, options: .regularExpression) { line.removeSubrange(range) }
        var words = line.split(separator: " ").map(String.init)
        while let first = words.first, first.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil {
            words.removeFirst()
        }
        if words.first == "sudo", words.count > 1 { words.removeFirst() }
        return TitleCleaner.truncate(words.joined(separator: " "), limit: 44)
    }

    static func patchTarget(_ summary: String) -> (verb: String, file: String)? {
        for (prefix, verb) in [("Edit ", "Editing"), ("Add ", "Adding"), ("Delete ", "Deleting")] where summary.hasPrefix(prefix) {
            return (verb, String(summary.dropFirst(prefix.count)))
        }
        return nil
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host ?? TextSummary.oneLine(url, limit: 40)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
