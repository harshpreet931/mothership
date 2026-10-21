import Foundation
import ShipModel

/// What a notification action asks the app to do.
public enum NotificationAction: Sendable, Equatable {
    /// Approve a held permission request.
    case allow(PermissionRequestID)
    /// Reject a held permission request.
    case deny(PermissionRequestID)
    /// Bring the user to this surface (or just the app when nil).
    case open(SurfaceID?)
    /// Send this text as a prompt to the agent in the surface (bracketed paste + Enter).
    case reply(SurfaceID, String)
}

public enum NotificationSound: Sendable, Equatable, Codable {
    case none
    case standard
    /// A sound file in the app bundle or `~/Library/Sounds` (e.g. "Glass.aiff").
    case named(String)
}

/// One sound per kind of event, so "needs permission" can be told apart from "done" by ear.
public struct NotificationSoundSettings: Sendable, Equatable, Codable {
    public var permission: NotificationSound
    public var needsInput: NotificationSound
    public var finished: NotificationSound
    public var failed: NotificationSound
    public var notification: NotificationSound

    public init(
        permission: NotificationSound = .standard, needsInput: NotificationSound = .standard,
        finished: NotificationSound = .standard, failed: NotificationSound = .standard,
        notification: NotificationSound = .standard
    ) {
        self.permission = permission
        self.needsInput = needsInput
        self.finished = finished
        self.failed = failed
        self.notification = notification
    }

    public func sound(for kind: AttentionEvent.Kind) -> NotificationSound {
        switch kind {
        case .permission: permission
        case .needsInput: needsInput
        case .finished: finished
        case .failed: failed
        case .notification: notification
        }
    }
}

/// Category and action identifiers registered with the notification center.
public enum NotificationIdentifiers {
    public static let permissionCategory = "PERMISSION"
    public static let attentionCategory = "ATTENTION"
    public static let idleCategory = "IDLE"

    public static let allowAction = "ALLOW"
    public static let denyAction = "DENY"
    public static let openAction = "OPEN"
    public static let replyAction = "REPLY"

    /// userInfo keys.
    public static let surfaceKey = "surface"
    public static let permissionKey = "permission"
    public static let sessionKey = "session"

    public static func permission(_ id: PermissionRequestID) -> String { "permission.\(id)" }
}

/// Platform-independent description of a notification, derived from an `AttentionEvent`.
/// The `Notifier` turns it into a `UNNotificationRequest`; tests inspect it directly.
public struct NotificationContent: Sendable, Equatable {
    public enum Urgency: Sendable, Equatable {
        case active
        /// Breaks through Focus when the user allowed time-sensitive alerts.
        case timeSensitive
    }

    /// Stable per session for status updates, so a newer state replaces an older banner
    /// instead of stacking ("finished" replaces "working on it… needs input").
    public var identifier: String
    public var title: String
    public var body: String
    public var categoryIdentifier: String
    /// Groups a session's notifications together in Notification Center.
    public var threadIdentifier: String
    public var userInfo: [String: String]
    public var sound: NotificationSound
    public var urgency: Urgency
    public var relevanceScore: Double

    static let maxBodyLength = 280

    public static func make(
        for event: AttentionEvent, workspaceName: String?, sounds: NotificationSoundSettings = NotificationSoundSettings()
    ) -> NotificationContent {
        let agent = event.session?.kind.displayName
        let suffix = workspaceName.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        let fallbackBody = clean(event.body)

        var userInfo: [String: String] = [:]
        if let surface = event.surface { userInfo[NotificationIdentifiers.surfaceKey] = surface.description }
        if let session = event.session { userInfo[NotificationIdentifiers.sessionKey] = session.description }

        let thread = event.session.map { "session.\($0)" }
            ?? event.surface.map { "surface.\($0)" }
            ?? "mothership"
        let statusIdentifier = event.session.map { "status.\($0)" } ?? event.surface.map { "status.\($0)" } ?? event.id.uuidString
        let replyable = event.surface != nil
        let sound = sounds.sound(for: event.kind)

        switch event.kind {
        case .permission(let request):
            userInfo[NotificationIdentifiers.permissionKey] = request.id.description
            let summary = clean(request.summary)
            return NotificationContent(
                identifier: NotificationIdentifiers.permission(request.id),
                title: "\(agent ?? request.session.kind.displayName) needs permission\(suffix)",
                body: summary.isEmpty ? request.toolName : "\(request.toolName): \(summary)",
                categoryIdentifier: NotificationIdentifiers.permissionCategory, threadIdentifier: thread,
                userInfo: userInfo, sound: sound, urgency: .timeSensitive, relevanceScore: 1
            )
        case .needsInput:
            return NotificationContent(
                identifier: statusIdentifier,
                title: "\(agent ?? "Your agent") is waiting for you\(suffix)",
                body: fallbackBody.isEmpty ? (clean(event.title).isEmpty ? "It has a question." : clean(event.title)) : fallbackBody,
                categoryIdentifier: replyable ? NotificationIdentifiers.idleCategory : NotificationIdentifiers.attentionCategory,
                threadIdentifier: thread, userInfo: userInfo, sound: sound, urgency: .active, relevanceScore: 0.8
            )
        case .finished:
            return NotificationContent(
                identifier: statusIdentifier,
                title: "\(agent ?? "Your agent") finished\(suffix)",
                body: fallbackBody.isEmpty ? "Ready for the next prompt." : fallbackBody,
                categoryIdentifier: replyable ? NotificationIdentifiers.idleCategory : NotificationIdentifiers.attentionCategory,
                threadIdentifier: thread, userInfo: userInfo, sound: sound, urgency: .active, relevanceScore: 0.5
            )
        case .failed:
            return NotificationContent(
                identifier: statusIdentifier,
                title: "\(agent ?? "Your agent") hit an error\(suffix)",
                body: fallbackBody.isEmpty ? "Open the pane to see what happened." : fallbackBody,
                categoryIdentifier: NotificationIdentifiers.attentionCategory, threadIdentifier: thread,
                userInfo: userInfo, sound: sound, urgency: .active, relevanceScore: 0.7
            )
        case .notification:
            let title = clean(event.title)
            return NotificationContent(
                identifier: event.id.uuidString,
                title: (title.isEmpty ? (agent ?? "Terminal") : title) + suffix,
                body: fallbackBody,
                categoryIdentifier: NotificationIdentifiers.attentionCategory, threadIdentifier: thread,
                userInfo: userInfo, sound: sound, urgency: .active, relevanceScore: 0.4
            )
        }
    }

    /// One paragraph, no control characters, bounded length.
    static func clean(_ text: String) -> String {
        let collapsed = text.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0) }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > maxBodyLength else { return collapsed }
        return String(collapsed.prefix(maxBodyLength - 1)) + "…"
    }

    /// Reads the action a user took from a delivered notification's identifiers.
    public static func action(
        actionIdentifier: String, userInfo: [String: String], replyText: String?
    ) -> NotificationAction? {
        let surface = SurfaceID(string: userInfo[NotificationIdentifiers.surfaceKey])
        let permission = PermissionRequestID(string: userInfo[NotificationIdentifiers.permissionKey])
        switch actionIdentifier {
        case NotificationIdentifiers.allowAction:
            return permission.map(NotificationAction.allow)
        case NotificationIdentifiers.denyAction:
            return permission.map(NotificationAction.deny)
        case NotificationIdentifiers.replyAction:
            guard let surface, let text = replyText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .open(surface)
            }
            return .reply(surface, text)
        case NotificationIdentifiers.openAction, defaultActionIdentifier:
            return .open(surface)
        default:
            return nil  // dismissed, or an action we don't know
        }
    }

    /// `UNNotificationDefaultActionIdentifier` (the user clicked the banner itself), repeated
    /// here so this file stays free of UserNotifications.
    public static let defaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
}
