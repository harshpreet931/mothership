import AppKit
import ThemeKit

/// The layer tree for one scene: the sky (gradient + glows) and a timed `canvas` holding a
/// node per `SceneLayer`. The sky sits outside the canvas so its color changes still
/// animate while motion is paused (the sun-cycle blend), and the canvas's timing is the
/// scene clock: `speed = 0` freezes every loop and particle in place.
@MainActor
final class Stage {
    let root = CALayer()
    let canvas = CALayer()
    let sky = SkyLayers()
    let purpose: Purpose
    private(set) var scene: Scene?
    private(set) var slots: [(key: String, node: Node)] = []
    private var retiring: [Node] = []
    private(set) var motion: Motion = .running
    private(set) var context: NodeContext

    init(purpose: Purpose) {
        self.purpose = purpose
        context = NodeContext(size: .zero, scale: 2, topBand: 0, purpose: purpose)
        for layer in [root, canvas] {
            layer.anchorPoint = .zero
            layer.masksToBounds = false
        }
        root.addSublayer(sky.layer)
        root.addSublayer(canvas)
    }

    var nodes: [Node] { slots.map(\.node) }

    // MARK: Layout

    func layout(size: CGSize, scale: CGFloat, topBand: CGFloat) {
        let next = NodeContext(size: size, scale: scale, topBand: topBand, purpose: purpose)
        guard next.size != context.size || next.scale != context.scale || next.topBand != context.topBand else { return }
        context = next
        CALayer.quietly {
            root.frame = CGRect(origin: .zero, size: size)
            canvas.frame = root.frame
            sky.layout(size: size)
            for node in nodes + retiring { node.layout(next) }
        }
    }

    // MARK: Scenes

    /// Shows `scene`. Matching layers (same kind, particle and occurrence) are kept: only
    /// their opacity animates, or they update in place; the rest cross-fade over `transition`.
    func apply(_ next: Scene?, transition: TimeInterval) {
        let previous = scene
        scene = next
        let fade = transition > 0 && motion == .running && previous != nil && !context.isEmpty ? transition : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let next else {
            sky.fade(to: 0, duration: fade)
            for slot in slots { retire(slot.node, fade: fade) }
            slots = []
            return
        }
        sky.fade(to: 1, duration: previous == nil && transition > 0 && motion == .running ? transition : 0)
        // Sky colors morph even while paused: they aren't motion, and it keeps the sun cycle seamless.
        sky.apply(next, duration: previous != nil ? transition : 0)

        var available = Dictionary(slots.map { ($0.key, $0.node) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        var updated: [(key: String, node: Node)] = []
        for spec in next.layers {
            let base = "\(spec.kind.rawValue)/\(spec.particle?.rawValue ?? "")"
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            let key = "\(base)#\(occurrence)"
            if let node = available.removeValue(forKey: key) {
                let oldOpacity = node.targetOpacity
                if node.spec == spec {
                    updated.append((key, node))
                    continue
                }
                if node.update(to: spec) {
                    animateOpacity(of: node.layer, from: oldOpacity, to: node.targetOpacity, duration: fade)
                    updated.append((key, node))
                    continue
                }
                retire(node, fade: fade)
            }
            let node = Node.make(spec, seed: stableSeed(key))
            node.layout(context)
            node.setMotion(motion)
            node.layer.opacity = node.targetOpacity
            if fade > 0 { animateOpacity(of: node.layer, from: 0, to: node.targetOpacity, duration: fade) }
            updated.append((key, node))
        }
        for node in available.values { retire(node, fade: fade) }
        slots = updated
        for slot in slots { slot.node.sceneGradient(next.gradient, duration: previous != nil ? transition : 0) }
        // Draw order follows the scene; retiring layers stay where they were until they go.
        var below: CALayer?
        for slot in slots {
            let layer = slot.node.layer
            let desired = below.flatMap { canvas.sublayers?.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            if layer.superlayer !== canvas || canvas.sublayers?.firstIndex(of: layer) != desired {
                canvas.insertSublayer(layer, at: UInt32(desired))
            }
            below = layer
        }
    }

    private func animateOpacity(of layer: CALayer, from: Float, to: Float, duration: TimeInterval) {
        // Mid-fade, start from what's on screen.
        let start = layer.animation(forKey: "fade") != nil ? (layer.presentation()?.opacity ?? from) : from
        layer.opacity = to
        guard duration > 0, start != to else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = Timing.easeInOut
        layer.add(animation, forKey: "fade")
    }

    private func retire(_ node: Node, fade: TimeInterval) {
        guard fade > 0 else {
            node.layer.removeFromSuperlayer()
            return
        }
        retiring.append(node)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak node] in
            MainActor.assumeIsolated {
                guard let self, let node else { return }
                node.layer.removeFromSuperlayer()
                self.retiring.removeAll { $0 === node }
            }
        }
        if let particles = node as? ParticlesNode { particles.stopEmitting() }
        animateOpacity(of: node.layer, from: node.layer.opacity, to: 0, duration: fade)
        CATransaction.commit()
    }

    /// Fades that can't finish (the clock stopped) end now.
    private func finishRetiring() {
        for node in retiring { node.layer.removeFromSuperlayer() }
        retiring = []
    }

    // MARK: Motion

    func setMotion(_ next: Motion) {
        guard next != motion else { return }
        let previous = motion
        motion = next
        CALayer.quietly {
            if next != .running { finishRetiring() }
            if previous == .running {
                let now = canvas.convertTime(CACurrentMediaTime(), from: nil)
                canvas.speed = 0
                canvas.timeOffset = now
            } else if next == .running {
                let pausedAt = canvas.timeOffset
                canvas.speed = 1
                canvas.timeOffset = 0
                canvas.beginTime = 0
                canvas.beginTime = canvas.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
            }
            for node in nodes { node.setMotion(next) }
        }
    }

    /// Stills: the clock stopped at a fixed time, so every render of a scene is identical.
    func freeze(at time: CFTimeInterval) {
        CALayer.quietly {
            canvas.speed = 0
            canvas.timeOffset = time
        }
        motion = .still
        for node in nodes { node.setMotion(.still) }
    }

    var layerCount: Int {
        func count(_ layer: CALayer) -> Int { 1 + (layer.sublayers ?? []).reduce(0) { $0 + count($1) } + (layer.mask.map(count) ?? 0) }
        return count(root)
    }
}

/// The base gradient (resampled to fixed stops so any two gradients morph) and radial glows.
@MainActor
final class SkyLayers {
    let layer = CALayer()
    let gradient = CAGradientLayer()
    private(set) var glows: [CAGradientLayer] = []
    private var specs: [Glow] = []
    private var size: CGSize = .zero
    /// The gradient on screen (or animating toward).
    private var shown: [GradientStop]?

    init() {
        layer.anchorPoint = .zero
        gradient.anchorPoint = .zero
        // macOS layers are y-up: (0.5, 1) is the top of the window.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer.addSublayer(gradient)
    }

    func layout(size: CGSize) {
        self.size = size
        layer.frame = CGRect(origin: .zero, size: size)
        gradient.frame = layer.frame
        for (glow, spec) in zip(glows, specs) { place(glow, spec) }
    }

    func fade(to opacity: Float, duration: TimeInterval) {
        guard layer.opacity != opacity else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = opacity
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        layer.add(animation, forKey: "fade")
    }

    func apply(_ scene: Scene, duration: TimeInterval) {
        if duration > 0, let shown {
            // Both gradients at the union of their stops, so the colors interpolate pairwise.
            let (from, to) = GradientSampler.aligned(shown, scene.gradient)
            let fromColors = from.colors.map(\.cgColor), toColors = to.colors.map(\.cgColor)
            let locations = to.locations.map { NSNumber(value: $0) }
            gradient.removeAnimation(forKey: "morph-colors")
            gradient.locations = locations
            gradient.colors = toColors
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = fromColors
            animation.toValue = toColors
            animation.duration = duration
            animation.timingFunction = Timing.easeInOut
            gradient.add(animation, forKey: "morph-colors")
        } else {
            let shape = GradientSampler.shape(scene.gradient)
            gradient.colors = shape.colors.map(\.cgColor)
            gradient.locations = shape.locations.map { NSNumber(value: $0) }
        }
        shown = scene.gradient

        let next = scene.glows ?? []
        if next.count == glows.count {
            for (glow, spec) in zip(glows, next) {
                let colors = Self.colors(spec)
                morph(glow, keyPath: "colors", to: colors, duration: duration) { glow.colors = colors }
                let (bounds, position) = geometry(spec)
                morph(glow, keyPath: "bounds", to: NSValue(rect: bounds), duration: duration) { glow.bounds = bounds }
                morph(glow, keyPath: "position", to: NSValue(point: position), duration: duration) { glow.position = position }
            }
        } else {
            for glow in glows { fadeOut(glow, duration: duration) }
            glows = next.map { spec in
                let glow = CAGradientLayer()
                glow.type = .radial
                glow.startPoint = CGPoint(x: 0.5, y: 0.5)
                glow.endPoint = CGPoint(x: 1, y: 1)
                glow.locations = [0, 0.38, 1]
                glow.colors = Self.colors(spec)
                place(glow, spec)
                layer.addSublayer(glow)
                if duration > 0 {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0
                    animation.toValue = 1
                    animation.duration = duration
                    glow.add(animation, forKey: "fade")
                }
                return glow
            }
        }
        specs = next
    }

    private static func colors(_ glow: Glow) -> [CGColor] {
        [glow.color.cgColor(alpha: 1), glow.color.cgColor(alpha: 0.42), glow.color.cgColor(alpha: 0)]
    }

    private func geometry(_ spec: Glow) -> (CGRect, CGPoint) {
        let radius = spec.radius * Double(max(size.width, size.height))
        return (CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), CGPoint(x: spec.center.x * size.width, y: (1 - spec.center.y) * size.height))
    }

    private func place(_ glow: CAGradientLayer, _ spec: Glow) {
        let (bounds, position) = geometry(spec)
        glow.bounds = bounds
        glow.position = position
    }

    private func morph(_ layer: CALayer, keyPath: String, to value: Any, duration: TimeInterval, set: () -> Void) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        set()
        guard duration > 0, let from else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = Timing.easeInOut
        layer.add(animation, forKey: "morph-\(keyPath)")
    }

    private func fadeOut(_ glow: CALayer, duration: TimeInterval) {
        guard duration > 0 else {
            glow.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak glow] in
            MainActor.assumeIsolated { glow?.removeFromSuperlayer() }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = glow.presentation()?.opacity ?? glow.opacity
        animation.toValue = 0
        animation.duration = duration
        glow.opacity = 0
        glow.add(animation, forKey: "fade")
        CATransaction.commit()
    }
}
