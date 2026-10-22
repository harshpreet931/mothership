import AppKit
import ShipModel
import ShipProtocol
import SwiftUI

/// Full-window views (the top bar's segmented pill, ⌂ and ⌘,).
enum AppScreen: String, Sendable {
    case workspaces, fleet, home, settings
    /// Best-of-N: the runs of `compareTaskID` side by side.
    case compare
    /// One run's changes (`diffRunID`).
    case diff

    /// Pages that sit beside the sidebar, like the pane canvas.
    var showsSidebar: Bool {
        switch self {
        case .workspaces, .fleet, .compare, .diff: true
        case .home, .settings: false
        }
    }
}

enum SettingsTab: String, CaseIterable, Sendable {
    case general, agents, appearance, notifications, keys

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .keys: "Keys"
        }
    }
}

enum PermissionDecisionKind: Sendable { case allowed, denied }

/// One card in the in-app attention stack.
struct AttentionToast: Identifiable, Equatable {
    let id: UUID
    let event: AttentionEvent

    var surface: SurfaceID? { event.surface }
    var permissionID: PermissionRequestID? {
        if case .permission(let request) = event.kind { return request.id }
        return nil
    }
}

/// A listening dev server, for Home's Ports panel.
struct ListeningPort: Identifiable, Equatable, Sendable {
    var id: Int { port }
    let port: Int
    /// The listening process ("node", "python3", "postgres").
    let process: String
    /// The workspace whose shell started it (from the process's `MOTHERSHIP_WORKSPACE_ID`).
    var workspaceID: WorkspaceID?
    var surfaceID: SurfaceID?
    /// Fixture-only fallback when there is no workspace ID (demo mode).
    var workspaceName: String?

    var url: URL? { URL(string: "http://localhost:" + String(port)) }
}

/// Runs `body` in a spring unless Reduce Motion is on.
@MainActor
func withAnimationIfAllowed(_ body: () -> Void) {
    if SkyAccessibility.reduceMotion {
        body()
    } else {
        withAnimation(Sky.spring, body)
    }
}

extension AppModel {
    // MARK: Sky / appearance

    /// The sky now showing: the preset at the sun's current position.

    func show(_ screen: AppScreen) {
        guard self.screen != screen else { return }
        withAnimationIfAllowed { self.screen = screen }
        if screen == .workspaces, let focused = focusedSurface?.id { requestFocus(focused) }
        if screen == .home { Task { await refreshPortsIfVisible() } }
    }

    /// ⌂ toggles Home.
    func toggleHome() {
        show(screen == .home ? .workspaces : .home)
    }

    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        show(.settings)
    }

    // MARK: Attention stack

    /// How long a toast stays: finished and terminal notifications 6 s, questions and
    /// errors 10 s, permission requests until they're answered.
    static func toastLifetime(_ kind: AttentionEvent.Kind) -> TimeInterval? {
        switch kind {
        case .permission: nil
        case .needsInput, .failed: 10
        case .finished, .notification: 6
        }
    }

    /// An agent with no Mothership pane (a terminal elsewhere, an editor).
    func isExternal(_ event: AttentionEvent) -> Bool {
        guard event.surface == nil else { return false }
        guard let key = event.session, let session = sessions.first(where: { $0.id == key }) else { return true }
        return session.surface == nil
    }

    /// Whether an engine attention event is news: under 2 minutes old on arrival, and
    /// from a Mothership pane unless "Agents running outside Mothership" is on.
    func shouldSurface(_ event: AttentionEvent, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(event.date) < 120 else { return false }
        if isExternal(event), !PreferenceStore.defaults.bool(forKey: PreferenceKey.Notifications.externalAgents) { return false }
        return true
    }

    func enqueueToast(_ event: AttentionEvent) {
        // Only what you didn't see; the pane you're watching speaks for itself.
        guard event.shouldNotify else { return }
        switch event.kind {
        case .finished where !appIsActive: return
        default: break
        }
        withAnimationIfAllowed {
            toasts.removeAll { $0.event.session == event.session && event.session != nil }
            toasts.insert(AttentionToast(id: event.id, event: event), at: 0)
            // Three at most; transient ones make way before permission requests.
            while toasts.count > 3 {
                if let index = toasts.lastIndex(where: { $0.permissionID == nil }) { toasts.remove(at: index) } else { toasts.removeLast() }
            }
        }
        if let lifetime = Self.toastLifetime(event.kind) { expireToast(event.id, after: lifetime) }
    }

    private func expireToast(_ id: UUID, after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, toasts.contains(where: { $0.id == id }) else { return }
            if toastsHeld { expireToast(id, after: 2) } else { dismissToast(id) }
        }
    }

    func dismissToast(_ id: UUID? = nil) {
        withAnimationIfAllowed {
            if let id { toasts.removeAll { $0.id == id } } else if !toasts.isEmpty { toasts.removeFirst() }
        }
    }

    func openToast(_ toast: AttentionToast) {
        if let surface = toast.surface { focusSurface(surface) }
        dismissToast(toast.id)
    }

    /// Drops toasts whose session no longer needs anything.
    func pruneToasts() {
        let stale = toasts.filter { toast in
            guard let key = toast.event.session else { return false }
            guard let session = sessions.first(where: { $0.id == key }) else { return true }
            switch toast.event.kind {
            case .permission: return session.pendingPermission == nil
            case .needsInput: return !session.state.isNeedsInput
            default: return false
            }
        }
        guard !stale.isEmpty else { return }
        let ids = Set(stale.map(\.id))
        withAnimationIfAllowed { toasts.removeAll { ids.contains($0.id) } }
    }

    // MARK: Composer

    /// The live agent in the focused pane, which the composer talks to.
    var composerTarget: AgentSession? {
        guard let surface = focusedSurface?.id else { return nil }
        return sessions.first { $0.surface == surface && $0.state.isLive }
    }

    var composerPlaceholder: String {
        if composerBroadcast { return "Message every agent" }
        if let target = composerTarget, let workspace = target.surface.flatMap({ workspace(containing: $0) }) {
            let context = task(for: workspace.id)?.title ?? workspace.name
            return "Message \(target.kind.shortName) · \(context)"
        }
        return "Start a task…"
    }

    // MARK: Composer pill

    /// Whether the composer shows at all: the pill (Settings → Composer), or open from ⌘L.
    var composerShown: Bool {
        switch screen {
        case .settings, .compare, .diff: false
        case .workspaces, .fleet, .home: isComposerVisible || isComposerExpanded
        }
    }

    /// Opens the composer and puts the caret in it (click, ⌘L, "Start a task").
    func openComposer() {
        withAnimationIfAllowed { isComposerExpanded = true }
        composerFocusRequest += 1
    }

    /// Folds the composer back into its pill; keys go back to the pane.
    func closeComposer(refocusPane: Bool = true) {
        guard isComposerExpanded else { return }
        withAnimationIfAllowed { isComposerExpanded = false }
        if refocusPane, screen == .workspaces, let surface = focusedSurface?.id { requestFocus(surface) }
    }

    // MARK: Onboarding

    /// First run: agents are on this Mac but none is connected yet. The card goes away by
    /// itself once one is.
    var needsOnboarding: Bool {
        !integrations.contains(where: \.installed)
            && integrations.contains { $0.executablePath != nil && $0.unsupportedReason == nil }
    }

    // MARK: Ports

    /// Ports only matter where they're shown: Home, or the sidebar's row chips.
    var portsVisible: Bool {
        switch screen {
        case .home: true
        case .workspaces, .fleet, .compare, .diff: !isSidebarCollapsed
        case .settings: false
        }
    }

    func refreshPortsIfVisible() async {
        // Nothing to look at while the app is hidden or the window is in the Dock.
        let onScreen = !NSApp.isHidden && !NSApp.windows.contains { $0 is MainWindow && $0.isMiniaturized }
        guard portsVisible, onScreen, let provider = portsProvider else { return }
        let fresh = await provider()
        if fresh != ports { ports = fresh }
    }

    func ports(in workspace: Workspace) -> [ListeningPort] {
        ports.filter { $0.workspaceID == workspace.id || ($0.workspaceID == nil && $0.workspaceName == workspace.name) }
    }

    func workspaceName(for port: ListeningPort) -> String? {
        port.workspaceID.flatMap { workspace(id: $0)?.name } ?? port.workspaceName
    }

    /// A browser split in the port's own workspace (or the current one).
    func openPort(_ port: ListeningPort) {
        guard let url = port.url else { return }
        if let id = port.workspaceID ?? workspaces.first(where: { $0.name == port.workspaceName })?.id {
            selectWorkspace(id)
        } else {
            show(.workspaces)
        }
        openBrowserSplit(url: url)
    }

    // MARK: Home

    var firstName: String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? (full.isEmpty ? "there" : full)
    }

    func greeting(at date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = switch hour {
        case 5 ..< 12: "Good morning"
        case 12 ..< 17: "Good afternoon"
        case 17 ..< 22: "Good evening"
        default: "Working late"
        }
        return "\(part), \(firstName)"
    }

    /// "3 agents working · 1 needs you", or a celebration of zero.
    var statusSentence: String {
        let live = sessions.filter { $0.state.isLive }
        let working = live.filter(\.state.isWorking).count
        let needs = live.filter(\.needsYou).count
        let errors = live.filter(\.state.isError).count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) agent\(working == 1 ? "" : "s") working") }
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if errors > 0 { parts.append("\(errors) failed") }
        if parts.isEmpty {
            return live.isEmpty ? "Nothing running. The sky is clear." : "All quiet. \(live.count) agent\(live.count == 1 ? "" : "s") idle."
        }
        return parts.joined(separator: " · ")
    }

    /// Tokens and cost across every known session (today's sessions in the real engine).
    var todayTotals: (tokens: Int, cost: Double, sessions: Int) {
        let live = sessions.filter { Calendar.current.isDateInToday($0.lastActivity) }
        let tokens = live.reduce(0) { $0 + $1.usage.inputTokens + $1.usage.outputTokens + $1.usage.cacheWriteTokens }
        let cost = live.reduce(0.0) { $0 + ($1.usage.costUSD ?? 0) }
        return (tokens, cost, live.count)
    }
}

extension AgentKind {
    /// "Claude", "Codex"… for tight UI.
    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        default: displayName
        }
    }
}
