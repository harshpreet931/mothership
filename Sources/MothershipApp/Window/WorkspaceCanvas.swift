import AppKit
import QuartzCore
import ShipModel

/// Stacks one `WorkspaceView` per workspace. Only the selected one shows; the others stay
/// in the window (so their shells keep ticking) but hidden and not rendering. Switching
/// crossfades with a 0.985 → 1 scale.
@MainActor
final class WorkspaceCanvas: NSView {
    private let model: AppModel
    private(set) var workspaceViews: [WorkspaceID: WorkspaceView] = [:]
    private var observation: ObservationLoop?
    private var shownWorkspace: WorkspaceID?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        observation = ObservationLoop { [weak self] in self?.sync() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for view in workspaceViews.values { view.frame = bounds }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    var selectedWorkspaceView: WorkspaceView? {
        model.selectedWorkspace.flatMap { workspaceViews[$0.id] }
    }

    private func sync() {
        let workspaces = model.workspaces
        let selected = model.selectedWorkspace?.id
        let showingPanes = model.screen == .workspaces
        let ids = Set(workspaces.map(\.id))

        for (id, view) in workspaceViews where !ids.contains(id) {
            view.tearDown()
            view.removeFromSuperview()
            workspaceViews[id] = nil
        }
        for workspace in workspaces where workspaceViews[workspace.id] == nil {
            let view = WorkspaceView(workspace: workspace, model: model)
            view.frame = bounds
            addSubview(view)
            workspaceViews[workspace.id] = view
        }
        for workspace in workspaces {
            let isSelected = workspace.id == selected
            workspaceViews[workspace.id]?.isHidden = !isSelected
            let visible = Set(workspace.visibleSurfaceIDs)
            for surface in workspace.surfaces.values {
                surface.terminal?.setVisible(showingPanes && isSelected && visible.contains(surface.id))
            }
        }
        if selected != shownWorkspace {
            if shownWorkspace != nil, let view = selected.flatMap({ workspaceViews[$0] }) { crossfade(view) }
            shownWorkspace = selected
        }
        model.pushAttentionContext()
    }

    private func crossfade(_ view: NSView) {
        guard !SkyAccessibility.reduceMotion, let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform")
        let bounds = view.bounds
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, 0.985, 0.985, 1)
        transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
        scale.fromValue = transform
        scale.toValue = CATransform3DIdentity
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "switch")
    }
}
