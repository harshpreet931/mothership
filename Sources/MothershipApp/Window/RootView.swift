import AppKit
import ShipModel
import SwiftUI

/// The window's layers, bottom to top: sky → pane canvas → full-window screens (Home,
/// Fleet, Settings) → sidebar → composer → top bar → attention stack → palette. Every
/// layer floats with 10 pt gutters where the sky shows (§5).
@MainActor
final class RootView: NSView {
    let model: AppModel
    let router: CommandRouter
    let canvas: WorkspaceCanvas
    private let skyHost: NSHostingView<SkyLayer>
    private let desktopBlur = NSVisualEffectView()
    private let screenHost: NSHostingView<ScreenLayer>
    private let sidebarHost: NSHostingView<SidebarView>
    private let composerHost: NSHostingView<ComposerView>
    private let topBarHost: NSHostingView<TopBar>
    private let toastHost: SizingHostingView<ToastLayer>
    private(set) var paletteHost: NSHostingView<CommandPaletteView>?
    private var observation: ObservationLoop?
    private var keyMonitor: Any?
    private let toastHover = ToastHover()
    private var peeking = false {
        didSet { if peeking != oldValue { animateLayout() } }
    }
    private var edgeArea: NSTrackingArea?
    private var sidebarArea: NSTrackingArea?
    private var lastScreen: AppScreen = .workspaces

    /// Tells the window to adopt the sky's appearance (dark chrome?, see-through?).
    var onSkyChange: ((Bool, Bool) -> Void)?

    init(model: AppModel, router: CommandRouter) {
        self.model = model
        self.router = router
        canvas = WorkspaceCanvas(model: model)
        skyHost = Self.host(SkyLayer(model: model))
        screenHost = Self.host(ScreenLayer(model: model))
        sidebarHost = Self.host(SidebarView(model: model))
        composerHost = Self.host(ComposerView(model: model))
        topBarHost = Self.host(TopBar(model: model, router: router))
        toastHost = SizingHostingView(rootView: ToastLayer(model: model, hover: toastHover))
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        wantsLayer = true

        desktopBlur.material = .underWindowBackground
        desktopBlur.blendingMode = .behindWindow
        desktopBlur.state = .active
        desktopBlur.isHidden = true
        for view in [desktopBlur, skyHost, canvas, screenHost, sidebarHost, composerHost, topBarHost, toastHost] as [NSView] {
            addSubview(view)
        }
        observation = ObservationLoop { [weak self] in self?.sync() }
        toastHost.onSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.layoutToasts() }
        }
        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.safeAreaRegions = []
        return host
    }

    override var isFlipped: Bool { true }

    // MARK: Layout

    struct Frames {
        var sidebar: NSRect
        var sidebarVisible: Bool
        var content: NSRect
        var composer: NSRect
        var screen: NSRect
    }

    func frames(for size: NSSize) -> Frames {
        let gutter = Sky.gutter
        let top = Sky.topBarHeight
        let screen = model.screen
        let sidebarAllowed = screen == .workspaces || screen == .fleet
        let docked = sidebarAllowed && !model.isSidebarCollapsed
        let sidebarVisible = docked || (sidebarAllowed && peeking)
        let composerVisible = model.isComposerVisible && screen != .settings
        let bottom = composerVisible ? 44 + gutter * 2 : gutter
        let left = docked ? gutter * 2 + Sky.sidebarWidth : gutter

        let sidebarX = sidebarVisible ? gutter : -Sky.sidebarWidth - gutter
        let sidebar = NSRect(x: sidebarX, y: top, width: Sky.sidebarWidth, height: max(0, size.height - top - gutter))
        let content = NSRect(x: left, y: top, width: max(0, size.width - left - gutter), height: max(0, size.height - top - bottom))
        let composerLeft = screen == .home ? 0 : left
        let composer = NSRect(x: composerLeft, y: size.height - gutter - 44, width: size.width - composerLeft - (screen == .home ? 0 : gutter), height: 44)
        let screenFrame: NSRect = switch screen {
        case .home: NSRect(x: 0, y: top, width: size.width, height: max(0, size.height - top - bottom))
        case .settings: NSRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        case .fleet, .workspaces: content
        }
        return Frames(sidebar: sidebar, sidebarVisible: sidebarVisible, content: content, composer: composer, screen: screenFrame)
    }

    override func layout() {
        super.layout()
        apply(frames(for: bounds.size), animated: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private func apply(_ frames: Frames, animated: Bool) {
        skyHost.frame = bounds
        desktopBlur.frame = bounds
        topBarHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Sky.topBarHeight)
        layoutToasts()
        paletteHost?.frame = bounds
        let targets: [(NSView, NSRect)] = [
            (canvas, frames.content), (screenHost, frames.screen), (sidebarHost, frames.sidebar), (composerHost, frames.composer),
        ]
        if animated, !SkyAccessibility.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                context.allowsImplicitAnimation = true
                for (view, frame) in targets { view.animator().frame = frame }
            }
        } else {
            for (view, frame) in targets { view.frame = frame }
        }
        updateTrackingAreas()
    }

    /// Exactly the stack's size (it grows while fanned), so it never blocks panes beneath it.
    private func layoutToasts() {
        let size = toastHost.intrinsicContentSize
        let height = min(max(size.height, 1), bounds.height - Sky.topBarHeight - 20)
        toastHost.frame = NSRect(x: bounds.width - Sky.gutter - 344, y: Sky.topBarHeight + 4, width: 344, height: height)
    }

    private func animateLayout() {
        apply(frames(for: bounds.size), animated: true)
    }

    // MARK: Model sync

    private func sync() {
        let screen = model.screen
        _ = model.isSidebarCollapsed
        _ = model.isComposerVisible
        let showPanes = screen == .workspaces && !model.workspaces.isEmpty
        canvas.isHidden = !showPanes
        screenHost.isHidden = screen == .workspaces && !model.workspaces.isEmpty
        composerHost.isHidden = !(model.isComposerVisible && screen != .settings)
        toastHost.isHidden = model.toasts.isEmpty || screen == .settings
        _ = model.toasts.count

        let sky = model.resolvedSky
        desktopBlur.isHidden = sky != .desktop
        onSkyChange?(model.chromeIsDark, sky == .desktop)

        if screen != lastScreen {
            // Keys must not reach a terminal that isn't on screen.
            if screen != .workspaces, let window, window.firstResponder is NSView,
               (window.firstResponder as? NSView)?.isDescendant(of: canvas) == true {
                window.makeFirstResponder(nil)
            }
            lastScreen = screen
        }
        syncPalette()
        animateLayout()
    }

    private func syncPalette() {
        let presented = model.isPalettePresented
        if presented, paletteHost == nil {
            let palette = CommandPaletteView(model: model, actions: router.paletteItems()) { [weak self] in
                self?.model.isPalettePresented = false
            }
            let host = Self.host(palette)
            host.frame = bounds
            host.alphaValue = 0
            addSubview(host)
            paletteHost = host
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                host.animator().alphaValue = 1
            }
            window?.makeFirstResponder(host)
        } else if !presented, let host = paletteHost {
            paletteHost = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                host.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { host.removeFromSuperview() }
            })
            if model.screen == .workspaces, let focused = model.focusedSurface?.id { model.requestFocus(focused) }
        }
    }

    /// Hosting views stacked above the canvas, in z-order (for snapshots).
    var chromeLayers: [NSView] {
        [screenHost, sidebarHost, composerHost, topBarHost, toastHost] + [paletteHost].compactMap { $0 }
    }

    // MARK: Sidebar peek (hover the left edge while collapsed)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let edgeArea { removeTrackingArea(edgeArea) }
        if let sidebarArea { removeTrackingArea(sidebarArea) }
        edgeArea = nil
        sidebarArea = nil
        guard model.isSidebarCollapsed, model.screen == .workspaces || model.screen == .fleet else { return }
        let edge = NSTrackingArea(rect: NSRect(x: 0, y: Sky.topBarHeight, width: 6, height: bounds.height), options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["edge": true])
        addTrackingArea(edge)
        edgeArea = edge
        if peeking {
            let area = NSTrackingArea(rect: sidebarHost.frame.insetBy(dx: -12, dy: -12), options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["sidebar": true])
            addTrackingArea(area)
            sidebarArea = area
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["edge"] != nil { peeking = true }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["sidebar"] != nil { peeking = false }
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            let isOurWindow = event.window.map { ObjectIdentifier($0) }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, isOurWindow == ObjectIdentifier(window),
                      !self.model.isPalettePresented else { return false }
                if self.toastHover.hovering, !self.model.toasts.isEmpty {
                    self.model.dismissToast()
                    return true
                }
                // Esc backs out of Home, Fleet and Settings, unless a text field is editing.
                let editing = window.firstResponder is NSTextView
                guard !editing, self.model.screen != .workspaces else { return false }
                self.model.show(.workspaces)
                return true
            }
            return consumed ? nil : event
        }
    }
}

// MARK: SwiftUI layers

/// The sky, re-rendered when the preset changes.
struct SkyLayer: View {
    let model: AppModel
    var body: some View {
        SkyBackdrop(preset: model.resolvedSky)
            .animation(.easeInOut(duration: 0.6), value: model.resolvedSky)
    }
}

/// Home, Fleet, Settings, or the empty state.
struct ScreenLayer: View {
    let model: AppModel
    var body: some View {
        ZStack {
            switch model.screen {
            case .home:
                HomeView(model: model)
            case .fleet:
                FleetView(model: model)
            case .settings:
                SettingsPage(model: model)
            case .workspaces:
                if model.workspaces.isEmpty { EmptyStateView(model: model) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }
}

struct EmptyStateView: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            MothershipMark(variant: .sky, size: 72)
                .padding(.bottom, -8)
            Text("Nothing running.")
                .font(Sky.Font.serifL)
                .foregroundStyle(Sky.ink)
            HStack(spacing: 8) {
                Button("Start a task") { model.composerFocusRequest += 1 }
                    .buttonStyle(InkCapsuleStyle(height: 32))
                Button("New workspace") { model.createWorkspace() }
                    .buttonStyle(SecondaryPillStyle(height: 32))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
@Observable
final class ToastHover {
    var hovering = false
}

struct ToastLayer: View {
    let model: AppModel
    let hover: ToastHover
    var body: some View {
        AttentionStack(model: model, hovering: Binding(get: { hover.hovering }, set: { hover.hovering = $0 }))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reports SwiftUI size changes so its owner can re-frame it to the content.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        safeAreaRegions = []
    }

    @available(*, unavailable)
    @MainActor @preconcurrency required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}
