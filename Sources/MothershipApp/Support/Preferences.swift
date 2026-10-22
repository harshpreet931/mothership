import Foundation

/// Every UserDefaults key Mothership reads, in one place. AttentionKit reads the
/// notification keys directly from `UserDefaults.standard`.
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
        UserDefaults.standard.register(defaults: [
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
