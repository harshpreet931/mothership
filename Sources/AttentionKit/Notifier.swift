import AppKit
import Foundation
import os
import ShipModel
import UserNotifications

/// Actionable macOS notifications and the Dock badge.
///
/// ```swift
/// let notifier = Notifier()
/// notifier.onAction = { action in
///     switch action {
///     case .allow(let id): Task { await engine.resolvePermission(id, decision: .allow) }
///     case .deny(let id): Task { await engine.resolvePermission(id, decision: .deny(reason: nil)) }
///     case .open(let surface): app.focus(surface)
///     case .reply(let surface, let text): app.paste(text, into: surface, submit: true)
///     }
/// }
/// await notifier.start()                         // registers categories, asks for permission
/// notifier.attentionContext = currentContext     // keep updated: drives foreground banners
/// notifier.present(event, workspaceName: "api-server")
/// notifier.withdraw(permission: id)              // when the engine reports it resolved
/// notifier.setBadge(count: needsInputCount)
/// ```
///
/// Safe no-op when the process has no bundle identifier (`swift run`, tests):
/// `UNUserNotificationCenter.current()` crashes in that case.
@MainActor
public final class Notifier: NSObject {
    public var onAction: ((NotificationAction) -> Void)?
    /// What the user is looking at. A notification for the focused surface of the active app
    /// isn't shown as a banner (it still lands in Notification Center if delivered while away).
    public var attentionContext = AttentionContext()
    public var sounds = NotificationSoundSettings()
    /// False when notifications can't work in this process (unbundled).
    public let isAvailable: Bool

    private var started = false
    private nonisolated static let log = Logger(subsystem: ShipInfo.bundleIdentifier, category: "notifications")

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        isAvailable = bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        super.init()
    }

    private var center: UNUserNotificationCenter? { isAvailable ? UNUserNotificationCenter.current() : nil }

    /// Registers the delegate and categories, then requests alert/sound/badge authorization.
    /// Returns whether notifications are authorized. Idempotent.
    @discardableResult
    public func start() async -> Bool {
        guard let center else {
            Self.log.info("notifications unavailable: not running from an app bundle")
            return false
        }
        if !started {
            started = true
            center.delegate = self
            center.setNotificationCategories(Self.categories)
        }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Self.log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    /// Shows the event unless `event.shouldNotify` is false. Permission requests get Allow /
    /// Deny / Open; finished or waiting agents get a Reply text field.
    public func present(_ event: AttentionEvent, workspaceName: String?) {
        guard event.shouldNotify, let center else { return }
        let spec = NotificationContent.make(for: event, workspaceName: workspaceName, sounds: sounds)
        let content = UNMutableNotificationContent()
        content.title = spec.title
        content.body = spec.body
        content.categoryIdentifier = spec.categoryIdentifier
        content.threadIdentifier = spec.threadIdentifier
        content.userInfo = spec.userInfo
        content.relevanceScore = spec.relevanceScore
        content.interruptionLevel = spec.urgency == .timeSensitive ? .timeSensitive : .active
        content.targetContentIdentifier = spec.userInfo[NotificationIdentifiers.surfaceKey]
        switch spec.sound {
        case .none: content.sound = nil
        case .standard: content.sound = .default
        case .named(let name): content.sound = UNNotificationSound(named: UNNotificationSoundName(name))
        }
        let request = UNNotificationRequest(identifier: spec.identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Self.log.error("couldn't post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Removes a permission notification once the request was decided, expired or released.
    public func withdraw(permission id: PermissionRequestID) {
        guard let center else { return }
        let identifier = NotificationIdentifiers.permission(id)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Clears notifications about a surface, e.g. when the user focuses it.
    public func withdraw(surface: SurfaceID) {
        guard let center else { return }
        let target = surface.description
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            let identifiers = delivered
                .filter { ($0.request.content.userInfo[NotificationIdentifiers.surfaceKey] as? String) == target }
                .map(\.request.identifier)
            if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        }
    }

    /// The Dock tile badge (e.g. the number of sessions that need input). 0 clears it.
    public func setBadge(count: Int) {
        // `NSApp` is nil until an NSApplication exists; don't create one as a side effect.
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
    }

    // MARK: Categories

    static var categories: Set<UNNotificationCategory> {
        let open = UNNotificationAction(
            identifier: NotificationIdentifiers.openAction, title: "Open", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app")
        )
        let allow = UNNotificationAction(
            identifier: NotificationIdentifiers.allowAction, title: "Allow", options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark")
        )
        let deny = UNNotificationAction(
            identifier: NotificationIdentifiers.denyAction, title: "Deny", options: [.destructive],
            icon: UNNotificationActionIcon(systemImageName: "xmark")
        )
        let reply = UNTextInputNotificationAction(
            identifier: NotificationIdentifiers.replyAction, title: "Reply", options: [],
            icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: "Send", textInputPlaceholder: "Next prompt…"
        )
        return [
            UNNotificationCategory(
                identifier: NotificationIdentifiers.permissionCategory, actions: [allow, deny, open], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: "Permission requested", options: [.hiddenPreviewsShowTitle]
            ),
            UNNotificationCategory(identifier: NotificationIdentifiers.attentionCategory, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationIdentifiers.idleCategory, actions: [reply, open], intentIdentifiers: []),
        ]
    }

    // MARK: Delegate plumbing

    func shouldPresentInForeground(surface: SurfaceID?) -> Bool {
        let appActive = NSApp?.isActive ?? attentionContext.appIsActive
        let watching = appActive && surface != nil && attentionContext.focusedSurface == surface
        return !watching
    }

    func deliver(_ action: NotificationAction) {
        onAction?(action)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let surface = SurfaceID(string: notification.request.content.userInfo[NotificationIdentifiers.surfaceKey] as? String)
        let show = await shouldPresentInForeground(surface: surface)
        return show ? [.banner, .list, .sound] : []
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        guard let action = NotificationContent.action(actionIdentifier: response.actionIdentifier, userInfo: info, replyText: text) else {
            return
        }
        await deliver(action)
    }
}
