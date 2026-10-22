import AppKit
import BackdropKit
import ThemeKit

/// What RootView needs from the backdrop renderer.
@MainActor
protocol SkyRendering: NSView {
    /// From `MotionPolicy` (the Motion setting, battery, Low Power, background).
    var motionLevel: BackdropView.MotionLevel { get set }
    /// Nothing moves right now (still, Reduce Motion, or the window can't be seen).
    var isPaused: Bool { get }
    /// Shows `state`'s scene, cross-fading over `transition` seconds.
    func apply(_ state: SkyState, transition: TimeInterval)
    /// The current scene as a still, for debug snapshots (bottom-left origin, points).
    func renderCurrentFrame(in context: CGContext)
}

/// The backdrop: BackdropKit's `BackdropView` showing the active theme's scene (Mothership
/// Sky included), recomputed from the sun every minute. The Desktop theme shows nothing
/// here; RootView's behind-window blur shows through.
///
/// Animation stops while the window is occluded or minimized and while the app is hidden;
/// Reduce Motion shows a still frame.
@MainActor
final class SkyBackdropView: NSView, SkyRendering {
    private let backdrop = BackdropView(frame: .zero)
    private var hasApplied = false
    private var shownScene: ThemeKit.Scene?
    private var windowObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        // The top bar's band, where some stars and the moon sit.
        backdrop.topBandHeight = Sky.topBarHeight
        backdrop.reducesMotion = SkyAccessibility.reduceMotion
        addSubview(backdrop)
        observeApp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    var motionLevel: BackdropView.MotionLevel {
        get { backdrop.motionLevel }
        set { if backdrop.motionLevel != newValue { backdrop.motionLevel = newValue } }
    }

    var isPaused: Bool { !backdrop.isAnimating || backdrop.reducesMotion || backdrop.motionLevel == .still }

    func apply(_ state: SkyState, transition: TimeInterval) {
        let scene = state.kind == .desktop ? nil : state.scene
        // RootView syncs on many changes; only a new scene goes to the renderer.
        guard !hasApplied || scene != shownScene else { return }
        let first = !hasApplied
        hasApplied = true
        shownScene = scene
        backdrop.apply(scene, transition: first ? 0 : transition)
    }

    func renderCurrentFrame(in context: CGContext) {
        backdrop.renderCurrentFrame(in: context)
    }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let newWindow else { return }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateVisibility()
    }

    private func observeApp() {
        let center = NotificationCenter.default
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
        appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.backdrop.reducesMotion = SkyAccessibility.reduceMotion }
        })
    }

    /// Animates only while some of the window can be seen.
    private func updateVisibility() {
        let visible = window.map { !NSApp.isHidden && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        if backdrop.isAnimating != visible { backdrop.isAnimating = visible }
    }
}
