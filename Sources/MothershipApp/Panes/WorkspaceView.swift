import AppKit
import ShipModel

/// One workspace's pane tree. Rebuilds nested `PaneSplitView`s only when the tree's shape
/// changes; pane containers (and the terminals inside them) are reused across rebuilds.
@MainActor
final class WorkspaceView: NSView {
    static let inset: CGFloat = 0

    let workspace: Workspace
    private unowned let model: AppModel
    private var containers: [SurfaceID: PaneContainerView] = [:]
    private var root: NSView?
    private var builtVersion = -1
    private var builtZoom: SurfaceID?
    private var observation: ObservationLoop?

    init(workspace: Workspace, model: AppModel) {
        self.workspace = workspace
        self.model = model
        super.init(frame: .zero)
        observation = ObservationLoop { [weak self] in self?.sync() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func tearDown() {
        observation?.cancel()
        observation = nil
    }

    override func layout() {
        super.layout()
        root?.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    /// Frames of terminal views, in this view's coordinates (for snapshots).
    func paneFrames() -> [(SurfaceID, CGRect)] {
        containers.compactMap { id, container in
            guard !container.isHiddenOrHasHiddenAncestor, container.superview != nil else { return nil }
            return (id, container.convert(container.bounds, to: self))
        }
    }

    private func sync() {
        let version = workspace.structureVersion
        let zoom = workspace.zoomedSurfaceID
        let surfaceIDs = Set(workspace.surfaces.keys)
        if version != builtVersion || zoom != builtZoom || Set(containers.keys) != surfaceIDs {
            rebuild()
            builtVersion = version
            builtZoom = zoom
        }
        decorate()
    }

    private func rebuild() {
        // Drop containers for panes that are gone.
        for (id, container) in containers where workspace.surfaces[id] == nil {
            container.setContent(nil)
            container.removeFromSuperview()
            containers[id] = nil
        }
        root?.removeFromSuperview()
        let node: PaneNode = workspace.zoomedSurfaceID.map { PaneNode.leaf($0) } ?? workspace.layout
        let view = build(node, path: [])
        addSubview(view)
        root = view
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Re-parenting panes drops keyboard focus; hand it back to the focused pane.
        if model.selectedWorkspace?.id == workspace.id, let focused = workspace.focusedSurface?.id,
           !model.isPalettePresented, model.renamingWorkspaceID == nil {
            model.requestFocus(focused)
        }
    }

    private func build(_ node: PaneNode, path: [Int]) -> NSView {
        switch node {
        case .leaf(let id):
            return container(for: id)
        case .split(let axis, let fractions, let children):
            let views = children.enumerated().map { index, child in build(child, path: path + [index]) }
            let split = PaneSplitView(axis: axis, fractions: fractions, children: views, path: path)
            let workspaceID = workspace.id
            split.onFractionsCommitted = { [weak model] path, fractions in
                model?.updateFractions(workspaceID, path: path, fractions: fractions)
            }
            return split
        }
    }

    private func container(for id: SurfaceID) -> PaneContainerView {
        if let existing = containers[id] {
            existing.removeFromSuperview()
            return existing
        }
        let container = PaneContainerView(surfaceID: id)
        container.setContent(workspace.surfaces[id]?.contentView)
        containers[id] = container
        return container
    }

    private func decorate() {
        let multiplePanes = workspace.visibleSurfaceIDs.count > 1
        let focused = workspace.focusedSurface?.id
        _ = model.appearanceVersion
        let background = model.runtime.backgroundColor
        let dark = model.chromeIsDark
        let tint = model.tintWithSky
        let clearance: CGFloat = 0
        for (id, container) in containers {
            container.bottomClearance = clearance
            guard let surface = workspace.surfaces[id] else { continue }
            if container.content !== surface.contentView { container.setContent(surface.contentView) }
            let isFocused = id == focused
            let resume = surface.resumeOffer.map { key in
                (key: key, title: model.sessions.first { $0.id == key }?.title)
            }
            let session = model.sessions(on: id).first
            // Browser panes bring their own toolbar; only terminals get the hover capsule.
            let pullRequest = model.pullRequest(for: workspace.id)
            let task = model.task(for: workspace.id)
            let compareTask = (task?.runs.count ?? 0) > 1 ? task?.id : nil
            let chrome = surface.kind == .terminal
                ? PaneChromeModel(
                    title: session?.title ?? surface.meaningfulTitle ?? PathDisplay.short(surface.cwd ?? workspace.currentDirectory),
                    session: session, pinned: session.map { $0.state.isWorking || $0.needsYou } ?? false || pullRequest != nil,
                    pullRequest: pullRequest, compareTask: compareTask
                )
                : nil
            let workspaceID = workspace.id
            container.update(
                focused: isFocused && multiplePanes, dimmed: multiplePanes && !isFocused,
                attention: model.paneNeedsAttention(id),
                background: surface.kind == .terminal ? background : .skyBubble, tint: tint && surface.kind == .terminal,
                progress: surface.progress, resume: resume, chrome: chrome, dark: dark,
                actions: PaneActions(
                    onResume: { [weak model] in model?.resume(id) },
                    onDismissResume: { [weak model] in model?.dismissResume(id) },
                    onSplitRight: { [weak model] in model?.split(id, direction: .right) },
                    onSplitDown: { [weak model] in model?.split(id, direction: .down) },
                    onClose: { [weak model] in
                        if model?.workspace(id: workspaceID) != nil { model?.closeSurface(id) }
                    },
                    onOpenPullRequest: { [weak model] in
                        if let status = model?.pullRequest(for: workspaceID) { model?.openPullRequest(status, in: workspaceID) }
                    },
                    onCompare: { [weak model] in
                        if let task = model?.task(for: workspaceID) { model?.openCompare(task.id) }
                    }
                )
            )
        }
    }
}
