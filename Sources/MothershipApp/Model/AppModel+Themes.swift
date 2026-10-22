import AppKit
import Foundation
import ShipModel
import TerminalEngine
import ThemeKit

/// Themes (ThemeKit): which one is active, the day/night schedule, per-workspace overrides,
/// user themes from the themes folder, and what a theme drives (backdrop, chrome palette,
/// tone, terminal colors).
extension AppModel {
    // MARK: Resolution

    func theme(id: String) -> Theme? {
        themes.first { $0.id == id } ?? ThemeLibrary.theme(id: id)
    }

    /// The theme the user lives in: the scheduled one (day/night) or their choice.
    var chosenTheme: Theme {
        let id = themeScheduled ? (skyClock.sun.altitude >= 0 ? dayThemeID : nightThemeID) : themeID
        return theme(id: id) ?? theme(id: ThemeLibrary.defaultThemeID) ?? ThemeLibrary.builtIn[0]
    }

    /// What's on screen: a gallery hover preview, else the selected workspace's override
    /// (while its panes show), else the chosen theme.
    var activeTheme: Theme {
        if let id = previewThemeID, let preview = theme(id: id) { return preview }
        if screen == .workspaces, let workspace = selectedWorkspaceID,
           let id = workspaceThemes[workspace], let override = theme(id: id) {
            return override
        }
        return chosenTheme
    }

    /// The backdrop for the active theme at the sun's position. Mothership Sky is drawn
    /// natively from the sun model; every other theme from its ThemeKit scene.
    var skyState: SkyState {
        let theme = activeTheme
        let sun = skyClock.sun
        switch theme.backdrop.kind {
        case .desktop:
            return SkyState(kind: .desktop, palette: .graphite, sun: sun, isDark: systemIsDark, themeID: theme.id)
        case .fixed, .sunCycle:
            if theme.id == ThemeLibrary.defaultThemeID {
                var state = SkyState.living(sun: sun)
                state.themeID = theme.id
                return state
            }
            let scene = ThemeLibrary.scene(for: theme, sunAltitude: sun.altitude)
            return SkyState(kind: .scene, palette: .graphite, sun: sun, isDark: scene?.isDark ?? true, themeID: theme.id, scene: scene)
        }
    }

    // MARK: Choosing

    /// Applies a theme (gallery click, palette). ⌘Z (Edit → Undo) goes back.
    func applyTheme(_ id: String, undoManager: UndoManager? = nil) {
        guard theme(id: id) != nil, id != themeID || themeScheduled else { return }
        let previous = themeID
        let previousScheduled = themeScheduled
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.themeScheduled = previousScheduled
                model.applyTheme(previous, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Theme Change")
        previewThemeID = nil
        if themeScheduled { themeScheduled = false }
        withAnimationIfAllowed { themeID = id }
    }

    /// ⌘K "Next theme": the next one in the gallery's order.
    func applyNextTheme(undoManager: UndoManager? = nil) {
        guard let index = themes.firstIndex(where: { $0.id == chosenTheme.id }) else { return }
        applyTheme(themes[(index + 1) % themes.count].id, undoManager: undoManager)
    }

    func setWorkspaceTheme(_ workspace: WorkspaceID, to id: String?) {
        if let id { workspaceThemes[workspace] = id } else { workspaceThemes[workspace] = nil }
    }

    // MARK: User themes

    static var themesDirectory: URL { ShipPaths.supportDirectory.appending(path: "themes", directoryHint: .isDirectory) }

    /// Loads built-ins plus `themes/*.json`, and watches the folder so saving a file
    /// reloads it.
    func startThemes() {
        try? FileManager.default.createDirectory(at: Self.themesDirectory, withIntermediateDirectories: true)
        reloadThemes()
        let watcher = ThemeDirectoryWatcher(directory: Self.themesDirectory) { [weak self] in
            Task { @MainActor in self?.reloadThemes() }
        }
        if watcher.start() { themeWatcher = watcher }
    }

    func reloadThemes() {
        let result = ThemeLibrary.load(userDirectory: Self.themesDirectory)
        if result.themes.map(\.self) != themes { themes = result.themes }
        if result.problems != themeProblems { themeProblems = result.problems }
    }

    var userThemeIDs: Set<String> {
        Set(themes.map(\.id)).subtracting(ThemeLibrary.builtIn.map(\.id))
    }

    /// "Import theme…": validates, then copies it into the themes folder.
    func importTheme(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return "Couldn't read \(url.lastPathComponent)." }
        let theme: Theme
        do {
            theme = try JSONDecoder().decode(Theme.self, from: data)
        } catch {
            return "\(url.lastPathComponent) isn't a theme: \(error.localizedDescription)"
        }
        if let problem = ThemeLibrary.validate(theme).first(where: { $0.severity == .error }) {
            return problem.message
        }
        if ThemeLibrary.theme(id: theme.id) != nil { return "“\(theme.id)” is a built-in theme's id; give yours its own." }
        let destination = Self.themesDirectory.appending(path: theme.id + ".json")
        do {
            try FileManager.default.createDirectory(at: Self.themesDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try data.write(to: destination)
        } catch {
            return "Couldn't copy it into the themes folder: \(error.localizedDescription)"
        }
        reloadThemes()
        return nil
    }

    // MARK: Driving the chrome

    /// Pushes the active theme's palette to the Sky tokens.
    func applyThemeChrome() {
        ThemeChrome.shared.apply(activeTheme.palette)
    }

    /// The theme's paired Ghostty theme for the terminal's current variant, if the catalog
    /// has it.
    var themeTerminalName: String? {
        guard let pairing = activeTheme.terminal else { return nil }
        let order = terminalPrefersDark ? [pairing.dark, pairing.light] : [pairing.light, pairing.dark]
        let available = Set(TerminalRuntime.availableThemeNames)
        return order.compactMap { $0 }.first { available.contains($0) }
    }
}

/// Theme preferences that need more than a UserDefaults key.
enum ThemePreferences {
    /// The stored theme, migrating the pre-theme sky preset once.
    static func initialThemeID() -> String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: PreferenceKey.themeID) { return id }
        guard let legacy = defaults.string(forKey: PreferenceKey.sky).flatMap(LegacySkyPreset.init(rawValue:)) else {
            return ThemeLibrary.defaultThemeID
        }
        defaults.set(legacy.themeID, forKey: PreferenceKey.themeID)
        defaults.removeObject(forKey: PreferenceKey.sky)
        return legacy.themeID
    }

    private static var workspaceThemesURL: URL { ShipPaths.supportDirectory.appending(path: "workspace-themes.json") }

    static func loadWorkspaceThemes() -> [WorkspaceID: String] {
        guard let data = try? Data(contentsOf: workspaceThemesURL),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var result: [WorkspaceID: String] = [:]
        for (key, value) in raw {
            if let uuid = UUID(uuidString: key) { result[WorkspaceID(uuid)] = value }
        }
        return result
    }

    static func saveWorkspaceThemes(_ themes: [WorkspaceID: String]) {
        let raw = Dictionary(uniqueKeysWithValues: themes.map { ($0.key.description, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: ShipPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: workspaceThemesURL)
    }
}
