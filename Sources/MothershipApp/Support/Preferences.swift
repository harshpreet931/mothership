import Foundation

/// Where preferences live: the app's own domain normally, but a separate suite whenever
/// `MOTHERSHIP_HOME` points at a scratch home (QA runs, snapshots), so test launches never
/// read or write the user's real settings. Use this everywhere instead of
/// `UserDefaults.standard`, and pass it as `store:` to `@AppStorage`.
enum PreferenceStore {
    // Safe: the reference never changes after first use, and UserDefaults is documented as
    // thread-safe; only its Swift import lacks a Sendable annotation.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let home = ProcessInfo.processInfo.environment["MOTHERSHIP_HOME"], !home.isEmpty else {
            return .standard
        }
        // FNV-1a: stable across launches, so a scratch home keeps its own settings.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in home.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return UserDefaults(suiteName: "com.mothership.app.scratch-" + String(hash, radix: 16)) ?? .standard
    }()
}

/// Every UserDefaults key Mothership reads, in one place. AttentionKit reads the
/// notification keys from the defaults it's handed (`PreferenceStore.defaults`).
enum PreferenceKey {
    static let fontSize = "terminal.fontSize"
    static let theme = "terminal.theme"
    /// Pre-theme sky preset (`LegacySkyPreset`), read once to migrate.
    static let sky = "sky.preset"
    /// Theme ids (ThemeKit): the chosen one, and the day/night schedule.
    static let themeID = "theme.id"
    static let themeScheduled = "theme.scheduled"
    static let dayThemeID = "theme.day"
    static let nightThemeID = "theme.night"
    static let usesThemeTerminal = "theme.terminalColors"
    /// "Animate sky" (twinkling stars, drifting clouds).
    static let skyAnimates = "sky.animates"
    /// "Use my location" for the sun's position (off: guessed from the time zone).
    static let skyUsesLocation = "sky.usesLocation"
    static let composerVisible = "composer.visible"
    /// Shells and agents outlive the app (`mshipd`); read by the sessions host.
    static let keepSessionsAlive = "sessions.keepAlive"
    /// Terminal cards at 88 % with a blur, letting the sky through.
    static let tintWithSky = "terminal.tintWithSky"
    /// By day, a dark terminal theme's light sibling ("Terminal follows the sky").
    static let terminalFollowsSky = "terminal.followsSky"

    enum Notifications {
        /// Master switch for banners.
        static let enabled = "notifications.enabled"
        static let permissionRequests = "notifications.permissionRequests"
        static let needsInput = "notifications.needsInput"
        static let finished = "notifications.finished"
        static let failed = "notifications.failed"
        /// OSC 9/99/777 from any program, not attributed to an agent.
        static let terminalNotifications = "notifications.terminal"
        static let sound = "notifications.sound"
        static let dockBadge = "notifications.dockBadge"
        /// Also alert when the pane is visible but the app isn't frontmost.
        static let whenVisible = "notifications.whenVisible"
        /// Toasts and banners for agents running outside Mothership (off by default).
        static let externalAgents = "notifications.externalAgents"
    }

    static func registerDefaults() {
        PreferenceStore.defaults.register(defaults: [
            keepSessionsAlive: true,
            Notifications.enabled: true,
            Notifications.permissionRequests: true,
            Notifications.needsInput: true,
            Notifications.finished: true,
            Notifications.failed: true,
            Notifications.terminalNotifications: true,
            Notifications.sound: true,
            Notifications.dockBadge: true,
            Notifications.whenVisible: false,
            Notifications.externalAgents: false,
        ])
    }
}
