import AppKit
import ShipModel
import SwiftUI

/// The single main window: transparent titlebar, glass sidebar, pane canvas, palette overlay.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, AppWindowHost {
    let model: AppModel
    let router: CommandRouter
    private let root: RootViewController

    init(model: AppModel, router: CommandRouter, frame: [Double]?, sidebarWidth: Double?) {
        self.model = model
        self.router = router
        root = RootViewController(model: model, router: router, sidebarWidth: sidebarWidth)

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Mothership"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 640, height: 400)
        window.backgroundColor = .canvasShip
        window.contentViewController = root
        // Layout and frame come from Mothership's own state file, not AppKit restoration.
        window.isRestorable = false
        super.init(window: window)
        // Keep the restored frame exactly; there is only ever one main window.
        shouldCascadeWindows = false
        window.delegate = self

        if let frame, frame.count == 4 {
            let rect = NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                window.setFrame(rect, display: false)
            } else {
                window.setContentSize(NSSize(width: 1280, height: 800))
                window.center()
            }
        } else {
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
        }
        model.host = self
        router.windowController = self
        installPaneClickMonitor()
    }

    private var clickMonitor: Any?

    /// Terminals report focus themselves; other panes (browser) don't, so a click anywhere
    /// in a pane makes it the workspace's focused pane.
    private func installPaneClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      let contentView = window.contentView,
                      let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
                else { return }
                var view: NSView? = hit
                while let current = view, !(current is PaneContainerView) { view = current.superview }
                guard let pane = view as? PaneContainerView,
                      self.model.surface(pane.surfaceID)?.kind != .terminal else { return }
                self.model.surfaceDidFocus(pane.surfaceID)
                if let content = pane.content, !(window.firstResponder.map { ($0 as? NSView)?.isDescendant(of: content) ?? false } ?? false) {
                    window.makeFirstResponder(content)
                }
            }
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Sidebar

    var isSidebarCollapsed: Bool { root.split.isSidebarCollapsed }

    func toggleSidebar() {
        root.split.toggleSidebarAnimated()
    }

    // MARK: AppWindowHost

    func focus(view: NSView) {
        guard let window, view.window === window else { return }
        window.makeFirstResponder(view)
    }

    var windowFrame: [Double]? {
        guard let frame = window?.frame else { return nil }
        return [frame.origin.x, frame.origin.y, frame.width, frame.height]
    }

    var sidebarWidth: Double? { root.split.sidebarWidth }

    var isWindowVisible: Bool {
        window?.occlusionState.contains(.visible) ?? false
    }

    /// The canvas, for debug snapshots.
    var contentController: ContentViewController { root.split.content }

    /// Views drawn above the panes (the palette), for debug snapshots.
    var overlayViews: [NSView] { [root.paletteHost].compactMap { $0 } }

    // MARK: NSWindowDelegate

    func windowDidResize(_: Notification) { model.scheduleSave() }
    func windowDidMove(_: Notification) { model.scheduleSave() }
    func windowDidChangeOcclusionState(_: Notification) { model.pushAttentionContext() }

    func windowDidBecomeKey(_: Notification) {
        model.setAppActive(NSApp.isActive)
    }
}

/// Keeps ⌘-shortcuts working while a SwiftUI text field (palette, rename) is focused:
/// NSHostingView would otherwise swallow some key equivalents.
final class MainWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Root content: the split view controller plus a palette overlay above everything.
@MainActor
final class RootViewController: NSViewController {
    let model: AppModel
    let router: CommandRouter
    let split: MainSplitViewController
    private(set) var paletteHost: NSHostingView<CommandPaletteView>?
    private var observation: ObservationLoop?

    init(model: AppModel, router: CommandRouter, sidebarWidth: Double?) {
        self.model = model
        self.router = router
        split = MainSplitViewController(model: model, router: router, sidebarWidth: sidebarWidth)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        addChild(split)
        split.view.frame = view.bounds
        split.view.autoresizingMask = [.width, .height]
        view.addSubview(split.view)
        observation = ObservationLoop { [weak self] in self?.syncPalette() }
    }

    private func syncPalette() {
        let presented = model.isPalettePresented
        if presented, paletteHost == nil {
            let palette = CommandPaletteView(model: model, actions: router.paletteItems()) { [weak self] in
                self?.model.isPalettePresented = false
            }
            let host = NSHostingView(rootView: palette)
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            host.alphaValue = 0
            view.addSubview(host)
            paletteHost = host
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                host.animator().alphaValue = 1
            }
            view.window?.makeFirstResponder(host)
        } else if !presented, let host = paletteHost {
            paletteHost = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                host.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { host.removeFromSuperview() }
            })
            if let focused = model.focusedSurface?.id { model.requestFocus(focused) }
        }
    }
}

/// Sidebar (SwiftUI, glass) + content (AppKit panes).
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let model: AppModel
    let content: ContentViewController
    private let sidebarItem: NSSplitViewItem
    private let initialSidebarWidth: CGFloat

    init(model: AppModel, router: CommandRouter, sidebarWidth: Double?) {
        self.model = model
        content = ContentViewController(model: model, router: router)
        let sidebar = NSHostingController(rootView: SidebarView(model: model))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow + 10
        initialSidebarWidth = CGFloat(sidebarWidth ?? 268)
        super.init(nibName: nil, bundle: nil)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 360
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.autosaveName = nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        splitView.setPosition(initialSidebarWidth, ofDividerAt: 0)
    }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    var sidebarWidth: Double? {
        sidebarItem.isCollapsed ? nil : Double(sidebarItem.viewController.view.frame.width)
    }

    func toggleSidebarAnimated() {
        let collapse = !sidebarItem.isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = collapse
        }
        model.isSidebarCollapsed = collapse
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if model.isSidebarCollapsed != sidebarItem.isCollapsed {
            model.isSidebarCollapsed = sidebarItem.isCollapsed
        }
        model.scheduleSave()
    }
}
