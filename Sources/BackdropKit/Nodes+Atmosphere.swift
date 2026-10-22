import AppKit
import ThemeKit

// MARK: - Aurora

/// Northern lights: a few curtains, each a vertical color gradient (bright lower edge,
/// fading upward) seen through a mask of two drifting curtain sheets. The sheets slide in
/// opposite directions at different speeds, so the curtain's outline keeps reshaping; the
/// colors drift through the palette and each curtain breathes and stretches.
/// `position.y` is where the curtains' lower edge hangs (default 0.42), `density` sets how
/// many (2–6), `size` their height, `speed` everything's pace, `colors` the palette (bottom
/// to top).
final class AuroraNode: Node {
    private var ribbons: [(gradient: CAGradientLayer, sheets: [CALayer])] = []
    private let glow = CAGradientLayer()

    private var palette: [RGBA] { spec.palette([RGBA(0x3CF5A3), RGBA(0x2FD4C8), RGBA(0x7B5CFF)]) }
    private var count: Int { Int((3 * spec.densityFactor).rounded()).clamped(2, 6) }

    override func build(_: NodeContext) {
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [palette[0].cgColor(alpha: 0.16), palette[0].cgColor(alpha: 0.06), palette[0].cgColor(alpha: 0)]
        layer.addSublayer(glow)
        for index in 0 ..< count {
            let gradient = CAGradientLayer()
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.locations = [0, 0.22, 0.5, 0.8, 1]
            let mask = CALayer()
            mask.anchorPoint = .zero
            let sheets = (0 ..< 2).map { sheetIndex in
                let sheet = CALayer()
                sheet.contents = Artwork.auroraCurtain(seed: seed &+ UInt64(index * 2 + sheetIndex))
                sheet.contentsGravity = .resize
                sheet.anchorPoint = .zero
                sheet.opacity = sheetIndex == 0 ? 1 : 0.7
                mask.addSublayer(sheet)
                return sheet
            }
            gradient.mask = mask
            layer.addSublayer(gradient)
            ribbons.append((gradient, sheets))
        }
    }

    private func colors(rotation: Int, palette: [RGBA]) -> [CGColor] {
        func color(_ index: Int) -> RGBA { palette[(index + rotation) % palette.count] }
        return [color(0).cgColor(alpha: 0.95), color(0).cgColor(alpha: 0.85), color(1).cgColor(alpha: 0.55), color(2).cgColor(alpha: 0.22), color(2).cgColor(alpha: 0)]
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        var random = SplitMix(seed: seed)
        let base = 1 - (spec.position?.y ?? 0.42)
        let height = Double(size.height) * 0.62 * spec.sizeFactor
        let palette = self.palette
        glow.bounds = CGRect(x: 0, y: 0, width: size.width * 1.3, height: height * 0.9)
        glow.position = CGPoint(x: size.width * (spec.position?.x ?? 0.5), y: size.height * base + height * 0.2)
        for (index, ribbon) in ribbons.enumerated() {
            let spread = count > 1 ? Double(index) / Double(count - 1) - 0.5 : 0
            let width = Double(size.width) * random.range(0.9, 1.3)
            let edge = Double(size.height) * base + spread * Double(size.height) * 0.14 + random.range(-0.03, 0.03) * Double(size.height)
            let ribbonHeight = height * random.range(0.75, 1.1)
            let center = Double(size.width) * ((spec.position?.x ?? 0.5) + spread * 0.35 + random.range(-0.08, 0.08))
            // The curtain art's edge sits ~19 % up its height; hang that on `edge`.
            let gradient = ribbon.gradient
            gradient.anchorPoint = CGPoint(x: 0.5, y: 0.19)
            gradient.bounds = CGRect(x: 0, y: 0, width: width, height: ribbonHeight)
            gradient.position = CGPoint(x: center, y: edge)
            gradient.colors = colors(rotation: index, palette: palette)
            gradient.mask?.frame = gradient.bounds
            for (sheetIndex, sheet) in ribbon.sheets.enumerated() {
                // Two periods side by side: sliding by one period loops seamlessly.
                let period = width * random.range(1.1, 1.6)
                sheet.frame = CGRect(x: 0, y: 0, width: period * 2, height: ribbonHeight)
                sheet.removeAllAnimations()
                let slide = CABasicAnimation(keyPath: "position.x")
                let leftward = (index + sheetIndex) % 2 == 0
                slide.fromValue = leftward ? 0 : -period
                slide.toValue = leftward ? -period : 0
                sheet.add(Timing.loop(slide, duration: random.range(70, 150) / spec.speedFactor, phase: random.unit()), forKey: "slide")
            }
            gradient.removeAllAnimations()
            if palette.count > 1 {
                let drift = CAKeyframeAnimation(keyPath: "colors")
                drift.values = (0 ... palette.count).map { colors(rotation: index + $0, palette: palette) }
                gradient.add(Timing.loop(drift, duration: random.range(40, 70) / spec.speedFactor * Double(palette.count) / 3, phase: random.unit()), forKey: "drift")
            }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.55
            breathe.toValue = 1
            breathe.timingFunction = Timing.easeInOut
            gradient.add(Timing.loop(breathe, duration: random.range(7, 13) / spec.speedFactor, phase: random.unit(), autoreverses: true), forKey: "breathe")
            let stretch = CABasicAnimation(keyPath: "transform.scale.y")
            stretch.fromValue = 0.9
            stretch.toValue = 1.08
            stretch.timingFunction = Timing.easeInOut
            gradient.add(Timing.loop(stretch, duration: random.range(11, 19) / spec.speedFactor, phase: random.unit(), autoreverses: true), forKey: "stretch")
        }
    }

    override func setScale(_: CGFloat) {}
}

// MARK: - Nebula

/// Large soft color clouds around a core (`position`, default upper right), each drifting
/// on its own slow loop, breathing in scale and brightness and turning very slowly.
/// `density` sets how many (3–10), `size` how large, `speed` the pace, `colors` the gases.
final class NebulaNode: Node {
    private var blobs: [CALayer] = []

    private var count: Int { Int((6 * spec.densityFactor).rounded()).clamped(3, 10) }

    override func build(_: NodeContext) {
        let palette = spec.palette([RGBA(0x7B5CFF), RGBA(0xFF5CA8), RGBA(0x3CB8FF)])
        for index in 0 ..< count {
            let blob = CALayer()
            blob.contents = Artwork.nebula(seed: seed &+ UInt64(index), color: palette[index % palette.count])
            blob.contentsGravity = .resize
            layer.addSublayer(blob)
            blobs.append(blob)
        }
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        let longest = Double(max(size.width, size.height))
        let core = context.point(spec.position ?? UnitPoint2(x: 0.66, y: 0.34))
        var random = SplitMix(seed: seed)
        for blob in blobs {
            let side = longest * random.range(0.32, 0.62) * spec.sizeFactor
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side * random.range(0.7, 1))
            let center = CGPoint(x: core.x + random.centered() * longest * 0.2, y: core.y + random.centered() * longest * 0.13)
            blob.position = center
            blob.opacity = Float(random.range(0.55, 0.9))
            blob.removeAllAnimations()
            // A slow closed loop around the blob's home.
            let radius = longest * random.range(0.02, 0.05)
            let drift = CAKeyframeAnimation(keyPath: "position")
            let start = random.range(0, 2 * .pi)
            drift.values = (0 ... 8).map { step in
                let angle = start + Double(step) / 8 * 2 * .pi
                return NSValue(point: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.6))
            }
            drift.calculationMode = .cubic
            blob.add(Timing.loop(drift, duration: random.range(70, 150) / spec.speedFactor), forKey: "drift")
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = random.range(0.88, 0.95)
            breathe.toValue = random.range(1.05, 1.14)
            breathe.timingFunction = Timing.easeInOut
            blob.add(Timing.loop(breathe, duration: random.range(18, 34) / spec.speedFactor, phase: random.unit(), autoreverses: true), forKey: "breathe")
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = Double(blob.opacity) * 0.65
            glow.toValue = Double(blob.opacity)
            glow.timingFunction = Timing.easeInOut
            blob.add(Timing.loop(glow, duration: random.range(14, 26) / spec.speedFactor, phase: random.unit(), autoreverses: true), forKey: "glow")
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            let clockwise = random.unit() < 0.5
            turn.fromValue = 0
            turn.toValue = clockwise ? -2 * Double.pi : 2 * Double.pi
            blob.add(Timing.loop(turn, duration: random.range(240, 420) / spec.speedFactor, phase: random.unit()), forKey: "turn")
        }
    }

    override func setScale(_: CGFloat) {}
}

// MARK: - Grid

/// A synthwave floor: lines converging on a vanishing point at the horizon (`position.y`,
/// default 0.62) and crosslines flowing toward the viewer, thickening as they approach,
/// faded into the horizon, which glows. `density` sets the line spacing, `speed` the flow,
/// `size` the line weight, `colors[0]` the grid and `colors[1]` the horizon glow.
final class GridNode: Node {
    private let floor = CALayer()
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private let rails = CAShapeLayer()
    private let railGlow = CAShapeLayer()
    private var crosslines: [CAGradientLayer] = []
    private let horizon = CAGradientLayer()
    private let horizonGlow = CAGradientLayer()

    private var palette: [RGBA] { spec.palette([RGBA(0xFF3CAC), RGBA(0xFF9A5C)]) }
    private var lineCount: Int { Int((14 * spec.densityFactor.squareRoot()).rounded()).clamped(8, 24) }

    override func build(_: NodeContext) {
        let line = palette[0]
        let glowColor = palette.count > 1 ? palette[1] : line.mixed(with: .white, 0.3)
        floor.anchorPoint = .zero
        floor.masksToBounds = true
        content.anchorPoint = .zero
        fade.anchorPoint = .zero
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.85), CGColor(gray: 0, alpha: 0)]
        fade.locations = [0, 0.55, 1]
        content.mask = fade
        for shape in [railGlow, rails] {
            shape.fillColor = nil
            shape.strokeColor = line.cgColor(alpha: shape === rails ? 0.9 : 0.22)
            shape.anchorPoint = .zero
            content.addSublayer(shape)
        }
        crosslines = (0 ..< lineCount).map { _ in
            let crossline = CAGradientLayer()
            crossline.startPoint = CGPoint(x: 0.5, y: 0)
            crossline.endPoint = CGPoint(x: 0.5, y: 1)
            crossline.colors = [0, 0.3, 1, 0.3, 0].map { line.cgColor(alpha: $0) }
            crossline.locations = [0, 0.3, 0.5, 0.7, 1]
            content.addSublayer(crossline)
            return crossline
        }
        floor.addSublayer(content)
        layer.addSublayer(floor)
        horizonGlow.type = .radial
        horizonGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        horizonGlow.endPoint = CGPoint(x: 1, y: 1)
        horizonGlow.colors = [glowColor.cgColor(alpha: 0.4), glowColor.cgColor(alpha: 0.12), glowColor.cgColor(alpha: 0)]
        horizonGlow.locations = [0, 0.4, 1]
        layer.addSublayer(horizonGlow)
        horizon.startPoint = CGPoint(x: 0, y: 0.5)
        horizon.endPoint = CGPoint(x: 1, y: 0.5)
        horizon.colors = [glowColor.cgColor(alpha: 0), glowColor.mixed(with: .white, 0.35).cgColor(alpha: 0.95), glowColor.mixed(with: .white, 0.35).cgColor(alpha: 0.95), glowColor.cgColor(alpha: 0)]
        horizon.locations = [0, 0.2, 0.8, 1]
        layer.addSublayer(horizon)
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        let horizonY = Double(size.height) * (1 - (spec.position?.y ?? 0.62))
        let width = Double(size.width)
        let weight = spec.sizeFactor
        floor.frame = CGRect(x: 0, y: 0, width: width, height: max(horizonY, 1))
        content.frame = floor.bounds
        fade.frame = floor.bounds

        // Rails: from the vanishing point to the bottom edge, extended past the sides.
        let spacing = width / (11 * spec.densityFactor.squareRoot())
        let vanishing = CGPoint(x: width / 2, y: horizonY)
        let path = CGMutablePath()
        let reach = Int((6 * width / spacing).rounded(.up))
        for index in -reach ... reach {
            path.move(to: vanishing)
            path.addLine(to: CGPoint(x: width / 2 + Double(index) * spacing, y: 0))
        }
        for shape in [railGlow, rails] {
            shape.frame = floor.bounds
            shape.path = path
            shape.lineWidth = (shape === rails ? 1.1 : 4.5) * weight
        }

        // Crosslines: depth z runs from far (24) to just behind the viewer (0.8); a line at
        // depth z sits at horizon × (1 − 1/z), so they bunch at the horizon and race at the bottom.
        let samples = 48
        let far = 24.0, near = 0.8
        var heights: [Double] = [], ys: [Double] = []
        for step in 0 ... samples {
            let z = far + (near - far) * Double(step) / Double(samples)
            ys.append(horizonY * (1 - 1 / z))
            heights.append(max(0.8, 7 * weight / z))
        }
        let keyTimes = (0 ... samples).map { NSNumber(value: Double($0) / Double(samples)) }
        let period = 7 / spec.speedFactor
        for (index, crossline) in crosslines.enumerated() {
            crossline.bounds = CGRect(x: 0, y: 0, width: width, height: heights[0])
            crossline.position = CGPoint(x: width / 2, y: ys[0])
            crossline.removeAllAnimations()
            let move = CAKeyframeAnimation(keyPath: "position.y")
            move.values = ys
            move.keyTimes = keyTimes
            let thicken = CAKeyframeAnimation(keyPath: "bounds.size.height")
            thicken.values = heights
            thicken.keyTimes = keyTimes
            let group = CAAnimationGroup()
            group.animations = [move, thicken]
            crossline.add(Timing.loop(group, duration: period, phase: Double(index) / Double(crosslines.count)), forKey: "flow")
        }

        horizon.bounds = CGRect(x: 0, y: 0, width: width, height: 2 * weight)
        horizon.position = CGPoint(x: width / 2, y: horizonY)
        horizonGlow.bounds = CGRect(x: 0, y: 0, width: width * 1.2, height: Double(size.height) * 0.42)
        horizonGlow.position = CGPoint(x: width / 2, y: horizonY)
    }

    override func setScale(_ scale: CGFloat) {
        for shape in [rails, railGlow] { shape.contentsScale = scale }
    }
}

// MARK: - Digital rain

/// Sparse columns of falling glyphs, faint by default (opacity 0.14) so they never compete
/// with text. One pre-rendered glyph atlas; each column shows a strip of it and falls on its
/// own loop. `density` sets how many columns, `speed` how fast, `size` the glyph size,
/// `colors[0]` the glyph color.
final class DigitalRainNode: Node {
    override class var defaultOpacity: Double { 0.14 }
    private var columns: [CALayer] = []

    override func build(_ context: NodeContext) {
        let atlas = Artwork.glyphAtlas(spec.palette([RGBA(0x3CFF7A)])[0])
        let count = Int((Double(context.size.width) / Artwork.glyphCell.width * 0.3 * spec.densityFactor).rounded()).clamped(6, 48)
        columns = (0 ..< count).map { _ in
            let column = CALayer()
            column.contents = atlas
            column.contentsGravity = .resize
            layer.addSublayer(column)
            return column
        }
    }

    override func relayout(_ context: NodeContext) {
        let size = context.size
        let cell = CGSize(width: Artwork.glyphCell.width * spec.sizeFactor, height: Artwork.glyphCell.height * spec.sizeFactor)
        let height = cell.height * Double(Artwork.glyphsPerColumn)
        let slots = max(Int(Double(size.width) / cell.width), 1)
        var random = SplitMix(seed: seed)
        var free = Array(0 ..< slots)
        for column in columns {
            let slot = free.isEmpty ? Int(random.unit() * Double(slots)) : free.remove(at: Int(random.unit() * Double(free.count)) % free.count)
            let strip = Int(random.unit() * Double(Artwork.glyphColumns)) % Artwork.glyphColumns
            column.contentsRect = CGRect(x: Double(strip) / Double(Artwork.glyphColumns), y: 0, width: 1 / Double(Artwork.glyphColumns), height: 1)
            column.bounds = CGRect(x: 0, y: 0, width: cell.width, height: height)
            let x = (Double(slot) + 0.5) * cell.width
            column.position = CGPoint(x: x, y: Double(size.height) + height / 2)
            column.removeAllAnimations()
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = Double(size.height) + height / 2
            fall.toValue = -height / 2
            let velocity = random.range(70, 150) * spec.speedFactor
            // A pause between passes so columns don't read as a conveyor belt.
            let travel = (Double(size.height) + height) / velocity
            let group = CAAnimationGroup()
            group.animations = [fall]
            fall.duration = travel
            group.duration = travel * random.range(1.2, 2.2)
            column.add(Timing.loop(group, duration: group.duration, phase: random.unit()), forKey: "fall")
        }
    }

    override func setScale(_: CGFloat) {}
}
