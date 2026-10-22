import AppKit
import ThemeKit

/// One `SceneLayer`, rendered. Its `layer` fills the view; the stage cross-fades nodes in and
/// out and sets their `opacity` from the spec. Animations are loops on the scene clock
/// (`Timing.loop`), so pausing the clock freezes every node in place.
@MainActor
class Node {
    let layer = CALayer()
    private(set) var spec: SceneLayer
    /// Deterministic per node (kind and occurrence), so two star layers differ but a star
    /// layer is the same across launches and renders.
    let seed: UInt64
    private(set) var context: NodeContext?

    required init(spec: SceneLayer, seed: UInt64) {
        self.spec = spec
        self.seed = seed
        layer.anchorPoint = .zero
        layer.masksToBounds = false
    }

    /// Opacity when the spec doesn't set one.
    class var defaultOpacity: Double { 1 }

    var targetOpacity: Float { Float(max(0, min(1, spec.opacity ?? Self.defaultOpacity))) }

    /// Lays the node out for a new size. Subclasses build their sublayers in `build(_:)`.
    final func layout(_ context: NodeContext) {
        let previous = self.context
        self.context = context
        layer.frame = CGRect(origin: .zero, size: context.size)
        guard !context.isEmpty else { return }
        if previous == nil { build(context) }
        if previous?.size != context.size || previous?.topBand != context.topBand || previous == nil {
            relayout(context)
        }
        if previous?.scale != context.scale { setScale(context.scale) }
    }

    /// Creates sublayers once (size is known).
    func build(_: NodeContext) {}
    /// Positions everything for the context's size; called on every size change.
    func relayout(_: NodeContext) {}
    func setScale(_ scale: CGFloat) {
        for sublayer in layer.sublayers ?? [] { sublayer.contentsScale = scale }
    }
    func setMotion(_: Motion) {}

    /// Applies `spec` without rebuilding when only cheap fields changed (in place, so live
    /// particles keep falling). Return false to have the stage cross-fade a fresh node.
    func update(to spec: SceneLayer) -> Bool {
        guard spec.matchesIgnoringOpacity(self.spec) else { return false }
        self.spec = spec
        return true
    }

    /// For subclasses that adopt a new spec in place.
    func adopt(_ spec: SceneLayer) { self.spec = spec }

    static func make(_ spec: SceneLayer, seed: UInt64) -> Node {
        let type: Node.Type = switch spec.kind {
        case .stars: StarsNode.self
        case .shootingStars: ShootingStarsNode.self
        case .moon: MoonNode.self
        case .sun: SunNode.self
        case .clouds: CloudsNode.self
        case .aurora: AuroraNode.self
        case .nebula: NebulaNode.self
        case .particles: ParticlesNode.self
        case .grid: GridNode.self
        case .digitalRain: DigitalRainNode.self
        case .grain: GrainNode.self
        }
        return type.init(spec: spec, seed: seed)
    }
}

// MARK: - Stars

/// A fixed field in three brightness tiers (three shape layers), plus twinklers that
/// breathe on their own 2.5–6 s cycles. `density` scales both counts, `size` the radii,
/// `speed` the twinkle, `colors` tint the tiers and twinklers in turn.
final class StarsNode: Node {
    private let tiers = (0 ..< 3).map { _ in CAShapeLayer() }
    private var twinklers: [CALayer] = []

    private struct Twinkle { var x: Double, y: Double, size: Double, peak: Double, duration: Double, phase: Double, inTopBand: Bool }

    override func build(_: NodeContext) {
        let colors = spec.palette([.white])
        for (index, tier) in tiers.enumerated() {
            tier.fillColor = colors[index % colors.count].cgColor
            tier.opacity = [0.32, 0.55, 0.85][index]
            tier.anchorPoint = .zero
            layer.addSublayer(tier)
        }
        let count = Int((34 * spec.densityFactor).rounded()).clamped(4, 60)
        twinklers = (0 ..< count).map { index in
            let twinkler = CALayer()
            let color = colors[(index + 1) % colors.count]
            twinkler.contents = Artwork.softDot
            if color != .white {
                // Tint by the color filter-free way: a colored soft dot drawn once.
                twinkler.contents = TintedDot.image(color)
            }
            layer.addSublayer(twinkler)
            return twinkler
        }
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        var random = SplitMix(seed: seed)
        let count = Int((240 * spec.densityFactor).rounded()).clamped(20, 900)
        let radiusScale = spec.sizeFactor
        let paths = (0 ..< 3).map { _ in CGMutablePath() }
        for _ in 0 ..< count {
            let roll = random.unit()
            let tier = roll < 0.6 ? 0 : roll < 0.9 ? 1 : 2
            let x = random.unit(), y = pow(random.unit(), 1.35) * 0.92
            let radius = ([0.45, 0.6, 0.8][tier] + random.unit() * 0.25) * radiusScale
            let center = context.point(UnitPoint2(x: x, y: y))
            paths[tier].addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        for (tier, path) in zip(tiers, paths) {
            tier.frame = CGRect(origin: .zero, size: size)
            tier.path = path
        }
        var twinkleRandom = SplitMix(seed: seed ^ 0x7317)
        let band = Double(context.topBand)
        for (index, twinkler) in twinklers.enumerated() {
            let spec = Twinkle(
                x: twinkleRandom.range(0.02, 0.98), y: twinkleRandom.unit(), size: twinkleRandom.range(4, 7.5) * self.spec.sizeFactor,
                peak: twinkleRandom.range(0.55, 1), duration: twinkleRandom.range(2.5, 6) / self.spec.speedFactor,
                phase: twinkleRandom.unit(), inTopBand: band > 0 && index % 3 == 0
            )
            // A third sit in the chrome's top band, where the sky always shows.
            let y = spec.inTopBand ? 8 + spec.y * max(band - 16, 1) : band + spec.y * (Double(size.height) - band) * 0.72
            twinkler.bounds = CGRect(x: 0, y: 0, width: spec.size, height: spec.size)
            twinkler.position = context.point(x: spec.x * size.width, fromTop: y)
            twinkler.opacity = Float(spec.peak)
            twinkler.removeAnimation(forKey: "twinkle")
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = spec.peak * 0.12
            twinkle.toValue = spec.peak
            twinkle.timingFunction = Timing.easeInOut
            twinkler.add(Timing.loop(twinkle, duration: spec.duration, phase: spec.phase, autoreverses: true), forKey: "twinkle")
        }
    }

    override func setScale(_ scale: CGFloat) {
        for tier in tiers { tier.contentsScale = scale }
        for twinkler in twinklers { twinkler.contentsScale = 2 }
    }
}

/// Colored soft dots for tinted twinklers (layer contents can't be tinted after the fact).
@MainActor
enum TintedDot {
    private static var cache: [String: CGImage] = [:]
    static func image(_ color: RGBA) -> CGImage? {
        if let image = cache[color.hex] { return image }
        guard let context = Artwork.bitmap(width: 32, height: 32) else { return nil }
        Artwork.radial(context, center: CGPoint(x: 16, y: 16), radius: 16, color: color.mixed(with: .white, 0.35), alphas: [1, 0.55, 0.12, 0], locations: [0, 0.14, 0.42, 1])
        let image = context.makeImage()
        if cache.count > 64 { cache.removeAll() }
        cache[color.hex] = image
        return image
    }
}

// MARK: - Shooting stars

/// The odd thin streak across the upper sky. No timers: one keyframe loop holds a dozen
/// streaks at irregular intervals (`everySeconds`, default 45–150 s), so it pauses with the
/// clock and costs the app nothing. `density` makes them more frequent, `speed` faster,
/// `size` longer; `direction` 90 sends them all rightward, 270 leftward (default: either).
final class ShootingStarsNode: Node {
    private let meteor = CAGradientLayer()
    private static let streaks = 12

    override func build(_: NodeContext) {
        let color = spec.palette([.white])[0]
        meteor.startPoint = CGPoint(x: 0, y: 0.5)
        meteor.endPoint = CGPoint(x: 1, y: 0.5)
        meteor.colors = [color.cgColor(alpha: 0), color.cgColor(alpha: 0.85)]
        meteor.anchorPoint = CGPoint(x: 1, y: 0.5)
        meteor.opacity = 0
        layer.addSublayer(meteor)
    }

    private struct Streak { var start: CGPoint, end: CGPoint, angle: Double, at: Double }

    private func streaks(_ context: NodeContext) -> (streaks: [Streak], loop: Double, duration: Double) {
        var random = SplitMix(seed: seed)
        let bounds = spec.everySeconds.flatMap { $0.count == 2 ? $0 : nil } ?? [45, 150]
        let low = max(1, min(bounds[0], bounds[1])) / spec.densityFactor
        let high = max(low, max(bounds[0], bounds[1]) / spec.densityFactor)
        let duration = 0.8 / spec.speedFactor.squareRoot()
        let travel = Double.random(in: 220 ... 320, using: &random) * spec.sizeFactor
        var time = random.range(0.15, 0.4) * low
        var result: [Streak] = []
        let size = context.size
        for _ in 0 ..< Self.streaks {
            let angle = random.range(0.38, 0.6)
            let rightward: Bool = switch spec.direction {
            case .some(let degrees) where sin(degrees * .pi / 180) > 0.3: true
            case .some(let degrees) where sin(degrees * .pi / 180) < -0.3: false
            default: random.unit() < 0.6
            }
            let start = context.point(x: random.range(rightward ? 0.12 : 0.3, rightward ? 0.7 : 0.88) * size.width, fromTop: random.range(0.02, 0.25) * size.height)
            let dx = cos(angle) * travel * (rightward ? 1 : -1)
            let end = CGPoint(x: start.x + dx, y: start.y - sin(angle) * travel)
            result.append(Streak(start: start, end: end, angle: rightward ? -angle : .pi + angle, at: time))
            time += duration + random.range(low, high)
        }
        return (result, time, duration)
    }

    override func relayout(_ context: NodeContext) {
        meteor.bounds = CGRect(x: 0, y: 0, width: 150 * spec.sizeFactor, height: 1.4 * max(spec.sizeFactor, 0.7))
        meteor.cornerRadius = meteor.bounds.height / 2
        meteor.removeAllAnimations()
        guard context.size.width > 200 else { return }
        let (streaks, loop, duration) = streaks(context)
        if context.purpose == .thumbnail, let first = streaks.first {
            // A still shows one streak mid-flight, so the gallery says "shooting stars".
            meteor.position = CGPoint(x: first.start.x + (first.end.x - first.start.x) * 0.55, y: first.start.y + (first.end.y - first.start.y) * 0.55)
            meteor.transform = CATransform3DMakeRotation(first.angle, 0, 0, 1)
            meteor.opacity = 0.75
            return
        }
        var times: [Double] = [0], positions: [CGPoint] = [streaks[0].start], angles: [Double] = [streaks[0].angle], alphas: [Double] = [0]
        var timing: [CAMediaTimingFunction] = []
        for streak in streaks {
            let t = streak.at / loop, d = duration / loop
            // Wait at the start (invisible), then streak with an ease-in.
            for (offset, progress, alpha) in [(0.0, 0.0, 0.0), (0.2, 0.04, 0.9), (0.7, 0.49, 0.7), (1.0, 1.0, 0.0)] {
                times.append(t + d * offset)
                positions.append(CGPoint(x: streak.start.x + (streak.end.x - streak.start.x) * progress, y: streak.start.y + (streak.end.y - streak.start.y) * progress))
                angles.append(streak.angle)
                alphas.append(alpha)
            }
        }
        times.append(1)
        positions.append(positions[positions.count - 1])
        angles.append(angles[angles.count - 1])
        alphas.append(0)
        timing = Array(repeating: Timing.linear, count: times.count - 1)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = positions.map { NSValue(point: $0) }
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = angles
        turn.calculationMode = .discrete
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = alphas
        for animation in [move, fade] {
            animation.keyTimes = times.map { NSNumber(value: $0) }
            animation.timingFunctions = timing
        }
        turn.keyTimes = times.map { NSNumber(value: $0) }
        let group = CAAnimationGroup()
        group.animations = [move, turn, fade]
        meteor.add(Timing.loop(group, duration: loop), forKey: "streaks")
    }

    override func setMotion(_ motion: Motion) {
        // Reduce Motion: no frozen streak hanging in the sky.
        meteor.isHidden = motion == .still && context?.purpose != .thumbnail
    }
}

// MARK: - Moon

/// A soft moon with a wide glow at `position` (default: high, a little left of center).
/// `colors[0]` lights the face, `colors[1]` the glow; `size` scales it.
final class MoonNode: Node {
    private let moon = CALayer()

    override func build(_: NodeContext) {
        let colors = spec.palette([RGBA(0xFFFDF4), RGBA(0xDDE4FF)])
        moon.contents = Artwork.moon(disc: colors[0], glow: colors.count > 1 ? colors[1] : colors[0])
        layer.addSublayer(moon)
    }

    override func relayout(_ context: NodeContext) {
        let side = 132 * spec.sizeFactor
        moon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        if let position = spec.position {
            moon.position = context.point(position)
        } else if context.topBand > 0 {
            moon.position = context.point(x: (context.size.width * 0.36).rounded(), fromTop: context.topBand / 2 + 1)
        } else {
            moon.position = context.point(UnitPoint2(x: 0.36, y: 0.1))
        }
    }

    override func setScale(_: CGFloat) { moon.contentsScale = 2 }
}

// MARK: - Sun

/// A disc in a breathing glow at `position` (default upper right). `colors[0]` tints the
/// disc, `colors[1]` the glow, so it can be a white noon sun, a red setting one or a blue
/// Earth over the lunar horizon. `size` scales the disc (glow follows); `speed` the breath.
final class SunNode: Node {
    private let glow = CALayer()
    private let disc = CALayer()

    override func build(_: NodeContext) {
        let colors = spec.palette([RGBA(0xFFF4DC), RGBA(0xFFB46A)])
        disc.contents = Artwork.sunDisc(colors[0])
        glow.contents = Artwork.sunGlow(colors.count > 1 ? colors[1] : colors[0])
        layer.addSublayer(glow)
        layer.addSublayer(disc)
    }

    override func relayout(_ context: NodeContext) {
        let radius = 34 * spec.sizeFactor
        let center = context.point(spec.position ?? UnitPoint2(x: 0.76, y: 0.28))
        disc.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        disc.position = center
        let halo = radius * 9
        glow.bounds = CGRect(x: 0, y: 0, width: halo, height: halo)
        glow.position = center
        glow.removeAllAnimations()
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.96
        breathe.toValue = 1.05
        breathe.timingFunction = Timing.easeInOut
        glow.add(Timing.loop(breathe, duration: 9 / spec.speedFactor, phase: 0.3, autoreverses: true), forKey: "breathe")
    }

    override func setScale(_: CGFloat) {
        glow.contentsScale = 2
        disc.contentsScale = 2
    }
}

// MARK: - Clouds

/// Soft procedural cloud banks drifting across in 3–6 minutes. `density` sets how many
/// (2–8), `size` how wide, `speed` how fast, `direction` 270 drifts them leftward,
/// `position.y` centers the band they fly in, `colors[0]` lights them and `colors[1]`
/// shades their undersides.
final class CloudsNode: Node {
    private var clouds: [CALayer] = []

    private struct Bank { var seed: UInt64, y: Double, width: Double, alpha: Double, crossing: Double, phase: Double }

    private var banks: [Bank] {
        var random = SplitMix(seed: seed)
        let count = Int((4 * spec.densityFactor).rounded()).clamped(2, 8)
        let center = spec.position?.y ?? 0.52
        return (0 ..< count).map { index in
            // Spread evenly through the band so banks don't stack, with a little jitter.
            let lane = (Double(index) + 0.5) / Double(count)
            return Bank(
                seed: UInt64(11 + index * 12) ^ (seed & 0xFFFF), y: min(max(center + (lane - 0.5) * 0.76 + random.range(-0.04, 0.04), 0.06), 0.94),
                width: random.range(0.38, 0.56) * spec.sizeFactor, alpha: random.range(0.5, 0.8),
                crossing: random.range(200, 360) / spec.speedFactor, phase: random.unit()
            )
        }
    }

    override func build(_: NodeContext) {
        let colors = spec.palette([.white])
        let tint = colors[0]
        let shade = colors.count > 1 ? colors[1] : tint.mixed(with: RGBA(0x8D9AB8), 0.3)
        for bank in banks {
            let cloud = CALayer()
            cloud.contentsGravity = .resize
            cloud.contents = Artwork.cloud(seed: bank.seed, tint: tint, shade: shade)
            cloud.opacity = Float(bank.alpha)
            layer.addSublayer(cloud)
            clouds.append(cloud)
        }
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        let leftward = sin(spec.directionRadians) < -0.3
        for (cloud, bank) in zip(clouds, banks) {
            let width = bank.width * max(size.width, 900)
            cloud.bounds = CGRect(x: 0, y: 0, width: width, height: width * 0.36)
            let y = size.height * (1 - bank.y)
            cloud.position = CGPoint(x: bank.phase * size.width, y: y)
            cloud.removeAnimation(forKey: "drift")
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = leftward ? size.width + width / 2 : -width / 2
            drift.toValue = leftward ? -width / 2 : size.width + width / 2
            cloud.add(Timing.loop(drift, duration: bank.crossing, phase: bank.phase), forKey: "drift")
        }
    }

    override func setScale(_: CGFloat) {}
}

// MARK: - Grain

/// Tiled monochrome noise against gradient banding. Opacity is the noise strength
/// (default 3 %); `size` scales the grain.
final class GrainNode: Node {
    override class var defaultOpacity: Double { 0.03 }

    override func build(_: NodeContext) {
        guard let noise = Artwork.noiseTile else { return }
        let side = 64 * spec.sizeFactor
        layer.backgroundColor = NSColor(patternImage: NSImage(cgImage: noise, size: NSSize(width: side, height: side))).cgColor
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

extension Double {
    static func random(in range: ClosedRange<Double>, using random: inout SplitMix) -> Double {
        random.range(range.lowerBound, range.upperBound)
    }
}
