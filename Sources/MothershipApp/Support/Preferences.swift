import Foundation

/// Every UserDefaults key Mothership reads, in one place. AttentionKit reads the
/// notification keys directly from `UserDefaults.standard`.
enum PreferenceKey {
    static let fontSize = "terminal.fontSize"
    static let theme = "terminal.theme"

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
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Notifications.enabled: true,
            Notifications.permissionRequests: true,
            Notifications.needsInput: true,
            Notifications.finished: true,
            Notifications.failed: true,
            Notifications.terminalNotifications: true,
            Notifications.sound: true,
            Notifications.dockBadge: true,
            Notifications.whenVisible: false,
        ])
    }
}
