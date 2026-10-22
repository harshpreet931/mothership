import AppKit
import CoreImage
import QuartzCore

/// The full-bleed sky, all Core Animation so it costs the app nothing per frame: a
/// gradient, a glow where the sun is, drifting clouds by day, stars that twinkle (and the
/// odd shooting star) with a soft moon by night, and 2 % grain.
///
/// Every animation lives under one `scene` layer, which pauses (`speed = 0`) while the
/// window is occluded or minimized, the app is hidden, in Low Power Mode, under Reduce
/// Motion, or with "Animate sky" off. Palette changes crossfade over 2 s.
@MainActor
final class LivingSkyView: NSView {
    private let scene = CALayer()
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let cloudDeck = CALayer()
    private let clouds: [CALayer]
    private let night = CALayer()
    /// Dim, mid and bright tiers of the fixed star field.
    private let fieldTiers: [CAShapeLayer]
    private let twinklers: [CALayer]
    private let moon = CALayer()
    private let meteor = CAGradientLayer()
    private let grain = CALayer()

    private(set) var state: SkyState?
    /// "Animate sky".
    var animationEnabled = true {
        didSet { if animationEnabled != oldValue { updatePause() } }
    }
    private(set) var isPaused = false
    private var cloudTint: RGB?
    private var laidOutSize: CGSize = .zero
    private var meteorTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    /// `MOTHERSHIP_SKY_ANIMATE=always` (debug): keep animating while occluded, for
    /// verification on headless machines.
    private let ignoresOcclusion = ProcessInfo.processInfo.environment["MOTHERSHIP_SKY_ANIMATE"] == "always"

    override init(frame: NSRect) {
        clouds = Self.cloudSpecs.map { _ in CALayer() }
        fieldTiers = (0 ..< 3).map { _ in CAShapeLayer() }
        twinklers = Self.twinkleSpecs.map { _ in CALayer() }
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = CGColor(gray: 0, alpha: 0)
        layer = root
        wantsLayer = true
        build(in: root)
        observeApp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    // MARK: Building

    private func build(in root: CALayer) {
        root.addSublayer(scene)
        scene.addSublayer(gradient)
        scene.addSublayer(glow)
        scene.addSublayer(night)
        scene.addSublayer(cloudDeck)
        scene.addSublayer(grain)

        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.55, 1]

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.38, 1]

        for (index, tier) in fieldTiers.enumerated() {
            tier.fillColor = CGColor(gray: 1, alpha: 1)
            tier.opacity = [0.32, 0.55, 0.85][index]
            night.addSublayer(tier)
        }
        let dot = Self.softDot
        for (layer, spec) in zip(twinklers, Self.twinkleSpecs) {
            layer.contents = dot
            layer.bounds = CGRect(x: 0, y: 0, width: spec.size, height: spec.size)
            layer.opacity = Float(spec.peak)
            night.addSublayer(layer)
        }
        moon.contents = Self.moonImage
        moon.bounds = CGRect(x: 0, y: 0, width: Self.moonSide, height: Self.moonSide)
        night.addSublayer(moon)

        meteor.startPoint = CGPoint(x: 0, y: 0.5)
        meteor.endPoint = CGPoint(x: 1, y: 0.5)
        meteor.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.85)]
        meteor.bounds = CGRect(x: 0, y: 0, width: 150, height: 1.4)
        meteor.anchorPoint = CGPoint(x: 1, y: 0.5)
        meteor.cornerRadius = 0.7
        meteor.opacity = 0
        night.addSublayer(meteor)

        for cloud in clouds {
            cloud.contentsGravity = .resize
            cloudDeck.addSublayer(cloud)
        }

        if let noise = Self.noiseTile {
            grain.backgroundColor = NSColor(patternImage: NSImage(cgImage: noise, size: NSSize(width: 64, height: 64))).cgColor
        }
        grain.opacity = 0.02
        night.opacity = 0
        cloudDeck.opacity = 0
    }

    // MARK: State

    /// Shows `state`, crossfading over 2 s when `animated` (and the sky is running).
    func apply(_ state: SkyState, animated: Bool) {
        guard state != self.state else { return }
        let previous = self.state
        self.state = state
        let fade = animated && previous != nil && !isPaused
        CATransaction.begin()
        CATransaction.setDisableActions(!fade)
        CATransaction.setAnimationDuration(fade ? 2 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        isHidden = state.kind == .desktop
        let palette = state.palette
        gradient.colors = [palette.top.cgColor(), palette.middle.cgColor(), palette.horizon.cgColor()]
        let strength = palette.glowStrength
        glow.colors = [palette.glow.cgColor(alpha: strength), palette.glow.cgColor(alpha: strength * 0.42), palette.glow.cgColor(alpha: 0)]
        night.opacity = Float(palette.stars)
        // The moon waits for real darkness, then comes up with the stars.
        moon.opacity = Float(min(max((palette.stars - 0.8) / 0.15, 0), 1))
        cloudDeck.opacity = Float(palette.clouds)
        if cloudTint.map({ $0.distance(to: palette.cloudTint) > 0.012 }) ?? true {
            cloudTint = palette.cloudTint
            let shade = palette.cloudTint.mixed(with: palette.middle, t: 0.35)
            for (cloud, spec) in zip(clouds, Self.cloudSpecs) {
                cloud.contents = Self.cloudImage(seed: spec.seed, tint: palette.cloudTint, shade: shade)
            }
        }
        layoutSunAndMoon()
        CATransaction.commit()
        updatePause()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.frame = bounds
        for layer in [gradient, night, cloudDeck, grain] { layer.frame = bounds }
        if size != laidOutSize, size.width > 0, size.height > 0 {
            laidOutSize = size
            layoutStars(size)
            layoutClouds(size)
        }
        layoutSunAndMoon()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [scene, gradient, glow, meteor] + fieldTiers as [CALayer] { layer.contentsScale = scale }
        moon.contentsScale = 2
        for layer in twinklers { layer.contentsScale = 2 }
    }

    /// Points from the top-left, in the layer's bottom-left space.
    private func point(_ x: Double, fromTop y: Double) -> CGPoint {
        CGPoint(x: x, y: bounds.height - y)
    }

    private func layoutStars(_ size: CGSize) {
        let paths = (0 ..< 3).map { _ in CGMutablePath() }
        for star in Self.fieldStars {
            let center = point(star.x * size.width, fromTop: star.y * size.height)
            paths[star.tier].addEllipse(in: CGRect(x: center.x - star.radius, y: center.y - star.radius, width: star.radius * 2, height: star.radius * 2))
        }
        for (tier, path) in zip(fieldTiers, paths) {
            tier.frame = bounds
            tier.path = path
        }
        for (layer, spec) in zip(twinklers, Self.twinkleSpecs) {
            // A third sit in the top bar's band, where the sky always shows.
            let y = spec.inTopBand ? 8 + spec.y * (Sky.topBarHeight - 16) : Sky.topBarHeight + spec.y * size.height * 0.72
            layer.position = point(spec.x * size.width, fromTop: y)
            layer.removeAnimation(forKey: "twinkle")
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = spec.peak * 0.12
            twinkle.toValue = spec.peak
            twinkle.duration = spec.duration
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timeOffset = spec.phase * spec.duration * 2
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(twinkle, forKey: "twinkle")
        }
    }

    private func layoutClouds(_ size: CGSize) {
        for (cloud, spec) in zip(clouds, Self.cloudSpecs) {
            let width = spec.width * max(size.width, 900)
            let height = width * 0.36
            cloud.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            cloud.opacity = Float(spec.alpha)
            let y = bounds.height - (spec.inTopBand ? spec.y : spec.y * size.height)
            cloud.position = CGPoint(x: spec.phase * size.width, y: y)
            cloud.removeAnimation(forKey: "drift")
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = -width / 2
            drift.toValue = size.width + width / 2
            drift.duration = spec.crossing
            drift.repeatCount = .infinity
            drift.timeOffset = spec.phase * spec.crossing
            cloud.add(drift, forKey: "drift")
        }
    }

    /// The glow sits where the sun is: east (left) in the morning, west in the evening,
    /// climbing with the sun and fading out by day.
    private func layoutSunAndMoon() {
        let size = bounds.size
        guard size.width > 0, let state else { return }
        let altitude = state.sun.altitude
        let x = (state.sun.isMorning ? 0.2 : 0.8) * size.width
        let lift = min(max((altitude + 4) / 40, 0), 0.7)
        let y = size.height * (lift - 0.06)
        glow.bounds = CGRect(x: 0, y: 0, width: size.width * 1.25, height: size.height * (0.9 + lift * 0.4))
        glow.position = CGPoint(x: x, y: y)
        // In the top bar's band, where the sky always shows: behind a card it would
        // smudge the card's text.
        moon.position = point((size.width * 0.36).rounded(), fromTop: Sky.topBarHeight / 2 + 1)
    }

    // MARK: Pausing

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
                MainActor.assumeIsolated { self?.updatePause() }
            })
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePause()
    }

    private func observeApp() {
        let center = NotificationCenter.default
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePause() }
            })
        }
        appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePause() }
        })
    }

    /// Whether anything should move right now.
    var shouldAnimate: Bool {
        guard animationEnabled, state?.kind == .living, !SkyAccessibility.reduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        if ignoresOcclusion { return true }
        guard let window, !NSApp.isHidden, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updatePause() {
        setPaused(!shouldAnimate)
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            let now = scene.convertTime(CACurrentMediaTime(), from: nil)
            scene.speed = 0
            scene.timeOffset = now
            meteorTimer?.invalidate()
            meteorTimer = nil
        } else {
            let pausedAt = scene.timeOffset
            scene.speed = 1
            scene.timeOffset = 0
            scene.beginTime = 0
            scene.beginTime = scene.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
            scheduleMeteor()
        }
    }

    // MARK: Shooting stars

    private func scheduleMeteor() {
        meteorTimer?.invalidate()
        let timer = Timer(timeInterval: Double.random(in: 45 ... 150), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.launchMeteor()
                self?.scheduleMeteor()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        meteorTimer = timer
    }

    /// A thin streak across the upper sky, ~0.8 s, only when stars are out.
    func launchMeteor() {
        guard !isPaused, (state?.palette.stars ?? 0) > 0.5, bounds.width > 200 else { return }
        let angle = Double.random(in: 0.38 ... 0.6)
        let start = point(Double.random(in: 0.15 ... 0.7) * bounds.width, fromTop: Double.random(in: 0.02 ... 0.25) * bounds.height)
        let travel = Double.random(in: 220 ... 320)
        let end = CGPoint(x: start.x + cos(angle) * travel, y: start.y - sin(angle) * travel)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meteor.transform = CATransform3DMakeRotation(-angle, 0, 0, 1)
        meteor.position = end
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: end)
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.7, 0]
        fade.keyTimes = [0, 0.2, 0.7, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.8
        group.beginTime = meteor.convertTime(CACurrentMediaTime(), from: nil)
        meteor.add(group, forKey: "streak")
    }

    // MARK: Snapshots

    /// Draws the sky as it is this instant (animated values included) into `context`,
    /// whose origin is bottom-left in points.
    func renderCurrentFrame(in context: CGContext) {
        guard !isHidden else { return }
        (scene.presentation() ?? scene).render(in: context)
    }

    // MARK: Fixed artwork

    private struct FieldStar {
        var x: Double, y: Double, radius: Double, tier: Int
    }

    private struct TwinkleSpec {
        var x: Double, y: Double, size: Double, peak: Double, duration: Double, phase: Double, inTopBand: Bool
    }

    private struct CloudSpec {
        /// `y`: fraction of the height from the top, or points from the top in the top band.
        var seed: UInt64, y: Double, width: Double, alpha: Double, crossing: Double, phase: Double
        var inTopBand = false
    }

    /// ~240 fixed stars, denser toward the top.
    private static let fieldStars: [FieldStar] = {
        var random = SplitMix(seed: 0x57A2)
        return (0 ..< 240).map { _ in
            let tierRoll = random.unit()
            let tier = tierRoll < 0.6 ? 0 : tierRoll < 0.9 ? 1 : 2
            return FieldStar(
                x: random.unit(), y: pow(random.unit(), 1.35) * 0.92,
                radius: [0.45, 0.6, 0.8][tier] + random.unit() * 0.25, tier: tier
            )
        }
    }()

    /// 34 twinklers, 2.5–6 s each, with random phases.
    private static let twinkleSpecs: [TwinkleSpec] = {
        var random = SplitMix(seed: 0x7317)
        return (0 ..< 34).map { index in
            TwinkleSpec(
                x: random.range(0.02, 0.98), y: random.unit(), size: random.range(4, 7.5),
                peak: random.range(0.55, 1), duration: random.range(2.5, 6), phase: random.unit(),
                inTopBand: index % 3 == 0
            )
        }
    }()

    /// Soft cloud banks, 3–6 minutes to cross. Most of the window is panels, so two drift
    /// through the top bar's band and the gutters where they're actually seen; the rest
    /// tint the glass from behind.
    private static let cloudSpecs: [CloudSpec] = [
        CloudSpec(seed: 11, y: 30, width: 0.32, alpha: 1, crossing: 300, phase: 0.22, inTopBand: true),
        CloudSpec(seed: 29, y: 18, width: 0.24, alpha: 0.9, crossing: 230, phase: 0.71, inTopBand: true),
        CloudSpec(seed: 37, y: 0.46, width: 0.56, alpha: 0.85, crossing: 360, phase: 0.4),
        CloudSpec(seed: 53, y: 0.86, width: 0.5, alpha: 0.75, crossing: 260, phase: 0.86),
    ]

    private static let moonSide: CGFloat = 132

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func radial(_ context: CGContext, center: CGPoint, radius: CGFloat, color: RGB, alphas: [CGFloat], locations: [CGFloat]) {
        let colors = alphas.map { color.cgColor(alpha: Double($0)) } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    /// A star with a soft halo, 32 px.
    private static let softDot: CGImage? = {
        guard let context = bitmap(width: 32, height: 32) else { return nil }
        radial(context, center: CGPoint(x: 16, y: 16), radius: 16, color: RGB(0xFFFFFF), alphas: [1, 0.55, 0.12, 0], locations: [0, 0.14, 0.42, 1])
        return context.makeImage()
    }()

    /// A soft, slightly warm moon with a wide glow.
    private static let moonImage: CGImage? = {
        let side = Int(moonSide * 2)
        guard let context = bitmap(width: side, height: side) else { return nil }
        let center = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        radial(context, center: center, radius: CGFloat(side) / 2, color: RGB(0xDDE4FF), alphas: [0.34, 0.12, 0.04, 0], locations: [0, 0.2, 0.5, 1])
        let disc: CGFloat = 20
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - disc, y: center.y - disc, width: disc * 2, height: disc * 2))
        context.clip()
        let colors = [RGB(0xFFFDF4).cgColor(), RGB(0xE9E4D6).cgColor()] as CFArray
        if let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(shade, start: CGPoint(x: center.x - disc, y: center.y + disc), end: CGPoint(x: center.x + disc, y: center.y - disc), options: [])
        }
        // Faint maria.
        context.setFillColor(RGB(0xBFB9AA).cgColor(alpha: 0.16))
        for (dx, dy, r) in [(-6.0, 5.0, 6.0), (5.0, -3.0, 4.0), (-2.0, -8.0, 3.0), (7.0, 7.0, 2.5)] {
            context.fillEllipse(in: CGRect(x: center.x + dx - r, y: center.y + dy - r, width: r * 2, height: r * 2))
        }
        context.restoreGState()
        return context.makeImage()
    }()

    /// A procedural cloud: many faint puffs piled on a low dome with a shaded underside,
    /// then blurred so no single puff reads as a ball.
    private static func cloudImage(seed: UInt64, tint: RGB, shade: RGB) -> CGImage? {
        let width = 480, height = 172
        guard let context = bitmap(width: width, height: height) else { return nil }
        var random = SplitMix(seed: seed)
        func centered() -> Double { (random.unit() + random.unit() + random.unit()) / 3 }
        // Underside first, then the lit body on top.
        for _ in 0 ..< 14 {
            let x = 80 + centered() * 320
            radial(context, center: CGPoint(x: x, y: random.range(50, 62)), radius: random.range(30, 48), color: shade, alphas: [0.22, 0.1, 0], locations: [0, 0.5, 1])
        }
        for _ in 0 ..< 46 {
            let u = centered()
            let x = 40 + u * 400
            let dome = sin(u * .pi)
            let y = 62 + dome * random.range(4, 38)
            let radius = 20 + dome * random.range(12, 30)
            radial(context, center: CGPoint(x: x, y: y), radius: radius, color: tint, alphas: [0.36, 0.19, 0], locations: [0, 0.5, 1])
        }
        guard let image = context.makeImage() else { return nil }
        return blurred(image, radius: 7)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: radius]),
              let output = filter.outputImage else { return image }
        return ciContext.createCGImage(output, from: input.extent) ?? image
    }

    /// 64 px monochrome noise, tiled at 2 % against gradient banding.
    private static let noiseTile: CGImage? = {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        var random = SplitMix(seed: 0xA5A5)
        for index in pixels.indices { pixels[index] = UInt8(random.unit() * 255) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }()
}

extension RGB {
    func distance(to other: RGB) -> Double {
        abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
    }
}
