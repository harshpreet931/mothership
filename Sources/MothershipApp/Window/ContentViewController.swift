import AppKit
import ShipModel
import SwiftUI

/// The right side of the window: a slim header over the canvas that stacks one
/// `WorkspaceView` per workspace. Only the selected one is shown; the others stay in the
/// window (so their shells keep ticking) but hidden and not rendering.
@MainActor
final class ContentViewController: NSViewController {
    /// Twice the window buttons' center (16 pt), so the title lines up with them.
    static let headerHeight: CGFloat = 32
    /// Breathing room between the header row and the panes.
    static let topGap: CGFloat = 4

    let model: AppModel
    let router: CommandRouter
    private let canvas = CanvasView()
    private var header: NSHostingView<ContentHeader>?
    private var emptyState: NSHostingView<EmptyStateView>?
    private(set) var workspaceViews: [WorkspaceID: WorkspaceView] = [:]
    private var observation: ObservationLoop?

    init(model: AppModel, router: CommandRouter) {
        self.model = model
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = ContentRootView()
        root.wantsLayer = true
        view = root

        root.addSubview(canvas)
        let header = NSHostingView(rootView: ContentHeader(model: model, router: router))
        header.sizingOptions = []
        // The header *is* the titlebar row; the titlebar safe area must not push it around.
        header.safeAreaRegions = []
        root.addSubview(header)
        self.header = header

        let empty = NSHostingView(rootView: EmptyStateView(model: model))
        empty.sizingOptions = []
        empty.isHidden = true
        root.addSubview(empty)
        emptyState = empty

        root.onLayout = { [weak self] in self?.layoutChrome() }
        observation = ObservationLoop { [weak self] in self?.sync() }
    }

    private func layoutChrome() {
        let bounds = view.bounds
        let headerHeight = Self.headerHeight
        header?.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        let canvasFrame = NSRect(
            x: 0, y: 0, width: bounds.width,
            height: max(0, bounds.height - headerHeight - Self.topGap + WorkspaceView.inset)
        )
        canvas.frame = canvasFrame
        emptyState?.frame = canvasFrame
    }

    var headerDebugDescription: String {
        guard let header else { return "no header" }
        return "header frame \(NSStringFromRect(header.frame)) in root \(NSStringFromRect(view.bounds)), safe area \(header.safeAreaInsets)"
    }

    /// Workspace view whose panes are on screen.
    var selectedWorkspaceView: WorkspaceView? {
        model.selectedWorkspace.flatMap { workspaceViews[$0.id] }
    }

    func canvasFrameInWindowContent() -> NSRect {
        canvas.convert(canvas.bounds, to: nil)
    }

    private func sync() {
        let workspaces = model.workspaces
        let selected = model.selectedWorkspace?.id
        let ids = Set(workspaces.map(\.id))

        for (id, view) in workspaceViews where !ids.contains(id) {
            view.tearDown()
            view.removeFromSuperview()
            workspaceViews[id] = nil
        }
        for workspace in workspaces where workspaceViews[workspace.id] == nil {
            let view = WorkspaceView(workspace: workspace, model: model)
            view.frame = canvas.bounds
            view.autoresizingMask = [.width, .height]
            canvas.addSubview(view)
            workspaceViews[workspace.id] = view
        }
        for workspace in workspaces {
            let isSelected = workspace.id == selected
            workspaceViews[workspace.id]?.isHidden = !isSelected
            let visible = Set(workspace.visibleSurfaceIDs)
            for surface in workspace.surfaces.values {
                surface.terminal?.setVisible(isSelected && visible.contains(surface.id))
            }
        }
        emptyState?.isHidden = !workspaces.isEmpty
        model.pushAttentionContext()
    }
}

/// Lays out its children on every size change (it has no constraints to do it).
final class ContentRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.canvasShip.cgColor
        }
    }
}

final class CanvasView: NSView {
    override var isFlipped: Bool { true }
}

/// Workspace title, location and quick actions, sitting in the transparent titlebar.
struct ContentHeader: View {
    let model: AppModel
    let router: CommandRouter

    var body: some View {
        let workspace = model.selectedWorkspace
        let focused = workspace?.focusedSurface
        HStack(spacing: 10) {
            if model.isSidebarCollapsed {
                Color.clear.frame(width: 66)
                headerButton("sidebar.left", help: "Show Sidebar (⌘B)") { router.perform(.toggleSidebar) }
            }
            if let workspace {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let branch = model.branch(of: workspace) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9, weight: .semibold))
                            Text(branch)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .lineLimit(1)
                    }
                    Text(PathDisplay.short(focused?.cwd ?? workspace.currentDirectory, maxComponents: 4))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let title = focused?.meaningfulTitle {
                        Text("·").foregroundStyle(.quaternary)
                        Text(title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if workspace.zoomedSurfaceID != nil {
                        Text("ZOOMED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 0) {
                headerButton("rectangle.split.2x1", help: "Split Right (⌘D)") { router.perform(.splitRight) }
                headerButton("rectangle.split.1x2", help: "Split Down (⌘⇧D)") { router.perform(.splitDown) }
                headerButton("safari", help: "Browser (⌘⇧B)") { router.perform(.openBrowser) }
                headerButton("command", help: "Command Palette (⌘K)") { router.perform(.commandPalette) }
            }
            .padding(.horizontal, 3)
            .glassEffect(.regular, in: Capsule())
            .disabled(workspace == nil)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HeaderIconButton(symbol: symbol, action: action)
            .help(help)
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 30, height: 24)
                .background(hovering ? Color.primary.opacity(0.09) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ShipMark()
                .frame(width: 56, height: 56)
                .opacity(0.9)
            Text("No workspaces")
                .font(.system(size: 17, weight: .semibold))
            Text("A workspace is a vertical tab with its own panes and agents.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Button {
                model.createWorkspace()
            } label: {
                Label("New Workspace", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.large)
            .padding(.top, 4)
            Text("⌘T")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The orbit mark, drawn in SwiftUI (the app icon draws the same shape in CoreGraphics).
struct ShipMark: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let orbit = Path(ellipseIn: CGRect(x: rect.minX + size.width * 0.06, y: center.y - size.height * 0.2, width: size.width * 0.88, height: size.height * 0.4))
            let tilted = orbit.applying(
                CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -.pi / 9).translatedBy(x: -center.x, y: -center.y)
            )
            context.stroke(tilted, with: .color(Palette.accent.opacity(0.85)), lineWidth: size.width * 0.045)
            let core = Path(ellipseIn: CGRect(x: center.x - size.width * 0.17, y: center.y - size.height * 0.17, width: size.width * 0.34, height: size.height * 0.34))
            context.fill(core, with: .linearGradient(
                Gradient(colors: [Color(red: 0.62, green: 0.68, blue: 1), Color(red: 0.36, green: 0.40, blue: 0.95)]),
                startPoint: CGPoint(x: center.x, y: center.y - size.height * 0.17),
                endPoint: CGPoint(x: center.x, y: center.y + size.height * 0.17)
            ))
            let moon = Path(ellipseIn: CGRect(x: rect.minX + size.width * 0.82, y: center.y - size.height * 0.2, width: size.width * 0.1, height: size.width * 0.1))
            context.fill(moon, with: .color(Palette.attention))
        }
    }
}
