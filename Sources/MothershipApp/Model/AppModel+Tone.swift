import AppKit
import TerminalEngine

/// Content-led tone (docs/DESIGN.md §4): the chrome — glass, text, selection, composer,
/// toasts — takes the terminal's light or dark, because the terminal is what fills the
/// window. The sky keeps following the sun around and through the glass. A dark terminal
/// by day is a sunny day seen from a cockpit: dark glass over a bright sky.
extension AppModel {
    /// Dark chrome when the terminal's background is dark.
    var chromeIsDark: Bool {
        _ = appearanceVersion
        return Self.isDark(runtime.backgroundColor)
    }

    /// The light/dark variant the terminal's theme should show: the Mac's appearance (as
    /// Ghostty itself does), or the sky's when "Terminal follows the sky" is on.
    var terminalPrefersDark: Bool {
        terminalFollowsSky ? skyState.isDark : systemIsDark
    }

    /// Perceived brightness under 50 %.
    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.5
    }

    // MARK: Terminal follows the sky

    /// The light theme paired with the user's dark one, when Mothership knows a pair.
    var terminalDayTheme: String? {
        TerminalThemePairs.lightCounterpart(of: baseThemeName)
    }

    /// The name of the theme the user chose (in Settings, or their Ghostty config).
    var baseThemeName: String? {
        switch baseThemeChoice {
        case .named(let name): return name
        case .mothership: return "Mothership"
        case .automatic: return GhosttyConfigTheme.darkThemeName(at: runtime.userConfigPath) ?? (runtime.userConfigHasTheme ? nil : "Mothership")
        }
    }

    /// By day, swap a dark theme for its light counterpart; at night (or when off) restore
    /// the user's own choice.
    func applyTerminalSkyPairing() {
        let wanted: TerminalThemeChoice
        if terminalFollowsSky, !skyState.isDark, let light = terminalDayTheme {
            wanted = .named(light)
        } else {
            wanted = baseThemeChoice
        }
        if runtime.themeChoice != wanted { runtime.themeChoice = wanted }
    }
}

/// Dark themes and their light siblings, matched against the bundled catalog by a loose
/// name comparison (case, spaces and dashes ignored).
@MainActor
enum TerminalThemePairs {
    private static let pairs: [(dark: [String], light: [String])] = [
        (["catppuccin mocha", "catppuccin macchiato", "catppuccin frappe"], ["catppuccin latte"]),
        (["tokyonight", "tokyonight storm", "tokyonight moon", "tokyonight night", "tokyo night", "tokyo night storm"], ["tokyonight day", "tokyo night day", "tokyo night light"]),
        (["gruvbox dark", "gruvbox dark hard", "gruvbox material dark", "gruvbox dark soft"], ["gruvbox light", "gruvbox light hard", "gruvbox material light"]),
        (["solarized dark", "solarized dark higher contrast", "solarized dark patched"], ["solarized light"]),
        (["rose pine", "rose pine moon", "rosepine", "rose-pine"], ["rose pine dawn", "rosepine dawn"]),
        (["github dark", "github dark default", "github dark dimmed", "github dark high contrast"], ["github light default", "github light", "github"]),
        (["one dark", "one dark two", "atom one dark", "onedark"], ["one light", "atom one light", "onelight"]),
        (["everforest dark hard", "everforest dark medium", "everforest dark soft", "everforest dark"], ["everforest light med", "everforest light medium", "everforest light"]),
        (["nord"], ["nord light"]),
        (["ayu", "ayu mirage"], ["ayu light"]),
        (["kanagawa wave", "kanagawa dragon", "kanagawa"], ["kanagawa lotus"]),
        (["dracula", "dracula+"], ["alucard"]),
        (["mothership"], ["github light default", "catppuccin latte"]),
    ]

    static func lightCounterpart(of name: String?) -> String? {
        guard let name else { return nil }
        let key = normalized(name)
        guard let pair = pairs.first(where: { $0.dark.map(normalized).contains(key) }) else { return nil }
        let catalog = Dictionary(TerminalRuntime.availableThemeNames.map { (normalized($0), $0) }, uniquingKeysWith: { first, _ in first })
        return pair.light.lazy.compactMap { catalog[normalized($0)] }.first
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }
}

/// The `theme = …` line of the user's Ghostty config (read-only).
enum GhosttyConfigTheme {
    /// The dark half of `theme = light:A,dark:B`, or the single theme.
    static func darkThemeName(at path: String?) -> String? {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var value: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if key == "theme" { value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        }
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let dark = parts.first(where: { $0.hasPrefix("dark:") }) { return String(dark.dropFirst(5)) }
        if parts.contains(where: { $0.hasPrefix("light:") }) { return nil }
        return value
    }
}
