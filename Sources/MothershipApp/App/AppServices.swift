import AppKit
import AttentionKit
import BrowserKit
import ControlPlane
import ShipModel
import ShipProtocol

/// Wires the control socket, system notifications and browser panes to the app model.
/// `AppDelegate` owns one; everything else stays unaware of these modules.
@MainActor
final class AppServices {
    private let model: AppModel
    private let notifier = Notifier()
    private let router = ControlRouter()
    private var server: ControlServer?
    private var browsers: [SurfaceID: WeakBrowser] = [:]
    /// Held permission requests we've notified about, so resolved ones get withdrawn.
    private var notifiedPermissions: Set<PermissionRequestID> = []

    private struct WeakBrowser {
        weak var session: BrowserSession?
    }

    init(model: AppModel) {
        self.model = model
        installBrowserPanes()
        installAttention()
        installRoutes()
    }

    func start() {
        // The app always listens on its own socket, never an inherited MOTHERSHIP_SOCKET.
        let server = ControlServer(socketPath: ShipPaths.appSocket.path, handler: router)
        self.server = server
        Task {
            do {
                try await server.start()
            } catch {
                NSLog("Mothership: control socket unavailable: %@", "\(error)")
            }
        }
        Task { _ = await notifier.start() }
    }

    func stop() {
        guard let server else { return }
        Task { await server.stop() }
    }

    // MARK: Browser panes

    private func installBrowserPanes() {
        model.makeBrowserView = { [weak self] surface, workspace, url in
            let session = BrowserSession(workspace: workspace, surface: surface)
            session.onElementPicked = { [weak self] element in
                self?.sendToAgent(element.promptText, in: workspace)
            }
            self?.browsers[surface] = WeakBrowser(session: session)
            if let url {
                Task { _ = try? await session.navigate(to: url.absoluteString) }
            }
            return BrowserSurfaceView(session: session)
        }
        model.navigateBrowser = { [weak self] surface, url in
            guard let session = self?.browsers[surface]?.session else { return false }
            Task { _ = try? await session.navigate(to: url.absoluteString) }
            return true
        }
    }

    /// The browser pane a request targets: explicit id, else the caller's workspace, else
    /// the selected workspace.
    fileprivate func browser(_ id: SurfaceID?, caller: CallerContext) throws(RPCError) -> BrowserSession {
        if let id {
            guard let session = browsers[id]?.session else { throw .notFound("No browser pane \(id)") }
            return session
        }
        let workspace = caller.surface.flatMap { model.workspace(containing: $0) }
            ?? caller.workspace.flatMap { id in model.workspaces.first { $0.id == id } }
            ?? model.selectedWorkspace
        let session = workspace?.orderedSurfaces
            .filter { $0.kind == .browser }
            .lazy.compactMap { self.browsers[$0.id]?.session }
            .first
        guard let session else {
            throw .notFound("No browser pane in this workspace. Open one with browser_open first.")
        }
        return session
    }

    /// Pastes text into the workspace's agent pane (or its focused terminal) without submitting,
    /// so the user can add their own instruction before pressing Enter.
    private func sendToAgent(_ text: String, in workspaceID: WorkspaceID) {
        guard let workspace = model.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let terminals = workspace.orderedSurfaces.filter { $0.kind == .terminal }
        let agentSurface = model.sessions
            .filter { $0.state.isLive }
            .compactMap(\.surface)
            .first { id in terminals.contains { $0.id == id } }
        guard let target = agentSurface ?? workspace.focusedSurface.flatMap({ $0.kind == .terminal ? $0.id : nil })
            ?? terminals.first?.id
        else { return }
        try? model.sendText(SendTextParams(surface: target, text: text, submit: false))
        model.focusSurface(target)
    }

    // MARK: Attention

    private func installAttention() {
        notifier.onAction = { [weak self] action in self?.perform(action) }
        model.onAttention = { [weak self] event in
            guard let self else { return }
            notifier.attentionContext = currentContext()
            notifier.present(event, workspaceName: workspaceName(for: event.surface))
            if case .permission(let request) = event.kind { notifiedPermissions.insert(request.id) }
        }
        model.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            let pending = Set(sessions.compactMap(\.pendingPermission?.id))
            for id in notifiedPermissions.subtracting(pending) { notifier.withdraw(permission: id) }
            notifiedPermissions.formIntersection(pending)
            notifier.setBadge(count: sessions.filter(\.state.needsAttention).count)
        }
    }

    private func perform(_ action: NotificationAction) {
        switch action {
        case .allow(let id):
            model.resolvePermission(id: id, decision: .allow)
        case .deny(let id):
            model.resolvePermission(id: id, decision: .deny(reason: nil))
        case .open(let surface):
            NSApp.activate()
            if let surface { model.focusSurface(surface) } else { model.jumpToAttention() }
        case .reply(let surface, let text):
            try? model.sendText(SendTextParams(surface: surface, text: text, submit: true))
        }
    }

    private func currentContext() -> AttentionContext {
        let workspace = model.selectedWorkspace
        return AttentionContext(
            focusedSurface: workspace?.focusedSurfaceID, appIsActive: NSApp.isActive,
            visibleSurfaces: Set(workspace?.visibleSurfaceIDs ?? [])
        )
    }

    private func workspaceName(for surface: SurfaceID?) -> String? {
        surface.flatMap { model.workspace(containing: $0)?.name }
    }

    /// The held request to answer: by id, else the one on `surface`, else the only one waiting.
    fileprivate func pendingPermission(id: PermissionRequestID?, surface: SurfaceID?) throws(RPCError) -> PermissionRequest {
        let pending = model.sessions.compactMap(\.pendingPermission)
        if let id {
            guard let request = pending.first(where: { $0.id == id }) else { throw .notFound("No waiting request \(id)") }
            return request
        }
        if let surface, let request = pending.first(where: { $0.surface == surface }) { return request }
        guard pending.count == 1, let only = pending.first else {
            throw pending.isEmpty
                ? .notFound("No permission request is waiting")
                : .invalidParams("\(pending.count) requests are waiting; pass an id (see `mship status`)")
        }
        return only
    }

    private func notify(_ params: NotifyParams, caller: CallerContext) {
        let surface = params.surface ?? caller.surface
        let context = currentContext()
        let event = AttentionEvent(
            kind: .notification, session: nil, surface: surface, title: params.title, body: params.body,
            shouldNotify: !context.isWatching(surface)
        )
        notifier.attentionContext = context
        notifier.present(event, workspaceName: workspaceName(for: surface))
    }

    // MARK: Control socket

    // A nil `surface` means "the caller's own pane" (from its MOTHERSHIP_SURFACE_ID), and the
    // model falls back to the focused pane when the caller runs outside Mothership.
    private func installRoutes() {
        let model = self.model
        let engine = model.engine

        router.on(.hook) { (hook: HookEnvelope, _) in await engine.handleHook(hook) }
        router.on(.notify) { [weak self] (params: NotifyParams, context) -> OKResult in
            await self?.notify(params, caller: context.caller)
            return OKResult()
        }
        router.on(.status) { (params: StatusParams, _) -> StatusResult in
            let sessions = await engine.sessions()
            return StatusResult(
                workspaces: await model.workspaceSummaries(),
                sessions: params.includeExternal ? sessions : sessions.filter { $0.surface != nil }
            )
        }

        router.on(.permissionResolve) { [weak self] (params: ResolvePermissionParams, context) -> ResolvePermissionResult in
            guard let self else { throw RPCError.internalError("Mothership is shutting down") }
            let request = try await self.pendingPermission(id: params.id, surface: params.surface ?? context.caller.surface)
            await model.resolvePermission(id: request.id, decision: params.allow ? .allow : .deny(reason: params.reason))
            return ResolvePermissionResult(request: request)
        }

        router.on(.workspaceNew) { (params: NewWorkspaceParams, _) in await model.newWorkspace(params) }
        router.on(.surfaceSplit) { (params: SplitParams, context) in
            var params = params
            params.surface = params.surface ?? context.caller.surface
            return try await model.split(params)
        }
        router.on(.surfaceFocus) { (params: SurfaceTarget, context) -> OKResult in
            guard let surface = params.surface ?? context.caller.surface else {
                throw RPCError.invalidParams("surface is required outside Mothership")
            }
            try await model.focus(surface)
            await MainActor.run { NSApp.activate() }
            return OKResult()
        }
        router.on(.surfaceSendText) { (params: SendTextParams, _) -> OKResult in
            try await model.sendText(params)
            return OKResult()
        }
        router.on(.surfaceReadScreen) { (params: ReadScreenParams, context) in
            var params = params
            params.surface = params.surface ?? context.caller.surface
            return try await model.readScreen(params)
        }

        router.on(.browserOpen) { (params: BrowserOpenParams, context) in
            var params = params
            params.surface = params.surface ?? context.caller.surface
            return try await model.openBrowser(params)
        }
        router.on(.browserSnapshot) { [weak self] (params: BrowserTarget, context) -> BrowserSnapshotResult in
            let snapshot = try await self.session(params.browser, context).snapshot()
            return BrowserSnapshotResult(url: snapshot.url, title: snapshot.title, outline: snapshot.outline)
        }
        router.on(.browserClick) { [weak self] (params: BrowserElementParams, context) -> OKResult in
            try await self.session(params.browser, context).click(ref: params.ref)
            return OKResult()
        }
        router.on(.browserFill) { [weak self] (params: BrowserFillParams, context) -> OKResult in
            try await self.session(params.browser, context).fill(ref: params.ref, text: params.text, submit: params.submit)
            return OKResult()
        }
        router.on(.browserEval) { [weak self] (params: BrowserEvalParams, context) in
            try await self.session(params.browser, context).evaluate(params.script)
        }
        router.on(.browserConsole) { [weak self] (params: BrowserTarget, context) -> BrowserConsoleResult in
            let entries = try await self.session(params.browser, context).consoleEntries()
            return BrowserConsoleResult(entries: entries.map {
                BrowserConsoleEntry(level: $0.level, message: $0.message, date: $0.date)
            })
        }
        router.on(.browserScreenshot) { [weak self] (params: BrowserTarget, context) -> BrowserScreenshotResult in
            let url = try await self.session(params.browser, context).screenshot()
            return BrowserScreenshotResult(path: url.path)
        }
    }
}

private extension Optional where Wrapped == AppServices {
    /// Resolves the target browser session on the main actor, failing cleanly if the app is
    /// shutting down.
    func session(_ id: SurfaceID?, _ context: ControlContext) async throws(RPCError) -> BrowserSession {
        guard let services = self else { throw .internalError("Mothership is shutting down") }
        return try await services.browser(id, caller: context.caller)
    }
}
