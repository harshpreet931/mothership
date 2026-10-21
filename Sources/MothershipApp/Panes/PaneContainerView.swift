import AppKit
import QuartzCore
import ShipModel
import SwiftUI

/// What the pane chrome shows.
struct PaneChromeModel: Equatable {
    var title: String
    var session: AgentSession?
    /// Keep the capsule up while an agent is active, not just on hover.
    var pinned: Bool
}

struct PaneActions {
    var onResume: () -> Void
    var onDismissResume: () -> Void
    var onSplitRight: () -> Void
    var onSplitDown: () -> Void
    var onClose: () -> Void
}

/// One pane card (§6 Pane chrome, §8): radius 18, the terminal's own background, Day
/// elevation, a 1 pt ink ring when focused, a pulsing amber halo when an agent waits, and a
/// small glass capsule (title · state · split · close) on hover.
@MainActor
final class PaneContainerView: NSView {
    static let cornerRadius = Sky.radiusPane
    /// Top padding of terminal cards that holds the pane capsule.
    static let statusStripHeight: CGFloat = 24

    let surfaceID: SurfaceID
    private let elevationLayer = CALayer()
    private let haloLayer = CALayer()
    private let clipView = FlippedView()
    private let ringLayer = CAShapeLayer()
    private let dimView = PassthroughView()
    private let progressLayer = CALayer()
    private var tintView: NSVisualEffectView?
    private var chromeHost: NSHostingView<PaneChrome>?
    private var bannerHost: NSHostingView<ResumeBanner>?
    private var bannerKey: AgentSessionKey?
    private(set) var content: NSView?
    private var trackingArea: NSTrackingArea?

    private(set) var isFocused = false
    private(set) var needsAttention = false
    private var hovering = false
    private var chrome: PaneChromeModel?
    private var actions: PaneActions?
    private var progress: Double?
    private var dark = true
    private var terminalIsDark = true
    /// Terminal panes (those with chrome) reserve the status strip; browsers bring a toolbar.
    private var reservesStatusStrip = false
    /// Clear margin kept at the bottom when this card sits on the canvas's bottom edge, so
    /// the floating composer never covers content.
    var bottomClearance: CGFloat = 0 {
        didSet { if bottomClearance != oldValue { needsLayout = true } }
    }

    init(surfaceID: SurfaceID) {
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        haloLayer.shadowColor = NSColor.skyAttention.cgColor
        haloLayer.shadowRadius = 14
        haloLayer.shadowOffset = .zero
        haloLayer.shadowOpacity = 0
        layer?.addSublayer(haloLayer)

        elevationLayer.shadowOffset = CGSize(width: 0, height: 8)
        elevationLayer.shadowRadius = 12
        elevationLayer.shadowOpacity = 0
        layer?.addSublayer(elevationLayer)

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Self.cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        dimView.wantsLayer = true
        dimView.alphaValue = 0
        clipView.addSubview(dimView)

        progressLayer.isHidden = true
        clipView.layer?.addSublayer(progressLayer)

        ringLayer.fillColor = nil
        ringLayer.lineWidth = 1
        ringLayer.opacity = 0
        layer?.addSublayer(ringLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setContent(_ view: NSView?) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        if let view {
            clipView.addSubview(view, positioned: .below, relativeTo: dimView)
        }
        needsLayout = true
    }

    // swiftlint:disable:next function_parameter_count
    func update(
        focused: Bool, dimmed: Bool, attention: Bool, background: NSColor, tint: Bool, progress: Double?,
        resume: (key: AgentSessionKey, title: String?)?, chrome: PaneChromeModel?, dark: Bool, actions: PaneActions
    ) {
        self.actions = actions
        self.dark = dark
        terminalIsDark = background.usingColorSpace(.sRGB).map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent < 0.5 } ?? true
        bannerHost?.appearance = NSAppearance(named: terminalIsDark ? .darkAqua : .aqua)
        clipView.layer?.backgroundColor = background.withAlphaComponent(tint ? 0.88 : 1).cgColor
        setTint(tint)
        setFocused(focused)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            dimView.animator().alphaValue = dimmed ? 1 : 0
        }
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        setAttention(attention)
        setProgress(progress)
        setResume(resume)
        self.chrome = chrome
        if reservesStatusStrip != (chrome != nil) {
            reservesStatusStrip = chrome != nil
            needsLayout = true
        }
        updateChrome()
        updateLayerColors()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        clipView.frame = bounds
        tintView?.frame = clipView.bounds
        // Terminal cards keep a status strip as top padding: the pane capsule lives there,
        // so it can never cover a glyph, and the terminal never resizes when it appears.
        let strip = reservesStatusStrip ? Self.statusStripHeight : 0
        let banner = bannerHost == nil ? 0 : ResumeBanner.height + 8
        bannerHost?.frame = NSRect(x: 0, y: strip + 2, width: bounds.width, height: ResumeBanner.height)
        let top = strip + banner
        let bottom = touchesCanvasBottom ? bottomClearance : 0
        content?.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - bottom))
        dimView.frame = clipView.bounds
        let path = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        elevationLayer.frame = bounds
        elevationLayer.shadowPath = path
        haloLayer.frame = bounds
        haloLayer.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), cornerWidth: Self.cornerRadius + 2, cornerHeight: Self.cornerRadius + 2, transform: nil)
        ringLayer.frame = bounds
        ringLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Self.cornerRadius - 0.5, cornerHeight: Self.cornerRadius - 0.5, transform: nil)
        layoutChrome()
        layoutProgress()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsLayout = true
    }

    /// Whether this card's bottom edge is the workspace's bottom edge (bottom row).
    private var touchesCanvasBottom: Bool {
        var view = superview
        while let candidate = view, !(candidate is WorkspaceView) { view = candidate.superview }
        guard let workspace = view else { return false }
        return convert(bounds, to: workspace).maxY >= workspace.bounds.maxY - 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ringLayer.strokeColor = NSColor.skyInk.withAlphaComponent(0.18).cgColor
            haloLayer.shadowColor = NSColor.skyAttention.cgColor
            progressLayer.backgroundColor = NSColor.skyInk.withAlphaComponent(0.6).cgColor
            // Day: every card floats a little; focus floats it further. Night: focus only.
            elevationLayer.shadowColor = dark ? NSColor.black.cgColor : NSColor.skyInk.cgColor
            elevationLayer.shadowOpacity = dark ? (isFocused ? 0.35 : 0) : (isFocused ? 0.16 : 0.08)
            elevationLayer.shadowRadius = isFocused ? 16 : 12
        }
    }

    // MARK: Hover chrome

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        updateChrome()
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        updateChrome()
    }

    private func updateChrome() {
        guard let chrome, let actions, hovering || chrome.pinned else {
            if let host = chromeHost {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; host.animator().alphaValue = 0 }, completionHandler: {
                    MainActor.assumeIsolated { if host.alphaValue == 0 { host.isHidden = true } }
                })
            }
            return
        }
        let view = PaneChrome(
            model: chrome, expanded: hovering, onSplitRight: actions.onSplitRight, onSplitDown: actions.onSplitDown,
            onClose: actions.onClose
        )
        if let host = chromeHost {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            // Exactly the capsule's size, so the rest of the pane's top edge stays clickable.
            host.sizingOptions = [.intrinsicContentSize]
            host.safeAreaRegions = []
            host.alphaValue = 0
            clipView.addSubview(host)
            chromeHost = host
        }
        chromeHost?.isHidden = false
        // The capsule floats on the terminal, so it takes the terminal's light or dark.
        chromeHost?.appearance = NSAppearance(named: terminalIsDark ? .darkAqua : .aqua)
        layoutChrome()
        if let host = chromeHost, host.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; host.animator().alphaValue = 1 }
        }
    }

    private func layoutChrome() {
        guard let host = chromeHost else { return }
        let size = host.intrinsicContentSize
        let width = min(max(size.width, PaneChrome.height), bounds.width - 16)
        let y = (Self.statusStripHeight - PaneChrome.height) / 2
        host.frame = NSRect(x: bounds.width - width - 6, y: y, width: width, height: PaneChrome.height)
    }

    // MARK: States

    private func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = 0.18
        ringLayer.opacity = focused ? 1 : 0
        ringLayer.add(fade, forKey: "fade")
    }

    private func setAttention(_ attention: Bool) {
        guard attention != needsAttention else { return }
        needsAttention = attention
        haloLayer.removeAllAnimations()
        if attention {
            haloLayer.shadowOpacity = 0.9
            guard !SkyAccessibility.reduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "shadowOpacity")
            pulse.fromValue = 0.35
            pulse.toValue = 0.95
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            haloLayer.add(pulse, forKey: "pulse")
        } else {
            haloLayer.shadowOpacity = 0
        }
    }

    private func setTint(_ tint: Bool) {
        if tint, tintView == nil {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            clipView.addSubview(blur, positioned: .below, relativeTo: nil)
            tintView = blur
            needsLayout = true
        } else if !tint, let tintView {
            tintView.removeFromSuperview()
            self.tintView = nil
        }
    }

    private func setProgress(_ value: Double?) {
        progress = value
        progressLayer.isHidden = value == nil
        progressLayer.removeAnimation(forKey: "indeterminate")
        if let value, value < 0, !SkyAccessibility.reduceMotion {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -bounds.width * 0.15
            slide.toValue = bounds.width * 1.15
            slide.duration = 1.4
            slide.repeatCount = .infinity
            progressLayer.add(slide, forKey: "indeterminate")
        }
        layoutProgress()
    }

    private func layoutProgress() {
        guard let progress else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(progress < 0)
        let width = progress < 0 ? bounds.width * 0.3 : bounds.width * min(max(progress, 0), 1)
        progressLayer.frame = CGRect(x: 0, y: 0, width: width, height: 2)
        CATransaction.commit()
    }

    private func setResume(_ resume: (key: AgentSessionKey, title: String?)?) {
        guard let resume, let actions else {
            if bannerHost != nil {
                bannerHost?.removeFromSuperview()
                bannerHost = nil
                bannerKey = nil
                needsLayout = true
            }
            return
        }
        let banner = ResumeBanner(kind: resume.key.kind, title: resume.title, onResume: actions.onResume, onDismiss: actions.onDismissResume)
        if let bannerHost, bannerKey == resume.key {
            bannerHost.rootView = banner
            return
        }
        bannerHost?.removeFromSuperview()
        let host = NSHostingView(rootView: banner)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.appearance = NSAppearance(named: terminalIsDark ? .darkAqua : .aqua)
        clipView.addSubview(host)
        bannerHost = host
        bannerKey = resume.key
        needsLayout = true
    }
}

/// Draws but never takes clicks.
final class PassthroughView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// Top-left origin, so overlays sit at the top and content below.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The pane capsule: title · state glyph · split · close on hover; just the state glyph in
/// a small circle while an agent is active and the pointer is elsewhere.
struct PaneChrome: View {
    /// Fits inside the card's status strip (`PaneContainerView.statusStripHeight`).
    static let height: CGFloat = 20

    let model: PaneChromeModel
    let expanded: Bool
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let session = model.session {
                AgentStatusGlyph(kind: session.kind, state: session.state, unread: session.unread, hasPermission: session.pendingPermission != nil, size: 9)
            }
            if expanded {
                Text(model.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Sky.ink.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                Rectangle().fill(Sky.ink.opacity(0.12)).frame(width: 1, height: 10)
                chromeButton("rectangle.split.2x1", "Split Right (⌘D)", onSplitRight)
                chromeButton("rectangle.split.1x2", "Split Down (⌘⇧D)", onSplitDown)
                chromeButton("xmark", "Close Pane (⌘W)", onClose)
            }
        }
        .padding(.leading, expanded ? 8 : 2)
        .padding(.trailing, 2)
        .frame(height: Self.height)
        .frame(minWidth: Self.height)
        .modifier(GlassBackground(shape: Capsule(style: .continuous), dense: true))
        .fixedSize()
        .help(expanded ? "" : model.title)
    }

    private func chromeButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Sky.ink.opacity(0.7))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Resume Claude session?" as a glass capsule at the top of a restored pane.
struct ResumeBanner: View {
    static let height: CGFloat = 40
    let kind: AgentKind
    let title: String?
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(kind: kind, size: 14)
            Text("Resume \(kind.shortName) session")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Sky.ink)
            if let title {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Sky.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss).buttonStyle(GhostPillStyle(height: 28))
            Button("Resume", action: onResume).buttonStyle(InkCapsuleStyle(height: 28))
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .modifier(GlassBackground(shape: Capsule(style: .continuous), dense: true))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
