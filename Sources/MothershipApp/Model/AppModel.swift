import AppKit
import Observation
import ShipModel
import ShipProtocol
import TerminalEngine

/// What the window layer provides to the model.
@MainActor
protocol AppWindowHost: AnyObject {
    /// Make `view` first responder once it's in the window.
    func focus(view: NSView)
    var windowFrame: [Double]? { get }
    var sidebarWidth: Double? { get }
    var isWindowVisible: Bool { get }
}

/// The whole app's state: workspaces → pane trees → surfaces, plus the agent fleet.
///
/// Composition root: `AppDelegate` creates it with an `AgentEngineProtocol`, injects the
/// browser view factory and attention hook, then calls `start()`.
@MainActor
@Observable
final class AppModel {
    // MARK: Dependencies (injection points for the lead)

    @ObservationIgnored let engine: any AgentEngineProtocol
    @ObservationIgnored let runtime: TerminalRuntime
    /// Builds the NSView for a browser pane. Default: a placeholder. BrowserKit plugs in here.
    @ObservationIgnored var makeBrowserView: (SurfaceID, WorkspaceID, URL?) -> NSView = { _, _, url in
        BrowserPlaceholderView(url: url)
    }
    /// Navigates an existing browser pane. Return false when the view can't (placeholder).
    @ObservationIgnored var navigateBrowser: ((SurfaceID, URL) -> Bool)?
    /// Every engine `AttentionEvent` (permission, needs input, finished, failed, OSC
    /// notification). AttentionKit plugs in here for banners and the Dock badge.
    @ObservationIgnored var onAttention: ((AttentionEvent) -> Void)?
    /// Fired after `sessions` changes (e.g. to refresh a Dock badge).
    @ObservationIgnored var onSessionsChanged: (([AgentSession]) -> Void)?
    /// Extra environment for every shell (PATH with the `mship` shim prepended).
    @ObservationIgnored var shellEnvironment: [String: String] = [:]
    @ObservationIgnored weak var host: AppWindowHost?
    @ObservationIgnored let store: StateStore?

    // MARK: State

    var workspaces: [Workspace] = []
    var selectedWorkspaceID: WorkspaceID?
    /// Every session the engine knows, in-app and external.
    var sessions: [AgentSession] = []
    var integrations: [IntegrationStatus] = []
    var isPalettePresented = false
    var appIsActive = true
    var renamingWorkspaceID: WorkspaceID?
    var isSidebarCollapsed = false
    /// Bumped when the terminal theme/font changes so chrome can re-tint.
    var appearanceVersion = 0

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var gitTimer: Timer?
    @ObservationIgnored private var lastAttentionContext: AttentionContext?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSessionKeys: [SurfaceID: AgentSessionKey] = [:]

    init(engine: any AgentEngineProtocol, runtime: TerminalRuntime = .shared, store: StateStore? = StateStore()) {
        self.engine = engine
        self.runtime = runtime
        self.store = store
        runtime.onConfigurationChange = { [weak self] in
            self?.appearanceVersion += 1
        }
    }

    // MARK: Lifecycle

    /// Starts the engine and the update loop. Call once, after injection.
    func start() {
        let engine = self.engine
        Task { await engine.start() }
        updatesTask = Task { [weak self] in
            for await update in engine.updates() {
                guard let self else { return }
                self.apply(update)
            }
        }
        Task { [weak self] in
            let statuses = await engine.integrationStatuses()
            self?.integrations = statuses
        }
        gitTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGitInfo() }
        }
    }

    func shutdown() {
        saveNow()
        updatesTask?.cancel()
        gitTimer?.invalidate()
        for workspace in workspaces {
            for surface in workspace.surfaces.values { surface.terminal?.terminate() }
        }
        let engine = self.engine
        Task { await engine.stop() }
    }

    // MARK: Lookup

    var selectedWorkspace: Workspace? {
        selectedWorkspaceID.flatMap(workspace(id:)) ?? workspaces.first
    }

    func workspace(id: WorkspaceID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func workspace(containing surface: SurfaceID) -> Workspace? {
        workspaces.first { $0.surfaces[surface] != nil }
    }

    func surface(_ id: SurfaceID) -> PaneSurface? {
        for workspace in workspaces {
            if let surface = workspace.surfaces[id] { return surface }
        }
        return nil
    }

    var focusedSurface: PaneSurface? {
        selectedWorkspace?.focusedSurface
    }

    /// Sessions bound to panes of `workspace`, in pane order.
    func sessions(in workspace: Workspace) -> [AgentSession] {
        let order = workspace.layout.surfaceIDs
        return sessions
            .filter { session in session.surface.map { workspace.surfaces[$0] != nil } ?? false && session.state != .ended }
            .sorted { lhs, rhs in
                let left = lhs.surface.flatMap { order.firstIndex(of: $0) } ?? 0
                let right = rhs.surface.flatMap { order.firstIndex(of: $0) } ?? 0
                return left == right ? lhs.startedAt < rhs.startedAt : left < right
            }
    }

    /// Git branch from `.git/HEAD`, else what an agent in the workspace reported.
    func branch(of workspace: Workspace) -> String? {
        workspace.git?.branch ?? sessions(in: workspace).lazy.compactMap(\.branch).first
    }

    func sessions(on surface: SurfaceID) -> [AgentSession] {
        sessions.filter { $0.surface == surface && $0.state != .ended }
    }

    /// Sessions running outside Mothership (VS Code, iTerm, tmux…).
    var externalSessions: [AgentSession] {
        sessions.filter { $0.surface == nil && $0.state != .ended }
    }

    /// Whether a pane should glow: an agent there is waiting and the user isn't looking.
    func paneNeedsAttention(_ surface: SurfaceID) -> Bool {
        let waiting = sessions.contains { $0.surface == surface && ($0.state.isNeedsInput || $0.pendingPermission != nil) }
        guard waiting else { return false }
        let watching = appIsActive && selectedWorkspace?.focusedSurfaceID == surface
        return !watching
    }

    // MARK: Workspaces

    /// Creates a workspace with one terminal and selects it (when `focus`).
    @discardableResult
    func createWorkspace(
        cwd: String? = nil, name: String? = nil, command: String? = nil, focus: Bool = true,
        id: WorkspaceID = WorkspaceID(), insertAfterSelection: Bool = true
    ) -> (Workspace, PaneSurface) {
        let directory = Self.resolveDirectory(cwd ?? focusedSurface?.terminal?.workingDirectory ?? focusedSurface?.cwd)
        let surfaceID = SurfaceID()
        let workspace = Workspace(
            id: id, name: name ?? PathDisplay.folderName(directory), hasCustomName: name != nil,
            rootDirectory: directory, layout: .leaf(surfaceID)
        )
        let surface = makeSurface(id: surfaceID, kind: .terminal, workspace: workspace, cwd: directory, initialInput: command)
        workspace.surfaces[surfaceID] = surface
        workspace.focusedSurfaceID = surfaceID
        workspace.refreshGit()
        if insertAfterSelection, let selected = selectedWorkspaceID, let index = workspaces.firstIndex(where: { $0.id == selected }) {
            workspaces.insert(workspace, at: index + 1)
        } else {
            workspaces.append(workspace)
        }
        if focus || selectedWorkspaceID == nil {
            selectWorkspace(workspace.id)
        }
        scheduleSave()
        return (workspace, surface)
    }

    func selectWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspace(id: id) else { return }
        if selectedWorkspaceID != id {
            selectedWorkspaceID = id
            scheduleSave()
        }
        renamingWorkspaceID = renamingWorkspaceID == id ? id : nil
        if let focused = workspace.focusedSurface {
            requestFocus(focused.id)
        }
        // Looking at a workspace counts as seeing every pane in it.
        let engine = self.engine
        for surfaceID in workspace.visibleSurfaceIDs where sessions.contains(where: { $0.surface == surfaceID && $0.unread }) {
            Task { await engine.markRead(surface: surfaceID) }
        }
        pushAttentionContext()
    }

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        selectWorkspace(workspaces[index].id)
    }

    func selectAdjacentWorkspace(_ offset: Int) {
        guard !workspaces.isEmpty else { return }
        let current = workspaces.firstIndex { $0.id == selectedWorkspaceID } ?? 0
        let next = (current + offset + workspaces.count) % workspaces.count
        selectWorkspace(workspaces[next].id)
    }

    func closeWorkspace(_ id: WorkspaceID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces[index]
        for surface in workspace.surfaces.values { tearDown(surface) }
        workspaces.remove(at: index)
        if selectedWorkspaceID == id {
            selectedWorkspaceID = nil
            if !workspaces.isEmpty {
                selectWorkspace(workspaces[min(index, workspaces.count - 1)].id)
            }
        }
        pushAttentionContext()
        scheduleSave()
    }

    func moveWorkspace(_ id: WorkspaceID, to destination: Int) {
        guard let source = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(destination, workspaces.count - 1))
        guard source != target else { return }
        let workspace = workspaces.remove(at: source)
        workspaces.insert(workspace, at: target)
        scheduleSave()
    }

    func rename(_ id: WorkspaceID, to name: String) {
        guard let workspace = workspace(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            workspace.hasCustomName = false
            workspace.refreshGit()
        } else {
            workspace.name = trimmed
            workspace.hasCustomName = true
        }
        renamingWorkspaceID = nil
        scheduleSave()
    }

    func setColor(_ id: WorkspaceID, hex: String?) {
        workspace(id: id)?.colorHex = hex
        scheduleSave()
    }

    func togglePin(_ id: WorkspaceID) {
        guard let workspace = workspace(id: id) else { return }
        workspace.isPinned.toggle()
        // Pinned workspaces stay grouped at the top.
        let pinned = workspaces.filter(\.isPinned)
        let unpinned = workspaces.filter { !$0.isPinned }
        workspaces = pinned + unpinned
        scheduleSave()
    }

    // MARK: Panes

    /// Splits `target` (default: the focused pane) and returns the new surface.
    @discardableResult
    func split(
        _ target: SurfaceID? = nil, direction: SplitDirection, kind: SurfaceKind = .terminal,
        cwd: String? = nil, command: String? = nil, url: URL? = nil, focus: Bool = true
    ) -> PaneSurface? {
        guard let workspace = target.flatMap({ workspace(containing: $0) }) ?? selectedWorkspace,
              let anchor = target ?? workspace.focusedSurface?.id
        else { return nil }
        let anchorSurface = workspace.surfaces[anchor]
        let directory = Self.resolveDirectory(cwd ?? anchorSurface?.terminal?.workingDirectory ?? anchorSurface?.cwd ?? workspace.rootDirectory)
        let surfaceID = SurfaceID()
        let surface = makeSurface(id: surfaceID, kind: kind, workspace: workspace, cwd: directory, initialInput: command, url: url)
        workspace.surfaces[surfaceID] = surface
        workspace.zoomedSurfaceID = nil
        workspace.layout = workspace.layout.inserting(surfaceID, beside: anchor, direction: direction)
        if focus {
            if selectedWorkspaceID != workspace.id { selectWorkspace(workspace.id) }
            focusSurface(surfaceID)
        }
        pushAttentionContext()
        scheduleSave()
        return surface
    }

    /// Closes a pane; closing the last pane closes its workspace.
    func closeSurface(_ id: SurfaceID) {
        guard let workspace = workspace(containing: id), let surface = workspace.surfaces[id] else { return }
        let neighbor = workspace.layout.neighbor(of: id, toward: .left)
            ?? workspace.layout.neighbor(of: id, toward: .up)
            ?? workspace.layout.neighbor(of: id, toward: .right)
            ?? workspace.layout.neighbor(of: id, toward: .down)
        guard let remaining = workspace.layout.removing(id) else {
            closeWorkspace(workspace.id)
            return
        }
        tearDown(surface)
        workspace.surfaces[id] = nil
        if workspace.zoomedSurfaceID == id { workspace.zoomedSurfaceID = nil }
        workspace.layout = remaining
        if workspace.focusedSurfaceID == id {
            workspace.focusedSurfaceID = neighbor ?? remaining.surfaceIDs.first
            if workspace.id == selectedWorkspaceID, let next = workspace.focusedSurfaceID {
                requestFocus(next)
            }
        }
        pushAttentionContext()
        scheduleSave()
    }

    func closeFocusedPane() {
        guard let surface = focusedSurface else { return }
        closeSurface(surface.id)
    }

    /// Selects the surface's workspace and gives the pane keyboard focus.
    func focusSurface(_ id: SurfaceID) {
        guard let workspace = workspace(containing: id) else { return }
        workspace.focusedSurfaceID = id
        if let zoomed = workspace.zoomedSurfaceID, zoomed != id { workspace.zoomedSurfaceID = nil }
        if selectedWorkspaceID != workspace.id {
            selectWorkspace(workspace.id)
        } else {
            requestFocus(id)
        }
        surfaceDidFocus(id)
    }

    func moveFocus(_ direction: SplitDirection) {
        guard let workspace = selectedWorkspace, let current = workspace.focusedSurface?.id,
              workspace.zoomedSurfaceID == nil,
              let next = workspace.layout.neighbor(of: current, toward: direction)
        else { return }
        focusSurface(next)
    }

    func toggleZoom() {
        guard let workspace = selectedWorkspace, let focused = workspace.focusedSurface?.id else { return }
        guard workspace.layout.surfaceIDs.count > 1 || workspace.zoomedSurfaceID != nil else { return }
        workspace.zoomedSurfaceID = workspace.zoomedSurfaceID == nil ? focused : nil
        requestFocus(focused)
        pushAttentionContext()
    }

    func equalizeSplits() {
        guard let workspace = selectedWorkspace else { return }
        workspace.layout = workspace.layout.equalized()
        scheduleSave()
    }

    /// A divider drag finished; keeps the tree's fractions in sync without a rebuild.
    func updateFractions(_ workspaceID: WorkspaceID, path: [Int], fractions: [Double]) {
        guard let workspace = workspace(id: workspaceID) else { return }
        workspace.layout = workspace.layout.settingFractions(fractions, at: path)
        scheduleSave()
    }

    /// ⌘⇧B: a browser beside the focused pane (or focus the existing one).
    func openBrowserSplit(url: URL? = nil) {
        if let workspace = selectedWorkspace,
           let existing = workspace.orderedSurfaces.first(where: { $0.kind == .browser }) {
            if let url { _ = navigateBrowser?(existing.id, url); existing.url = url.absoluteString }
            focusSurface(existing.id)
            return
        }
        split(direction: .right, kind: .browser, url: url ?? URL(string: "http://localhost:3000"))
    }

    // MARK: Agents

    /// ⌘⇧U: the newest session that needs the user, else the newest unread one.
    func jumpToAttention() {
        let local = sessions.filter { $0.surface != nil && $0.state != .ended }
        let target = local.filter { $0.state.needsAttention || $0.pendingPermission != nil }.max { $0.lastActivity < $1.lastActivity }
            ?? local.filter(\.unread).max { $0.lastActivity < $1.lastActivity }
        guard let surface = target?.surface else { NSSound.beep(); return }
        focusSurface(surface)
    }

    func resolvePermission(_ request: PermissionRequest, decision: PermissionDecision) {
        resolvePermission(id: request.id, decision: decision)
    }

    /// For notification actions, which carry only the request ID.
    func resolvePermission(id: PermissionRequestID, decision: PermissionDecision) {
        let engine = self.engine
        Task { await engine.resolvePermission(id, decision: decision) }
    }

    /// Restore banner → paste the agent's resume command into the pane and press Enter.
    func resume(_ surfaceID: SurfaceID) {
        guard let surface = surface(surfaceID), let key = surface.resumeOffer else { return }
        surface.resumeOffer = nil
        let engine = self.engine
        Task { [weak self] in
            guard let command = await engine.resumeCommand(for: key) else {
                NSSound.beep()
                return
            }
            guard let terminal = self?.surface(surfaceID)?.terminal else { return }
            terminal.paste(text: command)
            terminal.sendKey(.enter)
            self?.focusSurface(surfaceID)
        }
    }

    func dismissResume(_ surfaceID: SurfaceID) {
        surface(surfaceID)?.resumeOffer = nil
        surface(surfaceID)?.lastAgentSession = nil
        scheduleSave()
    }

    func installIntegration(_ kind: AgentKind) async throws {
        try await engine.installIntegration(kind)
        integrations = await engine.integrationStatuses()
    }

    func uninstallIntegration(_ kind: AgentKind) async throws {
        try await engine.uninstallIntegration(kind)
        integrations = await engine.integrationStatuses()
    }

    // MARK: Engine plumbing

    private func apply(_ update: AgentEngineUpdate) {
        switch update {
        case .sessions(let list):
            if list != sessions { sessions = list }
            var changedBinding = false
            for session in list where session.state.isLive {
                guard let surfaceID = session.surface, let surface = surface(surfaceID) else { continue }
                if surface.lastAgentSession != session.id {
                    surface.lastAgentSession = session.id
                    changedBinding = true
                }
            }
            if changedBinding { scheduleSave() }
            onSessionsChanged?(list)
        case .attention(let event):
            onAttention?(event)
        case .permissionResolved:
            break
        case .integrations(let list):
            integrations = list
        }
    }

    /// A terminal or browser pane got keyboard focus.
    func surfaceDidFocus(_ id: SurfaceID) {
        guard let workspace = workspace(containing: id) else { return }
        if workspace.focusedSurfaceID != id {
            workspace.focusedSurfaceID = id
            scheduleSave()
        }
        if let surface = workspace.surfaces[id], let cwd = surface.terminal?.workingDirectory ?? surface.cwd,
           cwd != workspace.currentDirectory {
            workspace.currentDirectory = cwd
            workspace.refreshGit()
        }
        if appIsActive, sessions.contains(where: { $0.surface == id && $0.unread }) {
            let engine = self.engine
            Task { await engine.markRead(surface: id) }
        }
        pushAttentionContext()
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        if active, let focused = focusedSurface?.id {
            surfaceDidFocus(focused)
        } else {
            pushAttentionContext()
        }
    }

    func pushAttentionContext() {
        let visible = (host?.isWindowVisible ?? true) ? Set(selectedWorkspace?.visibleSurfaceIDs ?? []) : []
        let context = AttentionContext(
            focusedSurface: selectedWorkspace?.focusedSurfaceID, appIsActive: appIsActive, visibleSurfaces: visible
        )
        guard context != lastAttentionContext else { return }
        lastAttentionContext = context
        let engine = self.engine
        Task { await engine.attentionContextChanged(context) }
    }

    private func handleSignal(_ signal: TerminalSignal, from surfaceID: SurfaceID) {
        guard let surface = surface(surfaceID) else { return }
        switch signal {
        case .title(let title):
            surface.title = title
        case .workingDirectory(let path):
            surface.cwd = path
            if let workspace = workspace(containing: surfaceID), workspace.focusedSurface?.id == surfaceID {
                workspace.currentDirectory = path
                workspace.refreshGit()
            }
            scheduleSave()
        case .progress(let state, let percent):
            switch state {
            case "remove": surface.progress = nil
            case "set", "pause", "error": surface.progress = Double(percent ?? 0) / 100
            default: surface.progress = -1
            }
        default:
            break
        }
        let engine = self.engine
        Task { await engine.surfaceSignal(surfaceID, signal) }
    }

    // MARK: Surfaces

    func makeSurface(
        id: SurfaceID, kind: SurfaceKind, workspace: Workspace, cwd: String?, initialInput: String? = nil,
        url: URL? = nil
    ) -> PaneSurface {
        let surface = PaneSurface(id: id, kind: kind, workspaceID: workspace.id, cwd: cwd, url: url?.absoluteString)
        switch kind {
        case .terminal:
            let terminal = TerminalSurfaceController(
                surfaceID: id, workspaceID: workspace.id, workingDirectory: cwd, initialInput: initialInput,
                environment: shellEnvironment, runtime: runtime
            )
            terminal.onSignal = { [weak self] signal in self?.handleSignal(signal, from: id) }
            terminal.onFocusChange = { [weak self] focused in
                if focused { self?.surfaceDidFocus(id) }
            }
            terminal.onClose = { [weak self] _ in
                // Not from inside Ghostty's close callback: closing frees the surface.
                DispatchQueue.main.async { self?.closeSurface(id) }
            }
            terminal.onOpenURL = { [weak self] url in
                guard let self, url.scheme == "http" || url.scheme == "https",
                      url.host == "localhost" || url.host == "127.0.0.1" else { return false }
                // Local dev servers open beside the terminal; everything else in the default browser.
                self.openBrowserSplit(url: url)
                return true
            }
            surface.terminal = terminal
        case .browser:
            surface.browserView = makeBrowserView(id, workspace.id, url)
        }
        let engine = self.engine
        let workspaceID = workspace.id
        Task { await engine.surfaceOpened(id, workspace: workspaceID, cwd: cwd) }
        return surface
    }

    private func tearDown(_ surface: PaneSurface) {
        surface.terminal?.onClose = nil
        surface.terminal?.terminate()
        let engine = self.engine
        let id = surface.id
        Task { await engine.surfaceClosed(id) }
    }

    /// Focus now if the view is already in the window, otherwise right after layout.
    func requestFocus(_ id: SurfaceID) {
        guard let surface = surface(id) else { return }
        let attempt = { [weak self] in
            guard let self, let view = self.surface(id)?.contentView else { return }
            if let terminal = surface.terminal {
                if !terminal.focus() { self.host?.focus(view: view) }
            } else {
                self.host?.focus(view: view)
            }
        }
        attempt()
        DispatchQueue.main.async { attempt() }
    }

    private func refreshGitInfo() {
        for workspace in workspaces { workspace.refreshGit() }
    }

    static func resolveDirectory(_ path: String?) -> String {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.path
        guard let path, !path.isEmpty else { return fallback }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue ? expanded : fallback
    }

    // MARK: Persistence

    func makeSnapshot() -> AppSnapshot {
        AppSnapshot(windows: [
            WindowSnapshot(
                frame: host?.windowFrame, sidebarWidth: host?.sidebarWidth,
                workspaces: workspaces.map(\.snapshot), selectedWorkspace: selectedWorkspaceID
            ),
        ])
    }

    func scheduleSave() {
        guard store != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        store?.save(makeSnapshot())
    }

    /// Rebuilds workspaces from a snapshot. Surfaces keep their IDs, so shells see the same
    /// `MOTHERSHIP_SURFACE_ID` across relaunches.
    func restore(_ snapshot: WindowSnapshot) {
        for saved in snapshot.workspaces {
            let workspace = Workspace(
                id: saved.id, name: saved.name, hasCustomName: saved.hasCustomName, colorHex: saved.colorHex,
                isPinned: saved.isPinned, rootDirectory: saved.rootDirectory, layout: saved.layout
            )
            let descriptors = Dictionary(saved.surfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var layout = saved.layout
            for surfaceID in saved.layout.surfaceIDs {
                guard let descriptor = descriptors[surfaceID] else {
                    layout = layout.removing(surfaceID) ?? layout
                    continue
                }
                let surface = makeSurface(
                    id: surfaceID, kind: descriptor.kind, workspace: workspace,
                    cwd: Self.resolveDirectory(descriptor.cwd ?? saved.rootDirectory),
                    url: descriptor.url.flatMap(URL.init(string:))
                )
                surface.title = descriptor.title
                surface.lastAgentSession = descriptor.lastAgentSession
                surface.resumeOffer = descriptor.kind == .terminal ? descriptor.lastAgentSession : nil
                workspace.surfaces[surfaceID] = surface
            }
            guard !workspace.surfaces.isEmpty else { continue }
            workspace.layout = layout
            workspace.focusedSurfaceID = saved.focusedSurface.flatMap { workspace.surfaces[$0] != nil ? $0 : nil }
                ?? layout.surfaceIDs.first
            workspace.currentDirectory = workspace.focusedSurface?.cwd ?? saved.rootDirectory
            workspace.refreshGit()
            if saved.hasCustomName { workspace.name = saved.name }
            workspaces.append(workspace)
        }
        if let selected = snapshot.selectedWorkspace, workspace(id: selected) != nil {
            selectWorkspace(selected)
        } else if let first = workspaces.first {
            selectWorkspace(first.id)
        }
    }
}

extension AgentState {
    var isNeedsInput: Bool {
        if case .needsInput = self { return true }
        return false
    }

    var isWorking: Bool {
        switch self {
        case .working, .starting: true
        default: false
        }
    }
}
