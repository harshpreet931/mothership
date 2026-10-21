import Foundation
import GhosttyTerminal
import GhosttyTheme

/// The user's Ghostty config, rewritten so it loads inside an embedded libghostty:
/// `theme =` is resolved against the bundled catalog (the trimmed build ships no themes
/// directory) and relative `config-file` includes are made absolute (the composed file
/// lives in a temp directory).
struct ComposedGhosttyConfig: Sendable, Equatable {
    /// Path of the user's config, nil when none was found.
    var sourcePath: String?
    /// Config text handed to Ghostty as the base layer.
    var base: String
    /// The user's `theme =` resolved to colors, if any.
    var userTheme: TerminalTheme?
    /// The user's config sets `background`/`foreground`/`palette` directly.
    var definesColors: Bool
    var userFontSize: Float?
    var definesPadding: Bool
}

enum GhosttyConfigComposer {
    /// Where Ghostty looks for its config on macOS, in its own precedence order.
    static func candidatePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var xdg = environment["XDG_CONFIG_HOME"] ?? ""
        if xdg.isEmpty { xdg = home + "/.config" }
        let appSupport = home + "/Library/Application Support/com.mitchellh.ghostty"
        return [
            xdg + "/ghostty/config.ghostty",
            xdg + "/ghostty/config",
            appSupport + "/config.ghostty",
            appSupport + "/config",
        ]
    }

    static func locateUserConfig() -> String? {
        candidatePaths().first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    /// Reads and rewrites the user's config. `strict` keeps only keys that are safe in an
    /// embedded surface; it's the fallback when the full file fails Ghostty's validation.
    static func compose(path: String?, strict: Bool = false) -> ComposedGhosttyConfig {
        guard let path, let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ComposedGhosttyConfig(
                sourcePath: nil, base: "", userTheme: nil, definesColors: false,
                userFontSize: nil, definesPadding: false
            )
        }
        let directory = (path as NSString).deletingLastPathComponent
        var lines: [String] = []
        var themeValue: String?
        var definesColors = false
        var fontSize: Float?
        var definesPadding = false

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            switch key {
            case "theme":
                themeValue = value
                continue
            case "config-file":
                if strict { continue }
                lines.append("config-file = \(absoluteInclude(value, relativeTo: directory))")
                continue
            case "background", "foreground", "palette":
                definesColors = true
            case "font-size":
                fontSize = Float(value)
            case "window-padding-x", "window-padding-y":
                definesPadding = true
            default:
                break
            }
            if strict, !isSafeInStrictMode(key) { continue }
            lines.append(line)
        }

        return ComposedGhosttyConfig(
            sourcePath: path,
            base: lines.joined(separator: "\n"),
            userTheme: themeValue.flatMap { resolveTheme($0, relativeTo: directory) },
            definesColors: definesColors,
            userFontSize: fontSize,
            definesPadding: definesPadding
        )
    }

    /// `theme = name` or `theme = light:A,dark:B`.
    static func resolveTheme(_ value: String, relativeTo directory: String) -> TerminalTheme? {
        var light: String?
        var dark: String?
        for part in value.split(separator: ",") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("light:") {
                light = String(item.dropFirst("light:".count))
            } else if item.hasPrefix("dark:") {
                dark = String(item.dropFirst("dark:".count))
            } else {
                light = item
                dark = item
            }
        }
        let lightConfig = light.flatMap { themeConfiguration(named: $0, relativeTo: directory) }
        let darkConfig = dark.flatMap { themeConfiguration(named: $0, relativeTo: directory) }
        guard lightConfig != nil || darkConfig != nil else { return nil }
        return TerminalTheme(
            light: lightConfig ?? darkConfig ?? TerminalConfiguration(),
            dark: darkConfig ?? lightConfig ?? TerminalConfiguration()
        )
    }

    static func themeConfiguration(named name: String, relativeTo directory: String) -> TerminalConfiguration? {
        if let definition = catalogTheme(named: name) {
            return definition.toTerminalConfiguration()
        }
        // A theme may also be a path to a file in config syntax.
        let path = name.hasPrefix("/") ? name : directory + "/themes/" + name
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let allowed: Set<String> = [
            "background", "foreground", "palette", "cursor-color", "cursor-text",
            "selection-background", "selection-foreground",
        ]
        return TerminalConfiguration { builder in
            for rawLine in contents.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if allowed.contains(key) { builder.withCustom(key, value) }
            }
        }
    }

    static func catalogTheme(named name: String) -> GhosttyThemeDefinition? {
        if let exact = GhosttyThemeCatalog.theme(named: name) { return exact }
        let lowered = name.lowercased()
        return GhosttyThemeCatalog.allThemes.first { $0.name.lowercased() == lowered }
    }

    private static func absoluteInclude(_ value: String, relativeTo directory: String) -> String {
        var path = value
        let optional = path.hasPrefix("?")
        if optional { path.removeFirst() }
        if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = directory + "/" + path
        }
        return (optional ? "?" : "") + path
    }

    private static let strictPrefixes = [
        "font-", "adjust-", "background", "foreground", "palette", "cursor-", "selection-",
        "bold-is-bright", "minimum-contrast", "window-padding-", "mouse-", "copy-on-select",
        "scrollback-limit", "shell-integration", "macos-option-as-alt", "clipboard-", "link-",
        "unfocused-split-", "alpha-blending", "grapheme-width-method", "term",
    ]

    private static func isSafeInStrictMode(_ key: String) -> Bool {
        strictPrefixes.contains { key.hasPrefix($0) }
    }
}

extension TerminalConfiguration {
    /// Mothership's own dark palette: near-black with a cool cast, tuned to sit under
    /// Liquid Glass chrome without looking washed out.
    static let mothershipDark = TerminalConfiguration { builder in
        builder.withBackground("0E1013")
        builder.withForeground("D9DCE3")
        builder.withCursorColor("F0B37E")
        builder.withCursorText("0E1013")
        builder.withSelectionBackground("2A3242")
        builder.withSelectionForeground("F2F4F8")
        let palette = [
            "#1C1F26", "#F2777A", "#A3D68E", "#EDC57E", "#7FA7F5", "#C59BF2", "#72D4CC", "#C9CDD6",
            "#4D5566", "#FF9393", "#B8E6A3", "#F5D598", "#9DBDFF", "#D7B4FF", "#93E6DE", "#F4F6FA",
        ]
        for (index, color) in palette.enumerated() {
            builder.withPalette(index, color: color)
        }
    }

}

extension TerminalTheme {
    /// Dark in every sky: dark terminal cards on a Day sky are part of the look (DESIGN §8).
    static let mothership = TerminalTheme(light: .mothershipDark, dark: .mothershipDark)
}
