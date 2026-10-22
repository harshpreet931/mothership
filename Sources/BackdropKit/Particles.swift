import AppKit
import ThemeKit

/// How one particle kind looks and moves. Speeds are points per second at `speed` 0.5;
/// `count` is how many are alive on a 1440 × 900 view at `density` 0.5. Birth rates come
/// from it, so density per area is the same in any window size, under a hard cap.
struct ParticleStyle {
    enum Source {
        /// Streams across the view along `direction` (0 falls, 90 drifts right, 180 rises),
        /// born just outside its upstream edge.
        case flow(defaultDirection: Double)
        /// Appears anywhere in the band between these fractions of the height (from the
        /// top) and wanders; `direction` gives the wander a drift.
        case area(top: Double, bottom: Double)
    }

    struct Sprite {
        var image: CGImage?
        /// Spins as it goes (petals, leaves).
        var tumbles = false
    }

    struct Plane {
        /// Multiplies size and speed: far planes are smaller and slower.
        var depth: Double
        var opacity: Float
        /// Share of the particles.
        var share: Double
        /// Side-to-side sway of the whole plane, points (0: none), and its period.
        var sway: Double = 0
        var swayPeriod: Double = 7
    }

    struct Glint {
        var rate: Double
        var lifetime: Double
        var scale: Double
        var scaleSpeed: Double
        var alphaSpeed: Double
        var color: RGBA?
    }

    var source: Source
    var sprites: [Sprite]
    var colors: [RGBA]
    var planes: [Plane]
    var count: Double
    var maxAlive: Int
    /// Sprite scale (sprites are 2× bitmaps, so 1 is the sprite's point size).
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
    /// Fixed lifetime (embers burn out, fireflies wander off); flowing kinds without one
    /// live until they've crossed the view.
    var lifetime: Double?
    var lifetimeRange: Double = 0
    var additive = false
    /// Short-lived glints emitted from each particle: ember flicker, firefly blinks.
    var glint: Glint?

    @MainActor
    static func style(for particle: SceneLayer.Particle, turn: Double) -> ParticleStyle {
        switch particle {
        case .snow:
            ParticleStyle(
                source: .flow(defaultDirection: 0), sprites: [Sprite(image: Artwork.flake)], colors: [.white],
                planes: [Plane(depth: 0.55, opacity: 0.55, share: 0.6, sway: 10, swayPeriod: 9), Plane(depth: 1, opacity: 0.95, share: 0.4, sway: 22, swayPeriod: 11)],
                count: 180, maxAlive: 520, scale: 1.0, scaleRange: 0.4, velocity: 48, velocityRange: 14, emissionRange: 0.3, alpha: 0.95, alphaRange: 0.1
            )
        case .rain:
            ParticleStyle(
                source: .flow(defaultDirection: 0), sprites: [Sprite(image: Artwork.rainStreak)], colors: [RGBA(0xA9C4E8)],
                planes: [Plane(depth: 0.6, opacity: 0.4, share: 0.6), Plane(depth: 1, opacity: 0.7, share: 0.4)],
                count: 200, maxAlive: 600, scale: 1.3, scaleRange: 0.25, velocity: 800, velocityRange: 110, emissionRange: 0.012, alpha: 0.85, alphaRange: 0.2
            )
        case .petals:
            ParticleStyle(
                source: .flow(defaultDirection: 0), sprites: [Sprite(image: Artwork.petal(narrow: false), tumbles: true), Sprite(image: Artwork.petal(narrow: true), tumbles: true)],
                colors: [RGBA(0xFFB7C9), RGBA(0xFFD3DE), RGBA(0xF49AB4)],
                planes: [Plane(depth: 0.6, opacity: 0.7, share: 0.5, sway: 18, swayPeriod: 8), Plane(depth: 1, opacity: 1, share: 0.5, sway: 34, swayPeriod: 10)],
                count: 90, maxAlive: 260, scale: 0.9, scaleRange: 0.3, velocity: 50, velocityRange: 16, emissionRange: 0.5, spin: 0.8, spinRange: 2.4
            )
        case .embers:
            ParticleStyle(
                source: .flow(defaultDirection: 180), sprites: [Sprite(image: Artwork.ember)], colors: [RGBA(0xFF8A33), RGBA(0xFFB347), RGBA(0xFF5E3A)],
                planes: [Plane(depth: 1, opacity: 1, share: 1, sway: 16, swayPeriod: 5)],
                count: 140, maxAlive: 340, scale: 1.3, scaleRange: 0.5, scaleSpeed: -0.08, velocity: 70, velocityRange: 32,
                emissionRange: 0.45, alpha: 1, alphaSpeed: -0.1, lifetime: 9, lifetimeRange: 3, additive: true,
                glint: Glint(rate: 3, lifetime: 0.12, scale: 0.8, scaleSpeed: 0, alphaSpeed: -7, color: RGBA(0xFFE3A0))
            )
        case .bubbles:
            ParticleStyle(
                source: .flow(defaultDirection: 180), sprites: [Sprite(image: Artwork.bubble(turn: turn))], colors: [RGBA(0xBFEFFF), RGBA(0xE2F8FF)],
                planes: [Plane(depth: 0.6, opacity: 0.55, share: 0.55, sway: 6, swayPeriod: 3.2), Plane(depth: 1, opacity: 0.9, share: 0.45, sway: 10, swayPeriod: 4.1)],
                count: 60, maxAlive: 200, scale: 0.5, scaleRange: 0.28, scaleSpeed: 0.01, velocity: 48, velocityRange: 18, emissionRange: 0.25,
                alpha: 0.85, alphaRange: 0.15
            )
        case .fireflies:
            ParticleStyle(
                source: .area(top: 0.3, bottom: 1), sprites: [Sprite(image: Artwork.firefly)], colors: [RGBA(0xD8FF6A), RGBA(0xFFE66B)],
                planes: [Plane(depth: 1, opacity: 1, share: 1)],
                count: 60, maxAlive: 150, scale: 0.7, scaleRange: 0.2, velocity: 12, velocityRange: 8, emissionRange: 2 * .pi,
                alpha: 0.8, alphaRange: 0.2, alphaSpeed: -0.04, lifetime: 11, lifetimeRange: 3, additive: true,
                glint: Glint(rate: 0.35, lifetime: 1.6, scale: 1, scaleSpeed: 0.5, alphaSpeed: -0.6, color: nil)
            )
        case .dust:
            ParticleStyle(
                source: .area(top: 0, bottom: 1), sprites: [Sprite(image: Artwork.mote)], colors: [RGBA(0xFFF3D6)],
                planes: [Plane(depth: 1, opacity: 1, share: 1)],
                count: 200, maxAlive: 420, scale: 1.4, scaleRange: 0.6, velocity: 8, velocityRange: 5, emissionRange: 2 * .pi,
                alpha: 0.75, alphaRange: 0.25, alphaSpeed: -0.03, lifetime: 16, lifetimeRange: 5
            )
        case .leaves:
            ParticleStyle(
                source: .flow(defaultDirection: 0), sprites: [Sprite(image: Artwork.leaf(0), tumbles: true), Sprite(image: Artwork.leaf(1), tumbles: true)],
                colors: [RGBA(0xE8772E), RGBA(0xC94A2B), RGBA(0xF2B43C), RGBA(0x9C6B30)],
                planes: [Plane(depth: 0.6, opacity: 0.75, share: 0.45, sway: 24, swayPeriod: 7), Plane(depth: 1, opacity: 1, share: 0.55, sway: 46, swayPeriod: 9)],
                count: 34, maxAlive: 160, scale: 0.75, scaleRange: 0.25, velocity: 62, velocityRange: 20, emissionRange: 0.5, spin: 1, spinRange: 3
            )
        }
    }
}

/// `CAEmitterLayer` particles: one emitter per depth plane (each with its own sway), cells
/// per sprite and color. Flowing kinds are emitted inside a layer turned to `direction`, from
/// a line just outside the view's upstream edge. Pausing stops births and freezes the live
/// particles; stills (Reduce Motion, thumbnails) hide the emitters and show a deterministic
/// scatter instead, since emitters can't be captured or frozen at a chosen moment.
final class ParticlesNode: Node {
    private let turned = CALayer()
    private(set) var emitters: [CAEmitterLayer] = []
    private let scatter = CALayer()
    private var scatterSize: CGSize = .zero
    private var motion: Motion = .running

    private var particle: SceneLayer.Particle { spec.particle ?? .dust }
    /// Radians from straight down, counterclockwise (toward the right) in layer space.
    private var turn: Double {
        let fallback: Double = if case .flow(let direction) = ParticleStyle.style(for: particle, turn: 0).source { direction } else { 0 }
        return (spec.direction ?? fallback) * .pi / 180
    }

    private var style: ParticleStyle { ParticleStyle.style(for: particle, turn: turn) }

    override func build(_: NodeContext) {
        turned.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.addSublayer(turned)
        scatter.anchorPoint = .zero
        scatter.isHidden = true
        layer.addSublayer(scatter)
        let style = self.style
        emitters = style.planes.map { plane in
            let emitter = CAEmitterLayer()
            emitter.renderMode = style.additive ? .additive : .unordered
            emitter.opacity = plane.opacity
            emitter.seed = UInt32(truncatingIfNeeded: seed &+ UInt64(plane.depth * 1000))
            turned.addSublayer(emitter)
            return emitter
        }
    }

    /// The view's extent along the flow (half) and across it, for a flow turned by `turn`.
    static func extents(_ size: CGSize, turn: Double) -> (along: Double, across: Double) {
        let s = abs(sin(turn)), c = abs(cos(turn))
        return (Double(size.width) / 2 * s + Double(size.height) / 2 * c, Double(size.width) * c + Double(size.height) * s)
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        let style = self.style
        let areaFactor = context.area / (1440 * 900)
        let colors = spec.palette(style.colors)
        let margin = 30.0
        var travel = Double(size.height)
        switch style.source {
        case .flow:
            // A square that covers the view at any angle, turned so the flow runs down it.
            let side = (size.width * size.width + size.height * size.height).squareRoot() + 2 * margin
            turned.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            turned.position = CGPoint(x: size.width / 2, y: size.height / 2)
            turned.transform = CATransform3DMakeRotation(turn, 0, 0, 1)
            let (along, across) = Self.extents(size, turn: turn)
            travel = 2 * along + 2 * margin
            for emitter in emitters {
                emitter.frame = turned.bounds
                // A thin rectangle rather than `.line`: line emitters ignore the emission
                // direction offscreen (CARenderer), and particles pile up on the line.
                emitter.emitterShape = .rectangle
                emitter.emitterMode = .surface
                emitter.emitterPosition = CGPoint(x: side / 2, y: side / 2 + along + margin)
                emitter.emitterSize = CGSize(width: across + 2 * margin, height: 2)
            }
        case .area(let top, let bottom):
            turned.transform = CATransform3DIdentity
            turned.bounds = CGRect(origin: .zero, size: size)
            turned.position = CGPoint(x: size.width / 2, y: size.height / 2)
            let y0 = (1 - bottom) * size.height, y1 = (1 - top) * size.height
            for emitter in emitters {
                emitter.frame = turned.bounds
                emitter.emitterShape = .rectangle
                emitter.emitterMode = .surface
                emitter.emitterPosition = CGPoint(x: size.width / 2, y: (y0 + y1) / 2)
                emitter.emitterSize = CGSize(width: size.width, height: y1 - y0)
            }
        }
        for (emitter, plane) in zip(emitters, style.planes) {
            install(cells(style: style, plane: plane, colors: colors, travel: travel, areaFactor: areaFactor), on: emitter)
            emitter.removeAnimation(forKey: "sway")
            guard plane.sway > 0 else { continue }
            let sway = CAKeyframeAnimation(keyPath: "position.x")
            let x = emitter.position.x
            let amplitude = plane.sway * spec.sizeFactor.squareRoot()
            sway.values = [0, 1, 0, -1, 0].map { x + $0 * amplitude }
            sway.calculationMode = .cubic
            emitter.add(Timing.loop(sway, duration: plane.swayPeriod / spec.speedFactor.squareRoot(), phase: plane.depth), forKey: "sway")
        }
        scatterSize = .zero
        if motion == .still { showScatter(context) }
    }

    private func cells(style: ParticleStyle, plane: ParticleStyle.Plane, colors: [RGBA], travel: Double, areaFactor: Double) -> [CAEmitterCell] {
        let speed = spec.speedFactor
        let velocity = style.velocity * plane.depth * speed
        let velocityRange = style.velocityRange * plane.depth * speed
        let lifetime: Double, lifetimeRange: Double, onScreen: Double
        if let fixed = style.lifetime {
            lifetime = fixed / speed.squareRoot()
            lifetimeRange = style.lifetimeRange / speed.squareRoot()
            onScreen = lifetime
        } else {
            // Live until even the slowest has crossed; on screen for the average crossing.
            lifetime = min(travel / max(velocity - velocityRange, velocity * 0.4), 240)
            lifetimeRange = 0
            onScreen = travel / max(velocity, 1)
        }
        // Alive ≈ rate × time on screen: `count` per reference area, under the cap.
        let alive = min(style.count * spec.densityFactor * areaFactor, Double(style.maxAlive)) * plane.share
        let rate = alive / max(onScreen, 0.1)
        let variants = Double(style.sprites.count * colors.count)
        let isArea: Bool = if case .area = style.source { true } else { false }
        let bodies = style.sprites.enumerated().flatMap { spriteIndex, sprite in
            colors.enumerated().map { colorIndex, color in
                let cell = CAEmitterCell()
                cell.name = "p\(spriteIndex)-\(colorIndex)"
                cell.contents = sprite.image
                cell.contentsScale = 2
                cell.birthRate = Float(rate / variants)
                cell.lifetime = Float(lifetime)
                cell.lifetimeRange = Float(lifetimeRange)
                cell.velocity = velocity
                cell.velocityRange = velocityRange
                if isArea {
                    // Wander; a direction gives the wander a drift.
                    cell.emissionLongitude = -.pi / 2 + turn
                    cell.emissionRange = spec.direction == nil ? style.emissionRange : 1.3
                } else {
                    cell.emissionLongitude = -.pi / 2
                    cell.emissionRange = style.emissionRange
                }
                cell.scale = style.scale * plane.depth * spec.sizeFactor
                cell.scaleRange = style.scaleRange * plane.depth * spec.sizeFactor
                cell.scaleSpeed = style.scaleSpeed * spec.sizeFactor
                if sprite.tumbles {
                    cell.spin = style.spin * speed.squareRoot()
                    cell.spinRange = style.spinRange * speed.squareRoot()
                }
                cell.color = color.cgColor(alpha: style.alpha)
                cell.alphaRange = Float(style.alphaRange)
                cell.alphaSpeed = Float(style.alphaSpeed * speed.squareRoot())
                return cell
            }
        }
        guard let glint = style.glint, let template = bodies.first else { return bodies }
        // Glints ride invisible carriers that move like the bodies: a cell that has sub-cells
        // is drawn untextured (a square), so the visible bodies can't carry them themselves.
        let carrier = CAEmitterCell()
        carrier.name = "carrier"
        for key in ["lifetime", "lifetimeRange", "velocity", "velocityRange", "emissionLongitude", "emissionRange", "xAcceleration", "yAcceleration"] {
            carrier.setValue(template.value(forKey: key), forKey: key)
        }
        carrier.birthRate = Float(rate * 0.6)
        // Zero size hides it; a transparent color would carry over to its glints.
        carrier.scale = 0
        let spark = CAEmitterCell()
        spark.name = "glint"
        spark.contents = style.sprites.first?.image
        spark.contentsScale = 2
        spark.birthRate = Float(glint.rate)
        spark.lifetime = Float(glint.lifetime)
        spark.velocity = 0
        spark.scale = glint.scale * plane.depth * spec.sizeFactor
        spark.scaleSpeed = glint.scaleSpeed * spec.sizeFactor
        spark.alphaSpeed = Float(glint.alphaSpeed)
        spark.color = (glint.color ?? colors[0].lerp(.white, 0.25)).cgColor
        carrier.emitterCells = [spark]
        return bodies + [carrier]
    }

    /// Cell properties a retune may change.
    private static let tunable = [
        "birthRate", "lifetime", "lifetimeRange", "velocity", "velocityRange", "emissionLongitude", "emissionRange",
        "scale", "scaleRange", "scaleSpeed", "spin", "spinRange", "color", "alphaRange", "alphaSpeed",
    ]

    /// Replacing an emitter's cells drops every live particle, so when the cells are the same
    /// set (same names) their properties change in place, through the emitter's key paths.
    private func install(_ cells: [CAEmitterCell], on emitter: CAEmitterLayer) {
        let names = cells.compactMap(\.name)
        guard let current = emitter.emitterCells, current.compactMap(\.name) == names, !names.isEmpty else {
            emitter.emitterCells = cells
            return
        }
        for cell in cells {
            guard let name = cell.name else { continue }
            for key in Self.tunable {
                emitter.setValue(cell.value(forKey: key), forKeyPath: "emitterCells.\(name).\(key)")
            }
            for sub in cell.emitterCells ?? [] {
                guard let subName = sub.name else { continue }
                for key in ["birthRate", "lifetime", "scale", "scaleSpeed", "alphaSpeed", "color"] {
                    emitter.setValue(sub.value(forKey: key), forKeyPath: "emitterCells.\(name).emitterCells.\(subName).\(key)")
                }
            }
        }
    }

    override func update(to spec: SceneLayer) -> Bool {
        // Same kind: retune the emitters in place so the live particles keep going.
        guard spec.particle == self.spec.particle else { return false }
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
            turned.isHidden = false
            for emitter in emitters { emitter.birthRate = 1 }
        case .paused:
            // Births stop; the frozen clock keeps the live particles where they are.
            for emitter in emitters { emitter.birthRate = 0 }
        case .still:
            for emitter in emitters { emitter.birthRate = 0 }
            turned.isHidden = true
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
        scatter.contents = Self.drawScatter(spec: spec, style: style, turn: turn, seed: seed, size: context.size, scale: context.scale)
    }

    /// Where the emitters would have put particles: the same sprites, sizes, tints and tilt
    /// at deterministic positions, in the same numbers per area (embers thinning out as they
    /// rise, as they burn out).
    static func drawScatter(spec: SceneLayer, style: ParticleStyle, turn: Double, seed: UInt64, size: CGSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded()), pixelHeight = Int((size.height * scale).rounded())
        guard let context = Artwork.bitmap(width: pixelWidth, height: pixelHeight) else { return nil }
        context.scaleBy(x: scale, y: scale)
        var random = SplitMix(seed: seed ^ 0x5CA7)
        let colors = spec.palette(style.colors)
        var tinted: [String: CGImage] = [:]
        let areaFactor = Double(size.width * size.height) / (1440 * 900)
        let (along, across) = extents(size, turn: turn)
        // Flow vector and its perpendicular, in layer space (y up).
        let flow = CGVector(dx: sin(turn), dy: -cos(turn)), side = CGVector(dx: cos(turn), dy: sin(turn))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Burning out: how far along the view they get before they're gone.
        let reach: Double = style.lifetime.map { min(1, style.velocity * spec.speedFactor.squareRoot() * $0 / max(2 * along, 1)) } ?? 1
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
                let point: CGPoint
                switch style.source {
                case .flow:
                    let t = reach < 1 ? pow(random.unit(), 1.4) * reach : random.unit()
                    let a = -along + t * 2 * along, b = (random.unit() - 0.5) * across
                    point = CGPoint(x: center.x + flow.dx * a + side.dx * b, y: center.y + flow.dy * a + side.dy * b)
                case .area(let top, let bottom):
                    point = CGPoint(x: random.unit() * size.width, y: (1 - (top + random.unit() * (bottom - top))) * size.height)
                }
                let particleScale = max(0.05, (style.scale + random.centered() * style.scaleRange) * plane.depth * spec.sizeFactor)
                let width = Double(image.width) / 2 * particleScale, height = Double(image.height) / 2 * particleScale
                var alpha = (style.alpha + random.centered() * style.alphaRange) * Double(plane.opacity)
                if style.alphaSpeed < 0, let lifetime = style.lifetime {
                    alpha *= max(0.2, 1 + style.alphaSpeed * lifetime * random.unit())
                }
                context.saveGState()
                context.setAlpha(max(0, min(1, alpha)))
                context.translateBy(x: point.x, y: point.y)
                context.rotate(by: sprite.tumbles ? random.range(0, 2 * .pi) : turn)
                context.draw(tintedImage, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
                context.restoreGState()
                if let glint = style.glint, random.unit() < 0.35 {
                    // A few mid-blink, as the eye would catch them.
                    let glow = (glint.scale + glint.scaleSpeed * glint.lifetime * 0.4) * spec.sizeFactor * Double(image.width) / 2
                    context.saveGState()
                    context.setAlpha(0.6)
                    context.draw(tintedImage, in: CGRect(x: point.x - glow / 2, y: point.y - glow / 2, width: glow, height: glow))
                    context.restoreGState()
                }
            }
        }
        return context.makeImage()
    }

    /// The sprite multiplied by `color`, keeping its alpha (what a tinted emitter cell draws).
    static func tint(_ image: CGImage, _ color: RGBA) -> CGImage? {
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
