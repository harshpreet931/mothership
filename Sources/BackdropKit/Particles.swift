import AppKit
import ThemeKit

/// How one particle kind looks and moves. Speeds are points per second at `speed` 0.5;
/// `count` is how many are alive on a 1440 × 900 view at `density` 0.5. Birth rates come
/// from it, so density per area stays the same in any window size, under a hard cap.
struct ParticleStyle {
    enum Source {
        /// Falls from above the view; `direction` tilts the fall.
        case top
        /// Rises from below the view; `direction` makes it drift sideways.
        case bottom
        /// Appears anywhere in the band between these fractions of the height (from the top).
        case area(top: Double, bottom: Double)
    }

    struct Sprite {
        var image: CGImage?
        /// Rotates as it falls (petals, leaves).
        var tumbles = false
    }

    struct Plane {
        /// Multiplies size and speed: far planes are smaller and slower.
        var depth: Double
        var opacity: Float
        /// Share of the particles.
        var share: Double
        /// Side-to-side sway of the whole plane, points; 0 for none.
        var sway: Double = 0
        var swayPeriod: Double = 7
    }

    var source: Source
    var sprites: [Sprite]
    var colors: [RGBA]
    var planes: [Plane]
    var count: Double
    var maxAlive: Int
    /// Points at scale 1 (sprites are 2× bitmaps).
    var scale: Double
    var scaleRange: Double
    var scaleSpeed: Double = 0
    var velocity: Double
    var velocityRange: Double
    var emissionRange: Double
    var spin: Double = 0
    var spinRange: Double = 0
    var alpha: Double = 1
    var alphaRange: Double = 0
    var alphaSpeed: Double = 0
    /// Fixed lifetime for area and rising kinds; falling kinds live until they've crossed.
    var lifetime: Double?
    var lifetimeRange: Double = 0
    var additive = false
    /// Short-lived glints emitted from each particle: ember flicker, firefly blinks.
    var glint: Glint?

    struct Glint {
        var rate: Double
        var lifetime: Double
        var scale: Double
        var scaleSpeed: Double
        var alphaSpeed: Double
        var color: RGBA?
    }

    @MainActor
    static func style(for particle: SceneLayer.Particle) -> ParticleStyle {
        switch particle {
        case .snow:
            ParticleStyle(
                source: .top, sprites: [Sprite(image: Artwork.flake)], colors: [.white],
                planes: [Plane(depth: 0.55, opacity: 0.55, share: 0.6, sway: 10, swayPeriod: 9), Plane(depth: 1, opacity: 0.95, share: 0.4, sway: 22, swayPeriod: 11)],
                count: 170, maxAlive: 520, scale: 0.55, scaleRange: 0.25, velocity: 48, velocityRange: 14, emissionRange: 0.3, alpha: 0.95, alphaRange: 0.1
            )
        case .rain:
            ParticleStyle(
                source: .top, sprites: [Sprite(image: Artwork.rainStreak)], colors: [RGBA(0xA9C4E8)],
                planes: [Plane(depth: 0.6, opacity: 0.35, share: 0.6), Plane(depth: 1, opacity: 0.6, share: 0.4)],
                count: 230, maxAlive: 600, scale: 0.8, scaleRange: 0.15, velocity: 1250, velocityRange: 160, emissionRange: 0.015, alpha: 0.8, alphaRange: 0.2
            )
        case .petals:
            ParticleStyle(
                source: .top, sprites: [Sprite(image: Artwork.petal(narrow: false), tumbles: true), Sprite(image: Artwork.petal(narrow: true), tumbles: true)],
                colors: [RGBA(0xFFB7C9), RGBA(0xFFD3DE), RGBA(0xF49AB4)],
                planes: [Plane(depth: 0.6, opacity: 0.7, share: 0.5, sway: 18, swayPeriod: 8), Plane(depth: 1, opacity: 1, share: 0.5, sway: 34, swayPeriod: 10)],
                count: 48, maxAlive: 200, scale: 0.6, scaleRange: 0.2, velocity: 46, velocityRange: 16, emissionRange: 0.5, spin: 0.8, spinRange: 2.4
            )
        case .embers:
            ParticleStyle(
                source: .bottom, sprites: [Sprite(image: Artwork.ember)], colors: [RGBA(0xFF8A33), RGBA(0xFFB347), RGBA(0xFF5E3A)],
                planes: [Plane(depth: 1, opacity: 1, share: 1, sway: 16, swayPeriod: 5)],
                count: 70, maxAlive: 240, scale: 0.36, scaleRange: 0.16, scaleSpeed: -0.04, velocity: 58, velocityRange: 30,
                emissionRange: 0.45, alpha: 0.95, alphaSpeed: -0.15, lifetime: 6, lifetimeRange: 2, additive: true,
                glint: Glint(rate: 3, lifetime: 0.12, scale: 0.42, scaleSpeed: 0, alphaSpeed: -7, color: RGBA(0xFFE3A0))
            )
        case .bubbles:
            ParticleStyle(
                source: .bottom, sprites: [Sprite(image: Artwork.bubble)], colors: [RGBA(0xBFEFFF), RGBA(0xE2F8FF)],
                planes: [Plane(depth: 0.6, opacity: 0.55, share: 0.55, sway: 6, swayPeriod: 3.2), Plane(depth: 1, opacity: 0.9, share: 0.45, sway: 10, swayPeriod: 4.1)],
                count: 42, maxAlive: 160, scale: 0.42, scaleRange: 0.24, scaleSpeed: 0.01, velocity: 42, velocityRange: 18, emissionRange: 0.25,
                alpha: 0.85, alphaRange: 0.15
            )
        case .fireflies:
            ParticleStyle(
                source: .area(top: 0.3, bottom: 1), sprites: [Sprite(image: Artwork.firefly)], colors: [RGBA(0xD8FF6A), RGBA(0xFFE66B)],
                planes: [Plane(depth: 1, opacity: 1, share: 1)],
                count: 30, maxAlive: 90, scale: 0.16, scaleRange: 0.05, velocity: 9, velocityRange: 6, emissionRange: 2 * .pi,
                alpha: 0.35, alphaSpeed: -0.025, lifetime: 11, lifetimeRange: 3, additive: true,
                glint: Glint(rate: 0.3, lifetime: 1.8, scale: 0.08, scaleSpeed: 0.55, alphaSpeed: -0.55, color: nil)
            )
        case .dust:
            ParticleStyle(
                source: .area(top: 0, bottom: 1), sprites: [Sprite(image: Artwork.mote)], colors: [RGBA(0xFFF3D6)],
                planes: [Plane(depth: 1, opacity: 1, share: 1)],
                count: 130, maxAlive: 360, scale: 0.45, scaleRange: 0.25, velocity: 6, velocityRange: 4, emissionRange: 2 * .pi,
                alpha: 0.45, alphaRange: 0.3, alphaSpeed: -0.025, lifetime: 16, lifetimeRange: 5
            )
        case .leaves:
            ParticleStyle(
                source: .top, sprites: [Sprite(image: Artwork.leaf(0), tumbles: true), Sprite(image: Artwork.leaf(1), tumbles: true)],
                colors: [RGBA(0xE8772E), RGBA(0xC94A2B), RGBA(0xF2B43C), RGBA(0x9C6B30)],
                planes: [Plane(depth: 0.6, opacity: 0.75, share: 0.45, sway: 24, swayPeriod: 7), Plane(depth: 1, opacity: 1, share: 0.55, sway: 46, swayPeriod: 9)],
                count: 30, maxAlive: 140, scale: 0.62, scaleRange: 0.2, velocity: 62, velocityRange: 20, emissionRange: 0.5, spin: 1, spinRange: 3
            )
        }
    }
}

/// `CAEmitterLayer` particles: one emitter per depth plane (each with its own sway), cells
/// per sprite and color. Falling kinds tilt by `direction`; rising ones drift with it.
/// Pausing stops births and freezes the live particles; stills (Reduce Motion, thumbnails)
/// hide the emitters and show a deterministic scatter instead, since emitters can't be
/// captured or frozen at a chosen moment.
final class ParticlesNode: Node {
    private let tilt = CALayer()
    private var emitters: [CAEmitterLayer] = []
    private let scatter = CALayer()
    private var scatterSize: CGSize = .zero
    private var motion: Motion = .running
    private var style: ParticleStyle { ParticleStyle.style(for: spec.particle ?? .dust) }

    override func build(_: NodeContext) {
        tilt.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.addSublayer(tilt)
        scatter.anchorPoint = .zero
        scatter.isHidden = true
        layer.addSublayer(scatter)
        let style = self.style
        emitters = style.planes.map { plane in
            let emitter = CAEmitterLayer()
            emitter.renderMode = style.additive ? .additive : .unordered
            emitter.opacity = plane.opacity
            emitter.seed = UInt32(truncatingIfNeeded: seed &+ UInt64(plane.depth * 1000))
            tilt.addSublayer(emitter)
            return emitter
        }
    }

    private var isFalling: Bool { if case .top = style.source { true } else { false } }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        let style = self.style
        // Falling kinds emit across a square that covers the view at any tilt.
        let side = isFalling ? (size.width * size.width + size.height * size.height).squareRoot() + 40 : 0
        let frame = isFalling ? CGRect(x: 0, y: 0, width: side, height: side) : CGRect(origin: .zero, size: size)
        tilt.bounds = frame
        tilt.position = CGPoint(x: size.width / 2, y: size.height / 2)
        tilt.transform = isFalling ? CATransform3DMakeRotation(spec.directionRadians, 0, 0, 1) : CATransform3DIdentity
        let areaFactor = context.area / (1440 * 900)
        let colors = spec.palette(style.colors)
        for (emitter, plane) in zip(emitters, style.planes) {
            emitter.frame = frame
            switch style.source {
            case .top:
                emitter.emitterShape = .line
                emitter.emitterPosition = CGPoint(x: frame.midX, y: frame.maxY + 20)
                emitter.emitterSize = CGSize(width: frame.width, height: 0)
            case .bottom:
                emitter.emitterShape = .line
                emitter.emitterPosition = CGPoint(x: frame.midX, y: -12)
                emitter.emitterSize = CGSize(width: frame.width * 1.1, height: 0)
            case .area(let top, let bottom):
                emitter.emitterShape = .rectangle
                emitter.emitterMode = .surface
                let y0 = (1 - bottom) * size.height, y1 = (1 - top) * size.height
                emitter.emitterPosition = CGPoint(x: size.width / 2, y: (y0 + y1) / 2)
                emitter.emitterSize = CGSize(width: size.width, height: y1 - y0)
            }
            emitter.emitterCells = cells(style: style, plane: plane, colors: colors, travel: isFalling ? side + 60 : size.height + 40, areaFactor: areaFactor)
            emitter.removeAnimation(forKey: "sway")
            if plane.sway > 0 {
                let sway = CAKeyframeAnimation(keyPath: "position.x")
                let x = emitter.position.x
                let amplitude = plane.sway * spec.sizeFactor.squareRoot()
                sway.values = [0, 1, 0, -1, 0].map { x + $0 * amplitude }
                sway.calculationMode = .cubic
                emitter.add(Timing.loop(sway, duration: plane.swayPeriod / spec.speedFactor.squareRoot(), phase: plane.depth), forKey: "sway")
            }
        }
        scatterSize = .zero
        if motion == .still { showScatter(context) }
    }

    private func cells(style: ParticleStyle, plane: ParticleStyle.Plane, colors: [RGBA], travel: Double, areaFactor: Double) -> [CAEmitterCell] {
        let speed = spec.speedFactor
        let velocity = style.velocity * plane.depth * speed
        let velocityRange = style.velocityRange * plane.depth * speed
        let lifetime: Double, range: Double
        if let fixed = style.lifetime {
            lifetime = fixed / speed.squareRoot()
            range = style.lifetimeRange / speed.squareRoot()
        } else {
            // Live until even the slowest has crossed.
            lifetime = min(travel / max(velocity - velocityRange, velocity * 0.4), 120)
            range = 0
        }
        // Alive ≈ rate × time on screen: aim for `count` per reference area, under the cap.
        let onScreen = style.lifetime.map { _ in lifetime } ?? travel / max(velocity, 1)
        var alive = style.count * spec.densityFactor * areaFactor * plane.share
        alive = min(alive, Double(style.maxAlive) * plane.share)
        let rate = alive / max(onScreen, 0.1)
        let variants = style.sprites.count * colors.count
        let tilt = isFalling ? 0.0 : spec.directionRadians
        return style.sprites.enumerated().flatMap { spriteIndex, sprite in
            colors.enumerated().map { colorIndex, color in
                let cell = CAEmitterCell()
                cell.name = "p\(spriteIndex)-\(colorIndex)"
                cell.contents = sprite.image
                cell.contentsScale = 2
                cell.color = color.cgColor
                cell.birthRate = Float(rate / Double(variants))
                cell.lifetime = Float(lifetime)
                cell.lifetimeRange = Float(range)
                cell.velocity = velocity
                cell.velocityRange = velocityRange
                switch style.source {
                case .top: cell.emissionLongitude = -.pi / 2
                case .bottom: cell.emissionLongitude = .pi / 2
                case .area: cell.emissionLongitude = 0
                }
                cell.emissionRange = style.emissionRange
                if !isFalling, spec.direction != nil {
                    // Rising and hovering kinds drift with the wind instead of tilting.
                    cell.xAcceleration = sin(tilt) * 8 * speed
                }
                cell.scale = style.scale * plane.depth * spec.sizeFactor
                cell.scaleRange = style.scaleRange * plane.depth * spec.sizeFactor
                cell.scaleSpeed = style.scaleSpeed * spec.sizeFactor
                if sprite.tumbles {
                    cell.spin = style.spin * speed
                    cell.spinRange = style.spinRange * speed
                }
                cell.alphaRange = Float(style.alphaRange)
                cell.alphaSpeed = Float(style.alphaSpeed * speed.squareRoot())
                cell.color = color.cgColor(alpha: style.alpha)
                if let glint = style.glint {
                    let spark = CAEmitterCell()
                    spark.name = "glint"
                    spark.contents = sprite.image
                    spark.contentsScale = 2
                    spark.birthRate = Float(glint.rate)
                    spark.lifetime = Float(glint.lifetime)
                    spark.velocity = 0
                    spark.scale = glint.scale * spec.sizeFactor
                    spark.scaleSpeed = glint.scaleSpeed * spec.sizeFactor
                    spark.alphaSpeed = Float(glint.alphaSpeed)
                    spark.color = (glint.color ?? color.mixed(with: .white, 0.25)).cgColor
                    cell.emitterCells = [spark]
                }
                return cell
            }
        }
    }

    override func update(to spec: SceneLayer) -> Bool {
        // Same particle kind: retune the emitters in place so the live particles keep going.
        guard spec.particle == self.spec.particle, spec.colors == self.spec.colors else { return false }
        adopt(spec)
        if let context { relayout(context) }
        return true
    }

    func stopEmitting() {
        for emitter in emitters { emitter.birthRate = 0 }
    }

    override func setMotion(_ motion: Motion) {
        self.motion = motion
        switch motion {
        case .running:
            scatter.isHidden = true
            tilt.isHidden = false
            for emitter in emitters { emitter.birthRate = 1 }
        case .paused:
            // Births stop; the frozen clock keeps the live particles where they are.
            for emitter in emitters { emitter.birthRate = 0 }
        case .still:
            for emitter in emitters { emitter.birthRate = 0 }
            tilt.isHidden = true
            if let context { showScatter(context) }
        }
    }

    // MARK: Stills

    private func showScatter(_ context: NodeContext) {
        scatter.isHidden = false
        guard scatterSize != context.size, !context.isEmpty else { return }
        scatterSize = context.size
        scatter.frame = CGRect(origin: .zero, size: context.size)
        scatter.contentsScale = context.scale
        scatter.contents = Self.drawScatter(spec: spec, style: style, seed: seed, size: context.size, scale: context.scale)
    }

    /// Where the emitters would have put particles: the same sprites, sizes, tints and
    /// tilt at deterministic positions, in the same numbers per area.
    static func drawScatter(spec: SceneLayer, style: ParticleStyle, seed: UInt64, size: CGSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded()), pixelHeight = Int((size.height * scale).rounded())
        guard let context = Artwork.bitmap(width: pixelWidth, height: pixelHeight) else { return nil }
        context.scaleBy(x: scale, y: scale)
        var random = SplitMix(seed: seed ^ 0x5CA7)
        let colors = spec.palette(style.colors)
        var tinted: [String: CGImage] = [:]
        let areaFactor = Double(size.width * size.height) / (1440 * 900)
        let tiltAngle: Double = if case .top = style.source { spec.directionRadians } else { 0 }
        for plane in style.planes {
            let count = Int((min(style.count * spec.densityFactor * areaFactor, Double(style.maxAlive)) * plane.share).rounded()).clamped(3, 400)
            for _ in 0 ..< count {
                let spriteIndex = Int(random.unit() * Double(style.sprites.count)) % style.sprites.count
                let colorIndex = Int(random.unit() * Double(colors.count)) % colors.count
                let sprite = style.sprites[spriteIndex]
                guard let image = sprite.image else { continue }
                let key = "\(spriteIndex)-\(colors[colorIndex].hex)"
                let tintedImage = tinted[key] ?? tint(image, colors[colorIndex])
                tinted[key] = tintedImage
                guard let tintedImage else { continue }
                var y = random.unit()
                if case .area(let top, let bottom) = style.source { y = top + y * (bottom - top) }
                let center = CGPoint(x: random.unit() * size.width, y: (1 - y) * size.height)
                let particleScale = max(0.05, (style.scale + random.centered() * style.scaleRange) * plane.depth * spec.sizeFactor)
                let width = Double(image.width) / 2 * particleScale, height = Double(image.height) / 2 * particleScale
                var alpha = (style.alpha + random.centered() * style.alphaRange) * Double(plane.opacity)
                if style.alphaSpeed < 0, let lifetime = style.lifetime {
                    // Partway through their lives, as they'd be on screen.
                    alpha *= max(0.2, 1 + style.alphaSpeed * lifetime * random.unit())
                }
                context.saveGState()
                context.setAlpha(max(0, min(1, alpha)))
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: sprite.tumbles ? random.range(0, 2 * .pi) : tiltAngle)
                context.draw(tintedImage, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
                context.restoreGState()
                if let glint = style.glint, random.unit() < 0.35 {
                    // A few mid-blink, as the eye would catch them.
                    let glow = glint.scale * 3 * spec.sizeFactor * Double(image.width) / 2
                    context.saveGState()
                    context.setAlpha(0.55)
                    context.draw(tintedImage, in: CGRect(x: center.x - glow / 2, y: center.y - glow / 2, width: glow, height: glow))
                    context.restoreGState()
                }
            }
        }
        return context.makeImage()
    }

    /// The sprite multiplied by `color`, keeping its alpha (what a tinted emitter cell draws).
    private static func tint(_ image: CGImage, _ color: RGBA) -> CGImage? {
        guard let context = Artwork.bitmap(width: image.width, height: image.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.multiply)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.setBlendMode(.destinationIn)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    override func setScale(_ scale: CGFloat) {
        scatter.contentsScale = scale
        if motion == .still, let context {
            scatterSize = .zero
            showScatter(context)
        }
    }
}
