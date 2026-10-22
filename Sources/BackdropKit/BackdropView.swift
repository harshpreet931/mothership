import AppKit
import ThemeKit

// CONTRACT for the scene renderer. The renderer engineer replaces the stub body; the app
// integrates against these signatures.

/// Renders a `ThemeKit.Scene` with Core Animation (drawn by the window server, so animation
/// costs the app almost no CPU). Transitions between scenes cross-fade.
@MainActor
public final class BackdropView: NSView {
    /// Animations run only while this is true; the app turns it off when the window is
    /// occluded or hidden, in Low Power Mode, or when the user switches animation off.
    public var isAnimating: Bool = true

    /// Reduce Motion: show a still frame of the scene.
    public var reducesMotion: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `scene`, cross-fading from the current one over `transition` seconds.
    public func apply(_ scene: Scene?, transition: TimeInterval = 1.5) {}

    /// A still image of `scene` at `size`, for theme gallery thumbnails and snapshots.
    public static func renderImage(of scene: Scene, size: CGSize, scale: CGFloat = 2) -> NSImage? { nil }
}
