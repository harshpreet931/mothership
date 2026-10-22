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
    private var isBuilt = false

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
        if !isBuilt {
            isBuilt = true
            build(context)
        }
        if previous?.size != context.size || previous?.topBand != context.topBand {
            relayout(context)
        }
        if previous?.scale != context.scale { setScale(context.scale) }
    }

    /// Creates sublayers once (size is known).
    func build(_: NodeContext) {}
    /// Positions everything for the context's size; called on every size change.
    func relayout(_: NodeContext) {}
    func setScale(_: CGFloat) {}
    func setMotion(_: Motion) {}
    /// The scene's gradient, for nodes that paint part of the sky themselves (the grid's floor).
    func sceneGradient(_: [GradientStop], duration _: TimeInterval) {}

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
/// breathe on their own cycles. `density` scales both counts, `size` the radii, `speed` the
/// twinkle (0: none, stars hold still), `colors` tint the tiers and twinklers in turn.
final class StarsNode: Node {
    private let tiers = (0 ..< 3).map { _ in CAShapeLayer() }
    private var twinklers: [CALayer] = []

    private var twinkles: Bool { spec.speed.map { $0 > 0.001 } ?? true }

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
            twinkler.contents = color == .white ? Artwork.softDot : TintedDot.image(color)
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
        // Speed 0.3 (the catalog's usual) twinkles at the original sky's 2.5–6 s.
        let pace = Relative.factor(spec.speed, range: 4) / Relative.factor(0.3, range: 4)
        for (index, twinkler) in twinklers.enumerated() {
            let x = twinkleRandom.range(0.02, 0.98), unitY = twinkleRandom.unit()
            let side = twinkleRandom.range(4, 7.5) * spec.sizeFactor
            let peak = twinkleRandom.range(0.55, 1)
            let duration = twinkleRandom.range(2.5, 6) / pace
            let phase = twinkleRandom.unit()
            // With a chrome band, a third sit in it, where the sky always shows.
            let inBand = band > 0 && index % 3 == 0
            let y = inBand ? 8 + unitY * max(band - 16, 1) : band + unitY * (Double(size.height) - band) * 0.72
            twinkler.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            twinkler.position = context.point(x: x * size.width, fromTop: y)
            twinkler.removeAnimation(forKey: "twinkle")
            guard twinkles else {
                twinkler.opacity = Float(peak * 0.7)
                continue
            }
            twinkler.opacity = Float(peak)
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = peak * 0.12
            twinkle.toValue = peak
            twinkle.timingFunction = Timing.easeInOut
            twinkler.add(Timing.loop(twinkle, duration: duration, phase: phase, autoreverses: true), forKey: "twinkle")
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
        Artwork.radial(context, center: CGPoint(x: 16, y: 16), radius: 16, color: color.lerp(.white, 0.35), alphas: [1, 0.55, 0.12, 0], locations: [0, 0.14, 0.42, 1])
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
        var time = random.range(0.15, 0.4) * low
        var result: [Streak] = []
        let size = context.size
        for _ in 0 ..< Self.streaks {
            let angle = random.range(0.38, 0.6)
            let travel = random.range(220, 320) * spec.sizeFactor
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
        meteor.transform = CATransform3DIdentity
        meteor.opacity = 0
        guard context.size.width > 200 else { return }
        let (streaks, loop, duration) = streaks(context)
        guard let first = streaks.first else { return }
        if context.purpose == .thumbnail {
            // A still shows one streak mid-flight, so the gallery says "shooting stars".
            meteor.position = CGPoint(x: first.start.x + (first.end.x - first.start.x) * 0.55, y: first.start.y + (first.end.y - first.start.y) * 0.55)
            meteor.transform = CATransform3DMakeRotation(first.angle, 0, 0, 1)
            meteor.opacity = 0.75
            return
        }
        meteor.position = first.start
        var times: [Double] = [0], positions: [CGPoint] = [first.start], angles: [Double] = [first.angle], alphas: [Double] = [0]
        for streak in streaks {
            let t = streak.at / loop, d = duration / loop
            // Invisible until its moment, then a streak with an ease-in.
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
        let keyTimes = times.map { NSNumber(value: $0) }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = positions.map { NSValue(point: $0) }
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = angles
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = alphas
        for animation in [move, turn, fade] { animation.keyTimes = keyTimes }
        let group = CAAnimationGroup()
        group.animations = [move, turn, fade]
        meteor.add(Timing.loop(group, duration: loop), forKey: "streaks")
    }

    override func setMotion(_ motion: Motion) {
        // Reduce Motion: no frozen streak hanging in the sky.
        meteor.isHidden = motion == .still && context?.purpose != .thumbnail
    }

    override func setScale(_ scale: CGFloat) { meteor.contentsScale = scale }
}

// MARK: - Moon

/// A soft moon at `position` (default high, a little left of center). `size` is its
/// diameter with its glow, as a fraction of the window's shorter side (default 0.12; the
/// disc is a fifth of that). One color tints it; several make it the Earth seen from the
/// Moon: ocean, its shade, then land and cloud colors.
final class MoonNode: Node {
    private let moon = CALayer()

    private var isEarth: Bool { (spec.colors?.count ?? 0) >= 2 }

    override func build(_: NodeContext) {
        let colors = spec.palette([RGBA(0xFFFDF4)])
        moon.contents = isEarth ? Artwork.earth(colors) : Artwork.moon(colors[0])
        layer.addSublayer(moon)
    }

    override func relayout(_ context: NodeContext) {
        let side = Double(min(context.size.width, context.size.height)) * (spec.size ?? 0.12)
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

/// A disc in a softly breathing glow at `position` (default upper right). `size` is the
/// disc's diameter as a fraction of the window's shorter side (default 0.07). One or two
/// colors: the disc, then the glow (a white noon sun, a red setting one, Mars's blue one).
/// Three or more: a retro sun, a gradient through them from top to bottom with slits across
/// its lower half (Synthwave). `speed` paces the breath.
final class SunNode: Node {
    private let glow = CALayer()
    private let disc = CALayer()

    private var isRetro: Bool { (spec.colors?.count ?? 0) >= 3 }

    override func build(_: NodeContext) {
        let colors = spec.palette([RGBA(0xFFF4DC), RGBA(0xFFB46A)])
        if isRetro {
            disc.contents = Artwork.retroSun(colors)
            glow.contents = Artwork.sunGlow(colors[colors.count - 1].lerp(colors[colors.count / 2], 0.4))
        } else {
            disc.contents = Artwork.sunDisc(colors[0])
            glow.contents = Artwork.sunGlow(colors.count > 1 ? colors[1] : colors[0])
        }
        layer.addSublayer(glow)
        layer.addSublayer(disc)
    }

    override func relayout(_ context: NodeContext) {
        let diameter = Double(min(context.size.width, context.size.height)) * (spec.size ?? 0.07)
        let center = context.point(spec.position ?? UnitPoint2(x: 0.76, y: 0.28))
        disc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        disc.position = center
        // A retro sun is mostly disc; a real one mostly glow.
        let halo = diameter * (isRetro ? 1.9 : 4.5)
        glow.bounds = CGRect(x: 0, y: 0, width: halo, height: halo)
        glow.position = center
        glow.opacity = isRetro ? 0.55 : 1
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

/// Soft procedural cloud banks drifting across. `density` sets how many (2–8), `size` how
/// wide, `speed` how fast (0.2 crosses in 3–6 minutes, like the original sky), `direction`
/// 270 drifts them leftward, `position.y` centers their band. `colors`: light, shade, then
/// extra lights that some banks take instead of the first.
final class CloudsNode: Node {
    private var clouds: [CALayer] = []

    private struct Bank { var seed: UInt64, y: Double, width: Double, alpha: Double, crossing: Double, phase: Double }

    private var banks: [Bank] {
        var random = SplitMix(seed: seed)
        let count = Int((4 * spec.densityFactor).rounded()).clamped(2, 8)
        let center = spec.position?.y ?? 0.52
        let pace = spec.speedFactor / Relative.factor(0.2, range: 4)
        return (0 ..< count).map { index in
            // Spread through the band so banks don't stack, with a little jitter.
            let lane = (Double(index) + 0.5) / Double(count)
            return Bank(
                seed: UInt64(11 + index * 12) ^ (seed & 0xFFFF), y: min(max(center + (lane - 0.5) * 0.76 + random.range(-0.04, 0.04), 0.06), 0.94),
                width: random.range(0.38, 0.56) * spec.sizeFactor, alpha: random.range(0.5, 0.8),
                crossing: random.range(200, 360) / pace, phase: random.unit()
            )
        }
    }

    override func build(_: NodeContext) {
        let colors = spec.palette([.white])
        let shade = colors.count > 1 ? colors[1] : colors[0].lerp(RGBA(0x8D9AB8), 0.3)
        let lights = [colors[0]] + colors.dropFirst(2)
        for (index, bank) in banks.enumerated() {
            let cloud = CALayer()
            cloud.contentsGravity = .resize
            cloud.contents = Artwork.cloud(seed: bank.seed, tint: lights[index % lights.count], shade: shade)
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
            cloud.position = CGPoint(x: bank.phase * size.width, y: size.height * (1 - bank.y))
            cloud.removeAnimation(forKey: "drift")
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = leftward ? size.width + width / 2 : -width / 2
            drift.toValue = leftward ? -width / 2 : size.width + width / 2
            cloud.add(Timing.loop(drift, duration: bank.crossing, phase: bank.phase), forKey: "drift")
        }
    }
}

// MARK: - Grain

/// Tiled noise against gradient banding. Opacity is its strength (default 3 %); `size`
/// scales the grain; a color makes it that color's tooth instead of gray.
final class GrainNode: Node {
    override class var defaultOpacity: Double { 0.03 }

    override func build(_: NodeContext) {
        guard let noise = Artwork.noiseTile(tint: spec.colors?.first) else { return }
        let side = 64 * spec.sizeFactor
        layer.backgroundColor = NSColor(patternImage: NSImage(cgImage: noise, size: NSSize(width: side, height: side))).cgColor
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
