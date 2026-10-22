import AppKit
import ThemeKit

// CONTRACT for the scene renderer. The app integrates against these signatures.

/// Renders a `ThemeKit.Scene` with Core Animation (drawn by the window server, so animation
/// costs the app almost no CPU). Transitions between scenes cross-fade.
///
/// Every moving part is a Core Animation loop or emitter on one scene clock: no timers, no
/// per-frame work in the app. Turning `isAnimating` off stops that clock (and emitter
/// births), freezing everything in place; `reducesMotion` shows a still frame with a static
/// scatter where particles were.
@MainActor
public final class BackdropView: NSView {
    /// Animations run only while this is true; the app turns it off when the window is
    /// occluded or hidden, in Low Power Mode, or when the user switches animation off.
    public var isAnimating: Bool = true {
        didSet { if isAnimating != oldValue { updateMotion() } }
    }

    /// Reduce Motion: show a still frame of the scene.
    public var reducesMotion: Bool = false {
        didSet { if reducesMotion != oldValue { updateMotion() } }
    }

    /// The scene on screen (nil: nothing, the desktop shows through).
    public private(set) var scene: Scene?

    /// Height of the window's top chrome band, where the sky always shows. A share of the
    /// twinkling stars and the default moon position sit in it; 0 spreads them over the sky.
    public var topBandHeight: CGFloat = 0 {
        didSet { if topBandHeight != oldValue { needsLayout = true } }
    }

    let stage = Stage(purpose: .live)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.backgroundColor = CGColor(gray: 0, alpha: 0)
        layer = root
        wantsLayer = true
        root.addSublayer(stage.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isOpaque: Bool { false }
    /// Decoration only: clicks go to whatever is behind or above it.
    public override func hitTest(_: NSPoint) -> NSView? { nil }

    /// Shows `scene`, cross-fading from the current one over `transition` seconds. Layers
    /// both scenes share stay put (opacity changes animate, particles keep falling), and
    /// sky colors morph directly, so a sun-cycle step every minute is seamless.
    public func apply(_ scene: Scene?, transition: TimeInterval = 1.5) {
        self.scene = scene
        layoutStage()
        stage.apply(scene, transition: transition)
    }

    public override func layout() {
        super.layout()
        layoutStage()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutStage()
    }

    private func layoutStage() {
        stage.layout(size: bounds.size, scale: window?.backingScaleFactor ?? layer?.contentsScale ?? 2, topBand: topBandHeight)
    }

    private func updateMotion() {
        stage.setMotion(reducesMotion ? .still : isAnimating ? .running : .paused)
    }

    /// Layers in the tree right now (sky, nodes and masks), for budgets and diagnostics.
    public var layerCount: Int { stage.layerCount }

    /// A still image of `scene` at `size`, for theme gallery thumbnails and snapshots.
    /// Deterministic: the same scene renders the same pixels, with a static scatter where
    /// particles would be and a mid-flight shooting star where there are any.
    public static func renderImage(of scene: Scene, size: CGSize, scale: CGFloat = 2) -> NSImage? {
        guard let image = OffscreenRenderer.still(of: scene, size: size, scale: scale) else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    /// The current scene as a still (see `renderImage`), drawn into `context` (origin
    /// bottom-left, in points) — for debug snapshots of the window.
    public func renderCurrentFrame(in context: CGContext) {
        guard let scene, bounds.width > 0, bounds.height > 0,
              let image = OffscreenRenderer.still(of: scene, size: bounds.size, scale: window?.backingScaleFactor ?? 2, topBand: topBandHeight)
        else { return }
        context.draw(image, in: bounds)
    }
}
