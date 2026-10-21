import AppKit
import ShipModel
import SwiftUI

/// The single main window: no titlebar band, everything floating over the sky.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, AppWindowHost {
    let model: AppModel
    let router: CommandRouter
    let root: RootView
    private var clickMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    init(model: AppModel, router: CommandRouter, frame: [Double]?, sidebarWidth _: Double?) {
        self.model = model
        self.router = router
        root = RootView(model: model, router: router)

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Mothership"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 760, height: 480)
        // An empty unified toolbar makes the titlebar 52 pt, so AppKit itself centers the
        // window buttons on the top bar; with a transparent titlebar it draws nothing.
        let toolbar = NSToolbar(identifier: "Mothership.TopBar")
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentView = root
        // Layout and frame come from Mothership's own state file, not AppKit restoration.
        window.isRestorable = false
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self

        if let frame, frame.count == 4,
           case let rect = NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]),
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
            window.setFrame(rect, display: false)
        } else {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        model.host = self
        router.windowController = self
        model.systemIsDark = NSApp.effectiveAppearance.isDark
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            MainActor.assumeIsolated { self?.model.systemIsDark = app.effectiveAppearance.isDark }
        }
        root.onSkyChange = { [weak window] dark, transparent in
            window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window?.isOpaque = !transparent
            window?.backgroundColor = transparent ? .clear : (dark ? NSColor(srgbRed: 0.06, green: 0.07, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.55, green: 0.67, blue: 0.84, alpha: 1))
        }
        installPaneClickMonitor()
        window.positionTrafficLights()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Sidebar

    var isSidebarCollapsed: Bool { model.isSidebarCollapsed }

    func toggleSidebar() {
        withAnimationIfAllowed { model.isSidebarCollapsed.toggle() }
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

    var sidebarWidth: Double? { model.isSidebarCollapsed ? nil : Double(Sky.sidebarWidth) }

    var isWindowVisible: Bool {
        window?.occlusionState.contains(.visible) ?? false
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_: Notification) {
        (window as? MainWindow)?.positionTrafficLights()
        model.scheduleSave()
    }

    func windowDidMove(_: Notification) { model.scheduleSave() }
    func windowDidChangeOcclusionState(_: Notification) { model.pushAttentionContext() }
    func windowDidExitFullScreen(_: Notification) { (window as? MainWindow)?.positionTrafficLights() }

    func windowDidBecomeKey(_: Notification) {
        (window as? MainWindow)?.positionTrafficLights()
        model.setAppActive(NSApp.isActive)
    }

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
}

/// Keeps ⌘-shortcuts working while a SwiftUI text field (palette, composer, rename) is
/// focused, and floats the window buttons in the 52 pt top bar.
final class MainWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The unified toolbar already centers the buttons vertically; this only nudges them so
    /// the close button lines up with the sidebar's inner edge.
    func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen) else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: Sky.gutter + 10 + CGFloat(index) * 20, y: button.frame.origin.y))
        }
    }
}
