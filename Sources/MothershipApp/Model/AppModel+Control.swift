import Foundation
import ShipModel
import ShipProtocol
import TerminalEngine

/// Control-plane actions, one per `ShipProtocol.ControlMethod` the app implements. The
/// `ControlHandling` router decodes params, resolves a nil `surface` from the caller's
/// `MOTHERSHIP_SURFACE_ID` when it can, and calls these on the main actor. A nil surface
/// that reaches here means "the focused pane".
extension AppModel {
    /// `workspace.new`
    func newWorkspace(_ params: NewWorkspaceParams) -> SurfaceResult {
        let (workspace, surface) = createWorkspace(
            cwd: params.cwd, name: params.name, command: params.command, focus: params.focus
        )
        return SurfaceResult(surface: surface.id, workspace: workspace.id)
    }

    /// `surface.split`
    func split(_ params: SplitParams) throws(RPCError) -> SurfaceResult {
        let target = try resolveSurface(params.surface)
        guard let workspace = workspace(containing: target) else { throw .notFound("No workspace for surface \(target)") }
        let url = params.url.flatMap(URL.init(string:))
        if params.kind == .browser, params.url != nil, url == nil {
            throw .invalidParams("Invalid URL: \(params.url ?? "")")
        }
        guard let surface = split(
            target, direction: params.direction, kind: params.kind, cwd: params.cwd, command: params.command,
            url: url, focus: params.focus
        ) else { throw .internalError("Could not split surface \(target)") }
        return SurfaceResult(surface: surface.id, workspace: workspace.id)
    }

    /// `surface.focus`
    func focus(_ surfaceID: SurfaceID) throws(RPCError) {
        guard surface(surfaceID) != nil else { throw .notFound("No surface \(surfaceID)") }
        focusSurface(surfaceID)
    }

    /// `surface.sendText`: bracketed paste, then Enter when `submit`.
    func sendText(_ params: SendTextParams) throws(RPCError) {
        guard let surface = surface(params.surface) else { throw .notFound("No surface \(params.surface)") }
        guard let terminal = surface.terminal else { throw .invalidParams("Surface \(params.surface) is not a terminal") }
        let keys = try (params.keys ?? []).map { (name) throws(RPCError) -> TerminalKeyInput in
            guard let key = TerminalKeyInput(name: name) else { throw .invalidParams("Unknown key '\(name)'") }
            return key
        }
        if !params.text.isEmpty { terminal.paste(text: params.text) }
        if params.submit { terminal.sendKey(.enter) }
        for key in keys { terminal.sendKey(key) }
    }

    /// `surface.close`: as closing the pane in the UI (its process and session end).
    func closePane(_ surfaceID: SurfaceID) throws(RPCError) {
        guard surface(surfaceID) != nil else { throw .notFound("No surface \(surfaceID)") }
        closeSurface(surfaceID)
    }

    /// `surface.readScreen`
    func readScreen(_ params: ReadScreenParams) throws(RPCError) -> ReadScreenResult {
        let target = try resolveSurface(params.surface)
        guard let terminal = surface(target)?.terminal else { throw .invalidParams("Surface \(target) is not a terminal") }
        guard let text = terminal.readScreenText(scrollbackLines: params.scrollbackLines) else {
            throw .internalError("Surface \(target) has no screen yet")
        }
        return ReadScreenResult(text: text)
    }

    /// `browser.open` placement: reuse the workspace's browser pane, split, or a new workspace.
    func openBrowser(_ params: BrowserOpenParams) throws(RPCError) -> SurfaceResult {
        guard let url = URL(string: params.url) else { throw .invalidParams("Invalid URL: \(params.url)") }
        switch params.placement {
        case .newWorkspace:
            let (workspace, terminal) = createWorkspace(focus: true)
            guard let browser = split(terminal.id, direction: .right, kind: .browser, url: url, focus: true) else {
                throw .internalError("Could not open browser")
            }
            return SurfaceResult(surface: browser.id, workspace: workspace.id)
        case .reuse, .split:
            let anchor = try resolveSurface(params.surface)
            guard let workspace = workspace(containing: anchor) else { throw .notFound("No workspace for surface \(anchor)") }
            if let existing = workspace.orderedSurfaces.first(where: { $0.kind == .browser }) {
                existing.url = url.absoluteString
                _ = navigateBrowser?(existing.id, url)
                return SurfaceResult(surface: existing.id, workspace: workspace.id)
            }
            guard let browser = split(anchor, direction: .right, kind: .browser, url: url, focus: false) else {
                throw .internalError("Could not open browser")
            }
            return SurfaceResult(surface: browser.id, workspace: workspace.id)
        }
    }

    /// `status` (workspaces half; sessions come from the engine).
    func workspaceSummaries() -> [WorkspaceSummary] {
        workspaces.map { workspace in
            WorkspaceSummary(
                id: workspace.id, name: workspace.name, rootDirectory: workspace.rootDirectory,
                surfaces: workspace.layout.surfaceIDs
            )
        }
    }

    /// Which workspace a surface belongs to (for scoping MCP tools to the caller's workspace).
    func workspace(for surfaceID: SurfaceID) -> WorkspaceID? {
        workspace(containing: surfaceID)?.id
    }

    func surfaceKind(_ surfaceID: SurfaceID) -> SurfaceKind? {
        surface(surfaceID)?.kind
    }

    private func resolveSurface(_ surfaceID: SurfaceID?) throws(RPCError) -> SurfaceID {
        if let surfaceID {
            guard surface(surfaceID) != nil else { throw .notFound("No surface \(surfaceID)") }
            return surfaceID
        }
        guard let focused = focusedSurface?.id else { throw .notFound("No focused surface") }
        return focused
    }
}
