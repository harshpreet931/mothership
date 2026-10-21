import AppKit
import QuartzCore
import ShipModel
import SwiftUI

/// Chrome around one pane: rounded clip, hairline border, focus ring, the animated
/// attention glow, the unfocused-pane dim, a progress hairline, and the resume banner.
@MainActor
final class PaneContainerView: NSView {
    static let cornerRadius: CGFloat = 10
    static let bannerHeight: CGFloat = 38

    let surfaceID: SurfaceID
    private let clipView = NSView()
    private let glowLayer = CAShapeLayer()
    private let dimView = PassthroughView()
    private let progressLayer = CALayer()
    private var bannerHost: NSHostingView<ResumeBanner>?
    private var bannerKey: AgentSessionKey?
    private(set) var content: NSView?

    private var isFocused = false
    private var showsFocusRing = false
    private var needsAttention = false
    private var progress: Double?

    init(surfaceID: SurfaceID) {
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        glowLayer.fillColor = nil
        glowLayer.strokeColor = NSColor.attentionShip.cgColor
        glowLayer.lineWidth = 2
        glowLayer.shadowColor = NSColor.attentionShip.cgColor
        glowLayer.shadowRadius = 9
        glowLayer.shadowOpacity = 0.9
        glowLayer.shadowOffset = .zero
        glowLayer.opacity = 0
        layer?.addSublayer(glowLayer)

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Self.cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1
        addSubview(clipView)

        dimView.wantsLayer = true
        dimView.alphaValue = 0
        clipView.addSubview(dimView)

        progressLayer.backgroundColor = NSColor.accentShip.cgColor
        progressLayer.isHidden = true
        clipView.layer?.addSublayer(progressLayer)
        updateColors()
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

    /// Re-applies every decoration. Cheap: called on any model change.
    func update(
        focused: Bool, showFocusRing: Bool, dimmed: Bool, attention: Bool, background: NSColor,
        progress: Double?, resume: (key: AgentSessionKey, title: String?)?, onResume: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        clipView.layer?.backgroundColor = background.cgColor
        let ringChanged = focused != isFocused || showFocusRing != showsFocusRing
        isFocused = focused
        showsFocusRing = showFocusRing
        if ringChanged { updateColors() }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            dimView.animator().alphaValue = dimmed ? 1 : 0
        }
        setAttention(attention)
        setProgress(progress)
        setResume(resume, onResume: onResume, onDismiss: onDismiss)
    }

    override func layout() {
        super.layout()
        clipView.frame = bounds
        let bannerOffset = bannerHost == nil ? 0 : Self.bannerHeight
        bannerHost?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.bannerHeight)
        content?.frame = CGRect(x: 0, y: bannerOffset, width: bounds.width, height: max(0, bounds.height - bannerOffset))
        dimView.frame = clipView.bounds
        let glowRect = bounds.insetBy(dx: -1, dy: -1)
        glowLayer.frame = bounds
        glowLayer.path = CGPath(
            roundedRect: glowRect, cornerWidth: Self.cornerRadius + 1, cornerHeight: Self.cornerRadius + 1, transform: nil
        )
        layoutProgress()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ring = showsFocusRing && isFocused
            clipView.layer?.borderColor = ring
                ? NSColor.accentShip.withAlphaComponent(0.7).cgColor
                : NSColor.paneBorderShip.cgColor
            clipView.layer?.borderWidth = ring ? 1.5 : 1
            dimView.layer?.backgroundColor = effectiveAppearance.isDark
                ? NSColor.black.withAlphaComponent(0.22).cgColor
                : NSColor.white.withAlphaComponent(0.28).cgColor
            progressLayer.backgroundColor = NSColor.accentShip.cgColor
        }
    }

    private func setAttention(_ attention: Bool) {
        guard attention != needsAttention else { return }
        needsAttention = attention
        glowLayer.removeAllAnimations()
        if attention {
            glowLayer.opacity = 1
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.35
            pulse.toValue = 1
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glowLayer.add(pulse, forKey: "pulse")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = glowLayer.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.25
            glowLayer.opacity = 0
            glowLayer.add(fade, forKey: "fade")
        }
    }

    private func setProgress(_ value: Double?) {
        progress = value
        progressLayer.isHidden = value == nil
        progressLayer.removeAnimation(forKey: "indeterminate")
        if let value, value < 0 {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -bounds.width * 0.15
            slide.toValue = bounds.width * 1.15
            slide.duration = 1.2
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

    private func setResume(
        _ resume: (key: AgentSessionKey, title: String?)?, onResume: @escaping () -> Void, onDismiss: @escaping () -> Void
    ) {
        guard let resume else {
            if bannerHost != nil {
                bannerHost?.removeFromSuperview()
                bannerHost = nil
                bannerKey = nil
                needsLayout = true
            }
            return
        }
        let banner = ResumeBanner(kind: resume.key.kind, title: resume.title, onResume: onResume, onDismiss: onDismiss)
        if let bannerHost, bannerKey == resume.key {
            bannerHost.rootView = banner
            return
        }
        bannerHost?.removeFromSuperview()
        let host = NSHostingView(rootView: banner)
        host.sizingOptions = []
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

/// "Resume Claude Code session?" strip at the top of a restored pane.
struct ResumeBanner: View {
    let kind: AgentKind
    let title: String?
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(kind: kind, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Resume \(kind.displayName) session?")
                    .font(.system(size: 12, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(PillButtonStyle())
            Button("Resume", action: onResume)
                .buttonStyle(PillButtonStyle(tint: Palette.accent))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}
